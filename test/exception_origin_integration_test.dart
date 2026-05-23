import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('infers throws from third-party helper bodies', () async {
    final result = await _analyzeFixture(
      dependencySource: '''
import 'dart:convert';

class DangerousClient {
  String fetch() => _decode('bad json');
}

String _decode(String input) => jsonDecode(input) as String;
''',
      mainSource: '''
import 'package:third_party_stub/third_party_stub.dart';

void f() {
  DangerousClient().fetch();
}
''',
    );

    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(result.stdout, contains('lib/main.dart:4:21'));
    expect(result.stdout, contains('catch_inferred_throwing_calls'));
    expect(result.stdout, contains('third_party_stub/DangerousClient.fetch'));
  });

  test('infers awaited async errors from third-party bodies', () async {
    final result = await _analyzeFixture(
      dependencySource: '''
class DangerousClient {
  Future<String> fetch() => Future.error(StateError('boom'));
}
''',
      mainSource: '''
import 'package:third_party_stub/third_party_stub.dart';

Future<void> f() async {
  await DangerousClient().fetch();
}
''',
    );

    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(result.stdout, contains('lib/main.dart:4:3'));
    expect(result.stdout, contains('catch_async_error_sources'));
    expect(result.stdout, contains('third_party_stub/DangerousClient.fetch'));
  });

  test('keeps manifest-backed reporting alongside inferred rules', () async {
    final result = await _analyzeFixture(
      dependencySource: '''
class DangerousClient {
  DangerousClient.named();
}
''',
      mainSource: '''
import 'package:third_party_stub/third_party_stub.dart';

void f() {
  DangerousClient.named();
}
''',
      manifest: '''
apis:
  - package: third_party_stub
    library: package:third_party_stub/third_party_stub.dart
    class: DangerousClient
    constructor: named
''',
    );

    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(_countCode(result.stdout, 'catch_throwing_third_party_calls'), 1);
  });
}

Future<ProcessResult> _analyzeFixture({
  required String dependencySource,
  required String mainSource,
  String? manifest,
}) async {
  final tempDir = await Directory.systemTemp.createTemp(
    'dart_exception_lint_origin_fixture_',
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
      catch_throwing_third_party_calls: true
      catch_runtime_throw_sources: true
      catch_async_error_sources: true
      catch_inferred_throwing_calls: true
      catch_unknown_dynamic_calls: true
''');

    if (manifest != null) {
      await _writeFile(
        p.join(tempDir.path, 'tool/dart_exception_lint/throwing_apis.yaml'),
        manifest,
      );
    }

    await _writeFile(p.join(tempDir.path, 'third_party_stub/pubspec.yaml'), '''
name: third_party_stub
publish_to: none

environment:
  sdk: ^3.10.0
''');

    await _writeFile(
      p.join(tempDir.path, 'third_party_stub/lib/third_party_stub.dart'),
      dependencySource,
    );
    await _writeFile(p.join(tempDir.path, 'lib/main.dart'), mainSource);

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
