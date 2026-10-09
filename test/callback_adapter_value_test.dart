import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:dart_exception_lint/src/analysis/inferred_throw_analyzer.dart';
import 'package:dart_exception_lint/src/config/exception_analysis_options.dart';
import 'package:dart_exception_lint/src/config/throwing_api_manifest.dart';
import 'package:dart_exception_lint/src/engine/error_producers.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Static factories named call remain ordinary native method invocations',
    () async {
      await _withUnit(
        (result) {
          final analyzer = _analyzer(result, () => true);
          final caller = result.unit.declarations
              .whereType<FunctionDeclaration>()
              .firstWhere(
                (function) => function.name.lexeme == 'namedCallCaller',
              );
          final body = caller.functionExpression.body as BlockFunctionBody;
          final initializer =
              (body.block.statements.first as VariableDeclarationStatement)
                  .variables
                  .variables
                  .single
                  .initializer!;
          final factory = analyzer.resolveInvokedCallback(initializer);
          expect(factory.hasUnknown, isFalse);
          expect(factory.targets.single.name, 'call');
          expect(
            factory.targets.single.enclosingElement!.name,
            'ProducerFactories',
          );
          final returned = analyzer.resolveCallbackValue(initializer);
          expect(returned.hasUnknown, isFalse);
          expect(
            explicitErrorProducer(returned.targets.single)!.displayName,
            'Future.error',
          );
        },
        extra: '''
final class ProducerFactories {
  static Future<void> Function(Object, [StackTrace?]) call() => Future<void>.error;
}
void namedCallCaller() { final producer = ProducerFactories.call(); producer('failure'); }
''',
      );
    },
  );
  test(
    'Producer forwarding retains uncertainty on unsupported flows and budgets',
    () async {
      var nested = "[Future<void>.error, ['failure']]";
      for (var depth = 0; depth < 20; depth++) {
        nested = '[Function.apply, $nested]';
      }
      await _withUnit(
        (result) {
          final analyzer = _analyzer(result, () => true);
          for (final function
              in result.unit.declarations.whereType<FunctionDeclaration>()) {
            if (!function.name.lexeme.startsWith('apply')) continue;
            final body = function.functionExpression.body as BlockFunctionBody;
            final call =
                (body.block.statements.last as ExpressionStatement).expression
                    as MethodInvocation;
            final value = explicitProducerInvocationTargets(
              analyzer.resolveInvokedCallback(call),
              call.argumentList,
              analyzer.resolveCallbackValue,
            );
            final producers = value.targets
                .map(explicitErrorProducer)
                .whereType<ErrorProducer>();
            if (function.name.lexeme == 'applyLiteral') {
              expect(producers.map((producer) => producer.displayName), [
                'Future.error',
              ]);
              expect(value.hasUnknown, isFalse);
            } else {
              expect(producers, isEmpty, reason: function.name.lexeme);
              expect(value.hasUnknown, isTrue, reason: function.name.lexeme);
            }
          }
        },
        extra:
            '''
void applyLiteral() { Function.apply(Function.apply, [Future<void>.error, ['failure']]); }
void applyDeep() { Function.apply(Function.apply, $nested); }
void applyStored() {
  const arguments = [Future<void>.error, ['failure']];
  Function.apply(Function.apply, arguments);
}
void applySpread() { Function.apply(Function.apply, [...[Future<void>.error, ['failure']]]); }
''',
      );
    },
  );
  test(
    'Diagnostic adapters share native values and reject stale proofs',
    () async {
      await _withUnit((result) {
        var current = true;
        final analyzer = _analyzer(result, () => current);
        final index = _InvocationIndex();
        result.unit.accept(index);
        final value = index.variable!;
        final safe = result.unit.declarations
            .whereType<FunctionDeclaration>()
            .first
            .declaredFragment!
            .element;
        expect(analyzer.resolveCallbackValue(value.initializer!).targets, {
          safe,
        });
        expect(
          analyzer
              .callbackValueForElement(value.declaredFragment!.element)
              .targets,
          {safe},
        );
        expect(analyzer.resolveInvokedCallback(index.invocation!).targets, {
          safe,
        });
        current = false;
        for (final resolution in [
          analyzer.resolveCallbackValue(value.initializer!),
          analyzer.callbackValueForElement(value.declaredFragment!.element),
          analyzer.resolveInvokedCallback(index.invocation!),
        ]) {
          expect(resolution.targets, isEmpty);
          expect(resolution.hasUnknown, isTrue);
        }
      });
    },
  );

  test(
    'Adapter values recheck freshness after resolving native targets',
    () async {
      await _withUnit((result) {
        final factory = result.unit.declarations
            .whereType<FunctionDeclaration>()
            .firstWhere((function) => function.name.lexeme == 'factory');
        final expression =
            (factory.functionExpression.body as ExpressionFunctionBody)
                .expression;
        var checks = 0;
        final analyzer = _analyzer(result, () => ++checks == 1);
        final value = analyzer.resolveCallbackValue(expression);
        expect(checks, 2);
        expect(value.targets, isEmpty);
        expect(value.hasUnknown, isTrue);
        checks = 0;
        final elementValue = analyzer.callbackValueForElement(
          (expression as SimpleIdentifier).element,
        );
        expect(checks, 2);
        expect(elementValue.targets, isEmpty);
        expect(elementValue.hasUnknown, isTrue);
      });
    },
  );
}

InferredThrowAnalyzer _analyzer(
  ResolvedUnitResult result,
  bool Function() current,
) => InferredThrowAnalyzer(
  manifest: ThrowingApiManifest.empty(),
  options: const ExceptionAnalysisOptions(),
  featureSet: result.libraryElement.featureSet,
  packageRootPath: File(result.path).parent.path,
  knownUnits: {result.path: result.unit},
  resolutionIsCurrent: current,
);

Future<void> _withUnit(
  void Function(ResolvedUnitResult) check, {
  String extra = '',
}) async {
  final directory = await Directory.systemTemp.createTemp('callback-adapter-');
  AnalysisContextCollection? collection;
  try {
    final file = File('${directory.path}/main.dart');
    await file.writeAsString('''
void safe() {}
void Function() factory() => safe;
void caller() { final value = factory(); value(); }
$extra
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
        (diagnostic) => diagnostic.diagnosticCode.severity.name == 'ERROR',
      ),
      isEmpty,
    );
    check(result);
  } finally {
    await collection?.dispose();
    await directory.delete(recursive: true);
  }
}

final class _InvocationIndex extends RecursiveAstVisitor<void> {
  VariableDeclaration? variable;
  FunctionExpressionInvocation? invocation;

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    variable = node;
    super.visitVariableDeclaration(node);
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    invocation = node;
    super.visitFunctionExpressionInvocation(node);
  }
}
