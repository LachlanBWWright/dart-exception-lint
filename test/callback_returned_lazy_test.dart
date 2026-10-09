import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:dart_exception_lint/src/analysis/inferred_throw_analyzer.dart';
import 'package:dart_exception_lint/src/config/exception_analysis_options.dart';
import 'package:dart_exception_lint/src/config/throwing_api_manifest.dart';
import 'package:dart_exception_lint/src/engine/exception_effect.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Future callback adoption does not consume returned lazy values',
    () async {
      final directory = await Directory.systemTemp.createTemp('returned-lazy-');
      AnalysisContextCollection? collection;
      try {
        final file = File('${directory.path}/main.dart');
        await file.writeAsString('''
Stream<int> failingStream() async* { throw 'stream'; }
Iterable<int> failingIterable() sync* { throw 'iterable'; }
Future<Stream<int>> asyncStream() async => failingStream();
Future<Iterable<int>> asyncIterable() async => failingIterable();
Future<Stream<int>?> streamCreationCatch() async {
  try { return await Future<Stream<int>>.sync(failingStream); }
  catch (_) { return null; }
}
Future<Iterable<int>?> iterableCreationCatch() async {
  try { return await Future<Iterable<int>>.sync(failingIterable); }
  catch (_) { return null; }
}
Future<Stream<int>?> asyncStreamCreationCatch() async {
  try { return await Future<Stream<int>>.sync(asyncStream); }
  catch (_) { return null; }
}
Future<Iterable<int>?> asyncIterableCreationCatch() async {
  try { return await Future<Iterable<int>>.sync(asyncIterable); }
  catch (_) { return null; }
}
Future<void> containedCallback() async {
  try { await Future<void>.sync(() { throw 'contained'; }); }
  catch (_) {}
}
Stream<int> streamExpand() => Stream<int>.value(1).expand((_) => failingIterable());
Stream<int> streamAsyncExpand() => Stream<int>.value(1).asyncExpand((_) => failingStream());
Iterable<int> iterableExpand() => [1].expand((_) => failingIterable());
''');
        collection = AnalysisContextCollection(includedPaths: [directory.path]);
        final result =
            await collection
                    .contextFor(file.path)
                    .currentSession
                    .getResolvedUnit(file.path)
                as ResolvedUnitResult;
        expect(
          result.diagnostics.where(
            (diagnostic) => diagnostic.diagnosticCode.severity.name == 'ERROR',
          ),
          isEmpty,
        );
        final analyzer = InferredThrowAnalyzer(
          manifest: ThrowingApiManifest.empty(),
          options: const ExceptionAnalysisOptions(),
          featureSet: result.libraryElement.featureSet,
          packageRootPath: directory.path,
          knownUnits: {file.path: result.unit},
        );
        final summaries = {
          for (final declaration
              in result.unit.declarations.whereType<FunctionDeclaration>())
            declaration.name.lexeme: analyzer.summarizeExecutable(
              declaration.declaredFragment!.element,
            ),
        };
        // VM probes confirm that creation succeeds and catches neither String;
        // only subsequent Stream/Iterable consumption produces the exception.
        // Until result ownership is modeled, scheduling uncertainty is acceptable.
        for (final name in [
          'streamCreationCatch',
          'iterableCreationCatch',
          'asyncStreamCreationCatch',
          'asyncIterableCreationCatch',
        ]) {
          expect(
            summaries[name]!.effects.any(
              (effect) =>
                  (effect.certainty == ExceptionCertainty.unknown &&
                      effect.channel == ExceptionChannel.scheduled) ||
                  (effect.source.exceptionTypes.contains('String') &&
                      {
                        ExceptionChannel.stream,
                        ExceptionChannel.deferred,
                      }.contains(effect.channel)),
            ),
            isTrue,
            reason: '$name must retain the returned value execution obligation',
          );
        }
        expect(
          summaries['containedCallback']!.effects.any(
            (effect) => effect.source.exceptionTypes.contains('String'),
          ),
          isFalse,
        );
        for (final entry in {
          'streamExpand': ExceptionChannel.stream,
          'streamAsyncExpand': ExceptionChannel.stream,
          'iterableExpand': ExceptionChannel.deferred,
        }.entries) {
          expect(
            summaries[entry.key]!.effects.any(
              (effect) =>
                  effect.source.exceptionTypes.contains('String') &&
                  effect.channel == entry.value,
            ),
            isTrue,
            reason: '${entry.key} consumes the callback returned lazy value',
          );
        }
      } finally {
        await collection?.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
}
