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

      final packageOptions = File('${directory.path}/package_options.yaml');
      await packageOptions.writeAsString('''
plugins:
  dart_exception_lint:
    path: /fixture/plugin
''');
      workspace_options.main([
        '--install-from',
        packageOptions.path,
        file.path,
      ]);
      expect(jsonDecode(await file.readAsString()), {
        ...jsonDecode(stripped) as Map<String, Object?>,
        'plugins': {
          'dart_exception_lint': {'path': '/fixture/plugin'},
        },
      });
    },
  );

  test('package activation extends existing analyzer exclusions', () async {
    final directory = await Directory.systemTemp.createTemp('corpus-package-');
    addTearDown(() => directory.delete(recursive: true));
    final options = File('${directory.path}/analysis_options.yaml');
    final overlay = File('${directory.path}/overlay.yaml');
    await options.writeAsString('''
include: development.yaml
analyzer:
  plugins: [old_plugin]
  exclude: [generated/**, example/**]
  errors:
    invalid_assignment: error
''');
    await overlay.writeAsString('''
analyzer:
  exclude: [example/**, nested/**]
plugins:
  dart_exception_lint:
    path: /fixture/plugin
''');
    workspace_options.main(['--configure-package', overlay.path, options.path]);
    expect(jsonDecode(await options.readAsString()), {
      'include': 'development.yaml',
      'analyzer': {
        'exclude': ['generated/**', 'example/**', 'nested/**'],
        'errors': {'invalid_assignment': 'error'},
      },
      'plugins': {
        'dart_exception_lint': {'path': '/fixture/plugin'},
      },
    });
  });

  if (!Platform.isWindows) {
    test(
      'package configuration leaves an options link target untouched',
      () async {
        final directory = await Directory.systemTemp.createTemp('corpus-link-');
        addTearDown(() => directory.delete(recursive: true));
        final target = File('${directory.path}/shared.yaml');
        const source = 'include: development.yaml\n';
        await target.writeAsString(source);
        final link = await Link(
          '${directory.path}/analysis_options.yaml',
        ).create(target.path);
        final overlay = File('${directory.path}/overlay.yaml');
        await overlay.writeAsString('plugins: {dart_exception_lint: {}}\n');

        workspace_options.main([
          '--configure-package',
          overlay.path,
          link.path,
        ]);
        expect(await target.readAsString(), source);
        expect(jsonDecode(await File(link.path).readAsString()), {
          'include': 'development.yaml',
          'plugins': {'dart_exception_lint': {}},
        });
      },
    );
  }
}
