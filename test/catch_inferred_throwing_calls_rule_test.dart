// ignore_for_file: non_constant_identifier_names

import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:analyzer/src/lint/registry.dart';
import 'package:dart_exception_lint/src/rules/catch_inferred_throwing_calls_rule.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(CatchInferredThrowingCallsRuleTest);
  });
}

@reflectiveTest
class CatchInferredThrowingCallsRuleTest extends AnalysisRuleTest {
  @override
  String get analysisRule => _rule.name;

  @override
  void setUp() {
    Registry.ruleRegistry.registerLintRule(_rule);
    super.setUp();
  }

  static final CatchInferredThrowingCallsRule _rule =
      CatchInferredThrowingCallsRule();

  Future<void> test_localHelperThrow_reports() async {
    const code = r'''
class BoomException implements Exception {}

void helper() {
  throw BoomException();
}

void f() {
  helper();
}
''';

    await assertDiagnostics(code, [
      lint(
        code.lastIndexOf('helper'),
        'helper'.length,
        messageContains: 'helper',
      ),
    ]);
  }

  Future<void> test_localHelperThrow_insideTryCatch_notReported() async {
    await assertNoDiagnostics(r'''
class BoomException implements Exception {}

void helper() {
  throw BoomException();
}

void f() {
  try {
    helper();
  } catch (_) {}
}
''');
  }

  Future<void> test_mismatchedTypedCatch_stillReports() async {
    const code = r'''
class BoomException implements Exception {}

void helper() {
  throw BoomException();
}

void f() {
  try {
    helper();
  } on FormatException {}
}
''';

    await assertDiagnostics(code, [
      lint(
        code.lastIndexOf('helper'),
        'helper'.length,
        messageContains: 'helper',
      ),
    ]);
  }

  Future<void> test_matchingTypedCatch_doesNotReport() async {
    await assertNoDiagnostics(r'''
class BoomException implements Exception {}

void helper() {
  throw BoomException();
}

void f() {
  try {
    helper();
  } on BoomException {}
}
''');
  }

  Future<void> test_localHelperKnownThrowSource_reports() async {
    const code = r'''
int parseValue(String value) => int.parse(value);

void f() {
  parseValue('not-an-int');
}
''';

    await assertDiagnostics(code, [
      lint(
        code.lastIndexOf('parseValue'),
        'parseValue'.length,
        messageContains: 'parseValue',
      ),
    ]);
  }

  Future<void> test_asyncHelper_isHandledByAsyncRule_notInferredRule() async {
    await assertNoDiagnostics(r'''
Future<int> helper() async => int.parse('not-an-int');

Future<void> f() async {
  await helper();
}
''');
  }
}
