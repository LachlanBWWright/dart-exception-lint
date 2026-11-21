import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/corpus/isolate_workspace_plugins.dart' as workspace_options;

void main() {
  test(
    'workspace isolation preserves settings and removes plugin activation',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'corpus-options-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/analysis_options.yaml');
      await file.writeAsString('''
include: relative_options.yaml
analyzer:
  exclude:
    - generated/**
  plugins: [legacy]
plugins:
  upstream:
    path: packages/upstream
linter:
  rules:
    avoid_print: true
''');

      workspace_options.main([file.path]);
      final stripped = await file.readAsString();
      expect(jsonDecode(stripped), {
        'include': 'relative_options.yaml',
        'analyzer': {
          'exclude': ['generated/**'],
        },
        'linter': {
          'rules': {'avoid_print': true},
        },
      });
      workspace_options.main([file.path]);
      expect(await file.readAsString(), stripped);
    },
  );
}
