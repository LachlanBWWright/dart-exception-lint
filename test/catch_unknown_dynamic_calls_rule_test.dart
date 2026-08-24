// ignore_for_file: non_constant_identifier_names

import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:analyzer/src/lint/registry.dart';
import 'package:dart_exception_lint/src/rules/catch_unknown_dynamic_calls_rule.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(CatchUnknownDynamicCallsRuleTest);
  });
}

@reflectiveTest
class CatchUnknownDynamicCallsRuleTest extends AnalysisRuleTest {
  @override
  String get analysisRule => _rule.name;

  @override
  void setUp() {
    Registry.ruleRegistry.registerLintRule(_rule);
    super.setUp();
  }

  static final CatchUnknownDynamicCallsRule _rule =
      CatchUnknownDynamicCallsRule();

  Future<void> test_dynamicMethodCall_reports() async {
    const code = r'''
void f(dynamic client) {
  client.fetch();
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('fetch'), 'fetch'.length),
    ]);
  }

  Future<void> test_dynamicMethodCall_insideTryCatch_notReported() async {
    await assertNoDiagnostics(r'''
void f(dynamic client) {
  try {
    client.fetch();
  } catch (_) {}
}
    ''');
  }

  Future<void> test_dynamicFunctionInvocation_reports() async {
    const code = r'''
void f(dynamic callback) {
  callback();
}
''';

    await assertDiagnostics(code, [
      lint(code.lastIndexOf('callback'), 'callback'.length),
    ]);
  }

  Future<void> test_functionTypedInvocation_reports() async {
    const code = r'''
void f(Function callback) {
  callback();
}
''';

    await assertDiagnostics(code, [
      lint(code.lastIndexOf('callback'), 'callback'.length),
    ]);
  }

  Future<void>
  test_dynamicFunctionInvocation_insideTryCatch_notReported() async {
    await assertNoDiagnostics(r'''
void f(dynamic callback) {
  try {
    callback();
  } catch (_) {}
}
''');
  }

  Future<void> test_dynamicAwait_reports() async {
    const code = r'''
Future<void> f(dynamic future) async {
  await future;
}
''';

    await assertDiagnostics(code, [
      lint(code.lastIndexOf('future'), 'future'.length),
    ]);
  }

  Future<void> test_dynamicAwait_insideTryCatch_notReported() async {
    await assertNoDiagnostics(r'''
Future<void> f(dynamic future) async {
  try {
    await future;
  } catch (_) {}
}
''');
  }

  Future<void> test_dynamicMethodCall_throughCascade_reports() async {
    const code = r'''
void f(dynamic client) {
  client..fetch();
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('fetch'), 'fetch'.length),
    ]);
  }

  Future<void> test_dynamicConditionalCall_insideTryCatch_notReported() async {
    await assertNoDiagnostics(r'''
void f(dynamic first, dynamic second, bool useFirst) {
  try {
    (useFirst ? first : second).fetch();
  } catch (_) {}
}
''');
  }
}
