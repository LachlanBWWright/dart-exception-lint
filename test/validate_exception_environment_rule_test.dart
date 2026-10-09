// ignore_for_file: non_constant_identifier_names
import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:analyzer/src/lint/registry.dart';
import 'package:dart_exception_lint/src/engine/analysis_compatibility.dart';
import 'package:dart_exception_lint/src/rules/validate_exception_environment_rule.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(ValidateExceptionEnvironmentRuleTest);
  });
}

@reflectiveTest
class ValidateExceptionEnvironmentRuleTest extends AnalysisRuleTest {
  final _rule = ValidateExceptionEnvironmentRule();
  String? _previous;
  @override
  String get analysisRule => _rule.name;
  @override
  void setUp() {
    Registry.ruleRegistry.registerLintRule(_rule);
    super.setUp();
    _previous = AnalysisCompatibility.warning;
  }

  @override
  Future<void> tearDown() async {
    AnalysisCompatibility.warning = _previous;
    await super.tearDown();
  }

  Future<void> test_unreviewedEnvironment_warns() async {
    AnalysisCompatibility.warning = 'Analyzer 14.1.1 has not been audited.';
    await assertDiagnostics('void f() {}', [lint(0, 1)]);
  }

  Future<void> test_supportedEnvironment_isQuiet() async {
    AnalysisCompatibility.warning = null;
    await assertNoDiagnostics('void f() {}');
  }
}
