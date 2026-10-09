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
  'callbackFailure': ('synchronous', 'String'),
  'callbackArgumentFailure': ('synchronous', 'TypeError'),
  'callbackResultFailure': ('synchronous', 'TypeError'),
  'callbackIgnoredFuture': ('scheduled', 'String'),
  'callbackAsyncVoid': ('scheduled', 'String'),
  'sdkIgnoredFuture': ('scheduled', 'String'),
  'castFailure': ('synchronous', 'TypeError'),
  'covarianceFailure': ('synchronous', 'TypeError'),
  'patternFailure': ('synchronous', 'TypeError'),
  'nullFailure': ('synchronous', 'TypeError'),
  'getterFailure': ('synchronous', 'String'),
  'futureFailure': ('future', 'String'),
  'streamFailure': ('stream', 'String'),
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
};

const _suppressedEffects = {
  'callbackAwaitedCaught': 'String',
  'containedCast': 'TypeError',
  'finallySuppressCast': 'TypeError',
  'finallyReplaceCast': 'TypeError',
  'finallySuppressFuture': 'String',
  'consumeStreamCaught': 'String',
  'consumeCopiedLazyCaught': 'String',
};

const _unknownEffects = {
  'abandonFuture': 'scheduled',
  'awaitDiscardedFuture': 'scheduled',
};

const _observations = {
  'callback': 'String',
  'callback_argument': 'TypeError',
  'callback_result': 'TypeError',
  'callback_ignored_future': 'none/String',
  'callback_async_void': 'none/String',
  'sdk_ignored_future': 'none/String',
  'callback_awaited_caught': 'none',
  'cast': 'TypeError',
  'covariance': 'TypeError',
  'pattern': 'TypeError',
  'null': 'TypeError',
  'getter': 'String',
  'future': 'String',
  'stream': 'String',
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
};

const _fixture = r'''
import 'dart:async';
import 'dart:convert';

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
void consumeWrappedLazy() { (lazyFailure()).toList(); }
void consumeMappedLazy() { lazyFailure().map((value) => value).toList(); }
void consumeCopiedLazy() { List<int>.of(lazyFailure()); }
void consumeCopiedLazyCaught() {
  try { List<int>.of(lazyFailure()); } on String {}
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

String label(Object error) => error is TypeError ? 'TypeError' : error is String ? 'String' : '$error';
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
    'callback': capture(callbackFailure),
    'callback_argument': capture(() => callbackArgumentFailure('bad')),
    'callback_result': capture(() { callbackResultFailure(); }),
    'callback_ignored_future': await captureUnobserved(() async { callbackIgnoredFuture(); }),
    'callback_async_void': await captureUnobserved(() async { callbackAsyncVoid(); }),
    'sdk_ignored_future': await captureUnobserved(() async { sdkIgnoredFuture(); }),
    'callback_awaited_caught': await captureAsync(callbackAwaitedCaught),
    'cast': capture(() => castFailure(1)),
    'covariance': capture(() => covarianceFailure(<String>[], Object())),
    'pattern': capture(() => patternFailure(1)),
    'null': capture(() => nullFailure(null)),
    'getter': capture(() => getterFailure(Data())),
    'future': await captureAsync(futureFailure),
    'stream': await captureAsync(() async { await streamFailure().toList(); }),
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
  };
  print(jsonEncode(observations));
}
''';
