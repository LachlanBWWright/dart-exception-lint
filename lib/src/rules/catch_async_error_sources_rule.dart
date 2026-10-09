import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/error.dart';

import '../analysis/inferred_throw_analyzer.dart';
import '../analysis/exception_type_labels.dart';
import '../analysis/diagnostic_emission_guard.dart';
import '../analysis/throw_protection.dart';
import '../analysis/throw_source_catalog.dart';
import '../analysis/throw_summary.dart';
import '../config/exception_analysis_options.dart';
import '../engine/exception_analysis_service.dart';
import '../engine/exception_effect.dart';
import '../engine/statement_completion.dart';
import '../engine/invocation_targets.dart';
import '../diagnostics.dart';
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
    final service = ExceptionAnalysisService.forContext(context);
    final options = service.options;
    if (shouldSkipLintRuleForFile(
      ruleName: name,
      options: options,
      filePath: context.definingUnit.file.path,
      packageRoot: context.package?.root.path,
    )) {
      return;
    }
    if (!options.requireAsyncErrorHandling) {
      return;
    }

    final visitor = _Visitor(
      this,
      options,
      service.analyzer,
      context.libraryElement!,
    );
    registry.addCompilationUnit(this, visitor);
  }
}

final class _Visitor extends RecursiveAstVisitor<void> {
  _Visitor(this.rule, this.options, this.analyzer, this.library);

  final AnalysisRule rule;
  final ExceptionAnalysisOptions options;
  final InferredThrowAnalyzer analyzer;
  final LibraryElement library;
  final DiagnosticEmissionGuard _emissions = DiagnosticEmissionGuard();
  Map<Object, List<_DeferredAsyncEffect>> _deferredEffects = {};
  Map<Object, List<_DeferredAsyncEffect>> _escapedEffects = {};
  Set<_DeferredAsyncEffect> _orphanedEffects = {};
  final Map<Element, int> _receiverVersions = {};
  final Set<Element> _safeFutureVariables = {};

  @override
  void visitPatternField(PatternField node) {
    node.visitChildren(this);
    for (final target in invocationTargets(node, library)) {
      _reportDirectAsyncSource(node, target, node);
    }
  }

  @override
  void visitConstantPattern(ConstantPattern node) {
    node.visitChildren(this);
    for (final target in invocationTargets(node, library)) {
      _reportDirectAsyncSource(node, target, node);
    }
  }

  @override
  void visitRelationalPattern(RelationalPattern node) {
    node.visitChildren(this);
    for (final target in invocationTargets(node, library)) {
      _reportDirectAsyncSource(node, target, node);
    }
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    node.visitChildren(this);
    if (node.propertyName.inGetterContext()) {
      _reportDirectAsyncSource(
        node,
        node.propertyName.element,
        node.propertyName,
      );
    }
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    node.visitChildren(this);
    if (node.identifier.inGetterContext()) {
      _reportDirectAsyncSource(node, node.identifier.element, node.identifier);
    }
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (node.inGetterContext() &&
        node.element is GetterElement &&
        node.parent is! PropertyAccess &&
        node.parent is! PrefixedIdentifier) {
      _reportDirectAsyncSource(node, node.element, node);
    }
  }

  @override
  void visitPrefixExpression(PrefixExpression node) {
    node.visitChildren(this);
    for (final target in invocationTargets(node, library)) {
      _reportDirectAsyncSource(node, target, node);
    }
  }

  @override
  void visitPostfixExpression(PostfixExpression node) {
    node.visitChildren(this);
    for (final target in invocationTargets(node, library)) {
      _reportDirectAsyncSource(node, target, node);
    }
  }

  @override
  void visitInterpolationExpression(InterpolationExpression node) {
    node.visitChildren(this);
    for (final target in invocationTargets(node, library)) {
      _reportDirectAsyncSource(node, target, node);
    }
  }

  @override
  void visitCompilationUnit(CompilationUnit node) {
    super.visitCompilationUnit(node);
    // Top-level and field initializer effects have no proven timely owner.
    // Merely declaring a consuming method cannot discharge these effects.
    for (final effects in _escapedEffects.values) {
      for (final effect in effects) {
        _reportAbandonedEffect(effect);
      }
    }
  }

  void _reportAbandonedEffect(_DeferredAsyncEffect effect) {
    if (effect.isProtectedAt(effect.node)) {
      return;
    }
    if (_emissions.claim(effect.node)) {
      rule.reportAtNode(
        effect.node,
        arguments: [
          effect.displayName,
          exceptionTypeLabel(effect.exceptionTypes),
        ],
      );
    }
  }

  @override
  void visitBlock(Block node) {
    for (final statement in node.statements) {
      statement.accept(this);
      if (!statementCompletion(statement).canCompleteNormally) break;
    }
  }

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
    final previousEscapes = _escapedEffects;
    final previousOrphans = _orphanedEffects;
    _orphanedEffects = {};
    _deferredEffects = {};
    _escapedEffects = {};
    node.visitChildren(this);
    final abandonedEffects = {
      for (final effects in _deferredEffects.values) ...effects,
      for (final effects in _escapedEffects.values) ...effects,
      ..._orphanedEffects,
    };
    _deferredEffects = previousEffects;
    _escapedEffects = previousEscapes;
    _orphanedEffects = previousOrphans;

    for (final effect in abandonedEffects) {
      _reportAbandonedEffect(effect);
    }
  }

  Map<Object, List<_DeferredAsyncEffect>> _copyEffects(
    Map<Object, List<_DeferredAsyncEffect>> effects,
  ) => {
    for (final entry in effects.entries) entry.key: [...entry.value],
  };

  Map<Object, List<_DeferredAsyncEffect>> _joinEffects(
    Map<Object, List<_DeferredAsyncEffect>> left,
    Map<Object, List<_DeferredAsyncEffect>> right,
  ) => {
    for (final key in {...left.keys, ...right.keys})
      key: {...?left[key], ...?right[key]}.toList(),
  };

  void _visitAlternatives(Iterable<AstNode?> alternatives) {
    final before = _copyEffects(_deferredEffects);
    final beforeEscapes = _copyEffects(_escapedEffects);
    final beforeOrphans = {..._orphanedEffects};
    var joined = <Object, List<_DeferredAsyncEffect>>{};
    var joinedEscapes = <Object, List<_DeferredAsyncEffect>>{};
    final joinedOrphans = <_DeferredAsyncEffect>{};
    for (final alternative in alternatives) {
      _deferredEffects = _copyEffects(before);
      _escapedEffects = _copyEffects(beforeEscapes);
      _orphanedEffects = {...beforeOrphans};
      alternative?.accept(this);
      joined = _joinEffects(joined, _deferredEffects);
      joinedEscapes = _joinEffects(joinedEscapes, _escapedEffects);
      joinedOrphans.addAll(_orphanedEffects);
    }
    _deferredEffects = joined;
    _escapedEffects = joinedEscapes;
    _orphanedEffects = joinedOrphans;
  }

  @override
  void visitConditionalExpression(ConditionalExpression node) {
    node.condition.accept(this);
    if (node.condition case BooleanLiteral(:final value)) {
      (value ? node.thenExpression : node.elseExpression).accept(this);
    } else {
      _visitAlternatives([node.thenExpression, node.elseExpression]);
    }
  }

  @override
  void visitBinaryExpression(BinaryExpression node) {
    node.leftOperand.accept(this);
    final operator = node.operator.lexeme;
    if (operator == '&&' || operator == '||') {
      if (node.leftOperand case BooleanLiteral(:final value)) {
        if ((operator == '&&' && value) || (operator == '||' && !value)) {
          node.rightOperand.accept(this);
        }
      } else {
        _visitAlternatives([node.rightOperand, null]);
      }
    } else if (operator == '??') {
      _visitAlternatives([node.rightOperand, null]);
    } else {
      node.rightOperand.accept(this);
    }
  }

  @override
  void visitSwitchStatement(SwitchStatement node) {
    node.expression.accept(this);
    _visitAlternatives([
      ...node.members,
      if (!node.members.any((member) => member is SwitchDefault)) null,
    ]);
  }

  @override
  void visitSwitchExpression(SwitchExpression node) {
    node.expression.accept(this);
    _visitAlternatives(node.cases);
  }

  @override
  void visitIfStatement(IfStatement node) {
    node.expression.accept(this);
    node.caseClause?.accept(this);
    if (node.expression is BooleanLiteral) {
      if ((node.expression as BooleanLiteral).value) {
        node.thenStatement.accept(this);
      } else {
        node.elseStatement?.accept(this);
      }
      return;
    }
    _visitAlternatives([node.thenStatement, node.elseStatement]);
  }

  @override
  void visitWhileStatement(WhileStatement node) {
    node.condition.accept(this);
    if (node.condition is BooleanLiteral &&
        !(node.condition as BooleanLiteral).value) {
      return;
    }
    final before = _copyEffects(_deferredEffects);
    final escapes = _copyEffects(_escapedEffects);
    final orphans = {..._orphanedEffects};
    node.body.accept(this);
    // The body may execute zero times: a consumer inside it cannot establish
    // ownership for an effect created outside it.
    _deferredEffects = _joinEffects(before, _deferredEffects);
    _escapedEffects = _joinEffects(escapes, _escapedEffects);
    _orphanedEffects.addAll(orphans);
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    node.visitChildren(this);
    final initializer = node.initializer;
    final variable = node.declaredFragment?.element;
    if (variable != null && initializer != null) {
      final source = ThrowSourceCatalog.matchResolvedInvocation(
        initializer,
        _elementForInvocation(initializer),
        options,
      );
      if (source?.confidence == ThrowConfidence.noObviousThrow ||
          (initializer is SimpleIdentifier &&
              _safeFutureVariables.contains(initializer.element))) {
        _safeFutureVariables.add(variable);
      }
    }
    if (initializer is SimpleIdentifier && variable != null) {
      final source = _storageElement(initializer.element);
      final effects = _deferredEffects[source] ?? _escapedEffects[source];
      if (effects != null) _deferredEffects[variable] = [...effects];
    }
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    node.visitChildren(this);
    for (final target in invocationTargets(node, library)) {
      _reportDirectAsyncSource(node, target, node);
    }
    if (_storageElement(node.writeElement) case final VariableElement element) {
      _receiverVersions[element] = (_receiverVersions[element] ?? 0) + 1;
      _safeFutureVariables.remove(element);
    }
    final source = node.rightHandSide;
    final destination = _storageElement(node.writeElement);
    if (source is SimpleIdentifier && destination is LocalVariableElement) {
      final effects = _deferredEffects[_storageElement(source.element)];
      if (effects != null) {
        _orphanedEffects.addAll(_deferredEffects[destination] ?? const []);
        _deferredEffects[destination] = [...effects];
      }
    }
  }

  bool _isUnverifiedFuture(
    Expression expression,
    ThrowSource? source,
    InferredCallAnalysis? analysis,
  ) {
    if (analysis != null || source != null) return false;
    final type = expression.staticType;
    if (type is! InterfaceType ||
        (!type.isDartAsyncFuture && !type.isDartAsyncFutureOr)) {
      return false;
    }
    if (expression is SimpleIdentifier &&
        _safeFutureVariables.contains(expression.element)) {
      return false;
    }
    final element = _elementForInvocation(expression);
    if (element is ExecutableElement) {
      final summary = analyzer.summarizeExecutable(element);
      if (summary.complete && !summary.hasAnyThrowSource) return false;
    }
    return true;
  }

  @override
  void visitAwaitExpression(AwaitExpression node) {
    node.visitChildren(this);
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
    final storedEffect =
        _effectForExpression(expression) ??
        (options.reportUnknown &&
                _isUnverifiedFuture(expression, source, analysis)
            ? _DeferredAsyncEffect(
                node: expression,
                displayName: 'unverified Future input',
                exceptionTypes: const [],
                exceptionSupertypes: const {},
              )
            : null);
    if (storedEffect != null) _consumeStoredEffect(storedEffect);
    if (analysis == null &&
        (source == null || !source.confidence.isAsync) &&
        storedEffect == null) {
      return;
    }
    final exceptionSupertypes =
        analysis?.exceptionSupertypes ??
        source?.exceptionSupertypes ??
        storedEffect!.exceptionSupertypes;
    final displayName =
        analysis?.displayName ??
        source?.displayName ??
        storedEffect!.displayName;
    final exceptionTypes =
        analysis?.exceptionTypes ??
        source?.exceptionTypes ??
        storedEffect!.exceptionTypes;
    final protected = analysis != null
        ? analysis.isProtectedAt(node, requireAsyncProtection: true)
        : source == null && storedEffect != null
        ? storedEffect.isProtectedAt(node)
        : isProtectedByCatch(
            node,
            requireAsyncProtection: true,
            channel: source?.channel,
            exceptionTypes: exceptionTypes,
            resolvedExceptionTypes:
                analysis?.resolvedExceptionTypes ??
                source?.resolvedExceptionTypes ??
                storedEffect!.resolvedExceptionTypes,
            exceptionSupertypes: exceptionSupertypes,
          );
    if (protected) return;

    if (_emissions.claim(node)) {
      rule.reportAtNode(
        node,
        arguments: [displayName, exceptionTypeLabel(exceptionTypes)],
      );
    }
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    node.visitChildren(this);
    _reportDirectAsyncSource(node, node.element, node.function);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    node.visitChildren(this);
    _reportDirectAsyncSource(
      node,
      node.constructorName.element,
      node.constructorName,
    );
  }

  @override
  void visitForStatement(ForStatement node) {
    node.forLoopParts.accept(this);
    final before = _copyEffects(_deferredEffects);
    final escapes = _copyEffects(_escapedEffects);
    final orphans = {..._orphanedEffects};
    node.body.accept(this);
    _deferredEffects = _joinEffects(before, _deferredEffects);
    _escapedEffects = _joinEffects(escapes, _escapedEffects);
    _orphanedEffects.addAll(orphans);
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
    if (!analysis.isProtectedAt(
      node,
      requireAsyncProtection: analysis.isAsync,
    )) {
      if (_emissions.claim(node)) {
        rule.reportAtNode(
          node,
          arguments: [
            analysis.displayName,
            exceptionTypeLabel(analysis.exceptionTypes),
          ],
        );
      }
    }
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    node.visitChildren(this);
    if (node.parent is AwaitExpression) {
      return;
    }
    if (node.parent is ForEachParts) {
      return;
    }
    final handledTarget = node.realTarget;
    if (handledTarget != null && hasUnconditionalAsyncErrorHandler(node)) {
      final effect = _effectForExpression(handledTarget);
      if (effect != null) _consumeStoredEffect(effect);
    }
    // Let the outer async chain report the effect once. For example,
    // Future.error(...).then(...) should report `then`, not both nodes.
    if (node.parent case MethodInvocation(
      :final target,
    ) when identical(target, node)) {
      return;
    }

    final method = node.methodName.element;
    if (method?.library?.uri.toString() == 'dart:async' &&
        method?.enclosingElement?.name == 'Stream' &&
        method?.name == 'listen' &&
        !_isUnhandledListen(node)) {
      return;
    }

    final inferred = analyzer.analyzeResolvedCall(
      node,
      element: node.methodName.element,
      treatUnknownAsReportable: false,
      requireObservedAsyncError: true,
    );
    if (inferred case final effect? when effect.isAsync) {
      if (effect.isProtectedAt(node, requireAsyncProtection: true)) {
        return;
      }
      if (_rememberStoredEffect(
        node,
        effect.displayName,
        effect.exceptionTypes,
        effect.exceptionSupertypes,
        resolvedExceptionTypes: effect.resolvedExceptionTypes,
        channel: effect.channel,
        analysis: effect,
      )) {
        return;
      }
      if (_emissions.claim(node.methodName)) {
        rule.reportAtNode(
          node.methodName,
          arguments: [
            effect.displayName,
            exceptionTypeLabel(effect.exceptionTypes),
          ],
        );
      }
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
        if (_emissions.claim(node.methodName)) {
          rule.reportAtNode(
            node.methodName,
            arguments: ['Stream.listen', 'an exception'],
          );
        }
      }
      return;
    }

    // Stream.listen has dedicated handling below so an explicit onError
    // callback is respected. Treating it like every other async operation
    // would report already-handled listeners.
    if (source.displayName == 'Stream.listen' && !_isUnhandledListen(node)) {
      return;
    }

    if (isProtectedByCatch(
      node,
      requireAsyncProtection: true,
      channel: source.channel,
      exceptionTypes: source.exceptionTypes,
      resolvedExceptionTypes: source.resolvedExceptionTypes,
      exceptionSupertypes: source.exceptionSupertypes,
    )) {
      return;
    }

    if (_rememberStoredEffect(
      node,
      source.displayName,
      source.exceptionTypes,
      source.exceptionSupertypes,
      resolvedExceptionTypes: source.resolvedExceptionTypes,
      channel: source.channel,
    )) {
      return;
    }

    if (_emissions.claim(node.methodName)) {
      rule.reportAtNode(
        node.methodName,
        arguments: [
          source.displayName,
          exceptionTypeLabel(source.exceptionTypes),
        ],
      );
    }
  }

  void _reportDirectAsyncSource(
    AstNode node,
    Element? element,
    AstNode diagnosticTarget,
  ) {
    if (node.parent is AwaitExpression) return;
    if (node.parent case MethodInvocation(
      :final target,
    ) when identical(target, node)) {
      return;
    }
    final inferred = analyzer.analyzeResolvedCall(
      node,
      element: element,
      treatUnknownAsReportable: false,
      requireObservedAsyncError: true,
    );
    if (inferred case final effect? when effect.isAsync) {
      if (effect.isProtectedAt(node, requireAsyncProtection: true)) {
        return;
      }
      if (_rememberStoredEffect(
        node,
        effect.displayName,
        effect.exceptionTypes,
        effect.exceptionSupertypes,
        resolvedExceptionTypes: effect.resolvedExceptionTypes,
        channel: effect.channel,
        analysis: effect,
      )) {
        return;
      }
      if (_emissions.claim(diagnosticTarget)) {
        rule.reportAtNode(
          diagnosticTarget,
          arguments: [
            effect.displayName,
            exceptionTypeLabel(effect.exceptionTypes),
          ],
        );
      }
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
      channel: source.channel,
      exceptionTypes: source.exceptionTypes,
      resolvedExceptionTypes: source.resolvedExceptionTypes,
      exceptionSupertypes: source.exceptionSupertypes,
    )) {
      return;
    }
    if (_rememberStoredEffect(
      node,
      source.displayName,
      source.exceptionTypes,
      source.exceptionSupertypes,
      resolvedExceptionTypes: source.resolvedExceptionTypes,
      channel: source.channel,
    )) {
      return;
    }
    if (_emissions.claim(diagnosticTarget)) {
      rule.reportAtNode(
        diagnosticTarget,
        arguments: [
          source.displayName,
          exceptionTypeLabel(source.exceptionTypes),
        ],
      );
    }
  }

  bool _isUnhandledListen(MethodInvocation node) {
    if (node.methodName.name != 'listen' ||
        node.methodName.element?.library?.uri.toString() != 'dart:async' ||
        node.methodName.element?.enclosingElement?.name != 'Stream') {
      return false;
    }

    if (node.target case MethodInvocation(
      :final methodName,
    ) when methodName.name == 'handleError') {
      if (hasUnconditionalAsyncErrorHandler(node.target as MethodInvocation)) {
        return false;
      }
    }

    final onErrorArguments = node.argumentList.arguments
        .whereType<NamedArgument>()
        .where((argument) => argument.name.lexeme == 'onError')
        .toList(growable: false);
    if (onErrorArguments.isEmpty) return true;
    final onError = onErrorArguments.first;
    // `onError: null` is equivalent to omitting the handler; merely seeing the
    // named argument is not proof that the asynchronous error is consumed.
    return _isNullLikeExpression(onError.argumentExpression);
  }

  bool _isNullLikeExpression(AstNode node) {
    return node is NullLiteral ||
        (node is AsExpression && _isNullLikeExpression(node.expression));
  }

  Element? _elementForInvocation(Expression expression) {
    return switch (expression) {
      MethodInvocation(:final methodName) => methodName.element,
      FunctionExpressionInvocation() => expression.element,
      InstanceCreationExpression(:final constructorName) =>
        constructorName.element,
      PropertyAccess(:final propertyName) => propertyName.element,
      PrefixedIdentifier(:final identifier) => identifier.element,
      SimpleIdentifier(:final element) => element,
      IndexExpression() => expression.element,
      ParenthesizedExpression(:final expression) => _elementForInvocation(
        expression,
      ),
      _ => null,
    };
  }

  Element? _elementForExpression(Expression expression) {
    return _elementForInvocation(expression);
  }

  bool _rememberStoredEffect(
    AstNode node,
    String displayName,
    List<String> exceptionTypes,
    Map<String, List<String>> exceptionSupertypes, {
    List<DartType> resolvedExceptionTypes = const [],
    ExceptionChannel? channel,
    InferredCallAnalysis? analysis,
  }) {
    final element = _storageElement(_storedElementFor(node));
    if (element == null) return false;
    final key = element is FieldElement
        ? _fieldStorageKey(node, element)
        : element;
    final effect = _DeferredAsyncEffect(
      node: node,
      displayName: displayName,
      exceptionTypes: exceptionTypes,
      exceptionSupertypes: exceptionSupertypes,
      resolvedExceptionTypes: resolvedExceptionTypes,
      channel: channel,
      analysis: analysis,
    );
    final destination = element is LocalVariableElement
        ? _deferredEffects
        : _escapedEffects;
    if (node.parent is AssignmentExpression) {
      _orphanedEffects.addAll(destination[key] ?? const []);
      destination[key] = [effect];
    } else {
      (destination[key] ??= <_DeferredAsyncEffect>[]).add(effect);
    }
    return true;
  }

  void _consumeStoredEffect(_DeferredAsyncEffect effect) {
    _orphanedEffects.remove(effect);
    for (final effects in [_deferredEffects, _escapedEffects]) {
      for (final entry in effects.entries.toList(growable: false)) {
        entry.value.removeWhere((candidate) => identical(candidate, effect));
        if (entry.value.isEmpty) effects.remove(entry.key);
      }
    }
  }

  Element? _storageElement(Element? element) =>
      element is PropertyAccessorElement
      ? element.variable.baseElement
      : element?.baseElement;

  Object _fieldKey(FieldElement field, Expression? receiver) {
    if (field.isStatic) return (field, 'static');
    if (receiver == null || receiver is ThisExpression) return (field, 'this');
    final element = receiver is SimpleIdentifier ? receiver.element : null;
    if (element != null) {
      return (
        field,
        (element.baseElement, _receiverVersions[element.baseElement] ?? 0),
      );
    }
    // Evaluating an arbitrary receiver expression twice need not produce the
    // same instance. Do not consume ownership from a different evaluation.
    return (field, receiver.offset);
  }

  Object _fieldStorageKey(AstNode node, FieldElement field) {
    AstNode? current = node.parent;
    while (current != null && current is! FunctionBody) {
      if (current is AssignmentExpression) {
        final left = current.leftHandSide;
        return _fieldKey(field, switch (left) {
          PropertyAccess() => left.realTarget,
          PrefixedIdentifier() => left.prefix,
          _ => null,
        });
      }
      if (current is VariableDeclaration) break;
      current = current.parent;
    }
    return _fieldKey(field, null);
  }

  _DeferredAsyncEffect? _effectForElement(
    Element? element, [
    Expression? receiver,
  ]) {
    final variable = _storageElement(element);
    final key = variable is FieldElement
        ? _fieldKey(variable, receiver)
        : variable;
    final effects = _deferredEffects[key] ?? _escapedEffects[key];
    return effects == null || effects.isEmpty ? null : effects.first;
  }

  _DeferredAsyncEffect? _effectForExpression(Expression expression) {
    switch (expression) {
      case SimpleIdentifier(:final element):
        return _effectForElement(element);
      case ParenthesizedExpression(:final expression):
        return _effectForExpression(expression);
      case PropertyAccess(:final target, :final propertyName):
        return _effectForElement(propertyName.element, target) ??
            (target == null ? null : _effectForExpression(target));
      case PrefixedIdentifier(:final prefix, :final identifier):
        return _effectForElement(identifier.element, prefix) ??
            _effectForExpression(prefix);
      case IndexExpression(:final realTarget):
        return _effectForExpression(realTarget);
      case PostfixExpression(:final operator, :final operand)
          when operator.lexeme == '!':
        return _effectForExpression(operand);
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
        return parent.writeElement ??
            switch (leftHandSide) {
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
    required this.exceptionSupertypes,
    this.resolvedExceptionTypes = const [],
    this.channel,
    this.analysis,
  });

  final AstNode node;
  final String displayName;
  final List<String> exceptionTypes;
  final Map<String, List<String>> exceptionSupertypes;
  final List<DartType> resolvedExceptionTypes;
  final ExceptionChannel? channel;
  final InferredCallAnalysis? analysis;

  bool isProtectedAt(AstNode consumer) =>
      analysis?.isProtectedAt(consumer, requireAsyncProtection: true) ??
      isProtectedByCatch(
        consumer,
        requireAsyncProtection: true,
        channel: channel,
        exceptionTypes: exceptionTypes,
        resolvedExceptionTypes: resolvedExceptionTypes,
        exceptionSupertypes: exceptionSupertypes,
      );
}
