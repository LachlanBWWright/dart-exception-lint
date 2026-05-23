import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('reports uncaught configured calls across invocation shapes', () async {
    final result = await _analyzeFixture({
      'lib/main.dart': '''
import 'package:third_party_stub/third_party_stub.dart';
import 'package:third_party_stub/third_party_stub.dart' as throwing;

void f(DangerousClient client) {
  dangerousTopLevel();
  DangerousClient.load();
  client.fetch();
  throwing.dangerousTopLevel();
}
''',
    });

    expect(_countCode(result.stdout, 'catch_throwing_third_party_calls'), 4);
    expect(result.stdout, contains('third_party_stub/dangerousTopLevel'));
    expect(result.stdout, contains('third_party_stub/DangerousClient.load'));
    expect(result.stdout, contains('third_party_stub/DangerousClient.fetch'));
  });

  test('distinguishes protected and unprotected configured calls', () async {
    final result = await _analyzeFixture({
      'lib/main.dart': '''
import 'package:third_party_stub/third_party_stub.dart';

void f(DangerousClient client) {
  try {
    dangerousTopLevel();
    client.fetch();
  } catch (_) {}

  try {
    DangerousClient.load();
  } finally {}

  try {
    dangerousTopLevel();
  } catch (_) {
    client.fetch();
  }
}
''',
    });

    expect(_countCode(result.stdout, 'catch_throwing_third_party_calls'), 2);
    expect(result.stdout, contains('third_party_stub/DangerousClient.load'));
    expect(result.stdout, contains('third_party_stub/DangerousClient.fetch'));
  });

  test('reports configured constructor calls', () async {
    final result = await _analyzeFixture({
      'lib/main.dart': '''
import 'package:third_party_stub/third_party_stub.dart';

void f() {
  DangerousClient.named();
}
''',
    });

    expect(_countCode(result.stdout, 'catch_throwing_third_party_calls'), 1);
    expect(result.stdout, contains('DangerousClient.named'));
  });
}

Future<ProcessResult> _analyzeFixture(Map<String, String> files) async {
  final tempDir = await Directory.systemTemp.createTemp(
    'dart_exception_lint_fixture_',
  );

  try {
    final repoRoot = Directory.current.path;

    await _writeFile(p.join(tempDir.path, 'pubspec.yaml'), '''
name: lint_fixture
publish_to: none

environment:
  sdk: ^3.10.0

dependencies:
  third_party_stub:
    path: third_party_stub
''');

    await _writeFile(p.join(tempDir.path, 'analysis_options.yaml'), '''
plugins:
  dart_exception_lint:
    path: ${_yamlPath(repoRoot)}
    diagnostics:
      no_null_assertion: true
      no_manual_throw: true
      catch_throwing_third_party_calls: true
''');

    await _writeFile(
      p.join(tempDir.path, 'tool/dart_exception_lint/throwing_apis.yaml'),
      '''
apis:
  - package: third_party_stub
    library: package:third_party_stub/third_party_stub.dart
    function: dangerousTopLevel
  - package: third_party_stub
    library: package:third_party_stub/third_party_stub.dart
    class: DangerousClient
    method: fetch
  - package: third_party_stub
    library: package:third_party_stub/third_party_stub.dart
    class: DangerousClient
    method: load
    static: true
  - package: third_party_stub
    library: package:third_party_stub/third_party_stub.dart
    class: DangerousClient
    constructor: named
''',
    );

    await _writeFile(p.join(tempDir.path, 'third_party_stub/pubspec.yaml'), '''
name: third_party_stub
publish_to: none

environment:
  sdk: ^3.10.0
''');

    await _writeFile(
      p.join(tempDir.path, 'third_party_stub/lib/third_party_stub.dart'),
      '''
class DangerousClient {
  DangerousClient();
  DangerousClient.named();

  static String load() => 'ok';

  String fetch() => 'ok';
}

String dangerousTopLevel() => 'ok';
''',
    );

    for (final entry in files.entries) {
      await _writeFile(p.join(tempDir.path, entry.key), entry.value);
    }

    final pubGet = await Process.run(Platform.resolvedExecutable, [
      'pub',
      'get',
    ], workingDirectory: tempDir.path);
    expect(pubGet.exitCode, 0, reason: pubGet.stderr.toString());

    return await Process.run(Platform.resolvedExecutable, [
      'analyze',
    ], workingDirectory: tempDir.path);
  } finally {
    await tempDir.delete(recursive: true);
  }
}

Future<void> _writeFile(String path, String content) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsString(content);
}

int _countCode(String output, String code) {
  return RegExp('\\b$code\\b').allMatches(output).length;
}

String _yamlPath(String path) {
  return path.replaceAll(r'\', r'/');
}
