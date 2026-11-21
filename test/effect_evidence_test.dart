import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:dart_exception_lint/src/analysis/inferred_throw_analyzer.dart';
import 'package:dart_exception_lint/src/analysis/throw_source_catalog.dart';
import 'package:dart_exception_lint/src/analysis/throw_summary.dart';
import 'package:dart_exception_lint/src/config/exception_analysis_options.dart';
import 'package:dart_exception_lint/src/config/throwing_api_manifest.dart';
import 'package:dart_exception_lint/src/engine/exception_effect.dart';
import 'package:test/test.dart';

void main() {
  test(
    'unresolved SDK spellings remain unknown; resolved SDK aliases retain models',
    () async {
      await _withSummaries(
        '''
import 'dart:convert' as convert;
import 'dart:collection';
import 'dart:core' as core;
import 'dart:core';
void dynamicFuture(dynamic Future) { Future.error('bad'); }
void dynamicInt(dynamic int) { int.parse('bad'); }
void dynamicUri(dynamic Uri) { Uri.parse('bad'); }
void dynamicJson(dynamic jsonDecode) { jsonDecode('bad'); }
void missing() { jsonDecode('bad'); }
void missingConstructor() { MissingClass(); }
void nativeJson(String value) { convert.jsonDecode(value); }
void nativeDate(String value) { core.DateTime.parse(value); }
void wrappedJson(String value) { nativeJson(value); }
class Parser { static int parse(String value) => 1; }
class RegExp { RegExp(String value); }
void userApis() { Parser.parse('bad'); RegExp('['); }
final class SafeList extends ListBase<int> {
  int get length => 1;
  set length(int value) {}
  int operator [](int index) => 1;
  void operator []=(int index, int value) {}
}
int customIndex(SafeList values) => values[100];
''',
        (summaries, unit) {
          for (final name in [
            'dynamicFuture',
            'dynamicInt',
            'dynamicUri',
            'dynamicJson',
            'missing',
            'missingConstructor',
          ]) {
            final summary = summaries[name]!;
            expect(summary.hasUnknownEffects, isTrue, reason: name);
            expect(
              summary.sources.expand((s) => s.exceptionTypes),
              isNot(contains('FormatException')),
              reason: name,
            );
            expect(
              summary.sources.any((s) => s.kind == ThrowSourceKind.futureError),
              isFalse,
              reason: name,
            );
            expect(
              summary.sources.every(
                (s) => s.evidenceKinds.contains(EffectEvidence.unresolved),
              ),
              isTrue,
              reason: name,
            );
            expect(
              summary.sources.any(
                (s) => s.evidenceKinds.contains(EffectEvidence.sdkModel),
              ),
              isFalse,
              reason: name,
            );
          }
          for (final name in ['nativeJson', 'nativeDate', 'wrappedJson']) {
            expect(
              summaries[name]!.sources.any(
                (s) =>
                    s.confidence != ThrowConfidence.unknown &&
                    s.evidenceKinds.contains(EffectEvidence.sdkModel),
              ),
              isTrue,
              reason:
                  '$name: ${summaries[name]!.sources.map((s) => '${s.displayName}/${s.exceptionTypes}/${s.evidenceKinds}').join('; ')}',
            );
          }
          expect(summaries['userApis']!.hasAnyThrowSource, isFalse);
          expect(
            summaries['customIndex']!.sources.expand((s) => s.exceptionTypes),
            isNot(contains('RangeError')),
          );
          expect(
            summaries['customIndex']!.sources.any(
              (s) => s.evidenceKinds.contains(EffectEvidence.sdkModel),
            ),
            isFalse,
          );
          final calls = _Calls();
          unit.unit.accept(calls);
          for (final call in calls.items) {
            // Even a familiar spelling cannot supply the missing identity.
            expect(
              ThrowSourceCatalog.matchResolvedInvocation(
                call,
                null,
                const ExceptionAnalysisOptions(),
              ),
              isNull,
            );
          }
        },
      );
    },
  );

  test(
    'source, contract, manifest, SDK scheduling and uncertainty evidence survives propagation',
    () async {
      final manifest = ThrowingApiManifest.parseResult('''
apis:
  - package: evidence_fixture
    library: package:evidence_fixture/main.dart
    function: manifested
    exception_types: [StateError]
''').valueOrNull!;
      await _withSummaries(
        '''
import 'dart:async';
import 'package:dart_exception_lint/dart_exception_lint.dart';
void direct() { throw 'failure'; }
void wrapper() { direct(); }
void manifested() {}
void manifestCaller() { manifested(); }
@MayThrow([FormatException])
external void contracted();
void contractCaller() { contracted(); }
void scheduled() { Timer.run(() { throw 'later'; }); }
void mixed(dynamic callback) { direct(); callback(); }
void cast(dynamic value) { int result = value; }
''',
        (summaries, unit) {
          expect(summaries['wrapper']!.sources.single.evidenceKinds, {
            EffectEvidence.sourceAnalysis,
          });
          expect(summaries['manifestCaller']!.sources.single.evidenceKinds, {
            EffectEvidence.manifestContract,
          });
          expect(
            summaries['contractCaller']!.sources.any(
              (s) =>
                  s.evidenceKinds.contains(EffectEvidence.annotationContract),
            ),
            isTrue,
          );
          expect(
            summaries['scheduled']!.effects.any(
              (e) =>
                  e.channel == ExceptionChannel.scheduled &&
                  e.source.evidenceKinds.containsAll({
                    EffectEvidence.sourceAnalysis,
                    EffectEvidence.sdkModel,
                  }),
            ),
            isTrue,
          );
          expect(
            summaries['mixed']!.sources.any(
              (s) => s.evidenceKinds.contains(EffectEvidence.sourceAnalysis),
            ),
            isTrue,
          );
          expect(
            summaries['mixed']!.sources.any(
              (s) => s.evidenceKinds.contains(EffectEvidence.unresolved),
            ),
            isTrue,
          );
          expect(
            summaries['cast']!.sources.any(
              (s) => s.evidenceKinds.contains(EffectEvidence.languageSemantics),
            ),
            isTrue,
          );
        },
        manifest: manifest,
      );
    },
  );

  test(
    'source deduplication retains independent evidence and truncation stays unresolved',
    () {
      const source = ThrowSource(
        kind: ThrowSourceKind.parseCall,
        confidence: ThrowConfidence.possibleThrow,
        displayName: 'parse',
      );
      final summary = ThrowSummary.merge(
        'test',
        [
          source.withEvidence({EffectEvidence.sdkModel}, replace: true),
          source.withEvidence({
            EffectEvidence.annotationContract,
          }, replace: true),
        ],
        dependencyElementKeys: [],
        complete: true,
      );
      expect(summary.sources, hasLength(2));
      final truncated = ThrowSummary.merge(
        'test',
        summary.sources,
        dependencyElementKeys: [],
        complete: true,
        maxSources: 0,
      );
      expect(truncated.complete, isFalse);
      expect(truncated.sources.single.evidenceKinds, {
        EffectEvidence.unresolved,
      });
    },
  );

  test('source deduplication compares typed fields and ancestry', () {
    const source = ThrowSource(
      kind: ThrowSourceKind.parseCall,
      confidence: ThrowConfidence.possibleThrow,
      displayName: 'parse',
      exceptionTypes: ['A', 'B'],
      exceptionSupertypes: {
        'A': ['Object'],
        'B': ['Exception', 'Object'],
      },
    );
    const sameSource = ThrowSource(
      kind: ThrowSourceKind.parseCall,
      confidence: ThrowConfidence.possibleThrow,
      displayName: 'parse',
      exceptionTypes: ['A', 'B'],
      exceptionSupertypes: {
        'B': ['Exception', 'Object'],
        'A': ['Object'],
      },
    );
    const distinct = ThrowSource(
      kind: ThrowSourceKind.parseCall,
      confidence: ThrowConfidence.possibleThrow,
      displayName: 'parse',
      exceptionTypes: ['A,B'],
      exceptionSupertypes: {
        'A': ['Object'],
        'B': ['Exception', 'Object'],
      },
    );
    final summary = ThrowSummary.merge(
      'test',
      [source, sameSource, distinct, source],
      dependencyElementKeys: [],
      complete: true,
    );
    expect(summary.sources, [source, distinct]);
  });
}

Future<void> _withSummaries(
  String source,
  void Function(Map<String, ThrowSummary>, ResolvedUnitResult) verify, {
  ThrowingApiManifest? manifest,
}) async {
  final directory = await Directory.systemTemp.createTemp('effect-evidence-');
  AnalysisContextCollection? collection;
  try {
    final file = File('${directory.path}/lib/main.dart');
    await file.parent.create(recursive: true);
    await file.writeAsString(source);
    await File(
      '${directory.path}/pubspec.yaml',
    ).writeAsString('name: evidence_fixture\nenvironment:\n  sdk: ^3.11.0\n');
    final config = File('${directory.path}/.dart_tool/package_config.json');
    await config.parent.create();
    await config.writeAsString(
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'evidence_fixture',
            'rootUri': '../',
            'packageUri': 'lib/',
            'languageVersion': '3.11',
          },
          {
            'name': 'dart_exception_lint',
            'rootUri': Directory.current.uri.toString(),
            'packageUri': 'lib/',
            'languageVersion': '3.11',
          },
        ],
      }),
    );
    collection = AnalysisContextCollection(includedPaths: [directory.path]);
    final unit =
        await collection
                .contextFor(file.path)
                .currentSession
                .getResolvedUnit(file.path)
            as ResolvedUnitResult;
    final analyzer = InferredThrowAnalyzer(
      manifest: manifest ?? ThrowingApiManifest.empty(),
      options: const ExceptionAnalysisOptions(),
      featureSet: unit.libraryElement.featureSet,
      packageRootPath: directory.path,
      knownUnits: {file.path: unit.unit},
    );
    verify({
      for (final declaration
          in unit.unit.declarations.whereType<FunctionDeclaration>())
        declaration.name.lexeme: analyzer.summarizeExecutable(
          declaration.declaredFragment!.element,
        ),
    }, unit);
  } finally {
    await collection?.dispose();
    await directory.delete(recursive: true);
  }
}

final class _Calls extends RecursiveAstVisitor<void> {
  final items = <AstNode>[];
  @override
  void visitMethodInvocation(MethodInvocation node) {
    items.add(node);
    super.visitMethodInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    items.add(node);
    super.visitInstanceCreationExpression(node);
  }
}
