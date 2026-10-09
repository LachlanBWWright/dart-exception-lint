import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/file_system/overlay_file_system.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:dart_exception_lint/src/analysis/inferred_throw_analyzer.dart';
import 'package:dart_exception_lint/src/config/exception_analysis_options.dart';
import 'package:dart_exception_lint/src/config/throwing_api_manifest.dart';
import 'package:dart_exception_lint/src/engine/exception_effect.dart';
import 'package:dart_exception_lint/src/engine/resolved_dependencies.dart';
import 'package:test/test.dart';

import '../tool/verification/callback_storage_runtime.dart';

void main() {
  test(
    'Returned and stored callables retain execution effects and uncertainty',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'callback-storage-',
      );
      AnalysisContextCollection? collection;
      try {
        final file = File('${directory.path}/main.dart');
        await file.writeAsString(callbackStorageFixture);
        collection = AnalysisContextCollection(includedPaths: [directory.path]);
        final result =
            await collection
                    .contextFor(file.path)
                    .currentSession
                    .getResolvedUnit(file.path)
                as ResolvedUnitResult;
        expect(
          result.diagnostics.where(
            (error) => error.diagnosticCode.severity.name == 'ERROR',
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
          for (final function
              in result.unit.declarations.whereType<FunctionDeclaration>())
            function.name.lexeme: analyzer.summarizeExecutable(
              function.declaredFragment!.element,
            ),
        };
        for (final entry in callbackStorageExpectedEffects.entries) {
          for (final channel in entry.value) {
            expect(
              summaries[entry.key]!.effects.any(
                (effect) =>
                    effect.channel.name == channel &&
                    effect.source.exceptionTypes.contains('String'),
              ),
              isTrue,
              reason: '${entry.key} must retain String/$channel',
            );
          }
        }
        for (final name in [
          'returnedSafe',
          'nestedFactorySafe',
          'recordSafe',
          'caughtFactoryCreation',
          'caughtReturnedFailure',
          'discardedFactoryValue',
        ]) {
          expect(summaries[name]!.hasAnyThrowSource, isFalse, reason: name);
        }
        for (final name in [
          'capturedReturned',
          'mutableCollection',
          'storedMutableCollection',
          'capturedRecordWrite',
          'capturedAliasReturned',
          'instanceFactoryValue',
          'recordMutableCollection',
        ]) {
          expect(summaries[name]!.hasUnknownEffects, isTrue, reason: name);
          expect(
            summaries[name]!.effects.any(
              (effect) =>
                  effect.certainty == ExceptionCertainty.unknown &&
                  effect.channel == ExceptionChannel.scheduled,
            ),
            isTrue,
            reason: '$name must retain opaque callback scheduling',
          );
        }
        final declarations = {
          for (final function
              in result.unit.declarations.whereType<FunctionDeclaration>())
            function.name.lexeme: function,
        };
        for (final name in ['returnedDirect', 'escapesFactoryCatch']) {
          final calls = _CallbackInvocationCollector();
          declarations[name]!.functionExpression.body.accept(calls);
          final call = calls.invocations.last;
          final projection = analyzer.analyzeResolvedCall(
            call,
            element: call.element,
            treatUnknownAsReportable: true,
            requireObservedAsyncError: false,
          );
          expect(projection, isNotNull, reason: name);
          expect(
            projection!.sources.any(
              (source) =>
                  source.exceptionTypes.contains('String') &&
                  source.channel == ExceptionChannel.synchronous,
            ),
            isTrue,
            reason: '$name must reach the rule-facing projection',
          );
        }
      } finally {
        await collection?.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
  test(
    'Imported callback factories follow dependency overlays and sessions',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'callback-import-',
      );
      AnalysisContextCollection? collection;
      try {
        final main = File('${directory.path}/main.dart');
        final dependency = File('${directory.path}/dependency.dart');
        await main.writeAsString("""
import 'dependency.dart';
void topCaller() { factory()(); }
void staticCaller() { Factories.make()(); }
""");
        String dependencyContent(String body) =>
            '''
void callback() { $body }
void Function() factory() { final result = callback; return result; }
final class Factories {
  static void Function() make() {
    final callbackAlias = callback;
    return callbackAlias;
  }
}
''';
        await dependency.writeAsString(dependencyContent("throw 'disk';"));
        final provider =
            OverlayResourceProvider(PhysicalResourceProvider.INSTANCE)
              ..setOverlay(
                dependency.path,
                content: dependencyContent(''),
                modificationStamp: 1,
              );
        collection = AnalysisContextCollection(
          includedPaths: [directory.path],
          resourceProvider: provider,
        );
        final context = collection.contextFor(main.path);
        final original =
            await context.currentSession.getResolvedUnit(main.path)
                as ResolvedUnitResult;
        InferredThrowAnalyzer build(
          ResolvedUnitResult unit,
          ResolvedDependencies dependencies,
        ) => InferredThrowAnalyzer(
          manifest: ThrowingApiManifest.empty(),
          options: const ExceptionAnalysisOptions(),
          featureSet: unit.libraryElement.featureSet,
          packageRootPath: directory.path,
          knownUnits: {unit.path: unit.unit},
          resolveDependency: dependencies.resolve,
          resolutionIsCurrent: () => dependencies.isCurrent,
        );
        final originalDependencies = ResolvedDependencies(
          original.libraryElement,
        );
        final originalAnalyzer = build(original, originalDependencies);
        void verify(
          ResolvedUnitResult unit,
          InferredThrowAnalyzer analyzer, {
          required bool throws,
        }) {
          expect(
            unit.diagnostics.where(
              (diagnostic) =>
                  diagnostic.diagnosticCode.severity.name == 'ERROR',
            ),
            isEmpty,
          );
          for (final caller
              in unit.unit.declarations.whereType<FunctionDeclaration>()) {
            final summary = analyzer.summarizeExecutable(
              caller.declaredFragment!.element,
            );
            expect(
              summary.hasUnknownEffects,
              isFalse,
              reason: caller.name.lexeme,
            );
            expect(
              summary.sources.any(
                (source) => source.exceptionTypes.contains('String'),
              ),
              throws,
              reason: caller.name.lexeme,
            );
            final calls = _CallbackInvocationCollector();
            caller.functionExpression.body.accept(calls);
            final call = calls.invocations.last;
            final projection = analyzer.analyzeResolvedCall(
              call,
              element: call.element,
              treatUnknownAsReportable: true,
              requireObservedAsyncError: false,
            );
            if (throws) {
              expect(projection, isNotNull, reason: caller.name.lexeme);
              expect(
                projection!.sources.any(
                  (source) => source.exceptionTypes.contains('String'),
                ),
                isTrue,
              );
            } else {
              expect(projection, isNull, reason: caller.name.lexeme);
            }
          }
        }

        verify(original, originalAnalyzer, throws: false);
        expect(originalAnalyzer.dependenciesAreCurrent, isTrue);
        provider.setOverlay(
          dependency.path,
          content: dependencyContent("throw 'overlay';"),
          modificationStamp: 2,
        );
        context.changeFile(dependency.path);
        expect(originalDependencies.isCurrent, isFalse);
        expect(originalAnalyzer.dependenciesAreCurrent, isFalse);
        await context.applyPendingFileChanges();
        final updated =
            await context.currentSession.getResolvedUnit(main.path)
                as ResolvedUnitResult;
        final updatedAnalyzer = build(
          updated,
          ResolvedDependencies(updated.libraryElement),
        );
        verify(updated, updatedAnalyzer, throws: true);
        expect(updatedAnalyzer.dependenciesAreCurrent, isTrue);
      } finally {
        await collection?.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
}

final class _CallbackInvocationCollector extends RecursiveAstVisitor<void> {
  final invocations = <FunctionExpressionInvocation>[];

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    super.visitFunctionExpressionInvocation(node);
    invocations.add(node);
  }
}
