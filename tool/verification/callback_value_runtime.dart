import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:dart_exception_lint/src/analysis/inferred_throw_analyzer.dart';
import 'package:dart_exception_lint/src/config/exception_analysis_options.dart';
import 'package:dart_exception_lint/src/config/throwing_api_manifest.dart';

/// Independent runtime observations for callback selection and local aliases.
Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp('callback-values-');
  AnalysisContextCollection? collection;
  try {
    final file = File('${directory.path}/main.dart');
    await file.writeAsString(callbackValueFixture);
    collection = AnalysisContextCollection(includedPaths: [directory.path]);
    final unit =
        await collection
                .contextFor(file.path)
                .currentSession
                .getResolvedUnit(file.path)
            as ResolvedUnitResult;
    final errors = unit.diagnostics.where(
      (diagnostic) => diagnostic.diagnosticCode.severity.name == 'ERROR',
    );
    if (errors.isNotEmpty) {
      throw StateError('Invalid differential fixture: ${errors.join('\n')}');
    }
    final analyzer = InferredThrowAnalyzer(
      manifest: ThrowingApiManifest.empty(),
      options: const ExceptionAnalysisOptions(),
      featureSet: unit.libraryElement.featureSet,
      packageRootPath: directory.path,
      knownUnits: {file.path: unit.unit},
    );
    for (final entry in callbackValueExpectedEffects.entries) {
      final declaration = unit.unit.declarations
          .whereType<FunctionDeclaration>()
          .singleWhere((function) => function.name.lexeme == entry.key);
      final summary = analyzer.summarizeExecutable(
        declaration.declaredFragment!.element,
      );
      for (final channel in entry.value) {
        if (!summary.effects.any(
          (effect) =>
              effect.channel.name == channel &&
              effect.source.exceptionTypes.contains('String'),
        )) {
          throw StateError('${entry.key} lost String/$channel');
        }
      }
    }
    for (final name in ['aliasSafe', 'selectedSafe', 'varAliasSafe']) {
      final declaration = unit.unit.declarations
          .whereType<FunctionDeclaration>()
          .singleWhere((function) => function.name.lexeme == name);
      if (analyzer
          .summarizeExecutable(declaration.declaredFragment!.element)
          .hasAnyThrowSource) {
        throw StateError('$name was not proved safe');
      }
    }
    for (final name in [
      'partialSelected',
      'mutableAlias',
      'capturedWrite',
      'unknownAwaited',
      'returnedStreamCreation',
      'returnedIterableCreation',
      'asyncReturnedStreamCreation',
      'asyncReturnedIterableCreation',
    ]) {
      final declaration = unit.unit.declarations
          .whereType<FunctionDeclaration>()
          .singleWhere((function) => function.name.lexeme == name);
      final summary = analyzer.summarizeExecutable(
        declaration.declaredFragment!.element,
      );
      if (!summary.effects.any(
        (effect) =>
            effect.certainty.name == 'unknown' &&
            effect.channel.name == 'scheduled',
      )) {
        throw StateError('$name lost unknown/scheduled');
      }
    }
    Future<void> verify(
      String executable,
      List<String> arguments,
      String platform,
    ) async {
      final result = await Process.run(executable, arguments);
      if (result.exitCode != 0) {
        throw StateError('$platform failed: ${result.stderr}');
      }
      final observed = jsonDecode((result.stdout as String).trim());
      if (jsonEncode(observed) != jsonEncode(_observations)) {
        throw StateError(
          '$platform observed $observed; expected $_observations',
        );
      }
      stdout.writeln(
        '$platform: ${_observations.length} callback observations match.',
      );
    }

    await verify(Platform.resolvedExecutable, [file.path], 'Dart VM');
    final output = '${directory.path}/main.js';
    final compile = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'js',
      file.path,
      '-o',
      output,
    ]);
    if (compile.exitCode != 0) {
      throw StateError('JavaScript compilation failed: ${compile.stderr}');
    }
    await verify('node', [
      '-e',
      'globalThis.self = globalThis; require(process.argv[1]);',
      output,
    ], 'Dart JavaScript (Node)');
  } finally {
    await collection?.dispose();
    await directory.delete(recursive: true);
  }
}

const callbackValueExpectedEffects = <String, List<String>>{
  'aliasFail': ['synchronous'],
  'varAliasFail': ['synchronous'],
  'chainFail': ['synchronous'],
  'capturedAlias': ['synchronous'],
  'selected': ['synchronous'],
  'switched': ['synchronous'],
  'inlineSelected': ['synchronous'],
  'directSelected': ['synchronous'],
  'directAlias': ['synchronous'],
  'partialSelected': ['synchronous'],
  'selectedSdk': ['scheduled'],
  'mixedSelected': ['synchronous', 'scheduled'],
  'mixedCaught': ['scheduled'],
};

const _observations = {
  'alias': 'String',
  'chain': 'String',
  'captured': 'String',
  'selected_fail': 'String',
  'selected_safe': 'none',
  'switch': 'String',
  'inline': 'String',
  'direct_selected': 'String',
  'direct_alias': 'String',
  'partial': 'String',
  'sdk': 'none/String',
  'mixed_sync': 'String',
  'mixed_async': 'none/String',
  'mixed_caught_sync': 'none',
  'mixed_caught_async': 'none/String',
  'awaited_opaque_scheduled': 'none/String',
  'returned_stream': 'String',
  'returned_iterable': 'String',
  'async_returned_stream': 'String',
  'async_returned_iterable': 'String',
};

const callbackValueFixture = r'''
import 'dart:async';
import 'dart:convert';
void run(void Function() action) { action(); }
void safe() {}
void safeOther() {}
void fail() { throw 'failure'; }
Future<void> asyncFail() async { throw 'failure'; }
void aliasSafe() { final action = safe; run(action); }
void aliasFail() { final action = fail; run(action); }
void varAliasSafe() { var action = safe; run(action); }
void varAliasFail() { var action = fail; run(action); }
void chainFail() { final first = fail; final second = first; run(second); }
void capturedAlias() { final action = fail; run(() { action(); }); }
void selected(bool choose) { final action = choose ? fail : safe; run(action); }
void selectedSafe(bool choose) { final action = choose ? safe : safeOther; run(action); }
void switched(int choice) {
  final action = switch (choice) { 0 => fail, _ => safe };
  run(action);
}
void inlineSelected(bool choose) {
  run(choose ? () { throw 'failure'; } : () {});
}
void directSelected(bool choose) { (choose ? fail : safe)(); }
void directAlias() { final action = fail; action(); }
void partialSelected(bool choose, void Function() opaque) {
  final action = choose ? fail : opaque;
  run(action);
}
void mutableAlias(bool choose) {
  var action = safe;
  if (choose) { action = fail; }
  run(action);
}
void capturedWrite() {
  var action = safe;
  void mutate() { action = fail; }
  mutate(); run(action);
}
void selectedSdk(bool choose) {
  final action = choose ? (int value) async { throw 'failure'; } : (int value) {};
  [1].forEach(action);
}
void mixedSelected(bool choose) {
  final action = choose ? fail : asyncFail;
  run(action);
}
void mixedCaught(bool choose) {
  try { final action = choose ? fail : asyncFail; run(action); } on String {}
}
Future<void> unknownAwaited(Future<void> Function() callback) async {
  try { await callback(); } catch (_) {}
}
Future<void> scheduledCallback() {
  Timer.run(() { throw 'failure'; });
  return Future<void>.value();
}
Stream<int> returnedStream() async* { throw 'failure'; }
Iterable<int> returnedIterable() sync* { throw 'failure'; }
Future<Stream<int>?> returnedStreamCreation() async {
  try { return await Future<Stream<int>>.sync(returnedStream); } catch (_) { return null; }
}
Future<Iterable<int>?> returnedIterableCreation() async {
  try { return await Future<Iterable<int>>.sync(returnedIterable); } catch (_) { return null; }
}
Future<Stream<int>> asyncReturnedStream() async => returnedStream();
Future<Iterable<int>> asyncReturnedIterable() async => returnedIterable();
Future<Stream<int>?> asyncReturnedStreamCreation() async {
  try { return await Future<Stream<int>>.sync(asyncReturnedStream); } catch (_) { return null; }
}
Future<Iterable<int>?> asyncReturnedIterableCreation() async {
  try { return await Future<Iterable<int>>.sync(asyncReturnedIterable); } catch (_) { return null; }
}
Future<String> captureFuture(Future<void> Function() action) async {
  try { await action(); return 'none'; } catch (error) { return label(error); }
}
String label(Object error) => error is String ? 'String' : '$error';
String capture(void Function() action) {
  try { action(); return 'none'; } catch (error) { return label(error); }
}
Future<String> escaped(void Function() action) async {
  final failure = Completer<String>();
  final complete = Completer<void>();
  var synchronous = 'pending';
  runZonedGuarded(() {
    synchronous = capture(action);
    complete.complete();
  }, (error, stack) { if (!failure.isCompleted) failure.complete(label(error)); });
  await complete.future.timeout(const Duration(seconds: 5));
  return '$synchronous/${await failure.future.timeout(const Duration(seconds: 5))}';
}
Future<void> main() async {
  print(jsonEncode({
    'alias': capture(aliasFail),
    'chain': capture(chainFail),
    'captured': capture(capturedAlias),
    'selected_fail': capture(() => selected(true)),
    'selected_safe': capture(() => selected(false)),
    'switch': capture(() => switched(0)),
    'inline': capture(() => inlineSelected(true)),
    'direct_selected': capture(() => directSelected(true)),
    'direct_alias': capture(directAlias),
    'partial': capture(() => partialSelected(true, safe)),
    'sdk': await escaped(() => selectedSdk(true)),
    'mixed_sync': capture(() => mixedSelected(true)),
    'mixed_async': await escaped(() => mixedSelected(false)),
    'mixed_caught_sync': capture(() => mixedCaught(true)),
    'mixed_caught_async': await escaped(() => mixedCaught(false)),
    'awaited_opaque_scheduled': await escaped(() { unknownAwaited(scheduledCallback); }),
    'returned_stream': await captureFuture(() async { final value = await returnedStreamCreation(); await value!.toList(); }),
    'returned_iterable': await captureFuture(() async { final value = await returnedIterableCreation(); value!.toList(); }),
    'async_returned_stream': await captureFuture(() async { final value = await asyncReturnedStreamCreation(); await value!.toList(); }),
    'async_returned_iterable': await captureFuture(() async { final value = await asyncReturnedIterableCreation(); value!.toList(); }),
  }));
}
''';
