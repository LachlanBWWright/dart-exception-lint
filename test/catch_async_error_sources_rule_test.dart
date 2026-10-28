// ignore_for_file: non_constant_identifier_names

import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:analyzer/src/lint/registry.dart';
import 'package:dart_exception_lint/src/rules/catch_async_error_sources_rule.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';
import 'support/exception_annotations.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(CatchAsyncErrorSourcesRuleTest);
  });
}

@reflectiveTest
class CatchAsyncErrorSourcesRuleTest extends AnalysisRuleTest {
  Future<void> test_existingFutures_nestedAggregateAliasesAreHandled() async {
    await assertNoDiagnostics(r'''
Future<void> f() async {
  final first = Future<void>.error('first');
  final second = Future<void>.error(2);
  final pending = ([first], other: {'key': second});
  try { await pending.$1[0]; } on String {}
  try { await pending.other['key']!; } on int {}
}
''');
  }

  Future<void> test_duplicateMapKey_doesNotConsumeReplacedFuture() async {
    const code = r'''
// ignore_for_file: equal_keys_in_map
Future<void> f() async {
  final pending = {'key': Future<void>.error('old'), 'key': Future<void>.error(2)};
  try { await pending['key']!; } catch (_) {}
}
''';
    await assertDiagnostics(code, [
      lint(
        code.indexOf("Future<void>.error('old')"),
        "Future<void>.error('old')".length,
      ),
    ]);
  }

  Future<void> test_spreadList_doesNotInventSlotIdentity() async {
    const code = r'''
Future<void> f(List<Future<void>> prefix) async {
  final pending = [...prefix, Future<void>.error('unknown slot')];
  try { await pending[1]; } catch (_) {}
}
''';
    await assertDiagnostics(code, [
      lint(
        code.indexOf("Future<void>.error('unknown slot')"),
        "Future<void>.error('unknown slot')".length,
      ),
    ]);
  }

  Future<void> test_recordSlots_haveIndependentOwners() async {
    await assertNoDiagnostics(r'''
Future<void> f() async {
  final pending = (Future<void>.error('first'), other: Future<void>.error(2));
  try { await pending.$1; } on String {}
  try { await pending.other; } on int {}
}
''');
  }

  Future<void> test_recordSlots_consumingOneDoesNotConsumeSibling() async {
    const code = r'''
Future<void> f() async {
  final pending = (Future<void>.error('first'), Future<void>.error(2));
  try { await pending.$1; } on String {}
}
''';
    await assertDiagnostics(code, [
      lint(
        code.indexOf('Future<void>.error(2)'),
        'Future<void>.error(2)'.length,
      ),
    ]);
  }

  Future<void> test_recordAlias_preservesSlotIdentity() async {
    await assertNoDiagnostics(r'''
Future<void> f() async {
  final pending = (Future<void>.error('first'), other: Future<void>.error(2));
  final alias = pending;
  try { await alias.$1; } on String {}
  try { await alias.other; } on int {}
}
''');
  }

  Future<void> test_listSlots_haveIndependentOwners() async {
    await assertNoDiagnostics(r'''
Future<void> f() async {
  final pending = [Future<void>.error('first'), Future<void>.error(2)];
  try { await pending[0]; } on String {}
  try { await pending[1]; } on int {}
}
''');
  }

  Future<void> test_mapSlots_haveIndependentOwners() async {
    await assertNoDiagnostics(r'''
Future<void> f() async {
  final pending = {'a': Future<void>.error('first'), 'b': Future<void>.error(2)};
  try { await pending['a']!; } on String {}
  try { await pending['b']!; } on int {}
}
''');
  }

  Future<void> test_joinedFuture_checksEveryAlternative() async {
    const code = r'''
Future<void> f(bool choose) async {
  late Future<void> pending;
  if (choose) { pending = Future<void>.error('first'); }
  else { pending = Future<void>.error(2); }
  try { await pending; } on String {}
}
''';
    await assertDiagnostics(code, [
      lint(code.indexOf('await pending'), 'await pending'.length),
    ]);
  }

  Future<void> test_mutatedList_doesNotDischargeReplacedFuture() async {
    const code = r'''
Future<void> f() async {
  final pending = [Future<void>.error('old')];
  final alias = pending;
  pending[0] = Future<void>.value();
  try { await alias[0]; } catch (_) {}
}
''';
    await assertDiagnostics(code, [
      lint(
        code.indexOf("Future<void>.error('old')"),
        "Future<void>.error('old')".length,
      ),
    ]);
  }

  Future<void> test_unknownIndex_doesNotConsumeArbitrarySlot() async {
    const code = r'''
Future<void> f(int index) async {
  final pending = [Future<void>.error('first'), Future<void>.error(2)];
  try { await pending[index]; } catch (_) {}
}
''';
    await assertDiagnostics(code, [
      lint(
        code.indexOf("Future<void>.error('first')"),
        "Future<void>.error('first')".length,
      ),
      lint(
        code.indexOf('Future<void>.error(2)'),
        'Future<void>.error(2)'.length,
      ),
    ]);
  }

  Future<void> test_asyncStreamConsumer_failureReachesWrapperFuture() async {
    const code = r'''
Stream<int> values() async* { throw 'failure'; }
Future<void> helper() async {
  await for (final value in values()) {}
}
void caller() { helper(); }
''';
    await assertDiagnostics(code, [
      lint(
        code.indexOf('await for'),
        'await for (final value in values()) {}'.length,
      ),
      lint(code.lastIndexOf('helper();'), 6),
    ]);
  }

  Future<void> test_asyncIterableConsumer_failureReachesWrapperFuture() async {
    const code = r'''
Iterable<int> values() sync* { throw 'failure'; }
Future<void> helper() async {
  for (final value in values()) {}
}
void caller() { helper(); }
''';
    await assertDiagnostics(code, [
      lint(
        code.indexOf('for (final'),
        'for (final value in values()) {}'.length,
      ),
      lint(code.lastIndexOf('helper();'), 6),
    ]);
  }

  Future<void> test_asyncStreamConsumer_callerTypedAwaitCatchContains() async {
    const code = r'''
Stream<int> values() async* { throw 'failure'; }
Future<void> helper() async {
  await for (final value in values()) {}
}
Future<void> caller() async { try { await helper(); } on String {} }
''';
    await assertDiagnostics(code, [
      lint(
        code.indexOf('await for'),
        'await for (final value in values()) {}'.length,
      ),
    ]);
  }

  Future<void>
  test_asyncStreamConsumer_localTypedCatchDischargesWrapper() async {
    await assertNoDiagnostics(r'''
Stream<int> values() async* { throw 'failure'; }
Future<void> helper() async {
  try { await for (final value in values()) {} } on String {}
}
void caller() { helper(); }
''');
  }

  Future<void> test_streamContract_awaitObjectDoesNotContain() async {
    const code = r'''
import 'package:dart_exception_lint/dart_exception_lint.dart';
@ReturnsFailingFuture([String])
Stream<int> values() async* {}
Future<void> f() async { try { await values(); } on String {} }
''';
    await assertDiagnostics(code, [
      lint(code.lastIndexOf('await values()'), 14),
    ]);
  }

  Future<void> test_streamContract_awaitForContains() async {
    await assertNoDiagnostics(r'''
import 'package:dart_exception_lint/dart_exception_lint.dart';
@ReturnsFailingFuture([String])
Stream<int> values() async* {}
Future<void> f() async {
  try { await for (final item in values()) {} } on String {}
}
''');
  }

  Future<void> test_storedFuture_multipleTypesAreCheckedIndependently() async {
    await assertNoDiagnostics(r'''
import 'package:dart_exception_lint/dart_exception_lint.dart';
@ReturnsFailingFuture([String, Exception])
Future<int> load() => Future.value(1);
Future<void> f() async {
  final pending = load();
  try { await pending; } on String {} on Exception {}
}
''');
  }

  Future<void> test_finallyReturn_containsAwaitedFutureFailure() async {
    await assertNoDiagnostics(r'''
Future<void> helper() async {
  try { await Future.error('failure'); } finally { return; }
}
Future<void> caller() async { await helper(); }
''');
  }

  @override
  String get analysisRule => _rule.name;

  @override
  void setUp() {
    Registry.ruleRegistry.registerLintRule(_rule);
    super.setUp();
    installExceptionAnnotations(this);
  }

  static final CatchAsyncErrorSourcesRule _rule = CatchAsyncErrorSourcesRule();

  Future<void> test_inlineAsyncClosure_creationCatchDoesNotContain() async {
    const code = r'''
void f() {
  try { (() async { throw 'failure'; })(); } catch (_) {}
}
''';
    final start = code.indexOf('(() async');
    await assertDiagnostics(code, [
      lint(start, "(() async { throw 'failure'; })".length),
    ]);
  }

  Future<void> test_inlineAsyncClosure_typedAwaitContains() async {
    await assertNoDiagnostics(r'''
Future<void> f() async {
  try { await (() async { throw 'failure'; })(); } on String {}
}
''');
  }

  Future<void> test_mixedContract_futureCatchUsesOnlyFutureTypes() async {
    await assertNoDiagnostics(r'''
import 'package:dart_exception_lint/dart_exception_lint.dart';
@MayThrow([String])
@ReturnsFailingFuture([Exception])
Future<int> load() => Future.value(1);
Future<void> caller() async {
  try { await load(); } on Exception {}
}
''');
  }

  Future<void> test_mixedContract_creationCatchRetainsFutureEffect() async {
    const code = r'''
import 'package:dart_exception_lint/dart_exception_lint.dart';
@MayThrow([String])
@ReturnsFailingFuture([Exception])
Future<int> load() => Future.value(1);
void caller() {
  try { load(); } on String {}
}
''';
    await assertDiagnostics(code, [lint(code.lastIndexOf('load();'), 4)]);
  }

  Future<void> test_failingFutureGetter_unobservedRead_reports() async {
    const code = r'''
import 'package:dart_exception_lint/dart_exception_lint.dart';
final class Api {
  @ReturnsFailingFuture([Exception])
  Future<int> get load => Future.value(1);
}
void f(Api api) { api.load; }
''';
    await assertDiagnostics(code, [lint(code.lastIndexOf('load'), 4)]);
  }

  Future<void> test_failingFutureGetter_typedAwaitContains() async {
    await assertNoDiagnostics(r'''
import 'package:dart_exception_lint/dart_exception_lint.dart';
final class Api {
  @ReturnsFailingFuture([Exception])
  Future<int> get load => Future.value(1);
}
Future<void> f(Api api) async {
  try { await api.load; } on Exception {}
}
''');
  }

  Future<void> test_conditionalConsumer_oneBranchRetainsOwnership() async {
    const code = r'''
void f(bool condition) {
  final pending = Future<void>.error(Exception());
  condition ? pending.catchError((_) {}) : null;
}
''';
    await assertDiagnostics(code, [
      lint(
        code.indexOf('Future<void>.error'),
        'Future<void>.error(Exception())'.length,
      ),
    ]);
  }

  Future<void> test_conditionalConsumer_bothBranchesDischargeOwnership() async {
    await assertNoDiagnostics(r'''
void f(bool condition) {
  final pending = Future<void>.error(Exception());
  condition ? pending.catchError((_) {}) : pending.catchError((_) {});
}
''');
  }

  Future<void> test_switchConsumer_oneCaseRetainsOwnership() async {
    const code = r'''
void f(int choice) {
  final pending = Future<void>.error(Exception());
  switch (choice) {
    case 1: pending.catchError((_) {});
    default: break;
  }
}
''';
    await assertDiagnostics(code, [
      lint(
        code.indexOf('Future<void>.error'),
        'Future<void>.error(Exception())'.length,
      ),
    ]);
  }

  Future<void> test_failingFutureContract_reportsAtAwait() async {
    const code = r'''
import 'package:dart_exception_lint/dart_exception_lint.dart';

@ReturnsFailingFuture([FormatException])
Future<String> load() => Future.value('ok');

Future<void> f() async {
  await load();
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('await load()'), 'await load()'.length),
    ]);
  }

  Future<void> test_awaitedHelperReturningFutureError_reports() async {
    const code = r'''
class BoomException implements Exception {}

Future<String> load() => Future.error(BoomException());

Future<void> f() async {
  await load();
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('Future.error'), 'Future.error'.length),
      lint(
        code.indexOf('await'),
        'await load()'.length,
        messageContainsAll: ['load'],
      ),
    ]);
  }

  Future<void> test_awaitedHelperInsideTryCatch_onlyProducerReports() async {
    const code = r'''
class BoomException implements Exception {}

Future<String> load() => Future.error(BoomException());

Future<void> f() async {
  try {
    await load();
  } catch (_) {}
}
''';
    await assertDiagnostics(code, [
      lint(code.indexOf('Future.error'), 'Future.error'.length),
    ]);
  }

  Future<void> test_awaitedHelperWithCaughtFutureError_notReported() async {
    await assertNoDiagnostics(r'''
class BoomException implements Exception {}

Future<String> load() async {
  try {
    await Future.error(BoomException());
  } catch (_) {
    return 'fallback';
  }
  return 'ok';
}

Future<void> f() async {
  await load();
}
''');
  }

  Future<void> test_listenWithoutOnError_reports() async {
    const code = r'''
void f(Stream<int> stream) {
  stream.listen((value) {});
}
''';

    await assertDiagnostics(code, [
      lint(
        code.indexOf('listen'),
        'listen'.length,
        messageContainsAll: ['Stream.listen'],
      ),
    ]);
  }

  Future<void> test_futureError_withCatchError_notReported() async {
    await assertNoDiagnostics(r'''
import 'dart:async';

Future<void> f() async {
  Future.error(Exception('boom')).catchError((_) {});
}
''');
  }

  Future<void> test_futureError_withThenOnError_notReported() async {
    await assertNoDiagnostics(r'''
import 'dart:async';

Future<void> f() async {
  Future.error(Exception('boom')).then<void>(
    (_) {},
    onError: (_) {},
  );
}
''');
  }

  Future<void> test_futureError_withoutAsyncHandler_reports() async {
    const code = r'''
import 'dart:async';

Future<void> f() async {
  Future.error(Exception('boom')).then<void>((_) {});
}
''';

    await assertDiagnostics(code, [lint(code.indexOf('then'), 'then'.length)]);
  }

  Future<void> test_futureError_insideTryCatch_notReported() async {
    await assertNoDiagnostics(r'''
import 'dart:async';

Future<void> f() async {
  try {
    await Future.error(Exception('boom'));
  } catch (_) {}
}
''');
  }

  Future<void> test_typedCatch_matchesFutureErrorArgument() async {
    await assertNoDiagnostics(r'''
import 'dart:async';

class BoomException implements Exception {}

Future<void> f() async {
  try {
    await Future.error(BoomException());
  } on BoomException {}
}
''');
  }

  Future<void> test_typedCatch_mismatchForFutureErrorArgument_reports() async {
    const code = r'''
import 'dart:async';

class BoomException implements Exception {}
class OtherException implements Exception {}

Future<void> f() async {
  try {
    await Future.error(BoomException());
  } on OtherException {}
}
''';

    await assertDiagnostics(code, [
      lint(
        code.indexOf('await Future.error'),
        'await Future.error(BoomException())'.length,
      ),
    ]);
  }

  Future<void> test_futureError_withNullPositionalOnError_reports() async {
    const code = r'''
import 'dart:async';

Future<void> f() async {
  Future.error(Exception('boom')).then<void>((_) {}, onError: null);
}
''';

    await assertDiagnostics(code, [lint(code.indexOf('then'), 'then'.length)]);
  }

  Future<void> test_unawaitedFutureError_insideTryCatch_stillReports() async {
    const code = r'''
import 'dart:async';

void f() {
  try {
    Future.error(Exception('boom'));
  } catch (_) {}
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('Future.error'), 'Future.error'.length),
    ]);
  }

  Future<void> test_futureError_insideFinally_reports() async {
    const code = r'''
import 'dart:async';

Future<void> f() async {
  try {
    await Future.value();
  } finally {
    await Future.error(Exception('boom'));
  }
}
''';

    await assertDiagnostics(code, [lint(code.lastIndexOf('await'), 37)]);
  }

  Future<void> test_completeError_reports() async {
    const code = r'''
import 'dart:async';

void f(Completer<void> completer) {
  completer.completeError(Exception('boom'));
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('completeError'), 'completeError'.length),
    ]);
  }

  Future<void> test_streamListen_withOnError_notReported() async {
    await assertNoDiagnostics(r'''
import 'dart:async';

void f(Stream<int> stream) {
  stream.listen((value) {}, onError: (_) {});
}
''');
  }

  Future<void> test_streamHandleError_notReported() async {
    await assertNoDiagnostics(r'''
void f(Stream<int> stream) {
  stream.handleError((_) {}).listen((value) {});
}
''');
  }

  Future<void> test_customAddErrorName_notReported() async {
    await assertNoDiagnostics(r'''
class CustomSink {
  void addError(Object error) {}
}

void f(CustomSink sink) {
  sink.addError(Exception('boom'));
}
    ''');
  }

  Future<void> test_streamListen_withNullOnError_reports() async {
    const code = r'''
import 'dart:async';

void f(Stream<int> stream) {
  stream.listen((value) {}, onError: null);
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('listen'), 'listen'.length),
    ]);
  }

  Future<void> test_streamListen_withNullCastOnError_reports() async {
    const code = r'''
import 'dart:async';

void f(Stream<int> stream) {
  stream.listen((value) {}, onError: null as dynamic);
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('listen'), 'listen'.length),
    ]);
  }

  Future<void> test_nullHandleErrorDoesNotProtectListener() async {
    const code = r'''
import 'dart:async';

void f(Stream<int> stream) {
  stream.handleError(null as dynamic).listen((value) {});
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('listen'), 'listen'.length),
    ]);
  }

  Future<void> test_unawaitedFutureError_reports() async {
    const code = r'''
void f() {
  Future.error(Exception('boom'));
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('Future.error'), 'Future.error'.length),
    ]);
  }

  Future<void> test_storedFutureError_reportsAtAwait() async {
    const code = r'''
import 'dart:async';

Future<void> f() async {
  final pending = Future.error(Exception('boom'));
  await pending;
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('await pending'), 'await pending'.length),
    ]);
  }

  Future<void> test_storedFutureError_abandoned_reportsAtCreation() async {
    const code = r'''
import 'dart:async';

void f() {
  final pending = Future.error(Exception('boom'));
}
''';

    await assertDiagnostics(code, [lint(code.indexOf('Future.error'), 31)]);
  }

  Future<void> test_fieldFuture_separateConsumerDoesNotProveHandling() async {
    const code = r'''
import 'dart:async';

class Holder {
  Future<void>? pending;

  void start() {
    this.pending = Future.error(Exception('boom'));
  }

  Future<void> finish() async {
    await pending!;
  }
}
''';

    await assertDiagnostics(code, [
      lint(
        code.indexOf('Future.error'),
        "Future.error(Exception('boom'))".length,
      ),
      lint(code.indexOf('await pending!'), 'await pending!'.length),
    ]);
  }

  Future<void>
  test_storedFutureInsideList_reportsAtCollectionConsumption() async {
    const code = r'''
import 'dart:async';

Future<void> f() async {
  final pending = <Future<void>>[Future.error(Exception('boom'))];
  await pending.first;
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('await pending.first'), 'await pending.first'.length),
    ]);
  }

  Future<void>
  test_storedFutureInsideIndexedList_reportsAtCollectionConsumption() async {
    const code = r'''
import 'dart:async';

Future<void> f() async {
  final pending = <Future<void>>[Future.error(Exception('boom'))];
  await pending[0];
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('await pending[0]'), 'await pending[0]'.length),
    ]);
  }

  Future<void>
  test_multipleStoredFutures_keepIndependentCollectionEffects() async {
    const code = r'''
import 'dart:async';

Future<void> f() async {
  final pending = <Future<void>>[
    Future.error(Exception('first')),
    Future.error(Exception('second')),
  ];
  await pending.first;
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('await pending.first'), 'await pending.first'.length),
      lint(
        code.lastIndexOf('Future.error'),
        'Future.error(Exception(\'second\'))'.length,
      ),
    ]);
  }

  Future<void> test_futureStoredInField_withoutConsumer_reports() async {
    const code = r'''
import 'dart:async';

class Holder {
  Future<void>? pending;

  void start() {
    this.pending = Future.error(Exception('boom'));
  }
}
''';
    await assertDiagnostics(code, [
      lint(
        code.indexOf('Future.error'),
        "Future.error(Exception('boom'))".length,
      ),
    ]);
  }

  Future<void> test_unawaitedFutureError_isNotConsideredHandled() async {
    const code = r'''
import 'dart:async';

void f() {
  unawaited(Future.error(Exception('boom')));
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('Future.error'), 'Future.error'.length),
    ]);
  }

  Future<void> test_handledChainedFuture_isNotReportedAsAbandoned() async {
    await assertNoDiagnostics(r'''
import 'dart:async';

void f() {
  final pending = Future.error(Exception('boom')).catchError((_) {});
}
''');
  }

  Future<void> test_futureCombinators_reportAsyncErrors() async {
    const code = r'''
import 'dart:async';

Future<void> f(Future<int> first, Future<int> second) async {
  await Future.wait([first, second]);
}
''';

    await assertDiagnostics(code, [
      lint(
        code.indexOf('await Future.wait'),
        'await Future.wait([first, second])'.length,
      ),
    ]);
  }

  Future<void> test_unawaitedHelperReturningFailingFuture_reports() async {
    const code = r'''
Future<void> load() => Future.error(Exception('boom'));

void f() {
  load();
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('Future.error'), 'Future.error'.length),
      lint(code.lastIndexOf('load'), 'load'.length),
    ]);
  }

  Future<void> test_syncGenerator_isDeferredUntilIteration() async {
    await assertNoDiagnostics(r'''
Iterable<int> values() sync* {
  yield 1;
  throw 'boom';
}

void f() {
  values();
}
''');
  }

  Future<void> test_syncGenerator_iteration_reportsWithoutCatch() async {
    const code = r'''
Iterable<int> values() sync* {
  throw 'boom';
}

void f() {
  for (final value in values()) {
    print(value);
  }
}
''';

    await assertDiagnostics(code, [
      lint(
        code.indexOf('for (final value'),
        'for (final value in values()) {\n    print(value);\n  }'.length,
      ),
    ]);
  }

  Future<void> test_asyncGenerator_awaitForCatch_contains() async {
    await assertNoDiagnostics(r'''
Stream<int> values() async* { throw 'failure'; }
Future<void> f() async {
  try { await for (final value in values()) {} } on String {}
}
''');
  }

  Future<void> test_streamObjectAwait_doesNotSubscribe() async {
    const code = r'''
Stream<int> values() async* { throw 'failure'; }
Future<void> f() async {
  try { await values(); } catch (_) {}
}
''';
    await assertDiagnostics(code, [
      lint(code.lastIndexOf('await values()'), 14),
    ]);
  }

  Future<void> test_asyncGenerator_awaitFor_reports() async {
    const code = r'''
import 'dart:async';

Stream<int> values() async* {
  yield 1;
  throw 'boom';
}

Future<void> f() async {
  await for (final value in values()) {
    print(value);
  }
}
''';

    await assertDiagnostics(code, [
      lint(
        code.indexOf('await for'),
        'await for (final value in values()) {\n    print(value);\n  }'.length,
      ),
    ]);
  }

  Future<void> test_filteredCatchError_false_reports() async {
    const code =
        'void f() { Future.error(Exception()).catchError((_) {}, test: (_) => false); }';
    await assertDiagnostics(code, [lint(code.indexOf('catchError'), 10)]);
  }

  Future<void> test_filteredCatchError_unknown_reports() async {
    const code =
        'void f(bool Function(Object) accepts) { Future.error(Exception()).catchError((_) {}, test: accepts); }';
    await assertDiagnostics(code, [lint(code.indexOf('catchError'), 10)]);
  }

  Future<void> test_filteredCatchError_true_isHandled() async {
    await assertNoDiagnostics(
      'void f() { Future.error(Exception()).catchError((_) {}, test: (_) => true); }',
    );
  }

  Future<void> test_filteredStreamHandler_false_reports() async {
    const code =
        'void f(Stream<int> s) { s.handleError((_) {}, test: (_) => false).listen((_) {}); }';
    await assertDiagnostics(code, [lint(code.indexOf('listen'), 6)]);
  }

  Future<void> test_filteredStreamHandler_true_isHandled() async {
    await assertNoDiagnostics(
      'void f(Stream<int> s) { s.handleError((_) {}, test: (_) => true).listen((_) {}); }',
    );
  }

  Future<void> test_customCatchErrorName_doesNotProtectProducer() async {
    const code =
        'void catchError(Future<dynamic> future) {} void f() { catchError(Future.error(Exception())); }';
    await assertDiagnostics(code, [
      lint(code.indexOf('Future.error'), 'Future.error'.length),
    ]);
  }

  Future<void> test_explicitFieldAwait_hasConsistentOwnership() async {
    const code =
        'class Holder { Future<void>? pending; void start() { this.pending = Future.error(Exception()); } Future<void> finish() async { await this.pending!; } }';
    await assertDiagnostics(code, [
      lint(code.indexOf('Future.error'), 'Future.error(Exception())'.length),
      lint(code.indexOf('await this.pending!'), 'await this.pending!'.length),
    ]);
  }

  Future<void> test_sameNamedFields_doNotShareOwnership() async {
    const code =
        'class A { Future<void>? pending; void start() { pending = Future.error(Exception()); } } class B { Future<void>? pending; Future<void> finish() async { await pending!; } }';
    await assertDiagnostics(code, [
      lint(code.indexOf('Future.error'), 'Future.error(Exception())'.length),
      lint(code.indexOf('await pending!'), 'await pending!'.length),
    ]);
  }

  Future<void> test_returnedFailingFuture_reports() async {
    const code = 'Future<void> f() { return Future.error(Exception()); }';
    await assertDiagnostics(code, [
      lint(code.indexOf('Future.error'), 'Future.error'.length),
    ]);
  }

  Future<void> test_storedFuture_laterCatchError_handlesOwnership() async {
    await assertNoDiagnostics(
      'void f() { final pending = Future.error(Exception()); pending.catchError((_) {}); }',
    );
  }

  Future<void>
  test_storedFuture_laterFilteredCatchError_doesNotHandleOwnership() async {
    const code =
        'void f() { final pending = Future.error(Exception()); pending.catchError((_) {}, test: (_) => false); }';
    await assertDiagnostics(code, [
      lint(code.indexOf('Future.error'), 'Future.error(Exception())'.length),
      lint(code.indexOf('catchError'), 'catchError'.length),
    ]);
  }

  Future<void> test_returnedFailingHelper_reportsWithoutCaller() async {
    const code =
        'Future<void> load() => Future.error(Exception()); Future<void> f() => load();';
    await assertDiagnostics(code, [
      lint(code.indexOf('Future.error'), 'Future.error'.length),
      lint(code.lastIndexOf('load()'), 'load'.length),
    ]);
  }

  Future<void> test_failingFutureContract_typedCatch_isHandled() async {
    await assertNoDiagnostics(
      'import \'package:dart_exception_lint/dart_exception_lint.dart\'; @ReturnsFailingFuture([FormatException]) Future<String> load() => Future.value("ok"); Future<void> f() async { try { await load(); } on FormatException {} }',
    );
  }

  Future<void> test_handlerOnOnlyOneBranch_retainsOwnership() async {
    const code =
        'void f(bool handle) { final future = Future.error(Exception()); if (handle) { future.catchError((_) {}); } }';
    await assertDiagnostics(code, [
      lint(code.indexOf('Future.error'), 'Future.error(Exception())'.length),
    ]);
  }

  Future<void> test_handlerOnBothBranches_dischargesOwnership() async {
    await assertNoDiagnostics(
      'void f(bool handle) { final future = Future.error(Exception()); if (handle) { future.catchError((_) {}); } else { future.catchError((_) {}); } }',
    );
  }

  Future<void> test_localAlias_preservesOwnership() async {
    await assertNoDiagnostics(
      'void f() { final future = Future.error(Exception()); final alias = future; alias.catchError((_) {}); }',
    );
  }

  Future<void> test_reassignment_retainsAbandonedOldFuture() async {
    const code =
        'void f() { var future = Future.error(Exception()); future = Future.error(Exception()); future.catchError((_) {}); }';
    await assertDiagnostics(code, [
      lint(code.indexOf('Future.error'), 'Future.error(Exception())'.length),
    ]);
  }

  Future<void> test_fieldInstances_doNotShareOwnership() async {
    const code =
        'class H { Future<void>? future; } void f(H a, H b) { a.future = Future.error(Exception()); b.future?.catchError((_) {}); }';
    await assertDiagnostics(code, [
      lint(code.indexOf('Future.error'), 'Future.error(Exception())'.length),
    ]);
  }

  Future<void> test_unverifiedFutureParameter_requiresHandling() async {
    const code = 'Future<void> f(Future<void> input) async { await input; }';
    await assertDiagnostics(code, [
      lint(code.indexOf('await input'), 'await input'.length),
    ]);
  }

  Future<void> test_unverifiedFutureParameter_universalCatchHandles() async {
    await assertNoDiagnostics(
      'Future<void> f(Future<void> input) async { try { await input; } catch (_) {} }',
    );
  }
}
