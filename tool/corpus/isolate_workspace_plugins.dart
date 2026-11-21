import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

/// Isolates plugin activation in analyzer options of disposable worktrees.
void main(List<String> arguments) {
  final mode = arguments.firstOrNull;
  final configuringPackage = mode == '--configure-package';
  final installing = configuringPackage || mode == '--install-from';
  final paths = installing ? arguments.skip(2) : arguments;
  final overlay = installing
      ? loadYaml(File(arguments[1]).readAsStringSync()) as Map
      : null;
  final activation = overlay?['plugins'];
  if (installing && activation == null) {
    throw StateError('Package options must include plugin activation');
  }
  for (final path in paths) {
    final file = File(path);
    final parsed = file.existsSync() ? loadYaml(file.readAsStringSync()) : null;
    if (parsed != null && parsed is! Map) {
      if (installing) {
        throw FormatException('Analyzer options must be a mapping', path);
      }
      continue;
    }
    final options = parsed is Map
        ? Map<String, Object?>.from(parsed)
        : <String, Object?>{};
    var changed = options.containsKey('plugins');
    options.remove('plugins');
    final analyzer = options['analyzer'];
    if (analyzer is Map && analyzer.containsKey('plugins')) {
      options['analyzer'] = Map<String, Object?>.from(analyzer)
        ..remove('plugins');
      changed = true;
    }
    if (installing) {
      options['plugins'] = activation;
      changed = true;
    }
    final defaults = overlay?['analyzer'];
    if (configuringPackage && defaults is Map) {
      final current = options['analyzer'] as Map?;
      options['analyzer'] = {
        ...?current,
        'exclude': {
          ...?current?['exclude'] as List?,
          ...defaults['exclude'] as List,
        }.toList(),
      };
    }
    if (changed) {
      // The analyzer accepts JSON as YAML. Relative includes retain their base.
      final staging = file.parent.createTempSync('.corpus-options-');
      try {
        final staged = File.fromUri(
          staging.uri.resolve('analysis_options.yaml'),
        );
        staged.writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(options)}\n',
        );
        staged.renameSync(file.path);
      } finally {
        staging.deleteSync(recursive: true);
      }
    }
  }
}
