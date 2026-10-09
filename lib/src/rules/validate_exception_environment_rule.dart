import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';

import '../diagnostics.dart';
import '../engine/analysis_compatibility.dart';

final class ValidateExceptionEnvironmentRule extends AnalysisRule {
  ValidateExceptionEnvironmentRule()
    : super(
        name: DartExceptionLintDiagnostics
            .unsupportedExceptionEnvironment
            .lowerCaseName,
        description: 'Reports unsupported exception-analysis environments.',
      );
  @override
  LintCode get diagnosticCode =>
      DartExceptionLintDiagnostics.unsupportedExceptionEnvironment;
  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    final warning = AnalysisCompatibility.warning;
    if (warning != null) {
      registry.addCompilationUnit(
        this,
        _Visitor(this, context.definingUnit.unit, warning),
      );
    }
  }
}

final class _Visitor extends SimpleAstVisitor<void> {
  _Visitor(this.rule, this.definingUnit, this.warning);
  final AnalysisRule rule;
  final CompilationUnit definingUnit;
  final String warning;
  @override
  void visitCompilationUnit(CompilationUnit node) {
    if (identical(node, definingUnit)) {
      rule.reportAtOffset(node.offset, 1, arguments: [warning]);
    }
  }
}
