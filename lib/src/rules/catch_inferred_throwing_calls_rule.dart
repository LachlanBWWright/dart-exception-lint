import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/error/error.dart';

import '../analysis/inferred_throw_analyzer.dart';
import '../analysis/diagnostic_emission_guard.dart';
import '../analysis/throw_summary.dart';
import '../engine/exception_analysis_service.dart';
import '../engine/invocation_targets.dart';
import '../analysis/throw_source_catalog.dart';
import '../diagnostics.dart';
import '../utils/source_utils.dart';

class CatchInferredThrowingCallsRule extends AnalysisRule {
  CatchInferredThrowingCallsRule()
    : super(
        name: DartExceptionLintDiagnostics
            .catchInferredThrowingCalls
            .lowerCaseName,
        description:
            'Reports calls whose implementation is inferred as throwing.',
      );

  @override
  LintCode get diagnosticCode =>
      DartExceptionLintDiagnostics.catchInferredThrowingCalls;

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
    final visitor = _Visitor(this, service.analyzer, context.libraryElement!);
    registry.addMethodInvocation(this, visitor);
    registry.addFunctionExpressionInvocation(this, visitor);
    registry.addInstanceCreationExpression(this, visitor);
    registry.addVariableDeclaration(this, visitor);
    registry.addPropertyAccess(this, visitor);
    registry.addPrefixedIdentifier(this, visitor);
    registry.addBinaryExpression(this, visitor);
    registry.addAssignmentExpression(this, visitor);
    registry.addPrefixExpression(this, visitor);
    registry.addPostfixExpression(this, visitor);
    registry.addInterpolationExpression(this, visitor);
    registry.addIndexExpression(this, visitor);
    registry.addPatternField(this, visitor);
    registry.addRelationalPattern(this, visitor);
    registry.addConstantPattern(this, visitor);
  }
}

final class _Visitor extends SimpleAstVisitor<void> {
  _Visitor(this.rule, this.analyzer, this.library);

  final AnalysisRule rule;
  final InferredThrowAnalyzer analyzer;
  final LibraryElement library;
  final DiagnosticEmissionGuard _emissions = DiagnosticEmissionGuard();
  final Map<Element, ExecutableElement> _callableAliases = {};

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    final initializer = node.initializer;
    final declaredElement = node.declaredFragment?.element;
    if (declaredElement != null && initializer is SimpleIdentifier) {
      final target = initializer.element;
      if (target is ExecutableElement) {
        _callableAliases[declaredElement] = target;
      }
    }
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    final element =
        node.element ??
        (node.function is SimpleIdentifier
            ? _callableAliases[(node.function as SimpleIdentifier).element]
            : null);
    _report(node, element: element, diagnosticTarget: node.function);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    _report(
      node,
      element: node.constructorName.element,
      diagnosticTarget: node.constructorName,
    );
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    _report(
      node,
      element: node.methodName.element,
      diagnosticTarget: node.methodName,
    );
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    _report(
      node,
      element: node.propertyName.element,
      diagnosticTarget: node.propertyName,
    );
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    _report(
      node,
      element: node.identifier.element,
      diagnosticTarget: node.identifier,
    );
  }

  @override
  void visitBinaryExpression(BinaryExpression node) {
    _report(node, element: node.element, diagnosticTarget: node);
  }

  @override
  void visitIndexExpression(IndexExpression node) {
    _report(node, element: node.element, diagnosticTarget: node);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    for (final element in invocationTargets(node, library)) {
      _report(node, element: element, diagnosticTarget: node);
    }
  }

  @override
  void visitPrefixExpression(PrefixExpression node) {
    for (final element in invocationTargets(node, library)) {
      _report(node, element: element, diagnosticTarget: node);
    }
  }

  @override
  void visitPostfixExpression(PostfixExpression node) {
    for (final element in invocationTargets(node, library)) {
      _report(node, element: element, diagnosticTarget: node);
    }
  }

  @override
  void visitInterpolationExpression(InterpolationExpression node) {
    for (final element in invocationTargets(node, library)) {
      _report(node, element: element, diagnosticTarget: node);
    }
  }

  @override
  void visitPatternField(PatternField node) {
    for (final element in invocationTargets(node, library)) {
      _report(node, element: element, diagnosticTarget: node);
    }
  }

  @override
  void visitRelationalPattern(RelationalPattern node) {
    for (final element in invocationTargets(node, library)) {
      _report(node, element: element, diagnosticTarget: node);
    }
  }

  @override
  void visitConstantPattern(ConstantPattern node) {
    for (final element in invocationTargets(node, library)) {
      _report(node, element: element, diagnosticTarget: node);
    }
  }

  void _report(
    AstNode node, {
    required Element? element,
    required AstNode diagnosticTarget,
  }) {
    // Direct numeric diagnostics belong to the runtime-source adapter. Only
    // the operator target is excluded; compound getters/setters still infer.
    final directNumeric = switch (node) {
      BinaryExpression() => ThrowSourceCatalog.matchBinaryExpression(
        node,
        analyzer.options,
      ),
      AssignmentExpression()
          when element?.baseElement == node.element?.baseElement =>
        ThrowSourceCatalog.matchAssignmentExpression(node, analyzer.options),
      _ => null,
    };
    if (directNumeric != null) return;
    if (ThrowSourceCatalog.matchResolvedInvocation(
          node,
          element,
          analyzer.options,
        ) !=
        null) {
      return;
    }
    final analysis = analyzer.analyzeResolvedCall(
      node,
      element: element,
      treatUnknownAsReportable: false,
      requireObservedAsyncError: false,
      includeManifestOverrides: false,
    );
    if (analysis == null || analysis.isAsync || analysis.isDeferred) {
      return;
    }
    if (analysis.isProtectedAt(node)) {
      return;
    }

    if (!_emissions.claim(diagnosticTarget)) return;
    rule.reportAtNode(
      diagnosticTarget,
      arguments: [
        analysis.displayName,
        analysis.confidence.label,
        _originLabel(analysis.origin),
      ],
    );
  }

  String _originLabel(ThrowOrigin? origin) {
    if (origin == null) return 'unavailable';
    final location = origin.filePath == null || origin.offset == null
        ? ''
        : ' at ${origin.filePath}:${origin.offset}';
    return '${origin.displayName}$location';
  }
}
