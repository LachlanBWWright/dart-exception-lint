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

import '../tool/verification/numeric_runtime.dart';

void main() {
  test(
    'Native numeric failures preserve types, compounds and portable catches',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'numeric-effects-',
      );
      AnalysisContextCollection? collection;
      try {
        final file = File('${directory.path}/main.dart');
        await file.writeAsString(numericFixture);
        collection = AnalysisContextCollection(includedPaths: [directory.path]);
        final unit =
            await collection
                    .contextFor(file.path)
                    .currentSession
                    .getResolvedUnit(file.path)
                as ResolvedUnitResult;
        expect(
          unit.diagnostics.where(
            (diagnostic) => diagnostic.diagnosticCode.severity.name == 'ERROR',
          ),
          isEmpty,
        );
        final analyzer = InferredThrowAnalyzer(
          manifest: ThrowingApiManifest.empty(),
          options: const ExceptionAnalysisOptions(),
          featureSet: unit.libraryElement.featureSet,
          packageRootPath: directory.path,
          knownUnits: {file.path: unit.unit},
        );
        final summaries = {
          for (final function
              in unit.unit.declarations.whereType<FunctionDeclaration>())
            function.name.lexeme: analyzer.summarizeExecutable(
              function.declaredFragment!.element,
            ),
        };
        for (final entry in numericExpectedTypes.entries) {
          for (final type in entry.value) {
            expect(
              summaries[entry.key]!.effects.any(
                (effect) =>
                    effect.channel == ExceptionChannel.synchronous &&
                    effect.source.exceptionTypes.contains(type),
              ),
              isTrue,
              reason: '${entry.key}: $type',
            );
          }
        }
        for (final name in numericSafeFunctions) {
          expect(
            summaries[name]!.hasAnyThrowSource,
            isFalse,
            reason:
                '$name: ${summaries[name]!.sources.map((source) => '${source.displayName}/${source.kind}/${source.exceptionTypes}/${source.origin}').join(', ')}',
          );
        }
        for (final name in ['customOperators', 'customConversion']) {
          expect(
            summaries[name]!.sources.expand((source) => source.exceptionTypes),
            isNot(
              anyOf(
                contains('UnsupportedError'),
                contains('ArgumentError'),
                contains('IntegerDivisionByZeroException'),
              ),
            ),
            reason: name,
          );
        }
        final functions = {
          for (final function
              in unit.unit.declarations.whereType<FunctionDeclaration>())
            function.name.lexeme: function,
        };
        for (final entry in {
          'converterAlias': 'UnsupportedError',
          'converterWrongArity': 'NoSuchMethodError',
          'floatingConverterWrongArityCaught': 'NoSuchMethodError',
          'fixedFormatAlias': 'RangeError',
        }.entries) {
          final calls = _NumericCallCollector();
          functions[entry.key]!.functionExpression.body.accept(calls);
          final invocation = calls.calls.single;
          final projection = analyzer.analyzeResolvedCall(
            invocation,
            element: invocation.element,
            treatUnknownAsReportable: true,
            requireObservedAsyncError: false,
          );
          expect(projection, isNotNull, reason: entry.key);
          expect(
            projection!.sources.any(
              (source) => source.exceptionTypes.contains(entry.value),
            ),
            isTrue,
            reason: '${entry.key}: rule-facing ${entry.value}',
          );
        }
      } finally {
        await collection?.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
}

final class _NumericCallCollector extends RecursiveAstVisitor<void> {
  final calls = <FunctionExpressionInvocation>[];

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    super.visitFunctionExpressionInvocation(node);
    calls.add(node);
  }
}
