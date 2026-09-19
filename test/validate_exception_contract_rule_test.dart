// ignore_for_file: non_constant_identifier_names

import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:analyzer/src/lint/registry.dart';
import 'package:dart_exception_lint/src/rules/validate_exception_contract_rule.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

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
  }

  static final ValidateExceptionContractRule _rule =
      ValidateExceptionContractRule();

  Future<void> test_failingFutureRequiresAsyncReturn() async {
    const code = r'''
class ReturnsFailingFuture {
  const ReturnsFailingFuture(this.exceptionTypes);
  final List<Type> exceptionTypes;
}

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
class DoesNotThrow {
  const DoesNotThrow();
}

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
class DoesNotThrow {
  const DoesNotThrow();
}

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
class MayThrow {
  const MayThrow(this.exceptionTypes);
  final List<Type> exceptionTypes;
}

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
