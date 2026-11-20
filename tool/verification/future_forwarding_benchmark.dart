import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:dart_exception_lint/src/analysis/inferred_throw_analyzer.dart';
import 'package:dart_exception_lint/src/config/exception_analysis_options.dart';
import 'package:dart_exception_lint/src/config/throwing_api_manifest.dart';

/// Guards shared proof lookup against per-caller declaration scans/file reads.
Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp(
    'future-proof-budget-',
  );
  AnalysisContextCollection? collection;
  try {
    final file = File('${directory.path}/main.dart');
    await File('${directory.path}/pubspec.yaml').writeAsString(
      'name: future_proof_benchmark\nenvironment:\n  sdk: ^3.11.0\n',
    );
    await file.writeAsString('''
Future<void> forward(Future<void> input) => input;
Future<void> delegate(Future<void> input) async => await forward(input);
${List.generate(1000, (i) => "Future<void> caller$i() async { await delegate(Future<void>.error('failure')); }").join('\n')}
''');
    collection = AnalysisContextCollection(includedPaths: [directory.path]);
    final unit =
        await collection
                .contextFor(file.path)
                .currentSession
                .getResolvedUnit(file.path)
            as ResolvedUnitResult;
    final cold = Stopwatch()..start();
    final analyzer = InferredThrowAnalyzer(
      manifest: ThrowingApiManifest.empty(),
      options: const ExceptionAnalysisOptions(),
      featureSet: unit.libraryElement.featureSet,
      packageRootPath: directory.path,
      knownUnits: {file.path: unit.unit},
    );
    final callers = unit.unit.declarations
        .whereType<FunctionDeclaration>()
        .where((d) => d.name.lexeme.startsWith('caller'))
        .map((d) => d.declaredFragment!.element)
        .toList();
    for (final caller in callers) {
      final summary = analyzer.summarizeExecutable(caller);
      if (!summary.complete ||
          summary.hasUnknownEffects ||
          !summary.effects.any(
            (e) =>
                e.channel.name == 'future' &&
                e.source.exceptionTypes.contains('String'),
          )) {
        throw StateError('Lost concrete Future effect: ${caller.name}');
      }
    }
    cold.stop();
    final warm = Stopwatch()..start();
    for (var pass = 0; pass < 10; pass++) {
      for (final caller in callers) {
        analyzer.summarizeExecutable(caller);
      }
    }
    warm.stop();
    final rss = ProcessInfo.maxRss ~/ (1024 * 1024);
    const coldBudget = 10000;
    const warmBudget = 10000;
    const rssBudget = 1024;
    stdout.writeln(
      jsonEncode({
        'callers': callers.length,
        'cold_ms': cold.elapsedMilliseconds,
        'warm_10_passes_ms': warm.elapsedMilliseconds,
        'max_rss_mb': rss,
        'cold_budget_ms': coldBudget,
        'warm_budget_ms': warmBudget,
        'rss_budget_mb': rssBudget,
      }),
    );
    if (cold.elapsedMilliseconds > coldBudget ||
        warm.elapsedMilliseconds > warmBudget ||
        rss > rssBudget) {
      throw StateError('Future forwarding performance budget exceeded.');
    }
  } finally {
    await collection?.dispose();
    await directory.delete(recursive: true);
  }
}
