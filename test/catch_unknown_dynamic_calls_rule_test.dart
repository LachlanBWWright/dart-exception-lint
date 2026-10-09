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
  Future<void> test_finallyReturn_doesNotContainUnobservedFuture() async {
    const code = r'''
void f(Future<void> Function() callback) {
  try { callback(); } finally { return; }
}
''';
    await assertDiagnostics(code, [lint(code.lastIndexOf('callback();'), 8)]);
  }

  Future<void>
  test_unknownFuture_awaitedConsumerDoesNotProveObservation() async {
    const code = r'''
Future<void> discard(Future<void> value) async {}
Future<void> f(Future<void> Function() callback) async {
  try { await discard(callback()); } catch (_) {}
}
''';
    await assertDiagnostics(code, [lint(code.lastIndexOf('callback()'), 8)]);
  }

  Future<void>
  test_unknownFuture_consumerHandlerDoesNotProveObservation() async {
    const code = r'''
Future<void> discard(Future<void> value) async {}
void f(Future<void> Function() callback) {
  try { discard(callback()).catchError((_) {}); } catch (_) {}
}
''';
    await assertDiagnostics(code, [lint(code.lastIndexOf('callback()'), 8)]);
  }

  Future<void>
  test_unknownFuture_parenthesizedAwaitRetainsScheduledUncertainty() async {
    const code = r'''
Future<void> f(Future<void> Function() callback) async {
  try { await (callback()); } catch (_) {}
}
''';
    await assertDiagnostics(code, [lint(code.lastIndexOf('callback()'), 8)]);
  }

  Future<void> test_externalFuture_creationCatchRetainsUncertainty() async {
    const code = r'''
external Future<void> nativeOperation();
void f() {
  try { nativeOperation(); } catch (_) {}
}
''';
    await assertDiagnostics(code, [
      lint(code.lastIndexOf('nativeOperation();'), 15),
    ]);
  }

  Future<void> test_externalFuture_awaitCatchContainsBothChannels() async {
    await assertNoDiagnostics(r'''
external Future<void> nativeOperation();
Future<void> f() async {
  try { await nativeOperation(); } catch (_) {}
}
''');
  }

  Future<void> test_externalFuture_abandonedByWrapperCannotBeCaught() async {
    const code = r'''
external Future<void> nativeOperation();
Future<void> wrapper() async {
  try { nativeOperation(); } catch (_) {}
}
Future<void> f() async {
  try { await wrapper(); } catch (_) {}
}
''';
    await assertDiagnostics(code, [
      lint(code.lastIndexOf('nativeOperation();'), 15),
      lint(code.lastIndexOf('wrapper();'), 7),
    ]);
  }

  Future<void> test_unknownFuture_creationCatchRetainsUncertainty() async {
    const code = r'''
void f(Future<void> Function() callback) {
  try { callback(); } catch (_) {}
}
''';
    await assertDiagnostics(code, [lint(code.lastIndexOf('callback();'), 8)]);
  }

  Future<void>
  test_unknownFuture_awaitCatchRetainsScheduledUncertainty() async {
    const code = r'''
Future<void> f(Future<void> Function() callback) async {
  try { await callback(); } catch (_) {}
}
''';
    await assertDiagnostics(code, [lint(code.lastIndexOf('callback()'), 8)]);
  }

  Future<void>
  test_unknownFuture_handlerDoesNotContainSynchronousThrow() async {
    const code = r'''
void f(Future<void> Function() callback) {
  callback().catchError((_) {});
}
''';
    await assertDiagnostics(code, [
      lint(code.lastIndexOf('callback().'), 8),
      lint(code.indexOf('catchError'), 10),
    ]);
  }

  Future<void>
  test_unknownFuture_handlerAndCatchRetainScheduledUncertainty() async {
    const code = r'''
void f(Future<void> Function() callback) {
  try { callback().catchError((_) {}); } catch (_) {}
}
''';
    await assertDiagnostics(code, [lint(code.lastIndexOf('callback()'), 8)]);
  }

  Future<void> test_objectAndPrimitivePatterns_failedMatchIsNormal() async {
    await assertNoDiagnostics(r'''
final class Data { int get value => 1; }
void f(Object value) {
  if (value case Data(value: 1)) {}
}
void numeric(int value) {
  if (value case > 0 && < 10) {}
}
''');
  }

  Future<void> test_nestedExternal_isIndependentOfDeclarationOrder() async {
    const code = r'''
void caller() { wrapper(); }
void wrapper() { nativeOperation(); }
external void nativeOperation();
''';
    await assertDiagnostics(code, [
      lint(code.indexOf('wrapper();'), 7),
      lint(code.indexOf('nativeOperation();'), 15),
    ]);
  }

  Future<void> test_scheduledMicrotask_surroundingCatchCannotContain() async {
    // The analyzer's mock SDK omits this real dart:async declaration.
    final asyncFile = sdkRoot.getFile('lib/async/async.dart');
    newFile(
      asyncFile.path,
      '${asyncFile.readAsStringSync()}\n'
      'void scheduleMicrotask(void Function() callback) {}\n',
    );
    const code = r'''
import 'dart:async';
void f(void Function() callback) {
  try { scheduleMicrotask(callback); } catch (_) {}
}
''';
    await assertDiagnostics(code, [
      lint(code.indexOf('scheduleMicrotask'), 17),
    ]);
  }

  @override
  String get analysisRule => _rule.name;

  @override
  void setUp() {
    Registry.ruleRegistry.registerLintRule(_rule);
    super.setUp();
  }

  static final CatchUnknownDynamicCallsRule _rule =
      CatchUnknownDynamicCallsRule();

  Future<void> test_unknownBoundary_requiresNoUserAnnotation() async {
    const code = r'''
void f(dynamic value) {
  value.run();
}
''';

    await assertDiagnostics(code, [lint(code.indexOf('run'), 'run'.length)]);
  }

  Future<void> test_abstractReceiverReportsIncompleteDispatch() async {
    const code = r'''
abstract class Worker {
  void run() {}
}

void f(Worker worker) {
  worker.run();
}
''';

    await assertDiagnostics(code, [
      lint(code.lastIndexOf('run'), 'run'.length),
    ]);
  }

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
Future<void> f(dynamic client) async {
  try {
    await client.fetch();
  } catch (_) {}
}
    ''');
  }

  Future<void> test_unknownBoundary_insideNarrowTypedCatch_reports() async {
    const code = r'''
void f(dynamic client) {
  try {
    client.fetch();
  } on Exception {}
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('fetch'), 'fetch'.length),
    ]);
  }

  Future<void> test_unknownBoundary_insideObjectCatch_isHandled() async {
    await assertNoDiagnostics(r'''
Future<void> f(dynamic client) async {
  try {
    await client.fetch();
  } on Object {}
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
  test_dynamicFunctionInvocation_awaitCatchRetainsScheduledUncertainty() async {
    const code = r'''
Future<void> f(dynamic callback) async {
  try {
    await callback();
  } catch (_) {}
}
''';
    await assertDiagnostics(code, [lint(code.lastIndexOf('callback()'), 8)]);
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

  Future<void> test_dynamicIteration_reportsWithoutAnnotation() async {
    const code = r'''
void f(dynamic values) {
  for (final value in values) {
    value;
  }
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('for'), code.indexOf('}') - code.indexOf('for') + 1),
    ]);
  }

  Future<void> test_dynamicAsyncIteration_reportsWithoutAnnotation() async {
    const code = r'''
Future<void> f(dynamic values) async {
  await for (final value in values) {
    value;
  }
}
''';

    await assertDiagnostics(code, [
      lint(
        code.indexOf('await for'),
        code.indexOf('}') - code.indexOf('await for') + 1,
      ),
    ]);
  }

  Future<void> test_dynamicCollectionSpreads_report() async {
    const code = r'''
void f(dynamic values) {
  <dynamic>[...values];
  <dynamic>{...values};
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('values', code.indexOf('...')), 'values'.length),
      lint(code.lastIndexOf('values'), 'values'.length),
    ]);
  }

  Future<void> test_dynamicYieldStar_reports() async {
    const code = r'''
Iterable<dynamic> f(dynamic values) sync* {
  yield* values;
}
''';

    await assertDiagnostics(code, [
      lint(code.lastIndexOf('values'), 'values'.length),
    ]);
  }

  Future<void> test_dynamicControlConditions_report() async {
    const code = r'''
void f(dynamic value) {
  if (value) {}
  while (value) {}
  do {} while (value);
  value ? 'yes' : 'no';
  switch (value) { case true: break; }
}
''';
    final bodyStart = code.indexOf('{');
    final ifOffset = code.indexOf('value', bodyStart);
    final whileOffset = code.indexOf('value', code.indexOf('while'));
    final doOffset = code.indexOf('value', code.indexOf('do'));
    final conditionalOffset = code.indexOf(
      'value',
      code.indexOf(';', doOffset) + 1,
    );

    await assertDiagnostics(code, [
      lint(ifOffset, 'value'.length),
      lint(whileOffset, 'value'.length),
      lint(doOffset, 'value'.length),
      lint(conditionalOffset, 'value'.length),
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
Future<void> f(dynamic first, dynamic second, bool useFirst) async {
  try {
    await (useFirst ? first : second).fetch();
  } catch (_) {}
}
''');
  }

  Future<void> test_universalCatch_dischargesUnknownCallerEffect() async {
    await assertNoDiagnostics(
      'external void nativeOperation(); void helper() { try { nativeOperation(); } catch (_) {} } void f() { helper(); }',
    );
  }

  Future<void> test_knownThrow_doesNotHideUnknownEffect() async {
    const code =
        'void helper(dynamic value) { value.go(); throw FormatException(); } void f(dynamic value) { helper(value); }';
    await assertDiagnostics(code, [
      lint(code.indexOf('go()'), 2),
      lint(code.lastIndexOf('helper(value)'), 6),
    ]);
  }

  Future<void> test_dynamicSwitchSubject_isSafe() async {
    await assertNoDiagnostics(
      'void f(dynamic value) { switch (value) { case true: break; } }',
    );
  }
}
