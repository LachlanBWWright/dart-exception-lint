import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';

import '../analysis/throw_protection.dart';
import '../analysis/throw_source_catalog.dart';
import '../analysis/throw_summary.dart';
import '../config/exception_analysis_options.dart';
import '../diagnostics.dart';
import '../utils/source_utils.dart';

class CatchRuntimeThrowSourcesRule extends AnalysisRule {
  CatchRuntimeThrowSourcesRule()
    : super(
        name: DartExceptionLintDiagnostics.catchRuntimeThrowSources.name,
        description: 'Reports known runtime throw sources outside try/catch.',
      );

  @override
  LintCode get diagnosticCode =>
      DartExceptionLintDiagnostics.catchRuntimeThrowSources;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    if (isGeneratedDartFile(context.currentUnit?.file.path)) {
      return;
    }

    final options = ExceptionAnalysisOptions.load(
      packageRoot: context.package?.root.path,
      currentFilePath: context.currentUnit?.file.path,
    );
    final visitor = _Visitor(this, options);
    registry.addMethodInvocation(this, visitor);
    registry.addFunctionExpressionInvocation(this, visitor);
    registry.addIndexExpression(this, visitor);
    registry.addAsExpression(this, visitor);
  }
}

final class _Visitor extends SimpleAstVisitor<void> {
  _Visitor(this.rule, this.options);

  final AnalysisRule rule;
  final ExceptionAnalysisOptions options;

  @override
  void visitAsExpression(AsExpression node) {
    final source = ThrowSourceCatalog.matchAsExpression(node, options);
    if (source == null || source.confidence.isAsync) {
      return;
    }
    _report(node, node.type, source.displayName, source.exceptionTypes);
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    final source = ThrowSourceCatalog.matchResolvedInvocation(
      node,
      node.element,
      options,
    );
    if (source == null || source.confidence.isAsync) {
      return;
    }
    _report(node, node.function, source.displayName, source.exceptionTypes);
  }

  @override
  void visitIndexExpression(IndexExpression node) {
    final source = ThrowSourceCatalog.matchIndexAccess(node, options);
    if (source == null || source.confidence.isAsync) {
      return;
    }
    _report(node, node, source.displayName, source.exceptionTypes);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final source = ThrowSourceCatalog.matchResolvedInvocation(
      node,
      node.methodName.element,
      options,
    );
    if (source == null || source.confidence.isAsync) {
      return;
    }
    _report(node, node.methodName, source.displayName, source.exceptionTypes);
  }

  void _report(
    AstNode node,
    AstNode diagnosticTarget,
    String displayName,
    List<String> exceptionTypes,
  ) {
    if (isProtectedByCatch(node, exceptionTypes: exceptionTypes)) {
      return;
    }

    rule.reportAtNode(diagnosticTarget, arguments: [displayName]);
  }
}
