import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/error.dart';

import '../config/exception_analysis_options.dart';
import '../diagnostics.dart';
import '../result.dart';
import '../utils/source_utils.dart';

class NoManualThrowRule extends AnalysisRule {
  NoManualThrowRule()
    : super(
        name: DartExceptionLintDiagnostics.noManualThrow.name,
        description: 'Reports manually written throw expressions.',
      );

  @override
  LintCode get diagnosticCode => DartExceptionLintDiagnostics.noManualThrow;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    final options = switch (ExceptionAnalysisOptions.loadResult(
      packageRoot: context.package?.root.path,
      currentFilePath: context.currentUnit?.file.path,
    )) {
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

    final visitor = _Visitor(this);
    registry.addThrowExpression(this, visitor);
    registry.addRethrowExpression(this, visitor);
  }
}

final class _Visitor extends SimpleAstVisitor<void> {
  _Visitor(this.rule);

  final AnalysisRule rule;

  @override
  void visitThrowExpression(ThrowExpression node) {
    final throwKeyword = node.throwKeyword;

    if (throwKeyword.isSynthetic) {
      return;
    }

    rule.reportAtToken(
      throwKeyword,
      arguments: [_describeThrownValue(node.expression.staticType)],
    );
  }

  @override
  void visitRethrowExpression(RethrowExpression node) {
    final rethrowKeyword = node.rethrowKeyword;
    if (rethrowKeyword.isSynthetic) {
      return;
    }

    rule.reportAtToken(rethrowKeyword, arguments: ['an Exception']);
  }

  String _describeThrownValue(DartType? thrownType) {
    if (thrownType == null) {
      return 'an unresolved value';
    }

    if (_isCoreTypeOrSubtype(thrownType, 'Exception')) {
      return 'an Exception';
    }

    if (_isCoreTypeOrSubtype(thrownType, 'Error')) {
      return 'an Error';
    }

    return 'a non-Exception value';
  }

  bool _isCoreTypeOrSubtype(DartType thrownType, String targetName) {
    if (thrownType is! InterfaceType) {
      return false;
    }

    final element = thrownType.element;
    if (_isCoreType(element, targetName)) {
      return true;
    }

    return element.allSupertypes.any(
      (type) => _isCoreType(type.element, targetName),
    );
  }

  bool _isCoreType(InterfaceElement element, String targetName) {
    return element.name == targetName &&
        element.library.firstFragment.source.uri.toString() == 'dart:core';
  }
}
