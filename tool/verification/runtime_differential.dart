import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:dart_exception_lint/src/analysis/inferred_throw_analyzer.dart';
import 'package:dart_exception_lint/src/config/exception_analysis_options.dart';
import 'package:dart_exception_lint/src/config/throwing_api_manifest.dart';

/// A small labeled differential corpus: native VM and JavaScript observations
/// are checked against independently specified source/type/channel expectations.
/// This is a regression gate, not a claim of exhaustive precision or recall.
Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp('exception-runtime-');
  AnalysisContextCollection? collection;
  try {
    await File(
      '${directory.path}/pubspec.yaml',
    ).writeAsString('name: runtime_fixture\nenvironment:\n  sdk: ^3.11.0\n');
    final file = File('${directory.path}/main.dart');
    await file.writeAsString(_fixture);
    collection = AnalysisContextCollection(includedPaths: [directory.path]);
    final unit =
        await collection
                .contextFor(file.path)
                .currentSession
                .getResolvedUnit(file.path)
            as ResolvedUnitResult;
    final analyzer = InferredThrowAnalyzer(
      manifest: ThrowingApiManifest.empty(),
      options: const ExceptionAnalysisOptions(),
      featureSet: unit.libraryElement.featureSet,
      packageRootPath: directory.path,
      knownUnits: {file.path: unit.unit},
    );
    for (final declaration
        in unit.unit.declarations.whereType<FunctionDeclaration>()) {
      if (const {
            'constantUnreachable',
            'exactDispatch',
            'skippedDoCondition',
            'forwardCaught',
            'adoptCaught',
          }.contains(declaration.name.lexeme) &&
          analyzer
              .summarizeExecutable(declaration.declaredFragment!.element)
              .hasAnyThrowSource) {
        throw StateError(
          '${declaration.name.lexeme} retained an impossible effect',
        );
      }
      final suppressed = _suppressedEffects[declaration.name.lexeme];
      if (suppressed != null) {
        final summary = analyzer.summarizeExecutable(
          declaration.declaredFragment!.element,
        );
        if (summary.sources.any(
          (source) => source.exceptionTypes.contains(suppressed),
        )) {
          throw StateError(
            '${declaration.name.lexeme} leaked its suppressed $suppressed effect',
          );
        }
      }
      final unknownChannel = _unknownEffects[declaration.name.lexeme];
      if (unknownChannel != null) {
        final summary = analyzer.summarizeExecutable(
          declaration.declaredFragment!.element,
        );
        if (!summary.effects.any(
          (effect) =>
              effect.channel.name == unknownChannel &&
              effect.certainty.name == 'unknown',
        )) {
          throw StateError(
            '${declaration.name.lexeme} lost unknown/$unknownChannel',
          );
        }
      }
      final expected = _effects[declaration.name.lexeme];
      if (expected == null) continue;
      final summary = analyzer.summarizeExecutable(
        declaration.declaredFragment!.element,
      );
      if (!summary.effects.any(
        (effect) =>
            effect.channel.name == expected.$1 &&
            effect.source.exceptionTypes.contains(expected.$2),
      )) {
        throw StateError(
          '${declaration.name.lexeme} lost ${expected.$1}/${expected.$2}',
        );
      }
    }
    Future<void> verify(
      String executable,
      List<String> arguments,
      String platform,
    ) async {
      final result = await Process.run(
        executable,
        arguments,
        workingDirectory: directory.path,
      );
      if (result.exitCode != 0) {
        throw StateError('$platform failed: ${result.stderr}');
      }
      if ((result.stdout as String).trim().isEmpty) {
        throw StateError(
          '$platform did not finish its runtime probes: ${result.stderr}',
        );
      }
      final observed = jsonDecode((result.stdout as String).trim());
      if (jsonEncode(observed) != jsonEncode(_observations)) {
        throw StateError(
          '$platform observed $observed, expected $_observations',
        );
      }
      stdout.writeln(
        '$platform: ${_observations.length} labeled runtime observations match.',
      );
    }

    await verify(Platform.resolvedExecutable, [file.path], 'Dart VM');
    final javascript = '${directory.path}/main.js';
    final compile = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'js',
      file.path,
      '-o',
      javascript,
    ], workingDirectory: directory.path);
    if (compile.exitCode != 0) {
      throw StateError('JavaScript compilation failed: ${compile.stderr}');
    }
    // dart2js targets a browser global. Node provides the same timers and
    // microtasks after exposing its global object as `self`.
    await verify('node', [
      '-e',
      'globalThis.self = globalThis; require(process.argv[1]);',
      javascript,
    ], 'Dart JavaScript (Node)');
  } finally {
    await collection?.dispose();
    await directory.delete(recursive: true);
  }
}

const _effects = {
  'stoppedPropertyWrite': ('synchronous', 'int'),
  'stoppedCompoundPropertyWrite': ('synchronous', 'String'),
  'stoppedIndexWrite': ('synchronous', 'int'),
  'stoppedCompoundIndexWrite': ('synchronous', 'RangeError'),
  'covariantIndexWrite': ('synchronous', 'TypeError'),
  'storedLazyIterator': ('synchronous', 'String'),
  'blockedLazyConsumer': ('synchronous', 'int'),
  'stoppedGuardCase': ('synchronous', 'int'),
  'stoppedStatementGuard': ('synchronous', 'int'),
  'groupedStatementCase': ('synchronous', 'int'),
  'parenthesizedNullAssertion': ('synchronous', 'TypeError'),
  'postfixAssertion': ('synchronous', 'TypeError'),
  'stoppedCascade': ('synchronous', 'int'),
  'stoppedCollection': ('synchronous', 'int'),
  'stoppedCollectionLoop': ('synchronous', 'int'),
  'stoppedInvocation': ('synchronous', 'int'),
  'stoppedInitializer': ('synchronous', 'int'),
  'continuedUpdate': ('synchronous', 'String'),
  'superDispatch': ('synchronous', 'String'),
  'adoptFailure': ('future', 'String'),
  'adoptDiscarded': ('scheduled', 'String'),
  'forwardFailure': ('future', 'String'),
  'forwardDiscarded': ('scheduled', 'String'),
  'callbackFailure': ('synchronous', 'String'),
  'callbackArgumentFailure': ('synchronous', 'TypeError'),
  'callbackResultFailure': ('synchronous', 'TypeError'),
  'callbackIgnoredFuture': ('scheduled', 'String'),
  'callbackAsyncVoid': ('scheduled', 'String'),
  'sdkIgnoredFuture': ('scheduled', 'String'),
  'waitCleanupFailure': ('scheduled', 'String'),
  'futureHandlerFailure': ('future', 'String'),
  'futureFilterFailure': ('future', 'String'),
  'streamHandlerFailure': ('stream', 'String'),
  'castFailure': ('synchronous', 'TypeError'),
  'covarianceFailure': ('synchronous', 'TypeError'),
  'patternFailure': ('synchronous', 'TypeError'),
  'nullFailure': ('synchronous', 'TypeError'),
  'getterFailure': ('synchronous', 'String'),
  'futureFailure': ('future', 'String'),
  'streamFailure': ('stream', 'String'),
  'constructedStream': ('stream', 'String'),
  'streamToList': ('future', 'String'),
  'streamToListDiscarded': ('scheduled', 'String'),
  'nestedStream': ('stream', 'String'),
  'futureAsStream': ('stream', 'String'),
  'streamFromFuture': ('stream', 'String'),
  'futureAsStreamTerminal': ('future', 'String'),
  'blockedStreamTerminal': ('synchronous', 'int'),
  'lazyFailure': ('deferred', 'String'),
  'scheduledFailure': ('scheduled', 'String'),
  'finallyReplaceCast': ('synchronous', 'String'),
  'finallyBreakImplicit': ('synchronous', 'String'),
  'consumeStream': ('future', 'String'),
  'consumeIterable': ('future', 'String'),
  'delegateStream': ('stream', 'String'),
  'consumeWrappedLazy': ('synchronous', 'String'),
  'consumeMappedLazy': ('synchronous', 'String'),
  'consumeCopiedLazy': ('synchronous', 'String'),
  'consumeLazyIterator': ('synchronous', 'String'),
  'createLazyIterator': ('deferred', 'String'),
};

const _suppressedEffects = {
  'stoppedPropertyWrite': 'bool',
  'stoppedCompoundPropertyWrite': 'bool',
  'stoppedIndexWrite': 'RangeError',
  'stoppedCompoundIndexWrite': 'UnsupportedError',
  'storedLazyIteratorCaught': 'String',
  'unusedLazyIterator': 'String',
  'blockedLazyConsumer': 'String',
  'stoppedGuardCase': 'String',
  'stoppedStatementGuard': 'String',
  'streamToListCaught': 'String',
  'futureHandlerCaught': 'String',
  'futureAsStreamCaught': 'String',
  'blockedStreamTerminal': 'String',
  'groupedStatementCase': 'String',
  'skippedGuard': 'String',
  'caughtPostfixAssertion': 'TypeError',
  'skippedSelector': 'String',
  'stoppedCascade': 'String',
  'skippedCascade': 'String',
  'stoppedCollection': 'String',
  'stoppedCollectionLoop': 'String',
  'skippedMapValue': 'String',
  'stoppedInvocation': 'String',
  'stoppedInitializer': 'String',
  'superDispatch': 'int',
  'callbackAwaitedCaught': 'String',
  'containedCast': 'TypeError',
  'finallySuppressCast': 'TypeError',
  'finallyReplaceCast': 'TypeError',
  'finallySuppressFuture': 'String',
  'consumeStreamCaught': 'String',
  'consumeCopiedLazyCaught': 'String',
  'consumeLazyIteratorCaught': 'String',
};

const _unknownEffects = {
  'abandonFuture': 'scheduled',
  'awaitDiscardedFuture': 'scheduled',
};

const _observations = {
  'stopped_property_write': '42',
  'stopped_compound_property_write': 'String',
  'stopped_index_write': '42',
  'stopped_compound_index_write': 'RangeError',
  'covariant_index_write': 'TypeError',
  'stored_lazy_iterator': 'String',
  'stored_lazy_iterator_caught': 'none',
  'unused_lazy_iterator': 'none',
  'blocked_lazy_consumer': '42',
  'stopped_guard_case': '42',
  'stopped_statement_guard': '42',
  'grouped_statement_case': '42',
  'skipped_guard': 'none',
  'postfix_assertion': 'TypeError',
  'caught_postfix_assertion': 'none',
  'skipped_selector': 'none',
  'parenthesized_null_assertion': 'TypeError',
  'stopped_cascade': '42',
  'skipped_cascade': 'none',
  'stopped_collection': '42',
  'stopped_collection_loop': '42',
  'skipped_map_value': 'none',
  'stopped_invocation': '42',
  'stopped_initializer': '42',
  'skipped_do_condition': 'none',
  'continued_update': 'String',
  'constant_unreachable': 'none',
  'exact_dispatch': 'none',
  'super_dispatch': 'String',
  'stored_adoption_caught': 'none',
  'stored_adoption_wrong_catch': 'String',
  'stored_adoption_two_outputs': 'none/String',
  'adopt_separate_output': 'none/String',
  'adopt_failure': 'String',
  'adopt_caught': 'none',
  'adopt_discarded': 'none/String',
  'forward_failure': 'String',
  'forward_caught': 'none',
  'forward_discarded': 'none/String',
  'callback': 'String',
  'callback_argument': 'TypeError',
  'callback_result': 'TypeError',
  'callback_ignored_future': 'none/String',
  'callback_async_void': 'none/String',
  'sdk_ignored_future': 'none/String',
  'wait_cleanup_failure': 'none/String',
  'future_handler_failure': 'String',
  'future_filter_failure': 'String',
  'stream_handler_failure': 'String',
  'future_handler_caught': 'none',
  'callback_awaited_caught': 'none',
  'cast': 'TypeError',
  'covariance': 'TypeError',
  'pattern': 'TypeError',
  'null': 'TypeError',
  'getter': 'String',
  'future': 'String',
  'stream': 'String',
  'constructed_stream': 'String',
  'stream_to_list': 'String',
  'stream_to_list_caught': 'none',
  'stream_to_list_discarded': 'none/String',
  'nested_stream': 'String',
  'future_as_stream': 'String',
  'stream_from_future': 'String',
  'future_as_stream_terminal': 'String',
  'future_as_stream_caught': 'none',
  'blocked_stream_terminal': '42',
  'lazy': 'String',
  'scheduled': 'String',
  'contained': 'none',
  'lazy_creation': 'none',
  'abandoned_future': 'none/String',
  'await_discarded_future': 'none/String',
  'finally_cast': 'none',
  'finally_replacement': 'String',
  'finally_future': 'none',
  'finally_break': 'String',
  'consume_stream': 'String',
  'consume_iterable': 'String',
  'delegate_stream': 'String',
  'consume_stream_caught': 'none',
  'consume_wrapped_lazy': 'String',
  'consume_mapped_lazy': 'String',
  'consume_copied_lazy': 'String',
  'consume_copied_lazy_caught': 'none',
  'consume_lazy_iterator': 'String',
  'consume_lazy_iterator_caught': 'none',
  'create_lazy_iterator': 'none',
};

const _fixture = r'''
import 'dart:async';
import 'dart:convert';

const disabledBranch = false;
Never stopEvaluation() => throw 42;
Never throwString() => throw 'effect';
final class AssignmentTarget {
  num get value => throwString();
  set value(num next) { throw true; }
}
void stoppedPropertyWrite() {
  AssignmentTarget().value = stopEvaluation();
}
void stoppedCompoundPropertyWrite() {
  AssignmentTarget().value += stopEvaluation();
}
void stoppedIndexWrite() {
  <num>[][0] = stopEvaluation();
}
void stoppedCompoundIndexWrite() {
  <num>[][0] += stopEvaluation();
}
void covariantIndexWrite(List<num> values) {
  values[0] = 1.5;
}
void stoppedGuardCase() {
  final result = switch (false) {
    _ when stopEvaluation() => throwString(),
    _ => throwString(),
  };
}
void stoppedStatementGuard() {
  switch (false) {
    case _ when stopEvaluation(): throwString();
    default: throwString();
  }
  throwString();
}
void groupedStatementCase() {
  switch (true) {
    case true:
    case false: stopEvaluation();
  }
  throwString();
}
void skippedGuard() {
  final result = switch (false) {
    true when throwString() => throwString(),
    _ => 0,
  };
}
final class CascadeTarget {
  Never stop() => stopEvaluation();
  Never fail() => throwString();
}
const CascadeTarget? absentCascadeTarget = null;
void stoppedCascade() { CascadeTarget()..stop()..fail(); }
void skippedCascade() { absentCascadeTarget?..fail(); }
final class SelectorTarget {
  CascadeTarget get next => throwString();
}
const SelectorTarget? absentSelectorTarget = null;
void skippedSelector() { absentSelectorTarget?.next.fail(); }
void parenthesizedNullAssertion() { (absentSelectorTarget?.next)!; }
void postfixAssertion(String? value) { value!; }
void caughtPostfixAssertion(String? value) {
  try { value!; } on TypeError {}
}
void stoppedCollection() { <int>[stopEvaluation(), throwString()]; }
void stoppedCollectionLoop() {
  <int>[for (int i = stopEvaluation(); false;) throwString()];
}
void skippedMapValue() { <int, int>{?null: throwString()}; }
void throwInCallee(int value) { throwString(); }
void stoppedInvocation() { throwInCallee(stopEvaluation()); }
void stoppedInitializer() {
  for (int i = stopEvaluation(); false;) { throwString(); }
}
void skippedDoCondition() { do { break; } while (throwString()); }
void continuedUpdate() { outer: for (;; throwString()) { continue outer; } }
void constantUnreachable() { if (disabledBranch) throw 'unreachable'; }
class ExactBase { void run() {} }
class ExactDerived extends ExactBase { @override void run() { throw 'override'; } }
void exactDispatch() { ExactBase().run(); }
class SuperBase { void run() { throw 'super'; } }
class SuperChild extends SuperBase {
  @override void run() { throw 42; }
  void callSuper() { super.run(); }
}
void superDispatch() { SuperChild().callSuper(); }
Future<void> storedAdoptionCaught() async {
  final input = Future<void>.error('stored');
  final output = adoptStatement(input);
  try { await output; } on String {}
}
Future<void> storedAdoptionWrongCatch() async {
  final input = Future<void>.error('stored');
  final output = adoptStatement(input);
  try { await output; } on int {}
}
Future<void> storedAdoptionTwoOutputs() async {
  final input = Future<void>.error('stored');
  final first = adoptStatement(input);
  final second = adoptStatement(input);
  try { await first; } on String {}
}
Future<void> adoptSeparateOutput() async {
  final input = Future<void>.error('separate');
  adoptStatement(input);
  try { await input; } on String {}
}
Future<void> adoptReturn(Future<void> input) async => input;
Future<void> adoptAwait(Future<void> input) async { return await adoptReturn(input); }
Future<void> adoptStatement(Future<void> input) async { await adoptAwait(input); }
Future<void> adoptFailure() async { await adoptStatement(Future<void>.error('adopt')); }
Future<void> adoptCaught() async { try { await adoptStatement(Future<void>.error('adopt')); } on String {} }
void adoptDiscarded() { try { adoptStatement(Future<void>.error('adopt')); } on String {} }
Future<void> forwardFuture(Future<void> input) => input;
Future<void> forwardFailure() async { await forwardFuture(Future<void>.error('forward')); }
Future<void> forwardCaught() async { try { await forwardFuture(Future<void>.error('forward')); } on String {} }
void forwardDiscarded() { try { forwardFuture(Future<void>.error('forward')); } on String {} }

void invoke(void Function() action) { action(); }
void callbackThrow() { throw 'callback'; }
void callbackFailure() { invoke(callbackThrow); }
void narrowArgument(int value) {}
void invokeDynamic(void Function(int) action, dynamic value) { action(value); }
void callbackArgumentFailure(dynamic value) { invokeDynamic(narrowArgument, value); }
dynamic badResult() => 'bad';
int invokeResult(dynamic Function() action) => action();
int callbackResultFailure() => invokeResult(badResult);
Future<void> callbackFuture() async { throw 'callback'; }
void callbackVoid() async { throw 'callback'; }
void callbackIgnoredFuture() { invoke(callbackFuture); }
void callbackAsyncVoid() { try { invoke(callbackVoid); } on String {} }
void sdkIgnoredFuture() { try { [1].forEach((_) async { throw 'callback'; }); } on String {} }
Future<void> invokeAwaited(Future<void> Function() action) async { await action(); }
Future<void> callbackAwaitedCaught() async {
  try { await invokeAwaited(callbackFuture); } on String {}
}
void castFailure(dynamic value) { String text = value; text.length; }
void covarianceFailure(List<Object> values, Object value) { values.add(value); }
void patternFailure(Object value) { if (value case var text as String) { text.length; } }
void nullFailure(String? value) { if (value case var text!) { text.length; } }
final class Data { int get value { throw 'getter'; } }
void getterFailure(Data data) { if (data case Data(value: var item)) { item; } }
Future<void> futureFailure() async { throw 'future'; }
Stream<int> streamFailure() async* { throw 'stream'; }
Iterable<int> lazyFailure() sync* { throw 'lazy'; }
void storedLazyIterator() {
  final iterator = lazyFailure().iterator;
  final alias = iterator;
  alias.moveNext();
}
void storedLazyIteratorCaught() {
  final iterator = lazyFailure().iterator;
  final alias = iterator;
  try { alias.moveNext(); } on String {}
}
void unusedLazyIterator() {
  final iterator = lazyFailure().iterator;
  if (false) iterator.moveNext();
}
void blockedLazyConsumer() {
  List<int>.of(lazyFailure(), growable: stopEvaluation());
}
void consumeWrappedLazy() { (lazyFailure()).toList(); }
void consumeMappedLazy() { lazyFailure().map((value) => value).toList(); }
void consumeCopiedLazy() { List<int>.of(lazyFailure()); }
void consumeCopiedLazyCaught() {
  try { List<int>.of(lazyFailure()); } on String {}
}
Iterator<int> createLazyIterator() => lazyFailure().iterator;
void consumeLazyIterator() { createLazyIterator().moveNext(); }
void consumeLazyIteratorCaught() {
  try { lazyFailure().map((value) => value).iterator.moveNext(); } on String {}
}
Future<void> consumeStream() async {
  await for (final value in streamFailure()) { value; }
}
Future<void> consumeIterable() async {
  for (final value in lazyFailure()) { value; }
}
Stream<int> delegateStream() async* { yield* streamFailure(); }
Future<void> consumeStreamCaught() async {
  try { await for (final value in streamFailure()) { value; } } on String {}
}
void scheduledFailure() { Timer.run(() { throw 'scheduled'; }); }
Stream<int> constructedStream() => Stream<int>.error('buffered error');
Future<void> streamToList() async {
  await Stream<int>.error('terminal error').toList();
}
Future<void> streamToListCaught() async {
  try { await Stream<int>.error('terminal error').toList(); } on String {}
}
Future<void> streamToListDiscarded() async {
  Stream<int>.error('discarded terminal error').toList();
}
Future<Stream<int>> nestedStream() async {
  try {
    return await Future<Stream<int>>.value(Stream<int>.error('buffered error'));
  } on String { return const Stream<int>.empty(); }
}
Stream<int> futureAsStream() => Future<int>.error('buffered error').asStream();
Stream<int> streamFromFuture() => Stream<int>.fromFuture(Future<int>.error('buffered error'));
Future<void> futureAsStreamTerminal() async {
  await Future<int>.error('buffered error').asStream().toList();
}
Future<void> futureAsStreamCaught() async {
  try {
    await for (final value in Future<int>.error('buffered error').asStream()) { value; }
  } on String {}
}
void blockedStreamTerminal() {
  Stream<int>.error('buffered error').fold<int>(stopEvaluation(), (a, b) => a + b);
}
void abandonFuture(Future<void> Function() source) {
  try { source(); } catch (_) {}
}
Future<void> discardFuture(Future<void> value) async {}
Future<void> awaitDiscardedFuture(Future<void> Function() source) async {
  try { await discardFuture(source()); } catch (_) {}
}
void finallySuppressCast(dynamic value) {
  try { String text = value; text.length; } finally { return; }
}
void finallyReplaceCast(dynamic value) {
  try { String text = value; text.length; } finally { throw 'replacement'; }
}
Future<void> finallySuppressFuture() async {
  try { await futureFailure(); } finally { return; }
}
void finallyBreakImplicit() {
  while (true) {
    try { while (true) { Object? value = null; value!; } }
    finally { break; }
  }
  throw 'after-loop';
}
void containedCast(dynamic value) {
  try { String text = value; text.length; } on TypeError {}
}

Future<void> waitCleanupFailure() async {
  try {
    await Future.wait<int>(
      [Future<int>.value(1), Future<int>.error(42)],
      cleanUp: (_) => throw 'cleanup failed',
    );
  } catch (_) {}
}
Future<void> futureHandlerFailure() =>
    Future<void>.error(42).catchError((Object _) => throw 'replacement');
Future<void> futureFilterFailure() => Future<void>.error(42).catchError(
  (Object _) {}, test: (Object _) => throw 'filter error',
);
Stream<void> streamHandlerFailure() =>
    Stream<void>.error(42).handleError((Object _) => throw 'replacement');
Future<void> futureHandlerCaught() async {
  try {
    await Future<void>.error(42).catchError((Object _) => throw 'replacement');
  } on String {}
}

String label(Object error) => error is TypeError ? 'TypeError' : error is RangeError ? 'RangeError' : error is String ? 'String' : '$error';
String capture(void Function() operation) {
  try { operation(); return 'none'; } catch (error) { return label(error); }
}
Future<String> captureAsync(Future<void> Function() operation) async {
  try { await operation(); return 'none'; } catch (error) { return label(error); }
}
Future<String> captureUnobserved(Future<void> Function() operation) async {
  final escaped = Completer<String>();
  final done = Completer<void>();
  var completion = 'pending';
  runZonedGuarded(() async {
    completion = await captureAsync(operation);
    done.complete();
  }, (error, stack) {
    if (!escaped.isCompleted) escaped.complete(label(error));
  });
  await done.future.timeout(const Duration(seconds: 5));
  return '$completion/${await escaped.future.timeout(const Duration(seconds: 5))}';
}
Future<void> main() async {
  final scheduled = Completer<String>();
  runZonedGuarded(scheduledFailure, (error, stack) { scheduled.complete(label(error)); });
  final observations = {
    'stopped_property_write': capture(stoppedPropertyWrite),
    'stopped_compound_property_write': capture(stoppedCompoundPropertyWrite),
    'stopped_index_write': capture(stoppedIndexWrite),
    'stopped_compound_index_write': capture(stoppedCompoundIndexWrite),
    'covariant_index_write': capture(() => covariantIndexWrite(<int>[0])),
    'stored_lazy_iterator': capture(storedLazyIterator),
    'stored_lazy_iterator_caught': capture(storedLazyIteratorCaught),
    'unused_lazy_iterator': capture(unusedLazyIterator),
    'blocked_lazy_consumer': capture(blockedLazyConsumer),
    'stopped_guard_case': capture(stoppedGuardCase),
    'stopped_statement_guard': capture(stoppedStatementGuard),
    'grouped_statement_case': capture(groupedStatementCase),
    'skipped_guard': capture(skippedGuard),
    'postfix_assertion': capture(() => postfixAssertion(null)),
    'caught_postfix_assertion': capture(() => caughtPostfixAssertion(null)),
    'skipped_selector': capture(skippedSelector),
    'parenthesized_null_assertion': capture(parenthesizedNullAssertion),
    'stopped_cascade': capture(stoppedCascade),
    'skipped_cascade': capture(skippedCascade),
    'stopped_collection': capture(stoppedCollection),
    'stopped_collection_loop': capture(stoppedCollectionLoop),
    'skipped_map_value': capture(skippedMapValue),
    'stopped_invocation': capture(stoppedInvocation),
    'stopped_initializer': capture(stoppedInitializer),
    'skipped_do_condition': capture(skippedDoCondition),
    'continued_update': capture(continuedUpdate),
    'constant_unreachable': capture(constantUnreachable),
    'exact_dispatch': capture(exactDispatch),
    'super_dispatch': capture(superDispatch),
    'stored_adoption_caught': await captureAsync(storedAdoptionCaught),
    'stored_adoption_wrong_catch': await captureAsync(storedAdoptionWrongCatch),
    'stored_adoption_two_outputs': await captureUnobserved(storedAdoptionTwoOutputs),
    'adopt_separate_output': await captureUnobserved(adoptSeparateOutput),
    'adopt_failure': await captureAsync(adoptFailure),
    'adopt_caught': await captureAsync(adoptCaught),
    'adopt_discarded': await captureUnobserved(() async { adoptDiscarded(); }),
    'forward_failure': await captureAsync(forwardFailure),
    'forward_caught': await captureAsync(forwardCaught),
    'forward_discarded': await captureUnobserved(() async { forwardDiscarded(); }),
    'callback': capture(callbackFailure),
    'callback_argument': capture(() => callbackArgumentFailure('bad')),
    'callback_result': capture(() { callbackResultFailure(); }),
    'callback_ignored_future': await captureUnobserved(() async { callbackIgnoredFuture(); }),
    'callback_async_void': await captureUnobserved(() async { callbackAsyncVoid(); }),
    'sdk_ignored_future': await captureUnobserved(() async { sdkIgnoredFuture(); }),
    'wait_cleanup_failure': await captureUnobserved(waitCleanupFailure),
    'future_handler_failure': await captureAsync(futureHandlerFailure),
    'future_filter_failure': await captureAsync(futureFilterFailure),
    'stream_handler_failure': await captureAsync(() async { await streamHandlerFailure().toList(); }),
    'future_handler_caught': await captureAsync(futureHandlerCaught),
    'callback_awaited_caught': await captureAsync(callbackAwaitedCaught),
    'cast': capture(() => castFailure(1)),
    'covariance': capture(() => covarianceFailure(<String>[], Object())),
    'pattern': capture(() => patternFailure(1)),
    'null': capture(() => nullFailure(null)),
    'getter': capture(() => getterFailure(Data())),
    'future': await captureAsync(futureFailure),
    'stream': await captureAsync(() async { await streamFailure().toList(); }),
    'constructed_stream': await captureAsync(() async { await constructedStream().toList(); }),
    'stream_to_list': await captureAsync(streamToList),
    'stream_to_list_caught': await captureAsync(streamToListCaught),
    'stream_to_list_discarded': await captureUnobserved(streamToListDiscarded),
    'nested_stream': await captureAsync(() async { await (await nestedStream()).toList(); }),
    'future_as_stream': await captureAsync(() async { await futureAsStream().toList(); }),
    'stream_from_future': await captureAsync(() async { await streamFromFuture().toList(); }),
    'future_as_stream_terminal': await captureAsync(futureAsStreamTerminal),
    'future_as_stream_caught': await captureAsync(futureAsStreamCaught),
    'blocked_stream_terminal': capture(blockedStreamTerminal),
    'lazy': capture(() { lazyFailure().toList(); }),
    'scheduled': await scheduled.future.timeout(const Duration(seconds: 5)),
    'contained': capture(() => containedCast(1)),
    'lazy_creation': capture(() { lazyFailure(); }),
    'abandoned_future': await captureUnobserved(() async { abandonFuture(futureFailure); }),
    'await_discarded_future': await captureUnobserved(() => awaitDiscardedFuture(futureFailure)),
    'finally_cast': capture(() => finallySuppressCast(1)),
    'finally_replacement': capture(() => finallyReplaceCast(1)),
    'finally_future': await captureAsync(finallySuppressFuture),
    'finally_break': capture(finallyBreakImplicit),
    'consume_stream': await captureAsync(consumeStream),
    'consume_iterable': await captureAsync(consumeIterable),
    'delegate_stream': await captureAsync(() async { await delegateStream().toList(); }),
    'consume_stream_caught': await captureAsync(consumeStreamCaught),
    'consume_wrapped_lazy': capture(consumeWrappedLazy),
    'consume_mapped_lazy': capture(consumeMappedLazy),
    'consume_copied_lazy': capture(consumeCopiedLazy),
    'consume_copied_lazy_caught': capture(consumeCopiedLazyCaught),
    'consume_lazy_iterator': capture(consumeLazyIterator),
    'consume_lazy_iterator_caught': capture(consumeLazyIteratorCaught),
    'create_lazy_iterator': capture(() { createLazyIterator(); }),
  };
  print(jsonEncode(observations));
}
''';
