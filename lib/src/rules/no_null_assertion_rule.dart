import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';

import '../diagnostics.dart';
import '../utils/source_utils.dart';

class NoNullAssertionRule extends AnalysisRule {
  NoNullAssertionRule()
    : super(
        name: DartExceptionLintDiagnostics.noNullAssertion.name,
        description: 'Reports every postfix null assertion operator.',
      );

  @override
  LintCode get diagnosticCode => DartExceptionLintDiagnostics.noNullAssertion;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    if (isGeneratedDartFile(context.currentUnit?.file.path)) {
      return;
    }

    registry.addPostfixExpression(this, _Visitor(this));
  }
}

final class _Visitor extends SimpleAstVisitor<void> {
  _Visitor(this.rule);

  final AnalysisRule rule;

  @override
  void visitPostfixExpression(PostfixExpression node) {
    final operator = node.operator;
    if (operator.isSynthetic || operator.type != TokenType.BANG) {
      return;
    }

    rule.reportAtToken(operator);
  }
}
