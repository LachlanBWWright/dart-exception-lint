import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/error/error.dart';

import '../analysis/inferred_throw_analyzer.dart';
import '../analysis/throw_protection.dart';
import '../analysis/throw_source_catalog.dart';
import '../analysis/throw_summary.dart';
import '../config/exception_analysis_options.dart';
import '../config/throwing_api_manifest.dart';
import '../diagnostics.dart';
import '../result.dart';
import '../utils/source_utils.dart';

class CatchAsyncErrorSourcesRule extends AnalysisRule {
  CatchAsyncErrorSourcesRule()
    : super(
        name: DartExceptionLintDiagnostics.catchAsyncErrorSources.lowerCaseName,
        description: 'Reports known async error sources without handling.',
      );

  @override
  LintCode get diagnosticCode =>
      DartExceptionLintDiagnostics.catchAsyncErrorSources;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    final optionsResult = ExceptionAnalysisOptions.loadResult(
      packageRoot: context.package?.root.path,
      currentFilePath: context.currentUnit?.file.path,
    );
    final options = switch (optionsResult) {
      Ok(value: final options) => options,
      Err() => const ExceptionAnalysisOptions(),
    };
    if (shouldSkipLintRuleForFile(
      ruleName: name,
      options: options,
      filePath: context.currentUnit?.file.path,
      packageRoot: context.package?.root.path,
    )) {
      return;
    }
    if (!options.requireAsyncErrorHandling) {
      return;
    }

    final manifestResult = ThrowingApiManifest.loadResult(
      packageRoot: context.package?.root.path,
      currentFilePath: context.currentUnit?.file.path,
    );
    final manifest = switch (manifestResult) {
      Ok(value: final manifest) => manifest,
      Err() => ThrowingApiManifest.empty(),
    };
    final analyzer = InferredThrowAnalyzer(
      manifest: manifest,
      options: options,
      featureSet: context.libraryElement!.featureSet,
      packageRootPath: context.package?.root.path,
      knownUnits: {
        for (final unit in context.allUnits) unit.file.path: unit.unit,
      },
    );
    final visitor = _Visitor(this, options, analyzer);
    registry.addCompilationUnit(this, visitor);
  }
}

final class _Visitor extends RecursiveAstVisitor<void> {
  _Visitor(this.rule, this.options, this.analyzer);

  final AnalysisRule rule;
  final ExceptionAnalysisOptions options;
  final InferredThrowAnalyzer analyzer;
  Map<Element, List<_DeferredAsyncEffect>> _deferredEffects = {};

  @override
  void visitBlockFunctionBody(BlockFunctionBody node) {
    _visitFunctionBody(node);
  }

  @override
  void visitExpressionFunctionBody(ExpressionFunctionBody node) {
    _visitFunctionBody(node);
  }

  void _visitFunctionBody(FunctionBody node) {
    final previousEffects = _deferredEffects;
    _deferredEffects = {};
    node.visitChildren(this);
    final abandonedEffects = [
      for (final effects in _deferredEffects.values) ...effects,
    ];
    _deferredEffects = previousEffects;

    for (final effect in abandonedEffects) {
      if (effect.mayEscapeScope) {
        continue;
      }
      if (isProtectedByCatch(
        effect.node,
        requireAsyncProtection: true,
        exceptionTypes: effect.exceptionTypes,
      )) {
        continue;
      }
      rule.reportAtNode(effect.node, arguments: [effect.displayName]);
    }
  }

  @override
  void visitAwaitExpression(AwaitExpression node) {
    final expression = node.expression;
    final analysis = analyzer.analyzeResolvedCall(
      expression,
      element: _elementForInvocation(expression),
      treatUnknownAsReportable: false,
      requireObservedAsyncError: true,
      includeManifestOverrides: false,
    );
    final source = ThrowSourceCatalog.matchResolvedInvocation(
      expression,
      _elementForInvocation(expression),
      options,
    );
    final storedEffect = _effectForExpression(expression);
    if (storedEffect != null) {
      for (final entry in _deferredEffects.entries.toList(growable: false)) {
        entry.value.removeWhere((effect) => identical(effect, storedEffect));
        if (entry.value.isEmpty) {
          _deferredEffects.remove(entry.key);
        }
      }
    }
    if (analysis == null &&
        (source == null || !source.confidence.isAsync) &&
        storedEffect == null) {
      return;
    }
    final displayName =
        analysis?.displayName ??
        source?.displayName ??
        storedEffect!.displayName;
    final exceptionTypes =
        analysis?.exceptionTypes ??
        source?.exceptionTypes ??
        storedEffect!.exceptionTypes;
    if (isProtectedByCatch(
      node,
      requireAsyncProtection: true,
      exceptionTypes: exceptionTypes,
    )) {
      return;
    }

    rule.reportAtNode(node, arguments: [displayName]);
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    _reportDirectAsyncSource(node, node.element, node.function);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    _reportDirectAsyncSource(
      node,
      node.constructorName.element,
      node.constructorName,
    );
  }

  @override
  void visitForStatement(ForStatement node) {
    if (node.forLoopParts is! ForEachParts) {
      return;
    }
    final parts = node.forLoopParts as ForEachParts;
    final iterable = parts.iterable;
    final analysis = analyzer.analyzeResolvedCall(
      iterable,
      element: _elementForExpression(iterable),
      treatUnknownAsReportable: false,
      requireObservedAsyncError: false,
    );
    if (analysis == null || (!analysis.isAsync && !analysis.isDeferred)) {
      return;
    }
    final requiresAsyncProtection = analysis.isAsync;
    if (!isProtectedByCatch(
      node,
      requireAsyncProtection: requiresAsyncProtection,
      exceptionTypes: analysis.exceptionTypes,
    )) {
      rule.reportAtNode(node, arguments: [analysis.displayName]);
    }
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.parent is AwaitExpression) {
      return;
    }
    if (node.parent is ForEachParts) {
      return;
    }
    if (node.parent is ReturnStatement ||
        node.parent is ExpressionFunctionBody) {
      return;
    }
    if (node.methodName.name == 'unawaited' &&
        node.argumentList.arguments.isNotEmpty) {
      final argument = node.argumentList.arguments.first;
      if (argument is! NamedArgument) {
        _reportDirectAsyncSource(
          argument.argumentExpression,
          _elementForInvocation(argument.argumentExpression),
          argument.argumentExpression,
        );
      }
      return;
    }
    // Let the outer async chain report the effect once. For example,
    // Future.error(...).then(...) should report `then`, not both nodes.
    if (node.parent case MethodInvocation(
      :final target,
    ) when identical(target, node)) {
      return;
    }

    final inferred = analyzer.analyzeResolvedCall(
      node,
      element: node.methodName.element,
      treatUnknownAsReportable: false,
      requireObservedAsyncError: false,
    );
    if (inferred case final effect? when effect.isAsync) {
      if (isProtectedByCatch(
        node,
        requireAsyncProtection: true,
        exceptionTypes: effect.exceptionTypes,
      )) {
        return;
      }
      if (_rememberStoredEffect(
        node,
        effect.displayName,
        effect.exceptionTypes,
      )) {
        return;
      }
      rule.reportAtNode(node.methodName, arguments: [effect.displayName]);
      return;
    }

    final directSource = ThrowSourceCatalog.matchResolvedInvocation(
      node,
      node.methodName.element,
      options,
    );
    final target = node.target;
    final chainedSource = switch (target) {
      MethodInvocation() => ThrowSourceCatalog.matchResolvedInvocation(
        target,
        target.methodName.element,
        options,
      ),
      InstanceCreationExpression() =>
        ThrowSourceCatalog.matchResolvedInvocation(
          target,
          target.constructorName.element,
          options,
        ),
      _ => null,
    };
    final source = directSource ?? chainedSource;
    if (source == null || !source.confidence.isAsync) {
      if (_isUnhandledListen(node)) {
        rule.reportAtNode(node.methodName, arguments: ['Stream.listen']);
      }
      return;
    }

    if (isProtectedByCatch(
      node,
      requireAsyncProtection: true,
      exceptionTypes: source.exceptionTypes,
    )) {
      return;
    }

    if (_rememberStoredEffect(
      node,
      source.displayName,
      source.exceptionTypes,
    )) {
      return;
    }

    rule.reportAtNode(node.methodName, arguments: [source.displayName]);
  }

  void _reportDirectAsyncSource(
    AstNode node,
    Element? element,
    AstNode diagnosticTarget,
  ) {
    if (node.parent is AwaitExpression) return;
    if (node.parent is ReturnStatement ||
        node.parent is ExpressionFunctionBody) {
      return;
    }
    if (node.parent case MethodInvocation(
      :final target,
    ) when identical(target, node)) {
      return;
    }
    final inferred = analyzer.analyzeResolvedCall(
      node,
      element: element,
      treatUnknownAsReportable: false,
      requireObservedAsyncError: false,
    );
    if (inferred case final effect? when effect.isAsync) {
      if (isProtectedByCatch(
        node,
        requireAsyncProtection: true,
        exceptionTypes: effect.exceptionTypes,
      )) {
        return;
      }
      if (_rememberStoredEffect(
        node,
        effect.displayName,
        effect.exceptionTypes,
      )) {
        return;
      }
      rule.reportAtNode(diagnosticTarget, arguments: [effect.displayName]);
      return;
    }
    final source = ThrowSourceCatalog.matchResolvedInvocation(
      node,
      element,
      options,
    );
    if (source == null || !source.isAsync) return;
    if (isProtectedByCatch(
      node,
      requireAsyncProtection: true,
      exceptionTypes: source.exceptionTypes,
    )) {
      return;
    }
    if (_rememberStoredEffect(
      node,
      source.displayName,
      source.exceptionTypes,
    )) {
      return;
    }
    rule.reportAtNode(diagnosticTarget, arguments: [source.displayName]);
  }

  bool _isUnhandledListen(MethodInvocation node) {
    if (node.methodName.name != 'listen') {
      return false;
    }

    if (node.target case MethodInvocation(
      :final methodName,
    ) when methodName.name == 'handleError') {
      return false;
    }

    return node.argumentList.arguments.whereType<NamedArgument>().every(
      (argument) => argument.name.lexeme != 'onError',
    );
  }

  Element? _elementForInvocation(Expression expression) {
    return switch (expression) {
      MethodInvocation(:final methodName) => methodName.element,
      FunctionExpressionInvocation() => expression.element,
      InstanceCreationExpression(:final constructorName) =>
        constructorName.element,
      _ => null,
    };
  }

  Element? _elementForExpression(Expression expression) {
    return switch (expression) {
      MethodInvocation(:final methodName) => methodName.element,
      FunctionExpressionInvocation() => expression.element,
      InstanceCreationExpression(:final constructorName) =>
        constructorName.element,
      _ => null,
    };
  }

  bool _rememberStoredEffect(
    AstNode node,
    String displayName,
    List<String> exceptionTypes,
  ) {
    final element = _storedElementFor(node);
    // A field/property is an interprocedural escape. We cannot prove where
    // it will eventually be awaited, but reporting it as an abandoned local
    // Future is incorrect because another method may own the consumption.
    if (element == null && _isEscapingAssignment(node)) {
      return true;
    }
    if (element == null) return false;
    final effect = _DeferredAsyncEffect(
      node: node,
      displayName: displayName,
      exceptionTypes: exceptionTypes,
      mayEscapeScope: element is! LocalVariableElement,
    );
    (_deferredEffects[element] ??= <_DeferredAsyncEffect>[]).add(effect);
    return true;
  }

  bool _isEscapingAssignment(AstNode node) {
    final parent = node.parent;
    return switch (parent) {
      AssignmentExpression(:final rightHandSide, :final leftHandSide)
          when identical(rightHandSide, node) =>
        switch (leftHandSide) {
          PropertyAccess() => true,
          SimpleIdentifier(:final element)
              when element == null || element is! LocalVariableElement =>
            true,
          _ => false,
        },
      _ => false,
    };
  }

  _DeferredAsyncEffect? _effectForExpression(Expression expression) {
    switch (expression) {
      case SimpleIdentifier(:final element):
        final effects = _deferredEffects[element];
        return effects == null || effects.isEmpty ? null : effects.first;
      case ParenthesizedExpression(:final expression):
        return _effectForExpression(expression);
      case PropertyAccess(:final target):
        return target == null ? null : _effectForExpression(target);
      case PrefixedIdentifier(:final prefix):
        return _effectForExpression(prefix);
      case IndexExpression(:final realTarget):
        return _effectForExpression(realTarget);
      case ConditionalExpression(:final thenExpression, :final elseExpression):
        return _effectForExpression(thenExpression) ??
            _effectForExpression(elseExpression);
      default:
        return null;
    }
  }

  Element? _storedElementFor(AstNode node) {
    AstNode? current = node;
    while (current?.parent != null) {
      final parent = current!.parent!;
      if (parent case VariableDeclaration(
        :final initializer,
      ) when identical(initializer, current)) {
        return parent.declaredFragment?.element;
      }
      if (parent case AssignmentExpression(
        :final rightHandSide,
        :final leftHandSide,
      ) when identical(rightHandSide, current)) {
        return switch (leftHandSide) {
          SimpleIdentifier(:final element) => element,
          PropertyAccess(:final propertyName) => propertyName.element,
          PrefixedIdentifier(:final identifier) => identifier.element,
          _ => null,
        };
      }
      // Do not associate a Future passed into a nested function with an
      // enclosing variable. Its ownership is either handled by that nested
      // scope or it has escaped this analysis boundary.
      if (parent is FunctionBody || parent is Statement) {
        return null;
      }
      current = parent;
    }
    return null;
  }
}

final class _DeferredAsyncEffect {
  const _DeferredAsyncEffect({
    required this.node,
    required this.displayName,
    required this.exceptionTypes,
    required this.mayEscapeScope,
  });

  final AstNode node;
  final String displayName;
  final List<String> exceptionTypes;
  final bool mayEscapeScope;
}
