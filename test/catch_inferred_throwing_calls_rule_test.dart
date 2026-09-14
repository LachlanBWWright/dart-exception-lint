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

  Future<void> test_mayThrowContract_reportsEvenWhenBodyLooksSafe() async {
    const code = r'''
class MayThrow {
  const MayThrow(this.exceptionTypes);
  final List<Type> exceptionTypes;
}

@MayThrow([FormatException])
String decode(String value) => value;

void f(String value) {
  decode(value);
}
''';

    await assertDiagnostics(code, [
      lint(code.lastIndexOf('decode(value)'), 'decode'.length),
    ]);
  }

  Future<void> test_doesNotThrowContract_suppressesInferredBody() async {
    await assertNoDiagnostics(r'''
class DoesNotThrow {
  const DoesNotThrow();
}

@DoesNotThrow()
String safe(String value) {
  throw FormatException();
}

void f(String value) {
  safe(value);
}
''');
  }

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
        messageContainsAll: ['helper'],
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
        messageContainsAll: ['helper'],
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
        messageContainsAll: ['parseValue'],
      ),
    ]);
  }

  Future<void> test_knownSourceType_matchingCatchDoesNotReport() async {
    await assertNoDiagnostics(r'''
int parseValue(String value) => int.parse(value);

void f(String value) {
  try {
    parseValue(value);
  } on FormatException {}
}
''');
  }

  Future<void> test_knownSourceType_mismatchedCatchReports() async {
    const code = r'''
class OtherException implements Exception {}

int parseValue(String value) => int.parse(value);

void f(String value) {
  try {
    parseValue(value);
  } on OtherException {}
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('parseValue(value)'), 'parseValue'.length),
    ]);
  }

  Future<void> test_localFunctionTearOff_preservesInferredThrow() async {
    const code = r'''
void helper() {
  throw 'boom';
}

void f() {
  final callback = helper;
  callback();
}
''';

    await assertDiagnostics(code, [
      lint(code.lastIndexOf('callback'), 'callback'.length),
    ]);
  }

  Future<void> test_interfaceDispatch_includesKnownOverride() async {
    const code = r'''
abstract class Base {
  void run();
}

class Child extends Base {
  @override
  void run() {
    throw 'boom';
  }
}

void f(Base value) {
  value.run();
}
''';

    await assertDiagnostics(code, [
      lint(code.lastIndexOf('run'), 'run'.length),
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

  Future<void> test_supertypeCatch_doesNotReport() async {
    await assertNoDiagnostics(r'''
class BaseException implements Exception {}
class ChildException extends BaseException {}

void helper() {
  throw ChildException();
}

void f() {
  try {
    helper();
  } on BaseException {}
}
''');
  }

  Future<void> test_throwingGetterAndOperator_areInferred() async {
    const code = r'''
class Value {
  int get value => throw Exception();
  Value operator +(Value other) => throw Exception();
}

void f(Value value) {
  value.value;
  value + value;
}
''';

    await assertDiagnostics(code, [
      lint(code.lastIndexOf('value.value') + 'value.'.length, 'value'.length),
      lint(code.lastIndexOf('value + value'), 'value + value'.length),
    ]);
  }

  Future<void> test_throwingGetterAndOperator_insideHelper_areInferred() async {
    const code = r'''
class Value {
  int get value => int.parse('bad');
  int operator +(Value other) => 1 ~/ 0;
}

void helper(Value value) {
  value.value;
  value + value;
}

void f(Value value) {
  helper(value);
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('value.value') + 'value.'.length, 'value'.length),
      lint(code.indexOf('value + value'), 'value + value'.length),
      lint(code.lastIndexOf('helper(value)'), 'helper'.length),
    ]);
  }

  Future<void> test_exceptionBoundary_allowsIntentionalPropagation() async {
    await assertNoDiagnostics(r'''
class ExceptionBoundary {
  const ExceptionBoundary();
}

void helper() {
  throw Exception();
}

@ExceptionBoundary()
void boundary() {
  helper();
}
''');
  }

  Future<void> test_exceptionBoundary_onClass_allowsMemberPropagation() async {
    await assertNoDiagnostics(r'''
class BoomException implements Exception {}
class ExceptionBoundary {
  const ExceptionBoundary();
}

void helper() {
  throw BoomException();
}

@ExceptionBoundary()
class PublicApi {
  void run() {
    helper();
  }
}
''');
  }

  Future<void> test_neverReturningCallable_reportsWithoutSourceBody() async {
    const code = r'''
Never fail() => throw 'boom';

void f() {
  fail();
}
''';

    await assertDiagnostics(code, [
      lint(code.lastIndexOf('fail'), 'fail'.length),
    ]);
  }

  Future<void> test_unreachableThrowAfterReturn_isNotPropagated() async {
    await assertNoDiagnostics(r'''
void helper() {
  return;
  // ignore: dead_code
  throw 'unreachable';
}

void f() {
  helper();
}
''');
  }

  Future<void> test_conditionalThrow_isPropagated() async {
    const code = r'''
void helper(bool shouldThrow) {
  if (shouldThrow) {
    throw 'boom';
  }
}

void f(bool shouldThrow) {
  helper(shouldThrow);
}
''';

    await assertDiagnostics(code, [
      lint(
        code.lastIndexOf('helper(shouldThrow)'),
        'helper'.length,
        messageContainsAll: ['possible throw'],
      ),
    ]);
  }

  Future<void> test_throwCaughtAndRecovered_isNotPropagated() async {
    await assertNoDiagnostics(r'''
void helper() {
  try {
    throw 'boom';
  } catch (_) {
    return;
  }
}

void f() {
  helper();
}
''');
  }

  Future<void> test_rethrowFromHelper_isPropagated() async {
    const code = r'''
void source() {
  throw 'boom';
}

void helper() {
  try {
    source();
  } catch (_) {
    rethrow;
  }
}

void f() {
  helper();
}
''';

    await assertDiagnostics(code, [
      lint(code.lastIndexOf('helper()'), 'helper'.length),
    ]);
  }

  Future<void> test_typedCatchOfSupertype_handlesInferredThrow() async {
    await assertNoDiagnostics(r'''
class BaseFailure implements Exception {}
class SpecificFailure extends BaseFailure {}

void helper() {
  throw SpecificFailure();
}

void f() {
  try {
    helper();
  } on BaseFailure {}
}
''');
  }

  Future<void> test_throwingClosureCapture_isFound() async {
    const code = r'''
void f(bool shouldThrow) {
  void callback() {
    if (shouldThrow) throw 'boom';
  }

  callback();
}
''';

    await assertDiagnostics(code, [
      lint(code.lastIndexOf('callback();'), 'callback'.length),
    ]);
  }

  Future<void>
  test_uninvokedClosure_isNotAttributedToEnclosingFunction() async {
    await assertNoDiagnostics(r'''
void makeCallback() {
  final callback = () {
    throw 'boom';
  };
}

void f() {
  makeCallback();
}
''');
  }

  Future<void> test_constructorFieldInitializer_isPropagated() async {
    const code = r'''
class Service {
  final value = int.parse('bad');
}

void f() {
  Service();
}
''';

    await assertDiagnostics(code, [
      lint(code.lastIndexOf('Service'), 'Service'.length),
    ]);
  }

  Future<void> test_constructorInitializerList_isPropagated() async {
    const code = r'''
class Service {
  final int value;

  Service() : value = int.parse('bad');
}

void f() {
  Service();
}
''';

    await assertDiagnostics(code, [
      lint(code.lastIndexOf('Service'), 'Service'.length),
    ]);
  }

  Future<void> test_throwingIndexOperator_isInferred() async {
    const code = r'''
class Dangerous {
  int operator [](int index) => throw 'boom';
}

void f(Dangerous value) {
  value[0];
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('value[0]'), 'value[0]'.length),
    ]);
  }

  Future<void> test_immediatelyInvokedThrowingClosure_isInferred() async {
    const code = r'''
void f() {
  (() {
    throw 'boom';
  })();
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('(()'), '(() {\n    throw \'boom\';\n  })'.length),
    ]);
  }
}
