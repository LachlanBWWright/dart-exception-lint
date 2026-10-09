import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/error.dart';

import '../analysis/inferred_throw_analyzer.dart';
import '../analysis/diagnostic_emission_guard.dart';
import '../analysis/throw_protection.dart';
import '../analysis/throw_summary.dart';
import '../config/exception_analysis_options.dart';
import '../engine/exception_analysis_service.dart';
import '../engine/invocation_targets.dart';
import '../engine/syntax_coverage.dart';
import '../diagnostics.dart';
import '../utils/source_utils.dart';

class CatchUnknownDynamicCallsRule extends AnalysisRule {
  CatchUnknownDynamicCallsRule()
    : super(
        name:
            DartExceptionLintDiagnostics.catchUnknownDynamicCalls.lowerCaseName,
        description:
            'Reports dynamic, unresolved, and unknown call boundaries.',
      );

  @override
  LintCode get diagnosticCode =>
      DartExceptionLintDiagnostics.catchUnknownDynamicCalls;

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
    if (!options.reportUnknown) {
      return;
    }

    final visitor = _Visitor(
      this,
      options,
      service.analyzer,
      context.libraryElement!,
    );
    registry.addCompilationUnit(this, _CoverageVisitor(this));
    registry.addMethodInvocation(this, visitor);
    registry.addFunctionExpressionInvocation(this, visitor);
    registry.addInstanceCreationExpression(this, visitor);
    registry.addPropertyAccess(this, visitor);
    registry.addBinaryExpression(this, visitor);
    registry.addIndexExpression(this, visitor);
    registry.addPatternField(this, visitor);
    registry.addRelationalPattern(this, visitor);
    registry.addConstantPattern(this, visitor);
    registry.addAssignmentExpression(this, visitor);
    registry.addPrefixExpression(this, visitor);
    registry.addPostfixExpression(this, visitor);
    registry.addInterpolationExpression(this, visitor);
    registry.addPrefixedIdentifier(this, visitor);
    registry.addAwaitExpression(this, visitor);
    registry.addForStatement(this, visitor);
    registry.addSpreadElement(this, visitor);
    registry.addYieldStatement(this, visitor);
    registry.addIfStatement(this, visitor);
    registry.addWhileStatement(this, visitor);
    registry.addDoStatement(this, visitor);
    registry.addConditionalExpression(this, visitor);
  }
}

final class _Visitor extends SimpleAstVisitor<void> {
  _Visitor(this.rule, this.options, this.analyzer, this.library);

  final AnalysisRule rule;
  final ExceptionAnalysisOptions options;
  final InferredThrowAnalyzer analyzer;
  final LibraryElement library;
  final DiagnosticEmissionGuard _emissions = DiagnosticEmissionGuard();

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    _report(node, element: node.element, diagnosticTarget: node.function);
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
  void visitIndexExpression(IndexExpression node) {
    _report(node, element: node.element, diagnosticTarget: node);
  }

  @override
  void visitBinaryExpression(BinaryExpression node) {
    _report(node, element: node.element, diagnosticTarget: node);
  }

  @override
  void visitAwaitExpression(AwaitExpression node) {
    if (!options.treatDynamicInvocationAsThrowing ||
        node.expression.staticType is! DynamicType) {
      return;
    }
    if (isProtectedByCatch(node)) {
      return;
    }

    if (_emissions.claim(node.expression)) {
      rule.reportAtNode(
        node.expression,
        arguments: ['dynamic await', 'dynamic_await'],
      );
    }
  }

  @override
  void visitForStatement(ForStatement node) {
    if (node.forLoopParts is! ForEachParts) return;
    if (!options.treatDynamicInvocationAsThrowing) return;
    final iterable = (node.forLoopParts as ForEachParts).iterable;
    if (iterable.staticType is! DynamicType || isProtectedByCatch(node)) {
      return;
    }
    if (_emissions.claim(node)) {
      rule.reportAtNode(
        node,
        arguments: [
          node.awaitKeyword == null
              ? 'dynamic iteration'
              : 'dynamic async iteration',
          node.awaitKeyword == null
              ? 'dynamic_iteration'
              : 'dynamic_async_iteration',
        ],
      );
    }
  }

  @override
  void visitSpreadElement(SpreadElement node) {
    if (!options.treatDynamicInvocationAsThrowing ||
        node.expression.staticType is! DynamicType ||
        isProtectedByCatch(node)) {
      return;
    }
    if (_emissions.claim(node.expression)) {
      rule.reportAtNode(
        node.expression,
        arguments: ['dynamic spread', 'dynamic_spread'],
      );
    }
  }

  @override
  void visitYieldStatement(YieldStatement node) {
    if (!options.treatDynamicInvocationAsThrowing ||
        node.star == null ||
        node.expression.staticType is! DynamicType ||
        isProtectedByCatch(node)) {
      return;
    }
    if (_emissions.claim(node.expression)) {
      rule.reportAtNode(
        node.expression,
        arguments: ['dynamic yield*', 'dynamic_yield'],
      );
    }
  }

  @override
  void visitIfStatement(IfStatement node) {
    _reportDynamicBoolean(node, node.expression, 'dynamic condition');
    super.visitIfStatement(node);
  }

  @override
  void visitWhileStatement(WhileStatement node) {
    _reportDynamicBoolean(node, node.condition, 'dynamic condition');
    super.visitWhileStatement(node);
  }

  @override
  void visitDoStatement(DoStatement node) {
    _reportDynamicBoolean(node, node.condition, 'dynamic condition');
    super.visitDoStatement(node);
  }

  @override
  void visitConditionalExpression(ConditionalExpression node) {
    _reportDynamicBoolean(node, node.condition, 'dynamic condition');
    super.visitConditionalExpression(node);
  }

  void _reportDynamicBoolean(
    AstNode reportNode,
    Expression expression,
    String displayName,
  ) {
    if (!options.treatDynamicInvocationAsThrowing ||
        expression.staticType is! DynamicType ||
        isProtectedByCatch(reportNode)) {
      return;
    }
    if (_emissions.claim(expression)) {
      rule.reportAtNode(
        expression,
        arguments: [displayName, 'dynamic_condition'],
      );
    }
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
    final analysis = analyzer.analyzeResolvedCall(
      node,
      element: element,
      treatUnknownAsReportable: true,
      requireObservedAsyncError: false,
      includeManifestOverrides: false,
    );
    if (analysis == null || analysis.confidence != ThrowConfidence.unknown) {
      return;
    }
    if (analysis.isProtectedAt(node)) {
      return;
    }

    if (_emissions.claim(diagnosticTarget)) {
      rule.reportAtNode(
        diagnosticTarget,
        arguments: [
          analysis.displayName,
          analysis.unknownReason ?? 'unknown_boundary',
        ],
      );
    }
  }
}

final class _CoverageVisitor extends GeneralizingAstVisitor<void> {
  _CoverageVisitor(this.rule);
  final AnalysisRule rule;

  @override
  void visitNode(AstNode node) {
    if (SyntaxCoverageInventory.requiresUnknown(node) &&
        !isProtectedByCatch(node)) {
      rule.reportAtNode(
        node,
        arguments: [SyntaxCoverageInventory.kind(node), 'unmodeled_syntax'],
      );
    }
    super.visitNode(node);
  }
}
