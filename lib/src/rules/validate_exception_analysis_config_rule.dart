import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';

import '../config/exception_analysis_options.dart';
import '../config/throwing_api_manifest.dart';
import '../diagnostics.dart';
import '../result.dart';

/// Reports configuration failures once per library instead of silently
/// disabling exception analysis.
class ValidateExceptionAnalysisConfigRule extends AnalysisRule {
  ValidateExceptionAnalysisConfigRule()
    : super(
        name: DartExceptionLintDiagnostics
            .invalidExceptionAnalysisConfig
            .lowerCaseName,
        description: 'Reports invalid dart_exception_lint configuration.',
      );

  @override
  LintCode get diagnosticCode =>
      DartExceptionLintDiagnostics.invalidExceptionAnalysisConfig;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    if (context.currentUnit?.file.path != context.definingUnit.file.path) {
      return;
    }

    final failures = <String>[];
    final options = ExceptionAnalysisOptions.loadResult(
      packageRoot: context.package?.root.path,
      currentFilePath: context.currentUnit?.file.path,
    );
    if (options case Err(error: final failure)) {
      failures.add(failure.message);
    }

    final manifest = ThrowingApiManifest.loadResult(
      packageRoot: context.package?.root.path,
      currentFilePath: context.currentUnit?.file.path,
    );
    if (manifest case Err(error: final failure)) {
      failures.add(failure.message);
    }

    if (failures.isNotEmpty) {
      registry.addCompilationUnit(this, _Visitor(this, failures));
    }
  }
}

final class _Visitor extends SimpleAstVisitor<void> {
  _Visitor(this.rule, this.failures);

  final AnalysisRule rule;
  final List<String> failures;

  @override
  void visitCompilationUnit(CompilationUnit node) {
    rule.reportAtOffset(node.offset, 1, arguments: [failures.join(' ')]);
  }
}
