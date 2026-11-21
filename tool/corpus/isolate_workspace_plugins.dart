import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

/// Isolates plugin activation in analyzer options of disposable worktrees.
void main(List<String> arguments) {
  final installing = arguments.firstOrNull == '--install-from';
  final paths = installing ? arguments.skip(2) : arguments;
  final activation = installing
      ? (loadYaml(File(arguments[1]).readAsStringSync()) as Map)['plugins']
      : null;
  if (installing && activation == null) {
    throw StateError('Package options must include plugin activation');
  }
  for (final path in paths) {
    final file = File(path);
    final parsed = loadYaml(file.readAsStringSync());
    if (parsed is! Map && (parsed != null || !installing)) continue;
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
    if (changed) {
      // The analyzer accepts JSON as YAML. Relative includes retain their base.
      file.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(options)}\n',
      );
    }
  }
}
