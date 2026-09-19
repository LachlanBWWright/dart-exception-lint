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
import '../config/throwing_api_manifest.dart';
import '../diagnostics.dart';
import '../result.dart';
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
    if (!options.reportUnknown) {
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
    final visitor = _Visitor(
      this,
      options,
      InferredThrowAnalyzer(
        manifest: manifest,
        options: options,
        featureSet: context.libraryElement!.featureSet,
        packageRootPath: context.package?.root.path,
        knownUnits: {
          for (final unit in context.allUnits) unit.file.path: unit.unit,
        },
      ),
    );
    registry.addMethodInvocation(this, visitor);
    registry.addFunctionExpressionInvocation(this, visitor);
    registry.addInstanceCreationExpression(this, visitor);
    registry.addPropertyAccess(this, visitor);
    registry.addBinaryExpression(this, visitor);
    registry.addPrefixedIdentifier(this, visitor);
    registry.addAwaitExpression(this, visitor);
    registry.addForStatement(this, visitor);
    registry.addSpreadElement(this, visitor);
    registry.addYieldStatement(this, visitor);
    registry.addIfStatement(this, visitor);
    registry.addWhileStatement(this, visitor);
    registry.addDoStatement(this, visitor);
    registry.addConditionalExpression(this, visitor);
    registry.addSwitchStatement(this, visitor);
  }
}

final class _Visitor extends SimpleAstVisitor<void> {
  _Visitor(this.rule, this.options, this.analyzer);

  final AnalysisRule rule;
  final ExceptionAnalysisOptions options;
  final InferredThrowAnalyzer analyzer;
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
      rule.reportAtNode(node.expression, arguments: ['dynamic await']);
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
      rule.reportAtNode(node.expression, arguments: ['dynamic spread']);
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
      rule.reportAtNode(node.expression, arguments: ['dynamic yield*']);
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

  @override
  void visitSwitchStatement(SwitchStatement node) {
    _reportDynamicBoolean(node, node.expression, 'dynamic switch value');
    super.visitSwitchStatement(node);
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
      rule.reportAtNode(expression, arguments: [displayName]);
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
    if (isProtectedByCatch(node, exceptionTypes: analysis.exceptionTypes)) {
      return;
    }

    if (_emissions.claim(diagnosticTarget)) {
      rule.reportAtNode(diagnosticTarget, arguments: [analysis.displayName]);
    }
  }
}
