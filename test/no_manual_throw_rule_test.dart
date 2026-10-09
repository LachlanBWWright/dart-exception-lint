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
  void _addErrorProducerSdkDeclarations() {
    final core = getFile(join(sdkRoot.path, 'lib', 'core', 'core.dart'));
    modifyFile2(
      core,
      core.readAsStringSync().replaceFirst(
        'class Error {',
        'class Error { static Never throwWithStackTrace(Object error, StackTrace stackTrace) => throw error;',
      ),
    );
    final stream = getFile(join(sdkRoot.path, 'lib', 'async', 'stream.dart'));
    modifyFile2(
      stream,
      stream.readAsStringSync().replaceFirst(
        'abstract mixin class Stream<T> {',
        'abstract mixin class Stream<T> { factory Stream.error(Object error, [StackTrace? stackTrace]) => throw error;',
      ),
    );
    final async = getFile(join(sdkRoot.path, 'lib', 'async', 'async.dart'));
    modifyFile2(
      async,
      '${async.readAsStringSync()}\n'
      'abstract class StreamController<T> { void addError(Object error, [StackTrace? stackTrace]); }\n',
    );
  }

  Future<void> test_errorProducer_aliasChainAndParentheses_report() async {
    const code = r'''
void f() {
  final first = Future<void>.error;
  final second = (first);
  (second)(Exception());
}
''';
    await assertDiagnostics(code, [lint(code.indexOf('(second)'), 8)]);
  }

  Future<void> test_errorProducer_explicitCallAndFunctionApply_report() async {
    final core = getFile(join(sdkRoot.path, 'lib', 'core', 'core.dart'));
    modifyFile2(
      core,
      core.readAsStringSync().replaceFirst(
        'abstract final class Function {}',
        'abstract final class Function { static dynamic apply(Function function, List<dynamic> positionalArguments, [Map<Symbol, dynamic>? namedArguments]) => null; }',
      ),
    );
    const code = r'''
void f() {
  final producer = Future<void>.error;
  producer.call(Exception());
  Function.apply(Future<void>.error, [Exception()]);
}
''';
    await assertDiagnostics(code, [
      lint(code.indexOf('call('), 4),
      lint(code.indexOf('apply('), 5),
    ]);
  }

  Future<void>
  test_errorProducer_cascadedCallableAndRecordField_report() async {
    const code = r'''
void f() {
  final action = Future<void>.error;
  action..call(Exception());
  final callbacks = (error: Future<void>.error);
  callbacks..error(Exception());
}
''';
    await assertDiagnostics(code, [
      lint(code.indexOf('call('), 4),
      lint(code.lastIndexOf('error(') - 2, 7),
    ]);
  }

  Future<void> test_errorProducer_callMethodTearoffAliases_report() async {
    const code = r'''
void f() {
  final invoke = Future<void>.error.call;
  invoke(Exception());
  final twice = Future<void>.error.call.call;
  twice(Exception());
  dynamic producer = Future<void>.error;
  final dynamicInvoke = producer.call;
  dynamicInvoke(Exception());
  final record = (call: Future<void>.error);
  record.call(Exception());
}
''';
    await assertDiagnostics(code, [
      lint(code.indexOf('invoke('), 6),
      lint(code.indexOf('twice('), 5),
      lint(code.indexOf('dynamicInvoke('), 13),
      lint(code.indexOf('record.call('), 11),
    ]);
  }

  Future<void>
  test_errorProducer_nestedApply_reportsWithoutUserCallFalsePositive() async {
    final core = getFile(join(sdkRoot.path, 'lib', 'core', 'core.dart'));
    modifyFile2(
      core,
      core.readAsStringSync().replaceFirst(
        'abstract final class Function {}',
        'abstract final class Function { static dynamic apply(Function function, List<dynamic> positionalArguments, [Map<Symbol, dynamic>? namedArguments]) => null; }',
      ),
    );
    const code = r'''
class UserCallable { void call(Object error) {} }
void f(UserCallable callable) {
  Function.apply(Function.apply, [Future<void>.error, [Exception()]]);
  final invoke = callable.call;
  invoke(Exception());
  dynamic dynamicCallable = callable;
  final dynamicInvoke = dynamicCallable.call;
  dynamicInvoke(Exception());
}
''';
    await assertDiagnostics(code, [lint(code.indexOf('apply('), 5)]);
  }

  Future<void>
  test_errorProducer_conditionalAndSwitch_reportKnownCandidate() async {
    const code = r'''
Future<void> safe(Object error, [StackTrace? trace]) => Future<void>.value();
void f(bool choose, Future<void> Function(Object, [StackTrace?]) opaque) {
  final selected = choose ? Future<void>.error : opaque;
  try { selected(Exception()); } catch (_) {}
  final switched = switch (choose) { true => Future<void>.error, false => safe };
  switched(Exception());
}
''';
    await assertDiagnostics(code, [
      lint(code.lastIndexOf('selected('), 8),
      lint(code.lastIndexOf('switched('), 8),
    ]);
  }

  Future<void> test_errorProducer_recordAndConstCollections_report() async {
    const code = r'''
void f() {
  final pair = (Future<void>.error, Future<void>.value);
  pair.$1(Exception());
  const callbacks = [Future<void>.error];
  callbacks[0](Exception());
  const named = {'error': Future<void>.error};
  named['error']!(Exception());
}
''';
    await assertDiagnostics(code, [
      lint(code.indexOf(r'pair.$1'), 7),
      lint(code.indexOf('callbacks[0]'), 12),
      lint(code.indexOf("named['error']!"), 15),
    ]);
  }

  Future<void> test_errorProducer_returnedFactoryAliases_report() async {
    const code = r'''
Future<void> Function(Object, [StackTrace?]) factory() {
  final alias = Future<void>.error;
  return alias;
}
final class Factories {
  static Future<void> Function(Object, [StackTrace?]) make() => Future<void>.error;
}
void f() {
  factory()(Exception());
  Factories.make()(Exception());
}
''';
    await assertDiagnostics(code, [
      lint(code.lastIndexOf('factory()'), 9),
      lint(code.lastIndexOf('Factories.make()'), 16),
    ]);
  }

  Future<void> test_errorProducer_boundMethodAliases_report() async {
    _addErrorProducerSdkDeclarations();
    const code = r'''
import 'dart:async';
void f(Completer<void> completer, StreamController<void> controller) {
  final complete = completer.completeError;
  complete(Exception());
  final pair = (error: controller.addError);
  pair.error(Exception());
}
''';
    await assertDiagnostics(code, [
      lint(code.lastIndexOf('complete('), 8),
      lint(code.indexOf('pair.error('), 10),
    ]);
  }

  Future<void> test_errorProducer_coreAndStreamAliases_report() async {
    _addErrorProducerSdkDeclarations();
    const code = r'''
void f(StackTrace trace) {
  final stream = Stream<void>.error;
  stream(Exception());
  final fail = Error.throwWithStackTrace;
  fail(Exception(), trace);
}
''';
    await assertDiagnostics(code, [
      lint(code.indexOf('stream('), 6),
      lint(code.indexOf('fail('), 4),
    ]);
  }

  Future<void> test_errorProducer_tearoffCreation_isAllowed() async {
    _addErrorProducerSdkDeclarations();
    await assertNoDiagnostics(r'''
import 'dart:async';
void f(Completer<void> completer, StreamController<void> controller) {
  final future = Future<void>.error;
  final stream = Stream<void>.error;
  final fail = Error.throwWithStackTrace;
  final complete = completer.completeError;
  final add = controller.addError;
}
''');
  }

  Future<void> test_errorProducer_mutationInvalidatesStaleAlias() async {
    await assertNoDiagnostics(r'''
Future<void> safe(Object error, [StackTrace? trace]) => Future<void>.value();
void reassigned() {
  var action = Future<void>.error;
  action = safe;
  action(Exception());
}
void captured() {
  var action = Future<void>.error;
  void mutate() { action = safe; }
  mutate();
  action(Exception());
}
''');
  }

  Future<void> test_errorProducer_customNamesAndAliases_areAllowed() async {
    await assertNoDiagnostics(r'''
class Custom {
  static void error(Object error) {}
  static void throwWithStackTrace(Object error, StackTrace trace) {}
  void completeError(Object error) {}
  void addError(Object error) {}
}
void f(Custom custom, StackTrace trace) {
  final error = Custom.error;
  final fail = Custom.throwWithStackTrace;
  final complete = custom.completeError;
  final add = custom.addError;
  error(Exception()); fail(Exception(), trace);
  complete(Exception()); add(Exception());
}
''');
  }

  Future<void> test_finallyReturn_doesNotPermitExplicitThrow() async {
    const code = r'''
void f() { try { throw 'failure'; } finally { return; } }
''';
    await assertDiagnostics(code, [lint(code.indexOf('throw'), 5)]);
  }

  Future<void> test_unreachableExplicitThrow_remainsProhibited() async {
    const code = r'''
void f() {
  return;
  // ignore: dead_code
  throw 'failure';
}
''';
    await assertDiagnostics(code, [lint(code.indexOf('throw'), 5)]);
  }

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
      lint(code.indexOf('throw'), 5, messageContainsAll: ['Exception']),
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
      lint(code.indexOf('throw'), 5, messageContainsAll: ['Error']),
    ]);
  }

  Future<void> test_conditionalExpression() async {
    const code = r'''
class BoomException implements Exception {}

int f(bool condition) => condition ? 1 : throw BoomException();
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('throw'), 5, messageContainsAll: ['Exception']),
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
      lint(code.indexOf('throw'), 5, messageContainsAll: ['Exception']),
    ]);
  }

  Future<void> test_nonExceptionValue() async {
    const code = r'''
void f() {
  throw 'boom';
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('throw'), 5, messageContainsAll: ['non-Exception']),
    ]);
  }

  Future<void> test_objectValue() async {
    const code = r'''
void f() {
  throw Object();
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('throw'), 5, messageContainsAll: ['non-Exception']),
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
      lint(code.indexOf('throw'), 5, messageContainsAll: ['Error']),
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
        messageContainsAll: ['Exception'],
      ),
    ]);
  }

  Future<void> test_handledFutureError_isStillExplicitErrorProduction() async {
    const code =
        'Future<void> f() async { try { await Future.error(Exception()); } catch (_) {} }';
    await assertDiagnostics(code, [
      lint(code.indexOf('Future.error'), 'Future.error'.length),
    ]);
  }

  Future<void> test_completerAndStreamErrorProducers_report() async {
    final asyncFile = getFile(join(sdkRoot.path, 'lib', 'async', 'async.dart'));
    modifyFile2(
      asyncFile,
      '${asyncFile.readAsStringSync()}\nabstract class StreamController<T> { void addError(Object error); }\n',
    );
    const code =
        "import 'dart:async'; void f(Completer<void> c, StreamController<int> s) { c.completeError(Exception()); s.addError(Exception()); }";
    await assertDiagnostics(code, [
      lint(code.indexOf('completeError'), 13),
      lint(code.indexOf('addError'), 8),
    ]);
  }

  Future<void> test_customErrorProducerNames_areAllowed() async {
    await assertNoDiagnostics(
      'class Custom { void addError(Object e) {} void completeError(Object e) {} } void f(Custom c) { c.addError(Exception()); c.completeError(Exception()); }',
    );
  }
}
