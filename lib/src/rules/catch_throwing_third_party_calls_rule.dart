import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/error.dart';

import '../config/config_failures.dart';
import '../analysis/diagnostic_emission_guard.dart';
import '../analysis/resolved_callable.dart';
import '../engine/invocation_targets.dart';
import '../analysis/throw_summary.dart';
import '../config/exception_analysis_options.dart';
import '../config/throwing_api_manifest.dart';
import '../engine/effect_containment.dart';
import '../diagnostics.dart';
import '../result.dart';
import '../utils/source_utils.dart';

class CatchThrowingThirdPartyCallsRule extends AnalysisRule {
  CatchThrowingThirdPartyCallsRule({ThrowingApiManifestLoader? loader})
    : loader = loader ?? ThrowingApiManifestLoader(),
      super(
        name: DartExceptionLintDiagnostics
            .catchThrowingThirdPartyCalls
            .lowerCaseName,
        description:
            'Reports configured third-party throwing API calls outside try/catch.',
      );

  final ThrowingApiManifestLoader loader;

  @override
  LintCode get diagnosticCode =>
      DartExceptionLintDiagnostics.catchThrowingThirdPartyCalls;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    final options = switch (ExceptionAnalysisOptions.loadResult(
      packageRoot: context.package?.root.path,
      currentFilePath: context.definingUnit.file.path,
    )) {
      Ok(value: final options) => options,
      Err() => const ExceptionAnalysisOptions(),
    };
    if (shouldSkipLintRuleForFile(
      ruleName: name,
      options: options,
      filePath: context.definingUnit.file.path,
      packageRoot: context.package?.root.path,
    )) {
      return;
    }

    final manifest = switch (loader.load(
      context.package?.root.path,
      context.definingUnit.file.path,
    )) {
      Ok(value: final manifest) => manifest,
      Err() => ThrowingApiManifest.empty(),
    };
    if (manifest.apis.isEmpty) {
      return;
    }

    final visitor = _Visitor(this, manifest, options, context.libraryElement!);
    registry.addMethodInvocation(this, visitor);
    registry.addFunctionExpressionInvocation(this, visitor);
    registry.addInstanceCreationExpression(this, visitor);
    registry.addPropertyAccess(this, visitor);
    registry.addPrefixedIdentifier(this, visitor);
    registry.addBinaryExpression(this, visitor);
    registry.addIndexExpression(this, visitor);
    registry.addPatternField(this, visitor);
    registry.addRelationalPattern(this, visitor);
    registry.addConstantPattern(this, visitor);
    registry.addAssignmentExpression(this, visitor);
    registry.addPrefixExpression(this, visitor);
    registry.addPostfixExpression(this, visitor);
  }
}

class ThrowingApiManifestLoader {
  const ThrowingApiManifestLoader();

  Result<ThrowingApiManifest, ManifestFailure> load(
    String? packageRoot,
    String? currentFilePath,
  ) {
    return ThrowingApiManifest.loadResult(
      packageRoot: packageRoot,
      currentFilePath: currentFilePath,
    );
  }
}

final class _Visitor extends SimpleAstVisitor<void> {
  _Visitor(this.rule, this.manifest, this.options, this.library);

  final AnalysisRule rule;
  final ThrowingApiManifest manifest;
  final ExceptionAnalysisOptions options;
  final LibraryElement library;
  final DiagnosticEmissionGuard _emissions = DiagnosticEmissionGuard();

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    _reportIfNeeded(
      node,
      element: node.element,
      diagnosticTarget: node.function,
    );
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    _reportIfNeeded(
      node,
      element: node.constructorName.element,
      diagnosticTarget: node.constructorName,
    );
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    _reportIfNeeded(
      node,
      element: node.methodName.element,
      diagnosticTarget: node.methodName,
    );
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    _reportIfNeeded(
      node,
      element: node.propertyName.element,
      diagnosticTarget: node,
    );
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    _reportIfNeeded(
      node,
      element: node.identifier.element,
      diagnosticTarget: node,
    );
  }

  @override
  void visitBinaryExpression(BinaryExpression node) {
    _reportIfNeeded(node, element: node.element, diagnosticTarget: node);
  }

  @override
  void visitIndexExpression(IndexExpression node) {
    _reportIfNeeded(node, element: node.element, diagnosticTarget: node);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    for (final element in invocationTargets(node, library)) {
      _reportIfNeeded(node, element: element, diagnosticTarget: node);
    }
  }

  @override
  void visitPrefixExpression(PrefixExpression node) {
    for (final element in invocationTargets(node, library)) {
      _reportIfNeeded(node, element: element, diagnosticTarget: node);
    }
  }

  @override
  void visitPostfixExpression(PostfixExpression node) {
    for (final element in invocationTargets(node, library)) {
      _reportIfNeeded(node, element: element, diagnosticTarget: node);
    }
  }

  @override
  void visitPatternField(PatternField node) {
    for (final element in invocationTargets(node, library)) {
      _reportIfNeeded(node, element: element, diagnosticTarget: node);
    }
  }

  @override
  void visitRelationalPattern(RelationalPattern node) {
    for (final element in invocationTargets(node, library)) {
      _reportIfNeeded(node, element: element, diagnosticTarget: node);
    }
  }

  @override
  void visitConstantPattern(ConstantPattern node) {
    for (final element in invocationTargets(node, library)) {
      _reportIfNeeded(node, element: element, diagnosticTarget: node);
    }
  }

  void _reportIfNeeded(
    AstNode node, {
    required Element? element,
    required AstNode diagnosticTarget,
  }) {
    final callable = ResolvedCallable.tryCreate(element);
    final matchedSpec = callable == null
        ? _findSyntaxFallback(node)
        : _findMatch(callable);
    if (matchedSpec == null) return;
    final hasResidual = matchedSpec.sources.any(
      (source) =>
          source.confidence != ThrowConfidence.noObviousThrow &&
          options.shouldReport(source.confidence) &&
          !isEffectContained(node, source),
    );
    if (!hasResidual) return;

    if (_emissions.claim(diagnosticTarget)) {
      rule.reportAtNode(diagnosticTarget, arguments: [matchedSpec.displayName]);
    }
  }

  ThrowingApiSpecification? _findMatch(ResolvedCallable callable) {
    ThrowingApiSpecification? bestMatch;
    var bestScore = -1;

    for (final spec in manifest.apis) {
      final score = spec.matchScore(callable);
      if (score > bestScore) {
        bestScore = score;
        bestMatch = spec;
      }
    }

    return bestScore >= 0 ? bestMatch : null;
  }

  ThrowingApiSpecification? _findSyntaxFallback(AstNode node) {
    return switch (node) {
      FunctionExpressionInvocation(:final function) =>
        function is SimpleIdentifier
            ? _findTopLevelFunctionFallback(node, function.name)
            : null,
      MethodInvocation() => _findMethodInvocationFallback(node),
      _ => null,
    };
  }

  ThrowingApiSpecification? _findMethodInvocationFallback(
    MethodInvocation node,
  ) {
    final target = node.target;
    final methodName = node.methodName.name;

    if (target == null) {
      return _findTopLevelFunctionFallback(node, methodName);
    }

    final targetType = target.staticType;
    if (targetType is InterfaceType) {
      final className = targetType.element.name;
      if (className == null) {
        return null;
      }
      return _findInstanceMethodFallback(
        libraryUri: targetType.element.library.firstFragment.source.uri
            .toString(),
        className: className,
        methodName: methodName,
      );
    }

    if (target is SimpleIdentifier) {
      return _findClassStyleFallback(
        node,
        className: target.name,
        callableName: methodName,
      );
    }

    return null;
  }

  ThrowingApiSpecification? _findClassStyleFallback(
    AstNode node, {
    required String className,
    required String callableName,
  }) {
    for (final spec in manifest.apis) {
      if (spec.className != className) {
        continue;
      }
      if (!_isLibraryImported(node, spec.libraryUri)) {
        continue;
      }
      if (spec.constructorName == callableName ||
          (spec.methodName == callableName && (spec.isStatic ?? true))) {
        return spec;
      }
    }
    return null;
  }

  ThrowingApiSpecification? _findInstanceMethodFallback({
    required String libraryUri,
    required String className,
    required String methodName,
  }) {
    for (final spec in manifest.apis) {
      if (spec.libraryUri == libraryUri &&
          spec.className == className &&
          spec.methodName == methodName &&
          spec.isStatic != true) {
        return spec;
      }
    }
    return null;
  }

  ThrowingApiSpecification? _findTopLevelFunctionFallback(
    AstNode node,
    String functionName,
  ) {
    for (final spec in manifest.apis) {
      if (spec.functionName == functionName &&
          _isLibraryImported(node, spec.libraryUri)) {
        return spec;
      }
    }
    return null;
  }

  bool _isLibraryImported(AstNode node, String libraryUri) {
    final unit = node.thisOrAncestorOfType<CompilationUnit>();
    if (unit == null) {
      return false;
    }

    return unit.directives.whereType<ImportDirective>().any((directive) {
      return directive.uri.stringValue == libraryUri;
    });
  }
}
