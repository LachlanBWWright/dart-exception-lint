// ignore_for_file: non_constant_identifier_names

import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:analyzer/src/lint/registry.dart';
import 'package:dart_exception_lint/src/rules/catch_runtime_throw_sources_rule.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(CatchRuntimeThrowSourcesRuleTest);
  });
}

@reflectiveTest
class CatchRuntimeThrowSourcesRuleTest extends AnalysisRuleTest {
  @override
  String get analysisRule => _rule.name;

  @override
  void setUp() {
    Registry.ruleRegistry.registerLintRule(_rule);
    super.setUp();
  }

  static final CatchRuntimeThrowSourcesRule _rule =
      CatchRuntimeThrowSourcesRule();

  Future<void> test_firstWhere_withoutOrElse() async {
    const code = r'''
void f(List<int> values) {
  values.firstWhere((value) => value > 10);
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('firstWhere'), 'firstWhere'.length),
    ]);
  }

  Future<void> test_intParse_reports() async {
    const code = r'''
void f(String value) {
  int.parse(value);
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('parse'), 'parse'.length, messageContains: 'int.parse'),
    ]);
  }

  Future<void> test_intParse_insideTryCatch_notReported() async {
    await assertNoDiagnostics(r'''
void f(String value) {
  try {
    int.parse(value);
  } catch (_) {}
}
''');
  }
}
