// ignore_for_file: non_constant_identifier_names

import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:analyzer/src/lint/registry.dart';
import 'package:dart_exception_lint/src/rules/validate_exception_contract_rule.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';
import 'support/exception_annotations.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(ValidateExceptionContractRuleTest);
  });
}

@reflectiveTest
class ValidateExceptionContractRuleTest extends AnalysisRuleTest {
  @override
  String get analysisRule => _rule.name;

  @override
  void setUp() {
    Registry.ruleRegistry.registerLintRule(_rule);
    super.setUp();
    installExceptionAnnotations(this);
  }

  static final ValidateExceptionContractRule _rule =
      ValidateExceptionContractRule();

  Future<void> test_inheritedSafeContract_throwingOverride_reports() async {
    const code = r'''
import 'package:dart_exception_lint/dart_exception_lint.dart';
abstract class Base {
  @DoesNotThrow()
  void run();
}
class Worker implements Base {
  void run() { throw Object(); }
}
''';
    final start = code.indexOf('void run() {');
    await assertDiagnostics(code, [
      lint(start, "void run() { throw Object(); }".length),
    ]);
  }

  Future<void> test_inheritedSafeContract_safeOverride_isAllowed() async {
    await assertNoDiagnostics(r'''
import 'package:dart_exception_lint/dart_exception_lint.dart';
abstract class Base {
  @DoesNotThrow()
  void run();
}
class Worker implements Base {
  void run() {}
}
''');
  }

  Future<void> test_secondContract_invalidAsyncReturn_reports() async {
    const code = r'''
import 'package:dart_exception_lint/dart_exception_lint.dart';
@MayThrow([Exception])
@ReturnsFailingFuture([Exception])
String invalid() => 'value';
''';
    await assertDiagnostics(code, [
      lint(
        code.indexOf('@MayThrow'),
        code.trimRight().length - code.indexOf('@MayThrow'),
      ),
    ]);
  }

  Future<void> test_failingFutureRequiresAsyncReturn() async {
    const code = r'''
import 'package:dart_exception_lint/dart_exception_lint.dart';

@ReturnsFailingFuture([Exception])
String invalid() => 'value';
''';

    await assertDiagnostics(code, [
      lint(
        code.indexOf('@ReturnsFailingFuture'),
        '@ReturnsFailingFuture([Exception]) String invalid() => \'value\';'
            .length,
      ),
    ]);
  }

  Future<void> test_missingContract_isAllowed() async {
    await assertNoDiagnostics(r'''
String valid() => 'value';
''');
  }

  Future<void> test_doesNotThrowContradictsDirectThrow() async {
    const code = r'''
import 'package:dart_exception_lint/dart_exception_lint.dart';

@DoesNotThrow()
void invalid() {
  throw Object();
}
''';

    await assertDiagnostics(code, [
      lint(
        code.indexOf('@DoesNotThrow'),
        '@DoesNotThrow() void invalid() {\n'
                '  throw Object();\n'
                '}'
            .length,
      ),
    ]);
  }

  Future<void> test_doesNotThrowIgnoresNestedClosure() async {
    await assertNoDiagnostics(r'''
import 'package:dart_exception_lint/dart_exception_lint.dart';

@DoesNotThrow()
void valid() {
  void callback() {
    throw Object();
  }
  callback;
}
''');
  }

  Future<void> test_mayThrowCannotDescribeAsyncResult() async {
    const code = r'''
import 'package:dart_exception_lint/dart_exception_lint.dart';

@MayThrow([Exception])
Future<String> invalid() async => 'value';
''';

    await assertDiagnostics(code, [
      lint(
        code.indexOf('@MayThrow'),
        "@MayThrow([Exception]) Future<String> invalid() async => 'value';"
            .length,
      ),
    ]);
  }
}
