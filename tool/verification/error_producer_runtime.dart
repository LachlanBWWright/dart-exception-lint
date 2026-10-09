import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:dart_exception_lint/src/engine/error_producers.dart';
import 'package:dart_exception_lint/src/analysis/inferred_throw_analyzer.dart';
import 'package:dart_exception_lint/src/config/exception_analysis_options.dart';
import 'package:dart_exception_lint/src/config/throwing_api_manifest.dart';

/// Independent runtime observations for explicit SDK error producer invocations.
Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp('producer-runtime-');
  AnalysisContextCollection? collection;
  try {
    final file = File('${directory.path}/main.dart');
    await file.writeAsString(_fixture);
    collection = AnalysisContextCollection(includedPaths: [directory.path]);
    final unit =
        await collection
                .contextFor(file.path)
                .currentSession
                .getResolvedUnit(file.path)
            as ResolvedUnitResult;
    final errors = unit.diagnostics.where(
      (diagnostic) => diagnostic.diagnosticCode.severity.name == 'ERROR',
    );
    if (errors.isNotEmpty) {
      throw StateError('Invalid differential fixture: ${errors.join('\n')}');
    }
    final analyzer = InferredThrowAnalyzer(
      manifest: ThrowingApiManifest.empty(),
      options: const ExceptionAnalysisOptions(),
      featureSet: unit.libraryElement.featureSet,
      packageRootPath: directory.path,
      knownUnits: {file.path: unit.unit},
    );
    for (final entry in _producers.entries) {
      final declaration = unit.unit.declarations
          .whereType<FunctionDeclaration>()
          .singleWhere((function) => function.name.lexeme == entry.key);
      final calls = _Calls();
      declaration.functionExpression.body.accept(calls);
      final producers = calls.nodes
          .expand(
            (node) => explicitProducerInvocationTargets(
              analyzer.resolveInvokedCallback(node),
              switch (node) {
                MethodInvocation() => node.argumentList,
                FunctionExpressionInvocation() => node.argumentList,
                _ => throw StateError('Unexpected invocation'),
              },
              analyzer.resolveCallbackValue,
            ).targets,
          )
          .map(explicitErrorProducer)
          .whereType<ErrorProducer>()
          .toList();
      if (!producers.any((producer) => producer.displayName == entry.value)) {
        throw StateError('${entry.key} lost explicit producer ${entry.value}');
      }
    }
    for (final name in ['customProducer', 'mereErrorObject']) {
      final declaration = unit.unit.declarations
          .whereType<FunctionDeclaration>()
          .singleWhere((function) => function.name.lexeme == name);
      final calls = _Calls();
      declaration.functionExpression.body.accept(calls);
      if (calls.nodes
          .expand((node) => analyzer.resolveInvokedCallback(node).targets)
          .any((target) => explicitErrorProducer(target) != null)) {
        throw StateError(
          '$name falsely classified as explicit error production',
        );
      }
    }
    Future<void> verify(
      String executable,
      List<String> arguments,
      String platform,
    ) async {
      final result = await Process.run(executable, arguments);
      if (result.exitCode != 0) {
        throw StateError('$platform failed: ${result.stderr}');
      }
      final observed = jsonDecode((result.stdout as String).trim());
      if (jsonEncode(observed) != jsonEncode(_observations)) {
        throw StateError(
          '$platform observed $observed; expected $_observations',
        );
      }
      stdout.writeln(
        '$platform: ${_observations.length} callback observations match.',
      );
    }

    await verify(Platform.resolvedExecutable, [file.path], 'Dart VM');
    final output = '${directory.path}/main.js';
    final compile = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'js',
      file.path,
      '-o',
      output,
    ]);
    if (compile.exitCode != 0) {
      throw StateError('JavaScript compilation failed: ${compile.stderr}');
    }
    await verify('node', [
      '-e',
      'globalThis.self = globalThis; require(process.argv[1]);',
      output,
    ], 'Dart JavaScript (Node)');
  } finally {
    await collection?.dispose();
    await directory.delete(recursive: true);
  }
}

const _producers = {
  'aliasFuture': 'Future.error',
  'selectedFuture': 'Future.error',
  'switchedFuture': 'Future.error',
  'recordFuture': 'Future.error',
  'constListFuture': 'Future.error',
  'constMapFuture': 'Future.error',
  'returnedFuture': 'Future.error',
  'staticReturnedFuture': 'Future.error',
  'explicitCall': 'Future.error',
  'appliedFuture': 'Future.error',
  'callTearoffFuture': 'Future.error',
  'broadCallTearoffFuture': 'Future.error',
  'nestedAppliedFuture': 'Future.error',
  'aliasStream': 'Stream.error',
  'aliasCompleter': 'Completer.completeError',
  'aliasController': 'StreamController.addError',
  'aliasThrow': 'Error.throwWithStackTrace',
};

const _observations = {
  'alias_future': 'String',
  'selected_failure': 'String',
  'selected_safe': 'none',
  'switch': 'String',
  'record': 'String',
  'const_list': 'String',
  'const_map': 'String',
  'factory': 'String',
  'static_factory': 'String',
  'call': 'String',
  'apply': 'String',
  'call_tearoff': 'String',
  'broad_call_tearoff': 'String',
  'nested_apply': 'String',
  'stream': 'String',
  'completer': 'String',
  'controller': 'String',
  'throw': 'String',
  'custom': 'none',
  'mere_error': 'none',
};

const _fixture = r'''
import 'dart:async';
import 'dart:convert';
Future<void> Function(Object, [StackTrace?]) factory() => Future<void>.error;
final class Factories {
  static Future<void> Function(Object, [StackTrace?]) make() => Future<void>.error;
}
Future<void> aliasFuture() async {
  final first = Future<void>.error;
  final second = (first);
  await (second)('failure');
}
Future<void> selectedFuture(bool choose) async {
  final action = choose ? Future<void>.error : safe;
  await action('failure');
}
Future<void> switchedFuture(bool choose) async {
  final action = switch(choose) { true => Future<void>.error, false => safe };
  await action('failure');
}
Future<void> safe(Object value, [StackTrace? stack]) => Future<void>.value();
Future<void> recordFuture() async {
  final pair = (Future<void>.error, safe);
  await pair.$1('failure');
}
Future<void> constListFuture() async {
  const callbacks = [Future<void>.error];
  await callbacks[0]('failure');
}
Future<void> constMapFuture() async {
  const callbacks = {'error': Future<void>.error};
  await callbacks['error']!('failure');
}
Future<void> returnedFuture() async { await factory()('failure'); }
Future<void> staticReturnedFuture() async { await Factories.make()('failure'); }
Future<void> explicitCall() async {
  final action = Future<void>.error;
  await action.call('failure');
}
Future<void> appliedFuture() async { await Function.apply(Future<void>.error, ['failure']); }
Future<void> callTearoffFuture() async {
  final action = Future<void>.error.call.call;
  await action('failure');
}
Future<void> broadCallTearoffFuture() async {
  Function producer = Future<void>.error;
  final action = producer.call;
  await action('failure');
}
Future<void> nestedAppliedFuture() async {
  await Function.apply(Function.apply, [Future<void>.error, ['failure']]);
}
Future<void> aliasStream() async {
  final action = Stream<void>.error;
  await action('failure').first;
}
Future<void> aliasCompleter() async {
  final completer = Completer<void>();
  final complete = completer.completeError;
  complete('failure');
  await completer.future;
}
Future<void> aliasController() async {
  final controller = StreamController<void>();
  final observed = controller.stream.first;
  final pair = (error: controller.addError);
  pair.error('failure');
  try { await observed; } finally { await controller.close(); }
}
void aliasThrow() {
  final action = Error.throwWithStackTrace;
  action('failure', StackTrace.current);
}
final class Custom { static void error(Object error) {} }
void customProducer() { final action = Custom.error; action('failure'); }
void mereErrorObject() { AsyncError('failure', StackTrace.current); }
String capture(void Function() action) {
  try { action(); return 'none'; } catch(error) { return error is String ? 'String' : '$error'; }
}
Future<String> captureAsync(Future<void> Function() action) async {
  try { await action(); return 'none'; } catch(error) { return error is String ? 'String' : '$error'; }
}
Future<void> main() async {
  print(jsonEncode({
    'alias_future': await captureAsync(aliasFuture),
    'selected_failure': await captureAsync(() => selectedFuture(true)),
    'selected_safe': await captureAsync(() => selectedFuture(false)),
    'switch': await captureAsync(() => switchedFuture(true)),
    'record': await captureAsync(recordFuture),
    'const_list': await captureAsync(constListFuture),
    'const_map': await captureAsync(constMapFuture),
    'factory': await captureAsync(returnedFuture),
    'static_factory': await captureAsync(staticReturnedFuture),
    'call': await captureAsync(explicitCall),
    'apply': await captureAsync(appliedFuture),
    'call_tearoff': await captureAsync(callTearoffFuture),
    'broad_call_tearoff': await captureAsync(broadCallTearoffFuture),
    'nested_apply': await captureAsync(nestedAppliedFuture),
    'stream': await captureAsync(aliasStream),
    'completer': await captureAsync(aliasCompleter),
    'controller': await captureAsync(aliasController),
    'throw': capture(aliasThrow),
    'custom': capture(customProducer),
    'mere_error': capture(mereErrorObject),
  }));
}
''';

final class _Calls extends RecursiveAstVisitor<void> {
  final nodes = <AstNode>[];
  @override
  void visitMethodInvocation(MethodInvocation node) {
    super.visitMethodInvocation(node);
    nodes.add(node);
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    super.visitFunctionExpressionInvocation(node);
    nodes.add(node);
  }
}
