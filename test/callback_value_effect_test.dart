import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:dart_exception_lint/src/analysis/inferred_throw_analyzer.dart';
import 'package:dart_exception_lint/src/config/exception_analysis_options.dart';
import 'package:dart_exception_lint/src/config/throwing_api_manifest.dart';
import 'package:dart_exception_lint/src/engine/exception_effect.dart';
import 'package:test/test.dart';

import '../tool/verification/callback_value_runtime.dart';

void main() {
  test(
    'Callback values retain known alternatives and unsupported uncertainty',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'callback-values-',
      );
      AnalysisContextCollection? collection;
      try {
        final file = File('${directory.path}/main.dart');
        await file.writeAsString('''
$callbackValueFixture
void directMutable(bool choose) {
  var action = safe;
  if (choose) { action = fail; }
  action();
}
void directPartial(bool choose, void Function() opaque) {
  final action = choose ? fail : opaque;
  action();
}
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
        for (final entry in callbackValueExpectedEffects.entries) {
          for (final channel in entry.value) {
            expect(
              summaries[entry.key]!.effects.any(
                (effect) =>
                    effect.source.exceptionTypes.contains('String') &&
                    effect.channel.name == channel,
              ),
              isTrue,
              reason: '${entry.key}: String/$channel',
            );
          }
        }
        for (final name in ['aliasSafe', 'selectedSafe', 'varAliasSafe']) {
          expect(summaries[name]!.hasAnyThrowSource, isFalse, reason: name);
        }
        for (final name in [
          'partialSelected',
          'mutableAlias',
          'capturedWrite',
          'unknownAwaited',
        ]) {
          expect(summaries[name]!.hasUnknownEffects, isTrue, reason: name);
        }
        expect(
          summaries['partialSelected']!.effects.any(
            (effect) =>
                effect.certainty == ExceptionCertainty.unknown &&
                effect.channel == ExceptionChannel.scheduled,
          ),
          isTrue,
        );
        expect(
          summaries['unknownAwaited']!.effects.any(
            (effect) =>
                effect.certainty == ExceptionCertainty.unknown &&
                effect.channel == ExceptionChannel.scheduled,
          ),
          isTrue,
        );
        expect(
          summaries['mixedCaught']!.effects.any(
            (effect) =>
                effect.source.exceptionTypes.contains('String') &&
                effect.channel == ExceptionChannel.synchronous,
          ),
          isFalse,
        );
        final declarations = {
          for (final function
              in result.unit.declarations.whereType<FunctionDeclaration>())
            function.name.lexeme: function,
        };
        final limited = InferredThrowAnalyzer(
          manifest: ThrowingApiManifest.empty(),
          options: const ExceptionAnalysisOptions(maxSourcesPerSummary: 1),
          featureSet: result.libraryElement.featureSet,
          packageRootPath: directory.path,
          knownUnits: {file.path: result.unit},
        );
        final limitedCaught = limited.summarizeExecutable(
          declarations['mixedCaught']!.declaredFragment!.element,
        );
        expect(
          limitedCaught.effects.any(
            (effect) =>
                effect.certainty == ExceptionCertainty.unknown &&
                effect.channel == ExceptionChannel.scheduled,
          ),
          isTrue,
          reason:
              'Source truncation must preserve the discarded Future channel '
              'after a catch handles the synchronous alternative',
        );
        InferredCallAnalysis? project(String name, {bool staleSafe = false}) {
          final collector = _CallCollector();
          declarations[name]!.functionExpression.body.accept(collector);
          final call = collector.calls.last;
          return analyzer.analyzeResolvedCall(
            call,
            element: staleSafe
                ? declarations['safe']!.declaredFragment!.element
                : switch (call) {
                    FunctionExpressionInvocation() => call.element,
                    MethodInvocation() => call.methodName.element,
                    _ => null,
                  },
            treatUnknownAsReportable: true,
            requireObservedAsyncError: false,
          );
        }

        for (final name in ['directAlias', 'directSelected']) {
          final projected = project(name);
          expect(projected, isNotNull, reason: name);
          expect(
            projected!.sources.any(
              (source) =>
                  source.exceptionTypes.contains('String') &&
                  source.channel == ExceptionChannel.synchronous,
            ),
            isTrue,
            reason: name,
          );
        }
        expect(project('aliasSafe'), isNull);
        expect(
          project('directMutable', staleSafe: true)!.sources.any(
            (source) =>
                ExceptionEffect.fromSource(source).certainty ==
                ExceptionCertainty.unknown,
          ),
          isTrue,
        );
        for (final name in ['directPartial', 'partialSelected']) {
          final projected = project(name)!;
          expect(
            projected.sources.any(
              (source) =>
                  source.exceptionTypes.contains('String') &&
                  source.channel == ExceptionChannel.synchronous,
            ),
            isTrue,
            reason: '$name known effect survives projection',
          );
          expect(
            projected.sources.any(
              (source) =>
                  ExceptionEffect.fromSource(source).certainty ==
                      ExceptionCertainty.unknown &&
                  source.channel == ExceptionChannel.scheduled,
            ),
            isTrue,
            reason: '$name unknown effect survives projection',
          );
        }
      } finally {
        await collection?.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
}

final class _CallCollector extends RecursiveAstVisitor<void> {
  final calls = <AstNode>[];

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    super.visitFunctionExpressionInvocation(node);
    calls.add(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    super.visitMethodInvocation(node);
    calls.add(node);
  }
}
