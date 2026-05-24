import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'third-party deliberate strictness reports explicit throws only',
    () async {
      final result = await _analyzeFixture(
        strictness: '''
      strictness:
        internal: possible
        third_party: deliberate
''',
        mainSource: '''
import 'package:third_party_stub/third_party_stub.dart';

void f(dynamic target) {
  thirdPartyExplicit();
  thirdPartyParse('1');
  thirdPartyDynamic(target);
}
''',
      );

      expect(
        _countCode(result.stdout, 'catch_inferred_throwing_calls'),
        1,
        reason: result.stdout.toString(),
      );
      expect(result.stdout, contains('third_party_stub/thirdPartyExplicit'));
      expect(
        result.stdout,
        isNot(contains('third_party_stub/thirdPartyParse')),
      );
      expect(
        result.stdout,
        isNot(contains('third_party_stub/thirdPartyDynamic')),
      );
      expect(_countCode(result.stdout, 'catch_unknown_dynamic_calls'), 0);
    },
  );

  test(
    'third-party possible strictness includes input-dependent APIs',
    () async {
      final result = await _analyzeFixture(
        strictness: '''
      strictness:
        internal: possible
        third_party: possible
''',
        mainSource: '''
import 'package:third_party_stub/third_party_stub.dart';

void f(dynamic target) {
  thirdPartyExplicit();
  thirdPartyParse('1');
  thirdPartyDynamic(target);
}
''',
      );

      expect(
        _countCode(result.stdout, 'catch_inferred_throwing_calls'),
        2,
        reason: result.stdout.toString(),
      );
      expect(result.stdout, contains('third_party_stub/thirdPartyExplicit'));
      expect(result.stdout, contains('third_party_stub/thirdPartyParse'));
      expect(
        result.stdout,
        isNot(contains('third_party_stub/thirdPartyDynamic')),
      );
      expect(_countCode(result.stdout, 'catch_unknown_dynamic_calls'), 0);
    },
  );

  test(
    'third-party unknown strictness includes unresolved boundaries',
    () async {
      final result = await _analyzeFixture(
        strictness: '''
      strictness:
        internal: possible
        third_party: unknown
''',
        mainSource: '''
import 'package:third_party_stub/third_party_stub.dart';

void f(dynamic target) {
  thirdPartyDynamic(target);
}
''',
      );

      expect(
        _countCode(result.stdout, 'catch_unknown_dynamic_calls'),
        1,
        reason: result.stdout.toString(),
      );
      expect(result.stdout, contains('third_party_stub/thirdPartyDynamic'));
    },
  );
}

Future<ProcessResult> _analyzeFixture({
  required String strictness,
  required String mainSource,
}) async {
  final tempDir = await Directory.systemTemp.createTemp(
    'dart_exception_lint_strictness_',
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
      catch_inferred_throwing_calls: true
      catch_unknown_dynamic_calls: true
    exception_analysis:
$strictness
''');

    await _writeFile(p.join(tempDir.path, 'third_party_stub/pubspec.yaml'), '''
name: third_party_stub
publish_to: none

environment:
  sdk: ^3.10.0
''');

    await _writeFile(
      p.join(tempDir.path, 'third_party_stub/lib/third_party_stub.dart'),
      '''
void thirdPartyExplicit() {
  throw Exception('boom');
}

int thirdPartyParse(String value) {
  return int.parse(value);
}

void thirdPartyDynamic(dynamic target) {
  try {
    target.call();
  } catch (_) {}
}
''',
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
