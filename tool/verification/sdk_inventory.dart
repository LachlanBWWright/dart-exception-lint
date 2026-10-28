import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:crypto/crypto.dart';
import 'package:dart_exception_lint/src/engine/error_producers.dart';
import 'package:path/path.dart' as p;

/// Records resolved public callable identities and signatures, including native
/// boundaries. This is an evolution gate, not a claim that every entry has an
/// exception model. Review semantic changes before accepting a new inventory.
Future<void> main(List<String> arguments) async {
  final write = arguments.contains('--write');
  final sdkArgument = arguments.indexOf('--sdk-root');
  final sdkRoot = sdkArgument < 0
      ? p.dirname(p.dirname(Platform.resolvedExecutable))
      : arguments[sdkArgument + 1];
  final version = File(p.join(sdkRoot, 'version')).readAsStringSync().trim();
  final series = version.split('.').take(2).join('.');
  final context = AnalysisContextCollection(
    includedPaths: [Directory.current.absolute.path],
    sdkPath: sdkRoot,
  );
  final declarations = <String, Object>{};
  try {
    final session = context.contexts.single.currentSession;
    for (final uri in const [
      'dart:core',
      'dart:async',
      'dart:collection',
      'dart:convert',
      'dart:math',
      'dart:typed_data',
      'dart:io',
      'dart:isolate',
      'dart:ffi',
      'dart:js_interop',
    ]) {
      final result = await session.getLibraryByUri(uri);
      if (result is! LibraryElementResult) {
        throw StateError('Cannot inventory $uri in Dart $version: $result');
      }
      final library = result.element;
      void record(ExecutableElement element, [String owner = '']) {
        final name = element.name ?? '';
        if (name.startsWith('_') || owner.startsWith('_')) return;
        final kind = switch (element) {
          ConstructorElement() => 'constructor',
          GetterElement() => 'get',
          SetterElement() => 'set',
          _ => 'call',
        };
        final id = '$uri/$owner/$kind/$name';
        declarations[id] = {
          'type': element.type.getDisplayString(),
          'external': element.isExternal,
          'static': switch (element) {
            MethodElement() => element.isStatic,
            PropertyAccessorElement() => element.isStatic,
            _ => false,
          },
          if (explicitErrorProducer(element) case final producer?)
            'explicitProducer': producer.displayName,
        };
      }

      for (final element in [
        ...library.topLevelFunctions,
        ...library.getters,
        ...library.setters,
      ]) {
        record(element);
      }
      for (final owner in <InstanceElement>[
        ...library.classes,
        ...library.enums,
        ...library.mixins,
        ...library.extensions,
        ...library.extensionTypes,
      ]) {
        if (owner.name == null || owner.name!.startsWith('_')) continue;
        for (final element in [
          ...owner.methods,
          ...owner.getters,
          ...owner.setters,
          if (owner is InterfaceElement) ...owner.constructors,
        ]) {
          record(element, owner.name!);
        }
      }
    }
  } finally {
    await context.dispose();
  }
  final inventory = <String, Object>{
    for (final key in declarations.keys.toList()..sort())
      key: declarations[key]!,
  };
  // Public signatures alone miss changes to SDK bodies and native patches.
  // Fingerprint source for all backends, including private implementations.
  final sources = <String, String>{};
  final files = await Directory(p.join(sdkRoot, 'lib'))
      .list(recursive: true)
      .where((entry) => entry is File && entry.path.endsWith('.dart'))
      .cast<File>()
      .toList();
  files.sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    sources[p.relative(file.path, from: sdkRoot).replaceAll('\\', '/')] = sha256
        .convert(await file.readAsBytes())
        .toString();
  }
  final destination = File('tool/sdk_inventory/dart-$series.json');
  if (write) {
    await destination.parent.create(recursive: true);
    await destination.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert({'reviewedSdk': version, 'declarations': inventory, 'sourceFiles': sources})}\n',
    );
    stdout.writeln(
      'Recorded ${inventory.length} declarations for Dart $version.',
    );
    return;
  }
  if (!await destination.exists()) {
    throw StateError(
      'No reviewed inventory for Dart $version. Generate with '
      '--write, review the diff and audit changed models before accepting it.',
    );
  }
  final baseline = jsonDecode(await destination.readAsString()) as Map;
  final expected = baseline['declarations'] as Map;
  final expectedSources = baseline['sourceFiles'] as Map;
  final changedSources = {
    ...sources.keys,
    ...expectedSources.keys,
  }.where((key) => sources[key] != expectedSources[key]).toList();
  final added = inventory.keys
      .where((key) => !expected.containsKey(key))
      .toList();
  final removed = expected.keys
      .where((key) => !inventory.containsKey(key))
      .toList();
  final changed = inventory.keys
      .where(
        (key) =>
            expected.containsKey(key) &&
            jsonEncode(expected[key]) != jsonEncode(inventory[key]),
      )
      .toList();
  if (added.isNotEmpty ||
      removed.isNotEmpty ||
      changed.isNotEmpty ||
      changedSources.isNotEmpty) {
    throw StateError(
      'SDK model audit required for Dart $version. '
      'Added: $added; removed: $removed; changed: $changed; source changes: $changedSources',
    );
  }
  stdout.writeln(
    '${inventory.length} SDK callable declarations match the reviewed Dart $series inventory.',
  );
}
