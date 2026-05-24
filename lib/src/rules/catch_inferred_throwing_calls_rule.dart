import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/error/error.dart';

import '../analysis/inferred_throw_analyzer.dart';
import '../analysis/throw_protection.dart';
import '../analysis/throw_summary.dart';
import '../config/exception_analysis_options.dart';
import '../config/throwing_api_manifest.dart';
import '../diagnostics.dart';
import '../result.dart';
import '../utils/source_utils.dart';

class CatchInferredThrowingCallsRule extends AnalysisRule {
  CatchInferredThrowingCallsRule()
    : super(
        name: DartExceptionLintDiagnostics.catchInferredThrowingCalls.name,
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
  }
}

final class _Visitor extends SimpleAstVisitor<void> {
  _Visitor(this.rule, this.analyzer);

  final AnalysisRule rule;
  final InferredThrowAnalyzer analyzer;

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

  void _report(
    AstNode node, {
    required Element? element,
    required AstNode diagnosticTarget,
  }) {
    final analysis = analyzer.analyzeResolvedCall(
      node,
      element: element,
      treatUnknownAsReportable: false,
      requireObservedAsyncError: false,
      includeManifestOverrides: false,
    );
    if (analysis == null || analysis.isAsync) {
      return;
    }
    if (isProtectedByCatch(node, exceptionTypes: analysis.exceptionTypes)) {
      return;
    }

    rule.reportAtNode(
      diagnosticTarget,
      arguments: [analysis.displayName, analysis.confidence.label],
    );
  }
}
