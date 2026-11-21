import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/file_system/overlay_file_system.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:dart_exception_lint/src/analysis/inferred_throw_analyzer.dart';
import 'package:dart_exception_lint/src/config/exception_analysis_options.dart';
import 'package:dart_exception_lint/src/config/throwing_api_manifest.dart';
import 'package:dart_exception_lint/src/engine/resolved_dependencies.dart';
import 'package:test/test.dart';

void main() {
  test(
    'resolved constants stay safe when dependency bodies are unavailable',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'exception-constants-',
      );
      AnalysisContextCollection? collection;
      try {
        final main = File('${directory.path}/application/lib/main.dart');
        await main.parent.create(recursive: true);
        await main.writeAsString('''
import '../../dependency.dart' as flags;
bool constantRead() => flags.enabled;
bool getterRead() => flags.computed;
''');
        await File('${directory.path}/dependency.dart').writeAsString('''
const bool enabled = true;
bool get computed => throw 'runtime getter';
''');
        collection = AnalysisContextCollection(includedPaths: [directory.path]);
        final resolved =
            await collection
                    .contextFor(main.path)
                    .currentSession
                    .getResolvedUnit(main.path)
                as ResolvedUnitResult;
        final analyzer = InferredThrowAnalyzer(
          manifest: ThrowingApiManifest.empty(),
          options: const ExceptionAnalysisOptions(
            analyzeThirdPartySource: false,
          ),
          featureSet: resolved.libraryElement.featureSet,
          packageRootPath: main.parent.parent.path,
          knownUnits: {main.path: resolved.unit},
        );
        final summaries = {
          for (final function
              in resolved.unit.declarations.whereType<FunctionDeclaration>())
            function.name.lexeme: analyzer.summarizeExecutable(
              function.declaredFragment!.element,
            ),
        };
        expect(summaries['constantRead']!.hasAnyThrowSource, isFalse);
        expect(summaries['getterRead']!.hasUnknownEffects, isTrue);
      } finally {
        await collection?.dispose();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'callback bindings cross resolved dependencies without mixing caches',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'exception-dependency-callback-',
      );
      AnalysisContextCollection? collection;
      try {
        final main = File('${directory.path}/main.dart');
        final dependency = File('${directory.path}/dependency.dart');
        final nested = File('${directory.path}/nested.dart');
        await main.writeAsString("""
import 'dependency.dart';
void safe() {}
void fail() { throw 'callback'; }
void safeCaller() { helper(safe); }
void failCaller() { helper(fail); }
void caughtCaller() { try { helper(fail); } on String {} }
""");
        await dependency.writeAsString(
          "import 'nested.dart'; void helper(void Function() action) { invoke(action); }",
        );
        await nested.writeAsString(
          'void invoke(void Function() action) { action(); }',
        );
        collection = AnalysisContextCollection(includedPaths: [directory.path]);
        final context = collection.contextFor(main.path);
        final resolved =
            await context.currentSession.getResolvedUnit(main.path)
                as ResolvedUnitResult;
        final dependencies = ResolvedDependencies(resolved.libraryElement);
        final analyzer = _analyzer(resolved, dependencies, directory.path);
        final functions = {
          for (final function
              in resolved.unit.declarations.whereType<FunctionDeclaration>())
            function.name.lexeme: function.declaredFragment!.element,
        };
        expect(
          analyzer
              .summarizeExecutable(functions['safeCaller']!)
              .hasAnyThrowSource,
          isFalse,
        );
        final failure = analyzer.summarizeExecutable(functions['failCaller']!);
        expect(failure.hasUnknownEffects, isFalse);
        expect(
          failure.sources.expand((source) => source.exceptionTypes),
          contains('String'),
        );
        expect(
          analyzer
              .summarizeExecutable(functions['caughtCaller']!)
              .hasAnyThrowSource,
          isFalse,
        );
        expect(analyzer.dependenciesAreCurrent, isTrue);
        // The dependency was loaded by a specialized child analyzer. Its proof
        // must still participate in the root analyzer's invalidation checks.
        await nested.writeAsString(
          'void invoke(void Function() action) { throw 42; }',
        );
        expect(analyzer.dependenciesAreCurrent, isFalse);
      } finally {
        await collection?.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
  test(
    'dependency overlays are resolved and old sessions cannot prove safety',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'exception-resolve-',
      );
      AnalysisContextCollection? collection;
      try {
        final main = File('${directory.path}/main.dart');
        final dependency = File('${directory.path}/dependency.dart');
        final sibling = File('${directory.path}/sibling.dart');
        await main.writeAsString(
          "import 'dependency.dart'; void caller() { helper(); }",
        );
        await sibling.writeAsString(
          "import 'dependency.dart'; void siblingCaller() { helper(); }",
        );
        await dependency.writeAsString('void helper() {}');
        final provider =
            OverlayResourceProvider(PhysicalResourceProvider.INSTANCE)
              ..setOverlay(
                dependency.path,
                content: "void helper() { throw 'unsaved'; }",
                modificationStamp: 1,
              );
        collection = AnalysisContextCollection(
          includedPaths: [directory.path],
          resourceProvider: provider,
        );
        final context = collection.contextFor(main.path);
        final resolved =
            await context.currentSession.getResolvedUnit(main.path)
                as ResolvedUnitResult;
        final dependencies = ResolvedDependencies(resolved.libraryElement);
        final analyzer = _analyzer(resolved, dependencies, directory.path);
        final caller = resolved.unit.declarations
            .whereType<FunctionDeclaration>()
            .single
            .declaredFragment!
            .element;
        final summary = analyzer.summarizeExecutable(caller);
        expect(summary.hasUnknownEffects, isFalse);
        expect(
          summary.sources.expand((source) => source.exceptionTypes),
          contains('String'),
        );
        expect(analyzer.dependenciesAreCurrent, isTrue);
        final imported = resolved.libraryElement.firstFragment.importedLibraries
            .singleWhere(
              (library) => library.uri.path.endsWith('dependency.dart'),
            );
        final firstResolution = dependencies.resolve(imported);
        final siblingUnit =
            await context.currentSession.getResolvedUnit(sibling.path)
                as ResolvedUnitResult;
        expect(firstResolution, isNotNull);
        expect(
          ResolvedDependencies(siblingUnit.libraryElement).resolve(imported),
          same(firstResolution),
        );

        // A notification invalidates the old session even before re-resolution.
        provider.setOverlay(
          dependency.path,
          content: 'void helper() { throw 42; }',
          modificationStamp: 2,
        );
        context.changeFile(dependency.path);
        expect(dependencies.isCurrent, isFalse);
        expect(analyzer.dependenciesAreCurrent, isFalse);
        expect(dependencies.resolve(resolved.libraryElement), isNull);
        await context.applyPendingFileChanges();
        final updated =
            await context.currentSession.getResolvedUnit(main.path)
                as ResolvedUnitResult;
        final newAnalyzer = _analyzer(
          updated,
          ResolvedDependencies(updated.libraryElement),
          directory.path,
        );
        final newSummary = newAnalyzer.summarizeExecutable(
          updated.unit.declarations
              .whereType<FunctionDeclaration>()
              .single
              .declaredFragment!
              .element,
        );
        expect(newSummary.hasUnknownEffects, isFalse);
        expect(
          newSummary.sources.expand((source) => source.exceptionTypes),
          contains('int'),
        );
        expect(
          newSummary.sources.expand((source) => source.exceptionTypes),
          isNot(contains('String')),
        );
      } finally {
        await collection?.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
}

InferredThrowAnalyzer _analyzer(
  ResolvedUnitResult resolved,
  ResolvedDependencies dependencies,
  String root,
) => InferredThrowAnalyzer(
  manifest: ThrowingApiManifest.empty(),
  options: const ExceptionAnalysisOptions(),
  featureSet: resolved.libraryElement.featureSet,
  packageRootPath: root,
  knownUnits: {resolved.path: resolved.unit},
  resolveDependency: dependencies.resolve,
  resolutionIsCurrent: () => dependencies.isCurrent,
);
