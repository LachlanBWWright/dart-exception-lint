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

  Future<void> test_numeric_compoundDivision_reports() async {
    const code = r'''
void f(int value, int divisor) { value ~/= divisor; }
''';
    await assertDiagnostics(code, [lint(code.indexOf('value ~/='), 17)]);
  }

  Future<void> test_numeric_negativeShift_reports() async {
    const code = r'''
int f(int value) => value << -1;
''';
    await assertDiagnostics(code, [lint(code.indexOf('value <<'), 11)]);
  }

  Future<void> test_numeric_divisionExceptionCatch_isNotPortable() async {
    const code = r'''
int f(int value, int divisor) {
  try { return value ~/ divisor; } on Exception { return 0; }
}
''';
    await assertDiagnostics(code, [lint(code.indexOf('value ~/'), 16)]);
  }

  Future<void> test_numeric_literalProofs_areSafe() async {
    await assertNoDiagnostics(r'''
int f() => (12 ~/ 2) + (12 % 5) + (1 << 2);
''');
  }

  Future<void> test_numeric_divisionUnsupportedCatch_contains() async {
    await assertNoDiagnostics(r'''
int f(int value, int divisor) {
  try { return value ~/ divisor; } on UnsupportedError { return 0; }
}
''');
  }

  Future<void> test_covariantGenericReceiver_insertion_reports() async {
    const code = r'''
void f(List<Object> values, Object value) {
  values.add(value);
}
''';
    await assertDiagnostics(code, [lint(code.lastIndexOf('value'), 5)]);
  }

  Future<void> test_covariantGenericReceiver_typedCatch_contains() async {
    await assertNoDiagnostics(r'''
void f(List<Object> values, Object value) {
  try { values.add(value); } on TypeError {}
}
''');
  }

  Future<void> test_relationalPattern_implicitOperandCast_reports() async {
    const code = r'''
const dynamic limit = 'invalid';
void f(int value) {
  if (value case > limit) {}
}
''';
    await assertDiagnostics(code, [lint(code.lastIndexOf('limit'), 5)]);
  }

  Future<void>
  test_genericPatternNullAssert_nullableInstantiation_reports() async {
    const code = r'''
void f<T>(T value) {
  if (value case var text!) { print(text); }
}
''';
    await assertDiagnostics(code, [lint(code.indexOf('var text!'), 9)]);
  }

  Future<void> test_patternCast_reports() async {
    const code = r'''
void f(Object value) {
  if (value case var text as String) { print(text); }
}
''';
    await assertDiagnostics(code, [lint(code.indexOf('String'), 6)]);
  }

  Future<void> test_patternCast_typedCatch_contains() async {
    await assertNoDiagnostics(r'''
void f(Object value) {
  try {
    if (value case var text as String) { print(text); }
  } on TypeError {}
}
''');
  }

  Future<void> test_patternCast_provenSubtype_isSafe() async {
    await assertNoDiagnostics(r'''
void f(String value) {
  // ignore: unnecessary_cast_pattern
  if (value case var text as Object) { print(text); }
}
''');
  }

  Future<void> test_patternNullAssert_reports() async {
    const code = r'''
void f(String? value) {
  if (value case var text!) { print(text); }
}
''';
    await assertDiagnostics(code, [lint(code.indexOf('var text!'), 9)]);
  }

  Future<void> test_patternNullAssert_typedCatch_contains() async {
    await assertNoDiagnostics(r'''
void f(String? value) {
  try {
    if (value case var text!) { print(text); }
  } on TypeError {}
}
''');
  }

  Future<void> test_typedVariablePattern_failedMatch_isNormal() async {
    await assertNoDiagnostics(r'''
void f(Object value) {
  if (value case String text) { print(text); }
}
''');
  }

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
      lint(
        code.indexOf('parse'),
        'parse'.length,
        messageContainsAll: ['int.parse'],
      ),
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

  Future<void> test_cast_reportsByDefault() async {
    const code = r'''
void f(Object value) {
  value as String;
}
''';

    await assertDiagnostics(code, [
      lint(code.lastIndexOf('String'), 'String'.length),
    ]);
  }

  Future<void> test_indexAccess_reportsByDefault() async {
    const code = r'''
void f(List<int> values) {
  values[99];
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('values[99]'), 'values[99]'.length),
    ]);
  }

  Future<void> test_customJsonDecodeName_notReported() async {
    await assertNoDiagnostics(r'''
String jsonDecode(String value) => value;

void f() {
  jsonDecode('value');
}
''');
  }

  Future<void> test_customCollectionMethodName_notReported() async {
    await assertNoDiagnostics(r'''
class CustomCollection {
  String first() => 'value';
  String firstWhere(bool Function(String) test) => 'value';
}

void f(CustomCollection values) {
  values.first();
  values.firstWhere((value) => true);
}
''');
  }

  Future<void> test_firstWhere_withOrElse_notReported() async {
    await assertNoDiagnostics(r'''
void f(List<int> values) {
  values.firstWhere((value) => value > 10, orElse: () => 0);
}
    ''');
  }

  Future<void> test_lastWhere_withoutOrElse_reports() async {
    const code = r'''
void f(List<int> values) {
  values.lastWhere((value) => value > 10);
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('lastWhere'), 'lastWhere'.length),
    ]);
  }

  Future<void> test_lateRead_reports() async {
    const code = r'''
late String value;

void f() {
  print(value);
}
''';

    await assertDiagnostics(code, [
      lint(code.lastIndexOf('value'), 'value'.length),
    ]);
  }

  Future<void> test_integerDivision_reports() async {
    const code = r'''
void f(int value) {
  print(value ~/ 0);
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('value ~/ 0'), 'value ~/ 0'.length),
    ]);
  }

  Future<void> test_assertions_report() async {
    const code = r'''
void f(bool condition) {
  assert(condition);
}
''';

    await assertDiagnostics(code, [
      lint(code.lastIndexOf('condition'), 'condition'.length),
    ]);
  }

  Future<void> test_argumentChecks_report() async {
    const code = r'''
void f(Object? value) {
  ArgumentError.checkNotNull(value);
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('checkNotNull'), 'checkNotNull'.length),
    ]);
  }

  Future<void> test_boundsAndSubstringOperations_report() async {
    const code = r'''
void f(List<int> values, String text) {
  values.elementAt(99);
  text.substring(99);
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('elementAt'), 'elementAt'.length),
      lint(code.indexOf('substring'), 'substring'.length),
    ]);
  }

  Future<void> test_validatingConstructors_report() async {
    const code = r'''
void f(String pattern) {
  RegExp(pattern);
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('RegExp'), 'RegExp'.length),
    ]);
  }

  Future<void> test_subtleCollectionStateOperations_report() async {
    const code = r'''
void f(Iterable<int> values, String text) {
  values.singleWhere((value) => value > 10);
  values.lastWhere((value) => value > 10);
  text.codeUnitAt(0);
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('singleWhere'), 'singleWhere'.length),
      lint(code.indexOf('lastWhere'), 'lastWhere'.length),
      lint(code.indexOf('codeUnitAt'), 'codeUnitAt'.length),
    ]);
  }

  Future<void> test_subtleOperations_insideTypedCatch_areHandled() async {
    await assertNoDiagnostics(r'''
void f(Iterable<int> values, String text) {
  try {
    values.singleWhere((value) => value > 10);
    text.codeUnitAt(0);
  } on Object {}
}
    ''');
  }

  Future<void> test_rangeError_isHandledByArgumentErrorCatch() async {
    await assertNoDiagnostics(r'''
void f(List<int> values) {
  try {
    values.elementAt(99);
  } on ArgumentError {}
}
''');
  }

  Future<void> test_exceptionCatch_doesNotCatchRangeError() async {
    const code = 'void f(List<int> xs) { try { xs[99]; } on Exception {} }';
    await assertDiagnostics(code, [lint(code.indexOf('xs[99]'), 6)]);
  }

  Future<void> test_errorCatch_doesNotCatchFormatException() async {
    const code = "void f(String s) { try { int.parse(s); } on Error {} }";
    await assertDiagnostics(code, [lint(code.indexOf('parse'), 5)]);
  }

  Future<void> test_errorCatch_catchesRangeError() async {
    await assertNoDiagnostics(
      'void f(List<int> xs) { try { xs[99]; } on Error {} }',
    );
  }

  Future<void> test_implicitCasts_allTypedBoundaries() async {
    const code = r"""
void takes(int value) {}
int f(dynamic value) {
  int local = value;
  local = value;
  takes(value);
  return value;
}
""";
    final first = code.indexOf('value', code.indexOf('int local'));
    final second = code.indexOf('value', first + 5);
    final third = code.indexOf('value', second + 5);
    final fourth = code.indexOf('value', third + 5);
    await assertDiagnostics(code, [
      lint(first, 5),
      lint(second, 5),
      lint(third, 5),
      lint(fourth, 5),
    ]);
  }

  Future<void> test_implicitCast_caughtTypeErrorIsSafe() async {
    await assertNoDiagnostics(
      'int f(dynamic value) { try { return value; } on TypeError { return 0; } }',
    );
  }

  Future<void> test_dynamicFunctionTypeBoundary_typedCatchContains() async {
    await assertNoDiagnostics(
      'void f(dynamic value) { try { void Function(String) callback = value; } '
      'on TypeError {} }',
    );
  }

  Future<void> test_redundantCast_isSafe() async {
    await assertNoDiagnostics('Object f(String value) => value as Object;');
  }
}
