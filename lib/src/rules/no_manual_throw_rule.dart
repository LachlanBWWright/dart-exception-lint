import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/error.dart';

import '../analysis/inferred_throw_analyzer.dart';
import '../diagnostics.dart';
import '../engine/callback_values.dart';
import '../engine/error_producers.dart';
import '../engine/exception_analysis_service.dart';
import '../utils/source_utils.dart';

class NoManualThrowRule extends AnalysisRule {
  NoManualThrowRule()
    : super(
        name: DartExceptionLintDiagnostics.noManualThrow.lowerCaseName,
        description:
            'Reports explicit throws and asynchronous error production.',
      );

  @override
  LintCode get diagnosticCode => DartExceptionLintDiagnostics.noManualThrow;

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

    final visitor = _Visitor(this, service.analyzer);
    registry.addThrowExpression(this, visitor);
    registry.addRethrowExpression(this, visitor);
    registry.addMethodInvocation(this, visitor);
    registry.addInstanceCreationExpression(this, visitor);
    registry.addFunctionExpressionInvocation(this, visitor);
  }
}

final class _Visitor extends SimpleAstVisitor<void> {
  _Visitor(this.rule, this.analyzer);

  final AnalysisRule rule;
  final InferredThrowAnalyzer analyzer;

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    _reportProducer(
      explicitProducerInvocationTargets(
        analyzer.resolveInvokedCallback(node),
        node.argumentList,
        analyzer.resolveCallbackValue,
      ),
      node.function,
    );
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    _reportProducer(
      explicitProducerInvocationTargets(
        analyzer.resolveInvokedCallback(node),
        node.argumentList,
        analyzer.resolveCallbackValue,
      ),
      node.methodName,
    );
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    _reportProducer(
      analyzer.callbackValueForElement(node.constructorName.element),
      node.constructorName,
    );
  }

  void _reportProducer(CallbackValue value, AstNode target) {
    final producers =
        value.targets
            .map(explicitErrorProducer)
            .whereType<ErrorProducer>()
            .toList()
          ..sort((a, b) => a.displayName.compareTo(b.displayName));
    if (producers.isEmpty) return;
    final producer = producers.first;
    // Report once per invocation even when several possible targets produce
    // errors. An unresolved alternative does not erase a known producer.
    rule.reportAtNode(
      target,
      arguments: ['an error via ${producer.displayName}'],
    );
  }

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
