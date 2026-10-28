import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:dart_exception_lint/src/analysis/inferred_throw_analyzer.dart';
import 'package:dart_exception_lint/src/config/exception_analysis_options.dart';
import 'package:dart_exception_lint/src/config/throwing_api_manifest.dart';

/// Independently labeled effect-presence cases. Metrics describe this corpus
/// only; they are not estimates of precision/recall on external projects.
Future<Map<String, Object>> verifySemanticCorpus({
  String fixturePath = 'tool/corpus/semantic_cases.json',
}) async {
  final cases = (jsonDecode(await File(fixturePath).readAsString()) as List)
      .cast<Map<String, dynamic>>();
  final directory = await Directory.systemTemp.createTemp('exception-labels-');
  AnalysisContextCollection? collection;
  try {
    await File(
      '${directory.path}/pubspec.yaml',
    ).writeAsString('name: semantic_corpus\nenvironment:\n  sdk: ^3.11.0\n');
    final file = File('${directory.path}/cases.dart');
    await file.writeAsString(
      'import "dart:async";\n${cases.map((item) => item['source']).join('\n')}',
    );
    collection = AnalysisContextCollection(includedPaths: [directory.path]);
    final result = await collection
        .contextFor(file.path)
        .currentSession
        .getResolvedUnit(file.path);
    if (result is! ResolvedUnitResult) {
      throw StateError('Cannot resolve corpus');
    }
    final errors = result.diagnostics.where(
      (error) => error.severity.name == 'error',
    );
    if (errors.isNotEmpty) {
      throw StateError('Invalid corpus: ${errors.join('\n')}');
    }
    final analyzer = InferredThrowAnalyzer(
      manifest: ThrowingApiManifest.empty(),
      options: const ExceptionAnalysisOptions(),
      featureSet: result.libraryElement.featureSet,
      packageRootPath: directory.path,
      knownUnits: {file.path: result.unit},
    );
    var truePositives = 0;
    var falsePositives = 0;
    var falseNegatives = 0;
    var unknownEffects = 0;
    final failures = <String>[];
    for (final item in cases) {
      final name = item['name'] as String;
      final declaration = result.unit.declarations
          .whereType<FunctionDeclaration>()
          .singleWhere((declaration) => declaration.name.lexeme == name);
      final summary = analyzer.summarizeExecutable(
        declaration.declaredFragment!.element,
      );
      final actual = summary.effects
          .map(
            (effect) =>
                '${effect.channel.name}:${effect.certainty.name == 'unknown' ? 'unknown' : 'known'}',
          )
          .toSet();
      unknownEffects += summary.effects
          .where((effect) => effect.certainty.name == 'unknown')
          .length;
      final expected = (item['effects'] as List).cast<String>().toSet();
      truePositives += actual.intersection(expected).length;
      falsePositives += actual.difference(expected).length;
      falseNegatives += expected.difference(actual).length;
      if (actual.difference(expected).isNotEmpty ||
          expected.difference(actual).isNotEmpty) {
        failures.add(
          '$name: expected $expected; actual $actual; sources: ${summary.sources.map((s) => "${s.displayName}/${s.channel}/${s.exceptionTypes}").join(", ")}',
        );
      }
    }
    if (failures.isNotEmpty) throw StateError(failures.join('\n'));
    return {
      'cases': cases.length,
      'truePositiveEffectLabels': truePositives,
      'falsePositiveEffectLabels': falsePositives,
      'falseNegativeEffectLabels': falseNegatives,
      'unknownEffects': unknownEffects,
    };
  } finally {
    await collection?.dispose();
    await directory.delete(recursive: true);
  }
}

Future<void> main() async {
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert(await verifySemanticCorpus()),
  );
}
