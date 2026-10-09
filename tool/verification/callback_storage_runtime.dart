import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:dart_exception_lint/src/analysis/inferred_throw_analyzer.dart';
import 'package:dart_exception_lint/src/config/exception_analysis_options.dart';
import 'package:dart_exception_lint/src/config/throwing_api_manifest.dart';

/// Independent runtime observations for returned and stored callback values.
Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp('callback-values-');
  AnalysisContextCollection? collection;
  try {
    final file = File('${directory.path}/main.dart');
    await file.writeAsString(callbackStorageFixture);
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
    for (final entry in callbackStorageExpectedEffects.entries) {
      final declaration = unit.unit.declarations
          .whereType<FunctionDeclaration>()
          .singleWhere((function) => function.name.lexeme == entry.key);
      final summary = analyzer.summarizeExecutable(
        declaration.declaredFragment!.element,
      );
      for (final channel in entry.value) {
        if (!summary.effects.any(
          (effect) =>
              effect.channel.name == channel &&
              effect.source.exceptionTypes.contains('String'),
        )) {
          throw StateError('${entry.key} lost String/$channel');
        }
      }
    }
    for (final name in [
      'returnedSafe',
      'nestedFactorySafe',
      'recordSafe',
      'caughtFactoryCreation',
      'caughtReturnedFailure',
    ]) {
      final declaration = unit.unit.declarations
          .whereType<FunctionDeclaration>()
          .singleWhere((function) => function.name.lexeme == name);
      if (analyzer
          .summarizeExecutable(declaration.declaredFragment!.element)
          .hasAnyThrowSource) {
        throw StateError('$name was not proved safe');
      }
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
      final declaration = unit.unit.declarations
          .whereType<FunctionDeclaration>()
          .singleWhere((function) => function.name.lexeme == name);
      final summary = analyzer.summarizeExecutable(
        declaration.declaredFragment!.element,
      );
      if (!summary.hasUnknownEffects) {
        throw StateError('$name was incorrectly proved complete');
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

const callbackStorageExpectedEffects = <String, List<String>>{
  'returnedDirect': ['synchronous'],
  'returnedAlias': ['synchronous'],
  'returnedSelected': ['synchronous'],
  'returnedBlock': ['synchronous'],
  'escapesFactoryCatch': ['synchronous'],
  'factoryCreationFailure': ['synchronous'],
  'recordFail': ['synchronous'],
  'namedRecordFail': ['synchronous'],
  'aliasedRecordFail': ['synchronous'],
  'constListFail': ['synchronous'],
  'constListAliasedFail': ['synchronous'],
  'constMapFail': ['synchronous'],
  'literalListFail': ['synchronous'],
  'literalMapFail': ['synchronous'],
};

const _observations = {
  'returned_direct': 'String',
  'returned_alias': 'String',
  'returned_safe': 'none',
  'selected_fail': 'String',
  'selected_safe': 'none',
  'block_fail': 'String',
  'escapes_factory_catch': 'String',
  'captured_returned': 'String',
  'captured_alias_returned': 'String',
  'nested_factory_safe': 'none',
  'instance_factory': 'String',
  'record_mutable_collection': 'String',
  'factory_creation_caught': 'none',
  'discarded_factory_value': 'none',
  'returned_failure_caught': 'none',
  'factory_creation_failure': 'String',
  'record': 'String',
  'record_safe': 'none',
  'named_record': 'String',
  'aliased_record': 'String',
  'const_list': 'String',
  'const_list_alias': 'String',
  'const_map': 'String',
  'literal_list': 'String',
  'literal_map': 'String',
  'mutated_collection': 'String',
  'captured_record_write': 'String',
};

const callbackStorageFixture = r'''
import 'dart:convert';
void invoke(void Function() action) { action(); }
void safe() {}
void fail() { throw 'failure'; }
void Function() failFactory() => fail;
void Function() safeFactory() => safe;
void Function() selectedFactory(bool choose) => choose ? fail : safe;
void Function() blockFactory(bool choose) {
  if (choose) return fail;
  return safe;
}
void Function() containedFactory() {
  try { return failFactory(); } on String { return safe; }
}
void escapesFactoryCatch() { containedFactory()(); }
void Function() throwingFactory() { throw 'creation'; }
void Function() closureFactory(void Function() action) => () { action(); };
void Function() closureAliasFactory(void Function() action) {
  final alias = action;
  return () { alias(); };
}
void Function() nestedFactory() {
  void Function() nested() => fail;
  return safe;
}
void nestedFactorySafe() { nestedFactory()(); }
void capturedAliasReturned() { invoke(closureAliasFactory(fail)); }
class Base {
  void Function() make() => safe;
}
final class Child extends Base {
  @override
  void Function() make() => fail;
}
void instanceFactoryValue(Base source) { source.make()(); }
void returnedDirect() { failFactory()(); }
void returnedAlias() { final action = failFactory(); invoke(action); }
void returnedSafe() { final action = safeFactory(); invoke(action); }
void returnedSelected(bool choose) { invoke(selectedFactory(choose)); }
void returnedBlock(bool choose) { blockFactory(choose)(); }
void capturedReturned() { invoke(closureFactory(fail)); }
void caughtFactoryCreation() { try { throwingFactory(); } on String {} }
void discardedFactoryValue() { try { failFactory(); } on String {} }
void caughtReturnedFailure() { try { failFactory()(); } on String {} }
void factoryCreationFailure() { throwingFactory(); }
void recordFail() { final callbacks = (fail, safe); invoke(callbacks.$1); }
void recordSafe() { final callbacks = (fail, safe); invoke(callbacks.$2); }
void namedRecordFail() { final callbacks = (bad: fail, good: safe); callbacks.bad(); }
void aliasedRecordFail() { final first = (fail, safe); final second = first; second.$1(); }
void constListFail() { const callbacks = [fail, safe]; invoke(callbacks[0]); }
void constListAliasedFail() { const callbacks = [fail, safe]; final alias = callbacks; const index = 0; alias[index](); }
void constMapFail() { const callbacks = {'bad': fail, 'good': safe}; invoke(callbacks['bad']!); }
void literalListFail() { [fail, safe][0](); }
void literalMapFail() { ({'bad': fail})['bad']!(); }
void storedMutableCollection() { final callbacks = [safe]; invoke(callbacks[0]); }
void mutableCollection() { final callbacks = [safe]; callbacks[0] = fail; invoke(callbacks[0]); }
void capturedRecordWrite() {
  var callbacks = (safe, safe);
  void mutate() { callbacks = (fail, safe); }
  mutate(); invoke(callbacks.$1);
}
void recordMutableCollection() {
  final record = (actions: [safe]);
  record.actions[0] = fail;
  invoke(record.actions[0]);
}
String capture(void Function() action) {
  try { action(); return 'none'; } catch(error) { return error is String ? 'String' : '$error'; }
}
void main() {
  print(jsonEncode({
    'returned_direct': capture(returnedDirect),
    'returned_alias': capture(returnedAlias),
    'returned_safe': capture(returnedSafe),
    'selected_fail': capture(() => returnedSelected(true)),
    'selected_safe': capture(() => returnedSelected(false)),
    'block_fail': capture(() => returnedBlock(true)),
    'escapes_factory_catch': capture(escapesFactoryCatch),
    'captured_returned': capture(capturedReturned),
    'captured_alias_returned': capture(capturedAliasReturned),
    'nested_factory_safe': capture(nestedFactorySafe),
    'instance_factory': capture(() => instanceFactoryValue(Child())),
    'record_mutable_collection': capture(recordMutableCollection),
    'factory_creation_caught': capture(caughtFactoryCreation),
    'discarded_factory_value': capture(discardedFactoryValue),
    'returned_failure_caught': capture(caughtReturnedFailure),
    'factory_creation_failure': capture(factoryCreationFailure),
    'record': capture(recordFail),
    'record_safe': capture(recordSafe),
    'named_record': capture(namedRecordFail),
    'aliased_record': capture(aliasedRecordFail),
    'const_list': capture(constListFail),
    'const_list_alias': capture(constListAliasedFail),
    'const_map': capture(constMapFail),
    'literal_list': capture(literalListFail),
    'literal_map': capture(literalMapFail),
    'mutated_collection': capture(mutableCollection),
    'captured_record_write': capture(capturedRecordWrite),
  }));
}
''';
