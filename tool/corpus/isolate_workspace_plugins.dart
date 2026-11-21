import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

/// Removes plugin activation from ancestor options in disposable worktrees.
void main(List<String> paths) {
  for (final path in paths) {
    final file = File(path);
    final parsed = loadYaml(file.readAsStringSync());
    if (parsed is! Map) continue;
    final options = Map<String, Object?>.from(parsed);
    var changed = options.containsKey('plugins');
    options.remove('plugins');
    final analyzer = options['analyzer'];
    if (analyzer is Map && analyzer.containsKey('plugins')) {
      options['analyzer'] = Map<String, Object?>.from(analyzer)
        ..remove('plugins');
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
