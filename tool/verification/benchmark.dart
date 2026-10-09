import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:dart_exception_lint/src/analysis/inferred_throw_analyzer.dart';
import 'package:dart_exception_lint/src/config/exception_analysis_options.dart';
import 'package:dart_exception_lint/src/config/throwing_api_manifest.dart';
import 'package:dart_exception_lint/src/engine/resolved_dependencies.dart';

/// Reproducible generated workloads; includes graph indexing in cold time and
/// measures repeated inference separately. Analyzer resolution is reported but
/// is not attributed to the linter. Budgets live alongside the workload.
Future<void> main() async {
  const workloads = [
    (pairs: 100, statements: 0, dependency: false, budgetMs: 2000),
    (pairs: 1000, statements: 0, dependency: false, budgetMs: 10000),
    (pairs: 0, statements: 2000, dependency: false, budgetMs: 10000),
    (pairs: 1000, statements: 0, dependency: true, budgetMs: 10000),
  ];
  final results = <Map<String, Object>>[];
  for (final workload in workloads) {
    final directory = await Directory.systemTemp.createTemp(
      'exception-benchmark-',
    );
    AnalysisContextCollection? collection;
    try {
      await File('${directory.path}/pubspec.yaml').writeAsString(
        'name: benchmark_fixture\nenvironment:\n  sdk: ^3.11.0\n',
      );
      final file = File('${directory.path}/lib/fixture.dart');
      await file.parent.create(recursive: true);
      final content = workload.statements > 0
          ? 'void flat(String value) {\n${List.filled(workload.statements, "int.parse(value);").join("\n")}\n}'
          : List.generate(
              workload.pairs,
              (i) =>
                  'int parse$i(String value) => int.parse(value);\nint call$i(String value) => parse$i(value);',
            ).join('\n');
      if (workload.dependency) {
        await File('${file.parent.path}/dependency.dart').writeAsString(
          List.generate(
            workload.pairs,
            (i) => 'int parse$i(String value) => int.parse(value);',
          ).join('\n'),
        );
        await file.writeAsString(
          "import 'dependency.dart';\n${List.generate(workload.pairs, (i) => 'int call$i(String value) => parse$i(value);').join('\n')}",
        );
      } else {
        await file.writeAsString(content);
      }
      final resolution = Stopwatch()..start();
      collection = AnalysisContextCollection(includedPaths: [directory.path]);
      final unit =
          await collection
                  .contextFor(file.path)
                  .currentSession
                  .getResolvedUnit(file.path)
              as ResolvedUnitResult;
      resolution.stop();
      final cold = Stopwatch()..start();
      final dependencies = ResolvedDependencies(unit.libraryElement);
      final analyzer = InferredThrowAnalyzer(
        manifest: ThrowingApiManifest.empty(),
        options: const ExceptionAnalysisOptions(),
        featureSet: unit.libraryElement.featureSet,
        packageRootPath: directory.path,
        knownUnits: {file.path: unit.unit},
        resolveDependency: dependencies.resolve,
        resolutionIsCurrent: () => dependencies.isCurrent,
      );
      final functions = unit.unit.declarations
          .whereType<FunctionDeclaration>()
          .map((declaration) => declaration.declaredFragment!.element)
          .toList();
      for (final function in functions) {
        final summary = analyzer.summarizeExecutable(function);
        if (!summary.sources.any(
              (source) => source.exceptionTypes.contains('FormatException'),
            ) ||
            (workload.dependency && summary.hasUnknownEffects)) {
          throw StateError(
            'Lost expected parse effect in ${workload.dependency ? "dependency" : "local"}/${function.name}: ${summary.truncationReason}; ${summary.sources.map((source) => source.displayName).join(", ")}',
          );
        }
      }
      cold.stop();
      final warm = Stopwatch()..start();
      for (var iteration = 0; iteration < 10; iteration++) {
        for (final function in functions) {
          analyzer.summarizeExecutable(function);
        }
      }
      warm.stop();
      final rss = ProcessInfo.maxRss ~/ (1024 * 1024);
      results.add({
        'shape': workload.dependency
            ? 'dependency_calls'
            : workload.statements > 0
            ? 'long_body'
            : 'call_pairs',
        'functions': functions.length,
        'statements': workload.statements,
        'resolve_ms': resolution.elapsedMilliseconds,
        'cold_ms': cold.elapsedMilliseconds,
        'warm_10_passes_ms': warm.elapsedMilliseconds,
        'max_rss_mb': rss,
        'cold_budget_ms': workload.budgetMs,
      });
      if (cold.elapsedMilliseconds > workload.budgetMs ||
          warm.elapsedMilliseconds > workload.budgetMs ||
          rss > 1024) {
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
