import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:dart_exception_lint/src/analysis/inferred_throw_analyzer.dart';
import 'package:dart_exception_lint/src/config/exception_analysis_options.dart';
import 'package:dart_exception_lint/src/config/throwing_api_manifest.dart';
import 'package:dart_exception_lint/src/engine/exception_effect.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Callback bindings preserve effects, containment, and runtime checks',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'exception-callback-',
      );
      AnalysisContextCollection? collection;
      try {
        final file = File('${directory.path}/main.dart');
        final contexts = List.generate(
          70,
          (index) => 'void context$index() { run(() {}); }',
        ).join('\n');
        await file.writeAsString('''
void ignored() { [1].forEach((_) async { throw 'failure'; }); }
void caught() { try { [1].forEach((_) async { throw 'failure'; }); } on String {} }
Future<void> adopted() => Future.sync(() async { throw 'failure'; });
void run(void Function() action) { action(); }
void runCaught(void Function() action) { try { action(); } on String {} }
void runNamed({required void Function() action}) { action(); }
void safe() {}
void fail() { throw 'failure'; }
Future<void> asyncFail() async { throw 'failure'; }
void asyncVoidFail() async { throw 'failure'; }
void safeCaller() { run(safe); }
void shadow(void Function() safe) { safe(); }
void shadowCaller() { shadow(fail); }
void unresolvedShadow(void Function() safe) { try { safe(); } catch (_) {} }
void unresolvedSdk(void Function(int) action) { try { [1].forEach(action); } catch (_) {} }
void withDefault([void Function() action = fail]) { action(); }
void defaultCaller() { withDefault(); }
void narrow(int value) {}
void runDynamic(void Function(int) action, dynamic value) { action(value); }
void castCaller(dynamic value) { runDynamic(narrow, value); }
dynamic dynamicResult() => 'bad';
int runResult(dynamic Function() action) => action();
int resultCaller() => runResult(dynamicResult);
final class Runner {
  Runner(void Function() action) { action(); }
  void execute(void Function() action) { action(); }
}
void constructorCaller() { Runner(fail); }
void methodCaller() { Runner(safe).execute(fail); }
void capturedRelay(void Function() action) { run(() { action(); }); }
void capturedCaller() { capturedRelay(fail); }
void failCaller() { run(fail); }
void caughtCaller() { runCaught(fail); }
void namedCaller() { runNamed(action: fail); }
void inlineCaller() { run(() { throw 'failure'; }); }
void mixedCaller() { run(safe); run(fail); run(safe); }
void relay(void Function() action) { run(action); }
void relayCaller() { relay(fail); }
void replaced(void Function() action) { action = fail; action(); }
void replacedCaller() { replaced(safe); }
void capturedWrite(void Function() action) {
  void mutate() { action = fail; }
  mutate(); action();
}
void capturedWriteCaller() { capturedWrite(safe); }
void recursive(void Function() action, bool again) {
  if (again) { recursive(fail, false); } else { action(); }
}
void recursiveCaller() { recursive(safe, true); }
void ignoredCaller() { run(asyncFail); }
void asyncVoidCaller() { runCaught(asyncVoidFail); }
Future<void> runAwaited(Future<void> Function() action) async { await action(); }
Future<void> awaitedCaller() async {
  try { await runAwaited(asyncFail); } on String {}
}
$contexts
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
              in result.unit.declarations
                  .whereType<FunctionDeclaration>()
                  .where(
                    (function) => !function.name.lexeme.startsWith('context'),
                  ))
            function.name.lexeme: analyzer.summarizeExecutable(
              function.declaredFragment!.element,
            ),
        };
        Iterable<ExceptionChannel> channels(String name) => summaries[name]!
            .effects
            .where((effect) => effect.source.exceptionTypes.contains('String'))
            .map((effect) => effect.channel);
        expect(channels('ignored'), contains(ExceptionChannel.scheduled));
        expect(channels('caught'), contains(ExceptionChannel.scheduled));
        expect(channels('adopted'), contains(ExceptionChannel.future));
        expect(
          channels('adopted'),
          isNot(contains(ExceptionChannel.scheduled)),
        );
        expect(
          summaries['safeCaller']!.hasAnyThrowSource,
          isFalse,
          reason: summaries['safeCaller']!.sources
              .map(
                (source) =>
                    '${source.displayName}/${source.channel}/${source.origin}',
              )
              .join('\n'),
        );
        for (final name in [
          'failCaller',
          'shadowCaller',
          'defaultCaller',
          'constructorCaller',
          'methodCaller',
          'capturedCaller',
          'namedCaller',
          'inlineCaller',
          'mixedCaller',
          'relayCaller',
        ]) {
          expect(
            channels(name),
            contains(ExceptionChannel.synchronous),
            reason: name,
          );
        }
        expect(channels('caughtCaller'), isEmpty);
        expect(summaries['caughtCaller']!.hasUnknownEffects, isFalse);
        expect(summaries['replacedCaller']!.hasUnknownEffects, isTrue);
        expect(summaries['capturedWriteCaller']!.hasUnknownEffects, isTrue);
        expect(
          summaries['recursiveCaller']!.hasUnknownEffects ||
              channels(
                'recursiveCaller',
              ).contains(ExceptionChannel.synchronous),
          isTrue,
        );
        for (final options in [
          const ExceptionAnalysisOptions(maxCallDepth: 0),
          const ExceptionAnalysisOptions(),
        ]) {
          final limited = InferredThrowAnalyzer(
            manifest: ThrowingApiManifest.empty(),
            options: options,
            featureSet: result.libraryElement.featureSet,
            packageRootPath: directory.path,
            knownUnits: {file.path: result.unit},
          );
          final functions = result.unit.declarations
              .whereType<FunctionDeclaration>();
          final names = options.maxCallDepth == 0
              ? ['relayCaller']
              : List.generate(70, (index) => 'context$index');
          for (final name in names) {
            final declaration = functions.singleWhere(
              (function) => function.name.lexeme == name,
            );
            final summary = limited.summarizeExecutable(
              declaration.declaredFragment!.element,
            );
            if (name == names.last) {
              expect(
                summary.effects.any(
                  (effect) =>
                      effect.certainty == ExceptionCertainty.unknown &&
                      effect.channel == ExceptionChannel.scheduled,
                ),
                isTrue,
                reason: name,
              );
            }
          }
        }
        for (final name in ['unresolvedShadow', 'unresolvedSdk']) {
          expect(
            summaries[name]!.effects.any(
              (effect) =>
                  effect.certainty == ExceptionCertainty.unknown &&
                  effect.channel == ExceptionChannel.scheduled,
            ),
            isTrue,
          );
        }
        expect(channels('ignoredCaller'), contains(ExceptionChannel.scheduled));
        expect(
          channels('asyncVoidCaller'),
          contains(ExceptionChannel.scheduled),
        );
        expect(channels('awaitedCaller'), isEmpty);
        expect(summaries['awaitedCaller']!.hasUnknownEffects, isFalse);
        for (final name in ['castCaller', 'resultCaller']) {
          expect(
            summaries[name]!.sources.any(
              (source) => source.exceptionTypes.contains('TypeError'),
            ),
            isTrue,
            reason: name,
          );
        }
      } finally {
        await collection?.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
}
