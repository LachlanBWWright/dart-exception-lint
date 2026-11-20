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
    'lazy errors survive creation catches and move at terminal consumers',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'exception-deferred-',
      );
      AnalysisContextCollection? collection;
      try {
        final file = File('${directory.path}/main.dart');
        await file.writeAsString('''
Iterable<int> values() sync* { throw 'failure'; }
Iterable<int> helper() {
  try { return values(); } on String { return []; }
}
void consume() { values().toList(); }
void consumeWrapped() { (values()).toList(); }
void consumeMapped() { values().where((_) => true).map((value) => value).toList(); }
void consumeCopied() { List<int>.of(values()); }
void consumeIterator() { (values().iterator).moveNext(); }
void consumeMappedIterator() { values().map((value) => value).iterator.moveNext(); }
Iterator<int> createIterator() {
  try { return values().iterator; } on String { return <int>[].iterator; }
}
void consumeForwardedIterator() { createIterator().moveNext(); }
void readCurrent() { values().iterator.current; }
void contained() { try { values().toList(); } on String {} }
void containedWrapped() { try { (values()).toList(); } on String {} }
void containedMapped() { try { values().map((value) => value).toList(); } on String {} }
void containedCopied() { try { List<int>.of(values()); } on String {} }
void containedIterator() { try { values().iterator.moveNext(); } on String {} }
void wrongIteratorCatch() { try { values().iterator.moveNext(); } on int {} }
Iterable<int> relay() sync* { try { yield* values(); } on String {} }
''');
        collection = AnalysisContextCollection(includedPaths: [directory.path]);
        final result =
            await collection
                    .contextFor(file.path)
                    .currentSession
                    .getResolvedUnit(file.path)
                as ResolvedUnitResult;
        final analyzer = InferredThrowAnalyzer(
          manifest: ThrowingApiManifest.empty(),
          options: const ExceptionAnalysisOptions(),
          featureSet: result.libraryElement.featureSet,
          packageRootPath: directory.path,
          knownUnits: {file.path: result.unit},
        );
        final summaries = {
          for (final function
              in result.unit.declarations.whereType<FunctionDeclaration>())
            function.name.lexeme: analyzer.summarizeExecutable(
              function.declaredFragment!.element,
            ),
        };
        Iterable<ExceptionChannel> stringChannels(String name) =>
            summaries[name]!.effects
                .where(
                  (effect) => effect.source.exceptionTypes.contains('String'),
                )
                .map((effect) => effect.channel);
        expect(stringChannels('helper'), contains(ExceptionChannel.deferred));
        expect(
          stringChannels('consume'),
          contains(ExceptionChannel.synchronous),
        );
        for (final name in [
          'consumeWrapped',
          'consumeMapped',
          'consumeCopied',
          'consumeIterator',
          'consumeMappedIterator',
          'consumeForwardedIterator',
          'wrongIteratorCatch',
        ]) {
          expect(
            stringChannels(name),
            contains(ExceptionChannel.synchronous),
            reason: name,
          );
        }
        expect(stringChannels('contained'), isEmpty);
        for (final name in [
          'containedWrapped',
          'containedMapped',
          'containedCopied',
          'containedIterator',
        ]) {
          expect(stringChannels(name), isEmpty, reason: name);
        }
        expect(stringChannels('createIterator'), [ExceptionChannel.deferred]);
        expect(
          stringChannels('readCurrent'),
          isNot(contains(ExceptionChannel.synchronous)),
        );
        expect(stringChannels('relay'), isEmpty);
      } finally {
        await collection?.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
}
