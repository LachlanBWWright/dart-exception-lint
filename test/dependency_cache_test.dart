import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:dart_exception_lint/src/analysis/inferred_throw_analyzer.dart';
import 'package:dart_exception_lint/src/config/exception_analysis_options.dart';
import 'package:dart_exception_lint/src/config/throwing_api_manifest.dart';
import 'package:test/test.dart';

void main() {
  test(
    'dependency edits and deletion invalidate an unchanged importing AST',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'exception-cache-',
      );
      AnalysisContextCollection? collection;
      try {
        final dependency = File('${directory.path}/dependency.dart');
        final main = File('${directory.path}/main.dart');
        await dependency.writeAsString('void helper() { throw Object(); }');
        await main.writeAsString(
          "import 'dependency.dart';\nvoid caller() { helper(); }",
        );
        collection = AnalysisContextCollection(includedPaths: [directory.path]);
        final resolved =
            await collection
                    .contextFor(main.path)
                    .currentSession
                    .getResolvedUnit(main.path)
                as ResolvedUnitResult;
        final analyzer = InferredThrowAnalyzer(
          manifest: ThrowingApiManifest.empty(),
          options: const ExceptionAnalysisOptions(),
          featureSet: resolved.libraryElement.featureSet,
          packageRootPath: directory.path,
          knownUnits: {main.path: resolved.unit},
        );
        final function = resolved.unit.declarations
            .whereType<FunctionDeclaration>()
            .single;
        final summary = analyzer.summarizeExecutable(
          function.declaredFragment!.element,
        );
        // Reading syntax from disk must not claim that dependency semantics have
        // been resolved, even when its visible throw is recognized.
        expect(summary.hasUnknownEffects, isTrue);
        expect(analyzer.dependenciesAreCurrent, isTrue);
        final original = await dependency.readAsString();
        final modified = (await dependency.stat()).modified;
        await dependency.writeAsString(
          original.replaceFirst('Object', 'String'),
        );
        await dependency.setLastModified(modified);
        expect(analyzer.dependenciesAreCurrent, isFalse);
        await dependency.writeAsString(original);
        expect(analyzer.dependenciesAreCurrent, isTrue);
        await dependency.delete();
        expect(analyzer.dependenciesAreCurrent, isFalse);
      } finally {
        await collection?.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
}
