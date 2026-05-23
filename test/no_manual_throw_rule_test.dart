// ignore_for_file: non_constant_identifier_names

import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:analyzer/src/lint/registry.dart';
import 'package:dart_exception_lint/src/rules/no_manual_throw_rule.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(NoManualThrowRuleTest);
  });
}

@reflectiveTest
class NoManualThrowRuleTest extends AnalysisRuleTest {
  @override
  String get analysisRule => _rule.name;

  @override
  void setUp() {
    Registry.ruleRegistry.registerLintRule(_rule);
    super.setUp();
  }

  static final NoManualThrowRule _rule = NoManualThrowRule();

  Future<void> test_arrowFunction() async {
    const code = r'''
class BoomException implements Exception {}

Never fail() => throw BoomException();
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('throw'), 5, messageContains: 'Exception'),
    ]);
  }

  Future<void> test_asyncClosure() async {
    const code = r'''
class BoomError extends Error {}

Future<void> f() async {
  final callback = () async {
    throw BoomError();
  };
  await callback();
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('throw'), 5, messageContains: 'Error'),
    ]);
  }

  Future<void> test_conditionalExpression() async {
    const code = r'''
class BoomException implements Exception {}

int f(bool condition) => condition ? 1 : throw BoomException();
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('throw'), 5, messageContains: 'Exception'),
    ]);
  }

  Future<void> test_exception() async {
    const code = r'''
class BoomException implements Exception {}

void f() {
  throw BoomException();
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('throw'), 5, messageContains: 'Exception'),
    ]);
  }

  Future<void> test_nonExceptionValue() async {
    const code = r'''
void f() {
  throw 'boom';
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('throw'), 5, messageContains: 'non-Exception'),
    ]);
  }

  Future<void> test_objectValue() async {
    const code = r'''
void f() {
  throw Object();
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('throw'), 5, messageContains: 'non-Exception'),
    ]);
  }

  Future<void> test_syncClosureError() async {
    const code = r'''
class BoomError extends Error {}

void f() {
  final callback = () {
    throw BoomError();
  };
  callback();
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('throw'), 5, messageContains: 'Error'),
    ]);
  }

  Future<void> test_rethrow_reported() async {
    const code = r'''
void f() {
  try {
    g();
  } catch (_) {
    rethrow;
  }
}

void g() {}
''';

    await assertDiagnostics(code, [
      lint(
        code.indexOf('rethrow'),
        'rethrow'.length,
        messageContains: 'Exception',
      ),
    ]);
  }
}
