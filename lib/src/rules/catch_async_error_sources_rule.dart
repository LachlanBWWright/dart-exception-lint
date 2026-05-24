import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/error/error.dart';

import '../analysis/inferred_throw_analyzer.dart';
import '../analysis/throw_protection.dart';
import '../analysis/throw_source_catalog.dart';
import '../analysis/throw_summary.dart';
import '../config/exception_analysis_options.dart';
import '../config/throwing_api_manifest.dart';
import '../diagnostics.dart';
import '../result.dart';
import '../utils/source_utils.dart';

class CatchAsyncErrorSourcesRule extends AnalysisRule {
  CatchAsyncErrorSourcesRule()
    : super(
        name: DartExceptionLintDiagnostics.catchAsyncErrorSources.name,
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
    if (!options.requireAsyncErrorHandling) {
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
    final analyzer = InferredThrowAnalyzer(
      manifest: manifest,
      options: options,
      featureSet: context.libraryElement!.featureSet,
      packageRootPath: context.package?.root.path,
      knownUnits: {
        for (final unit in context.allUnits) unit.file.path: unit.unit,
      },
    );
    final visitor = _Visitor(this, options, analyzer);
    registry.addMethodInvocation(this, visitor);
    registry.addAwaitExpression(this, visitor);
  }
}

final class _Visitor extends SimpleAstVisitor<void> {
  _Visitor(this.rule, this.options, this.analyzer);

  final AnalysisRule rule;
  final ExceptionAnalysisOptions options;
  final InferredThrowAnalyzer analyzer;

  @override
  void visitAwaitExpression(AwaitExpression node) {
    final expression = node.expression;
    final analysis = analyzer.analyzeResolvedCall(
      expression,
      element: _elementForInvocation(expression),
      treatUnknownAsReportable: false,
      requireObservedAsyncError: true,
      includeManifestOverrides: false,
    );
    if (analysis == null || analysis.confidence != ThrowConfidence.asyncError) {
      return;
    }
    if (isProtectedByCatch(
      node,
      requireAsyncProtection: true,
      exceptionTypes: analysis.exceptionTypes,
    )) {
      return;
    }

    rule.reportAtNode(node, arguments: [analysis.displayName]);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.parent is AwaitExpression) {
      return;
    }

    final source = ThrowSourceCatalog.matchResolvedInvocation(
      node,
      node.methodName.element,
      options,
    );
    if (source == null || !source.confidence.isAsync) {
      if (_isUnhandledListen(node)) {
        rule.reportAtNode(node.methodName, arguments: ['Stream.listen']);
      }
      return;
    }

    if (isProtectedByCatch(
      node,
      requireAsyncProtection: true,
      exceptionTypes: source.exceptionTypes,
    )) {
      return;
    }

    rule.reportAtNode(node.methodName, arguments: [source.displayName]);
  }

  bool _isUnhandledListen(MethodInvocation node) {
    if (node.methodName.name != 'listen') {
      return false;
    }

    return node.argumentList.arguments.whereType<NamedExpression>().every(
      (argument) => argument.name.label.name != 'onError',
    );
  }

  Element? _elementForInvocation(Expression expression) {
    return switch (expression) {
      MethodInvocation(:final methodName) => methodName.element,
      FunctionExpressionInvocation() => expression.element,
      InstanceCreationExpression(:final constructorName) =>
        constructorName.element,
      _ => null,
    };
  }
}
