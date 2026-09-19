// ignore_for_file: non_constant_identifier_names

import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:analyzer/src/lint/registry.dart';
import 'package:dart_exception_lint/src/rules/catch_async_error_sources_rule.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(CatchAsyncErrorSourcesRuleTest);
  });
}

@reflectiveTest
class CatchAsyncErrorSourcesRuleTest extends AnalysisRuleTest {
  @override
  String get analysisRule => _rule.name;

  @override
  void setUp() {
    Registry.ruleRegistry.registerLintRule(_rule);
    super.setUp();
  }

  static final CatchAsyncErrorSourcesRule _rule = CatchAsyncErrorSourcesRule();

  Future<void> test_failingFutureContract_reportsAtAwait() async {
    const code = r'''
class ReturnsFailingFuture {
  const ReturnsFailingFuture(this.exceptionTypes);
  final List<Type> exceptionTypes;
}

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
      lint(
        code.indexOf('await'),
        'await load()'.length,
        messageContainsAll: ['load'],
      ),
    ]);
  }

  Future<void> test_awaitedHelperInsideTryCatch_notReported() async {
    await assertNoDiagnostics(r'''
class BoomException implements Exception {}

Future<String> load() => Future.error(BoomException());

Future<void> f() async {
  try {
    await load();
  } catch (_) {}
}
''');
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

  Future<void> test_fieldFuture_canBeConsumedByAnotherMethod() async {
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

  Future<void>
  test_futureStoredInField_isNotReportedAsLocalAbandonment() async {
    await assertNoDiagnostics(r'''
import 'dart:async';

class Holder {
  Future<void>? pending;

  void start() {
    this.pending = Future.error(Exception('boom'));
  }
}
''');
  }

  Future<void> test_unawaitedFutureError_isNotConsideredHandled() async {
    const code = r'''
import 'dart:async';

void f() {
  unawaited(Future.error(Exception('boom')));
}
''';

    await assertDiagnostics(code, [lint(code.indexOf('Future.error'), 31)]);
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
}
