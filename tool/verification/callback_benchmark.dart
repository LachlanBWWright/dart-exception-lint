import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:dart_exception_lint/src/analysis/inferred_throw_analyzer.dart';
import 'package:dart_exception_lint/src/config/exception_analysis_options.dart';
import 'package:dart_exception_lint/src/config/throwing_api_manifest.dart';
import 'package:dart_exception_lint/src/engine/exception_effect.dart';

/// Generated callback workloads exercise context reuse and bounded fallback.
/// Resolution is measured separately from inference. These fixtures are a
/// regression gate, rather than a representative real-project performance claim.
Future<void> main() async {
  const budgetMs = 10000;
  final results = <Map<String, Object>>[];
  for (final workload in [
    (name: 'shared_alias_target', count: 1000, distinct: false, storage: false),
    (
      name: 'distinct_inline_targets',
      count: 256,
      distinct: true,
      storage: false,
    ),
    (
      name: 'stored_returned_target',
      count: 1000,
      distinct: false,
      storage: true,
    ),
  ]) {
    final directory = await Directory.systemTemp.createTemp(
      'callback-benchmark-',
    );
    AnalysisContextCollection? collection;
    try {
      final file = File('${directory.path}/main.dart');
      await file.writeAsString('''
void invoke(void Function() action) { action(); }
void fail() { throw 'failure'; }
void Function() factory() => fail;
${List.generate(workload.count, (index) => workload.distinct
          ? "void call$index() { invoke(() { throw 'failure'; }); }"
          : workload.storage
          ? 'void call$index() { const actions = [fail]; final record = (actions[0], factory()); invoke(record.\$2); }'
          : 'void call$index() { var action = fail; invoke(action); }').join('\n')}
''');
      final resolution = Stopwatch()..start();
      collection = AnalysisContextCollection(includedPaths: [directory.path]);
      final unit =
          await collection
                  .contextFor(file.path)
                  .currentSession
                  .getResolvedUnit(file.path)
              as ResolvedUnitResult;
      resolution.stop();
      final errors = unit.diagnostics.where(
        (diagnostic) => diagnostic.diagnosticCode.severity.name == 'ERROR',
      );
      if (errors.isNotEmpty) {
        throw StateError('Invalid benchmark fixture: ${errors.join('\n')}');
      }
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
          .where((function) => function.name.lexeme.startsWith('call'))
          .map((function) => function.declaredFragment!.element)
          .toList();
      var knownCallers = 0;
      var uncertainCallers = 0;
      for (final caller in callers) {
        final summary = analyzer.summarizeExecutable(caller);
        final known = summary.effects.any(
          (effect) =>
              effect.channel == ExceptionChannel.synchronous &&
              effect.source.exceptionTypes.contains('String'),
        );
        if (known) knownCallers++;
        if (summary.hasUnknownEffects) {
          uncertainCallers++;
          if (!summary.effects.any(
            (effect) =>
                effect.certainty == ExceptionCertainty.unknown &&
                effect.channel == ExceptionChannel.scheduled,
          )) {
            throw StateError(
              '${caller.name} lost scheduled budget uncertainty',
            );
          }
        }
        if (!known && !summary.hasUnknownEffects) {
          throw StateError('${caller.name} was incorrectly proved safe');
        }
      }
      cold.stop();
      if (!workload.distinct &&
          (knownCallers != workload.count || uncertainCallers != 0)) {
        throw StateError(
          'Repeated aliases did not reuse callback contexts: '
          '$knownCallers known, $uncertainCallers uncertain',
        );
      }
      if (workload.distinct && (knownCallers == 0 || uncertainCallers == 0)) {
        throw StateError(
          'Distinct callbacks did not exercise known effects '
          'and bounded conservative fallback',
        );
      }
      final warm = Stopwatch()..start();
      for (var iteration = 0; iteration < 10; iteration++) {
        for (final caller in callers) {
          analyzer.summarizeExecutable(caller);
        }
      }
      warm.stop();
      final rssMb = ProcessInfo.maxRss ~/ (1024 * 1024);
      results.add({
        'shape': workload.name,
        'callers': callers.length,
        'known_string_callers': knownCallers,
        'uncertain_callers': uncertainCallers,
        'resolve_ms': resolution.elapsedMilliseconds,
        'cold_ms': cold.elapsedMilliseconds,
        'warm_10_passes_ms': warm.elapsedMilliseconds,
        'max_rss_mb': rssMb,
        'cold_budget_ms': budgetMs,
        'warm_budget_ms': budgetMs,
        'rss_budget_mb': 1024,
      });
      if (cold.elapsedMilliseconds > budgetMs ||
          warm.elapsedMilliseconds > budgetMs ||
          rssMb > 1024) {
        exitCode = 1;
      }
    } finally {
      await collection?.dispose();
      await directory.delete(recursive: true);
    }
  }
  stdout.writeln(
    const JsonEncoder.withIndent(
      '  ',
    ).convert({'sdk': Platform.version, 'workloads': results}),
  );
}
