// ignore_for_file: non_constant_identifier_names

import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:analyzer/src/lint/registry.dart';
import 'package:dart_exception_lint/src/rules/catch_inferred_throwing_calls_rule.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';
import 'support/exception_annotations.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(CatchInferredThrowingCallsRuleTest);
  });
}

@reflectiveTest
class CatchInferredThrowingCallsRuleTest extends AnalysisRuleTest {
  Future<void> test_shortCircuitAndArgumentOrder_doNotLeakDeadSources() async {
    await assertNoDiagnostics(r'''
// ignore_for_file: dead_code
bool fails() { throw 'failure'; }
bool consume(Object first, bool second) => second;
void helper() {
  false && fails();
  true || fails();
  true ? 1 : fails();
  try { consume(throw 1, fails()); } on int {}
}
void caller() { helper(); }
''');
  }

  Future<void> test_argumentFailure_doesNotHideEarlierEffects() async {
    const code = r'''
bool fails() { throw 'failure'; }
bool consume(bool first, Object second) => first;
void helper() { try { consume(fails(), throw 1); } on int {} }
void caller() { helper(); }
''';
    await assertDiagnostics(code, [
      lint(code.indexOf('fails(),'), 5),
      lint(code.lastIndexOf('helper();'), 6),
    ]);
  }

  Future<void> test_lazyIterable_creationCatchDoesNotContainIteration() async {
    const code = '''
Iterable<int> values() sync* { throw 'failure'; }
Iterable<int> helper() {
  try { return values(); } on String { return []; }
}
void consume() { for (final _ in helper()) {} }
void caller() { consume(); }
''';
    await assertDiagnostics(code, [lint(code.lastIndexOf('consume();'), 7)]);
  }

  Future<void> test_lazyIterable_iterationCatchContainsEffect() async {
    await assertNoDiagnostics('''
Iterable<int> values() sync* { throw 'failure'; }
Iterable<int> helper() {
  try { return values(); } on String { return []; }
}
void consume() { try { for (final _ in helper()) {} } on String {} }
void caller() { consume(); }
''');
  }

  Future<void> test_lazyIterable_terminalConsumerEffectReachesCaller() async {
    const code = '''
Iterable<int> values() sync* { throw 'failure'; }
void consume() { values().toList(); }
void caller() { consume(); }
''';
    await assertDiagnostics(code, [lint(code.lastIndexOf('consume();'), 7)]);
  }

  Future<void> test_lazyIterable_yieldStarCatchContainsEffect() async {
    await assertNoDiagnostics('''
Iterable<int> values() sync* { throw 'failure'; }
Iterable<int> relay() sync* { try { yield* values(); } on String {} }
void consume() { for (final _ in relay()) {} }
void caller() { consume(); }
''');
  }

  Future<void> test_lazyCreationCatchDoesNotContainLaterIteration() async {
    const code = '''
Iterable<int> values() sync* { throw 'failure'; }
Iterable<int> helper() {
  try { return values(); } catch (_) { return []; }
}
void consume() { for (final value in helper()) { value; } }
void caller() { consume(); }
''';
    await assertDiagnostics(code, [lint(code.lastIndexOf('consume();'), 7)]);
  }

  Future<void> test_lazyIterationCatchContainsFailure() async {
    await assertNoDiagnostics('''
Iterable<int> values() sync* { throw 'failure'; }
void consume() { try { for (final value in values()) { value; } } on String {} }
void caller() { consume(); }
''');
  }

  Future<void> test_lazyTerminalConsumerRoutesEffectToCaller() async {
    const code = '''
Iterable<int> values() sync* { throw 'failure'; }
void consume() { values().toList(); }
void caller() { consume(); }
''';
    await assertDiagnostics(code, [lint(code.lastIndexOf('consume();'), 7)]);
  }

  Future<void> test_lazyTerminalConsumerTypedCatchContainsEffect() async {
    await assertNoDiagnostics('''
Iterable<int> values() sync* { throw 'failure'; }
void consume() { try { values().toList(); } on String {} }
void caller() { consume(); }
''');
  }

  Future<void> test_dependency_transitiveTypedEffect() async {
    newFile(
      '$testPackageLibPath/leaf.dart',
      "void fail() { throw 'failure'; }",
    );
    newFile(
      '$testPackageLibPath/dependency.dart',
      "import 'leaf.dart'; void helper() { fail(); }",
    );
    const code = "import 'dependency.dart'; void caller() { helper(); }";
    await assertDiagnostics(code, [lint(code.indexOf('helper();'), 6)]);
  }

  Future<void> test_dependency_transitiveTypedCatch() async {
    newFile(
      '$testPackageLibPath/leaf.dart',
      "void fail() { throw 'failure'; }",
    );
    newFile(
      '$testPackageLibPath/dependency.dart',
      "import 'leaf.dart'; void helper() { fail(); }",
    );
    await assertNoDiagnostics('''
import 'dependency.dart';
void caller() { try { helper(); } on String {} }
''');
  }

  Future<void> test_dependency_safeBody() async {
    newFile('$testPackageLibPath/dependency.dart', 'int helper() => 1;');
    await assertNoDiagnostics(
      "import 'dependency.dart'; void caller() { helper(); }",
    );
  }

  Future<void> test_dependency_exportedPart() async {
    newFile('$testPackageLibPath/api.dart', "export 'dependency.dart';");
    newFile(
      '$testPackageLibPath/dependency.dart',
      "part 'implementation.dart';",
    );
    newFile(
      '$testPackageLibPath/implementation.dart',
      "part of 'dependency.dart'; void helper() { throw 'failure'; }",
    );
    await assertNoDiagnostics('''
import 'api.dart';
void caller() { try { helper(); } on String {} }
''');
  }

  Future<void> test_dependency_lazyInitializerTypedCatch() async {
    newFile(
      '$testPackageLibPath/dependency.dart',
      "int fail() { throw 'failure'; } final value = fail();",
    );
    await assertNoDiagnostics('''
import 'dependency.dart';
void caller() { try { value; } on String {} }
''');
  }

  Future<void>
  test_dependency_conditionalImportUsesSelectedImplementation() async {
    newFile('$testPackageLibPath/stub.dart', 'void fail() { throw 42; }');
    newFile(
      '$testPackageLibPath/native.dart',
      "void fail() { throw 'native'; }",
    );
    newFile(
      '$testPackageLibPath/dependency.dart',
      "import 'stub.dart' if (dart.library.io) 'native.dart'; "
          'void helper() { fail(); }',
    );
    await assertNoDiagnostics('''
import 'dependency.dart';
void caller() { try { helper(); } on int {} }
''');
  }

  Future<void> test_dependency_recursionKeepsFailure() async {
    newFile(
      '$testPackageLibPath/a.dart',
      "import 'b.dart'; void a(bool stop) { if (stop) { throw 'failure'; } b(stop); }",
    );
    newFile(
      '$testPackageLibPath/b.dart',
      "import 'a.dart'; void b(bool stop) { a(stop); }",
    );
    const code = "import 'b.dart'; void caller(bool stop) { b(stop); }";
    await assertDiagnostics(code, [lint(code.indexOf('b(stop);'), 1)]);
  }

  Future<void> test_dependency_deferredImportBodyIsResolved() async {
    newFile(
      '$testPackageLibPath/dependency.dart',
      "void helper() { throw 'failure'; }",
    );
    await assertNoDiagnostics('''
import 'dependency.dart' deferred as dependency;
Future<void> caller() async {
  await dependency.loadLibrary();
  try { dependency.helper(); } on String {}
}
''');
  }

  Future<void> test_finallyReturn_suppressesEscapingCast() async {
    await assertNoDiagnostics(r'''
void helper(dynamic value) {
  try { value as String; } finally { return; }
}
void caller(dynamic value) { helper(value); }
''');
  }

  Future<void> test_finallyConditionalReturn_preservesCastEffect() async {
    const code = r'''
void helper(dynamic value, bool suppress) {
  try { value as String; } finally { if (suppress) return; }
}
void caller(dynamic value, bool suppress) { helper(value, suppress); }
''';
    await assertDiagnostics(code, [lint(code.lastIndexOf('helper(value'), 6)]);
  }

  Future<void> test_finallyThrow_replacesOriginalExceptionType() async {
    await assertNoDiagnostics(r'''
int helper(dynamic value) {
  try { return value as int; } finally { throw 'replacement'; }
}
void caller(dynamic value) { try { helper(value); } on String {} }
''');
  }

  Future<void> test_branchTerminators_unreachableCallDoesNotEscape() async {
    const code = r'''
void fail() { throw 'failure'; }
void helper(bool flag) {
  if (flag) return; else return;
  // ignore: dead_code
  fail();
}
void caller(bool flag) { helper(flag); }
''';
    await assertNoDiagnostics(code);
  }

  Future<void> test_finallyBreak_implicitFailureCanReachFollowingCall() async {
    const code = r'''
external void nativeOperation();
void fail() { throw 'failure'; }
void helper() {
  while (true) {
    try { while (true) { nativeOperation(); } } finally { break; }
  }
  fail();
}
void caller() { helper(); }
''';
    await assertDiagnostics(code, [
      lint(code.lastIndexOf('fail();'), 4),
      lint(code.lastIndexOf('helper();'), 6),
    ]);
  }

  @override
  String get analysisRule => _rule.name;

  @override
  void setUp() {
    Registry.ruleRegistry.registerLintRule(_rule);
    super.setUp();
    installExceptionAnnotations(this);
  }

  static final CatchInferredThrowingCallsRule _rule =
      CatchInferredThrowingCallsRule();

  Future<void>
  test_mixedContract_futureCatchDoesNotHideSynchronousEffect() async {
    const code = r'''
import 'package:dart_exception_lint/dart_exception_lint.dart';
@MayThrow([String])
@ReturnsFailingFuture([Exception])
Future<int> load() => Future.value(1);
Future<void> caller() async {
  try { await load(); } on Exception {}
}
''';
    await assertDiagnostics(code, [lint(code.lastIndexOf('load();'), 4)]);
  }

  Future<void> test_superNoSuchMethodCall_reportsNoSuchMethodError() async {
    const code = r'''
class Adapter {
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
void caller(Adapter adapter, Invocation invocation) {
  adapter.noSuchMethod(invocation);
}
''';
    await assertDiagnostics(code, [lint(code.lastIndexOf('noSuchMethod'), 12)]);
  }

  Future<void> test_superNoSuchMethodErrorCatchContains() async {
    await assertNoDiagnostics(r'''
class Adapter {
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
void caller(Adapter adapter, Invocation invocation) {
  try { adapter.noSuchMethod(invocation); } on Error {}
}
''');
  }

  Future<void> test_covariantOverride_dispatchArgumentCheck_reports() async {
    const code = r'''
sealed class Base { void apply(covariant Object value); }
final class Worker extends Base {
  void apply(covariant String value) {}
}
void f(Base worker, Object value) { worker.apply(value); }
''';
    await assertDiagnostics(code, [lint(code.lastIndexOf('apply'), 5)]);
  }

  Future<void> test_objectPattern_getterEffectsPropagate() async {
    const code = r'''
final class Data {
  int get value { throw 'failure'; }
}
void helper(Data data) {
  if (data case Data(value: var item)) { print(item); }
}
void caller(Data data) { helper(data); }
''';
    await assertDiagnostics(code, [
      lint(code.indexOf('value: var item'), 'value: var item'.length),
      lint(code.lastIndexOf('helper(data)'), 6),
    ]);
  }

  Future<void> test_objectPattern_getterEffectsTypedCatchContains() async {
    await assertNoDiagnostics(r'''
final class Data {
  int get value { throw 'failure'; }
}
void helper(Data data) {
  try {
    if (data case Data(value: var item)) { print(item); }
  } on String {}
}
void caller(Data data) { helper(data); }
''');
  }

  Future<void> test_constantPattern_customEqualityPropagates() async {
    const code = r'''
final class Match {
  const Match();
  bool operator ==(Object other) { throw 'failure'; }
  int get hashCode => 0;
}
const key = Match();
void helper(Object value) {
  if (value case key) {}
}
void caller(Object value) { helper(value); }
''';
    await assertDiagnostics(code, [
      lint(code.indexOf('case key') + 5, 3),
      lint(code.lastIndexOf('helper(value)'), 6),
    ]);
  }

  Future<void> test_nestedContract_isIndependentOfDeclarationOrder() async {
    const code = r'''
import 'package:dart_exception_lint/dart_exception_lint.dart';
void caller() { wrapper(); }
void wrapper() { contracted(); }
@MayThrow([FormatException])
void contracted() {}
''';
    await assertDiagnostics(code, [
      lint(code.indexOf('wrapper();'), 7),
      lint(code.indexOf('contracted();'), 10),
    ]);
  }

  Future<void> test_recursiveComponent_effectReachesEveryCaller() async {
    const code = r'''
void first(bool failure) { second(failure); }
void second(bool failure) {
  if (failure) { throw 'boom'; }
  first(true);
}
void caller(bool failure) { first(failure); }
''';
    await assertDiagnostics(code, [
      lint(code.indexOf('second(failure)'), 6),
      lint(code.indexOf('first(true)'), 5),
      lint(code.lastIndexOf('first(failure)'), 5),
    ]);
  }

  Future<void> test_sdkForEach_callbackThrow_propagates() async {
    const code = r'''
void helper(List<int> values) {
  values.forEach((value) { throw Object(); });
}
void caller(List<int> values) { helper(values); }
''';
    await assertDiagnostics(code, [
      lint(code.indexOf('forEach'), 7),
      lint(code.lastIndexOf('helper(values)'), 6),
    ]);
  }

  Future<void> test_sdkForEach_callbackThrow_containedAtInvocation() async {
    await assertNoDiagnostics(r'''
void helper(List<int> values) {
  try { values.forEach((value) { throw Object(); }); } catch (_) {}
}
void caller(List<int> values) { helper(values); }
''');
  }

  Future<void> test_patternCast_propagatesToCaller() async {
    const code = r'''
void helper(Object value) {
  if (value case var text as String) { print(text); }
}
void caller(Object value) { helper(value); }
''';
    await assertDiagnostics(code, [lint(code.lastIndexOf('helper(value)'), 6)]);
  }

  Future<void> test_patternChecks_containedInHelper() async {
    await assertNoDiagnostics(r'''
void helper(String? value) {
  try {
    if (value case var text!) {}
  } on TypeError {}
}
void caller(String? value) { helper(value); }
''');
  }

  Future<void> test_mayThrowContract_reportsEvenWhenBodyLooksSafe() async {
    const code = r'''
import 'package:dart_exception_lint/dart_exception_lint.dart';

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

  Future<void> test_doesNotThrowContract_preservesContradictoryBody() async {
    const code = r'''
import 'package:dart_exception_lint/dart_exception_lint.dart';
@DoesNotThrow()
String safe(String value) { throw FormatException(); }
void f(String value) { safe(value); }
''';
    await assertDiagnostics(code, [lint(code.lastIndexOf('safe(value)'), 4)]);
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

  Future<void> test_directNumericSources_belongToRuntimeRule() async {
    await assertNoDiagnostics(r'''
void f(int value, int divisor) {
  value ~/ divisor;
  value ~/= divisor;
  value << -1;
}
''');
  }

  Future<void> test_numericCompound_preservesGetterSource() async {
    const code = r'''
class Cell {
  int get value => throw 'getter';
  set value(int replacement) {}
}
void f(Cell cell, int divisor) {
  try { cell.value ~/= divisor; } on UnsupportedError {}
}
''';
    await assertDiagnostics(code, [
      lint(
        code.indexOf('cell.value ~/= divisor'),
        'cell.value ~/= divisor'.length,
      ),
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
import 'package:dart_exception_lint/dart_exception_lint.dart';

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
import 'package:dart_exception_lint/dart_exception_lint.dart';
class BoomException implements Exception {}

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

  Future<void> test_switchThrow_isPossibleRatherThanDefinite() async {
    const code = r'''
void helper(int value) {
  switch (value) {
    case 1:
      throw 'boom';
    default:
      break;
  }
}

void f(int value) {
  helper(value);
}
''';

    await assertDiagnostics(code, [
      lint(
        code.lastIndexOf('helper(value)'),
        'helper'.length,
        messageContainsAll: ['possible throw'],
      ),
    ]);
  }

  Future<void> test_loopThrow_isPossibleRatherThanDefinite() async {
    const code = r'''
void helper(bool enabled) {
  while (enabled) {
    throw 'boom';
  }
}

void f(bool enabled) {
  helper(enabled);
}
''';

    await assertDiagnostics(code, [
      lint(
        code.lastIndexOf('helper(enabled)'),
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

  Future<void> test_partialCatch_doesNotDischargeOtherTypes() async {
    const code =
        "class A implements Exception {} class B implements Exception {} void helper(bool b) { if (b) { throw A(); } throw B(); } void f(bool b) { try { helper(b); } on A {} }";
    await assertDiagnostics(code, [lint(code.lastIndexOf('helper(b)'), 6)]);
  }

  Future<void> test_separateTypedCatches_coverEveryAlternative() async {
    await assertNoDiagnostics(
      "class A implements Exception {} class B implements Exception {} void helper(bool b) { if (b) { throw A(); } throw B(); } void f(bool b) { try { helper(b); } on A {} on B {} }",
    );
  }

  Future<void> test_nestedTypedCatches_coverEveryAlternative() async {
    await assertNoDiagnostics(
      "class A implements Exception {} class B implements Exception {} void helper(bool b) { if (b) { throw A(); } throw B(); } void f(bool b) { try { try { helper(b); } on A {} } on B {} }",
    );
  }

  Future<void> test_exceptionBoundary_preservesEffectAtCaller() async {
    const code =
        "import 'package:dart_exception_lint/dart_exception_lint.dart'; @ExceptionBoundary() int parse(String s) => int.parse(s); void f(String s) { parse(s); }";
    await assertDiagnostics(code, [lint(code.lastIndexOf('parse(s)'), 5)]);
  }

  Future<void>
  test_classExceptionBoundary_preservesMemberEffectAtCaller() async {
    const code =
        "import 'package:dart_exception_lint/dart_exception_lint.dart'; @ExceptionBoundary() class Parser { int parse(String s) => int.parse(s); } void f(Parser parser, String s) { parser.parse(s); }";
    await assertDiagnostics(code, [lint(code.lastIndexOf('parse(s)'), 5)]);
  }

  Future<void> test_caughtExceptionBoundary_hasNoOutwardEffect() async {
    await assertNoDiagnostics(
      "import 'package:dart_exception_lint/dart_exception_lint.dart'; @ExceptionBoundary() int parse(String s) { try { return int.parse(s); } catch (_) { return 0; } } void f(String s) { parse(s); }",
    );
  }

  Future<void> test_knownAndUnknownThrownTypes_requireUniversalCatch() async {
    const code =
        "int helper(String? s) => int.parse(s!); void f(String? s) { try { helper(s); } on FormatException {} }";
    await assertDiagnostics(code, [
      lint(code.lastIndexOf('helper(s)'), 'helper'.length),
    ]);
  }

  Future<void> test_mayThrowContract_typedCatch_usesRepresentedType() async {
    await assertNoDiagnostics(
      'import \'package:dart_exception_lint/dart_exception_lint.dart\'; @MayThrow([FormatException]) String decode(String s) => s; void f(String s) { try { decode(s); } on FormatException {} }',
    );
  }

  Future<void> test_setterAndUnaryOperator_effectsReachCallers() async {
    const code = r"""
class C {
  set value(int v) { throw FormatException(); }
  C operator -() { throw FormatException(); }
}
void write(C c) { c.value = 1; }
C negate(C c) => -c;
void f(C c) { write(c); negate(c); }
""";
    await assertDiagnostics(code, [
      lint(code.indexOf('c.value = 1'), 'c.value = 1'.length),
      lint(code.indexOf('-c'), 2),
      lint(code.lastIndexOf('write(c)'), 5),
      lint(code.lastIndexOf('negate(c)'), 6),
    ]);
  }

  Future<void> test_interpolation_effectReachesCaller() async {
    const code = r"""
class C {
  @override
  String toString() { throw FormatException(); }
}
String render(C c) => '$c';
void f(C c) { render(c); }
""";
    await assertDiagnostics(code, [
      lint(code.indexOf(r'$c'), 2),
      lint(code.lastIndexOf('render(c)'), 6),
    ]);
  }

  Future<void> test_implicitReturnCast_effectReachesCaller() async {
    const code =
        'int convert(dynamic value) => value; void f(dynamic value) { convert(value); }';
    await assertDiagnostics(code, [
      lint(code.lastIndexOf('convert(value)'), 7),
    ]);
  }
}
