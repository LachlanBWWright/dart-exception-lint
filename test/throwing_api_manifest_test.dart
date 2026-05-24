import 'dart:io';

import 'package:dart_exception_lint/src/analysis/throw_summary.dart';
import 'package:dart_exception_lint/src/config/config_failures.dart';
import 'package:dart_exception_lint/src/config/throwing_api_manifest.dart';
import 'package:dart_exception_lint/src/result.dart';
import 'package:test/test.dart';

void main() {
  test('parses manifest entries', () {
    final result = ThrowingApiManifest.parseResult('''
apis:
  - package: dio
    library: package:dio/dio.dart
    class: Dio
    method: get
    static: false
    subtypes: true
    exception_types:
      - DioException
''');
    expect(result, isA<Ok<ThrowingApiManifest, ManifestFailure>>());
    final manifest = result.valueOrNull!;

    expect(manifest.apis, hasLength(1));
    expect(manifest.apis.single.packageName, 'dio');
    expect(manifest.apis.single.libraryUri, 'package:dio/dio.dart');
    expect(manifest.apis.single.className, 'Dio');
    expect(manifest.apis.single.methodName, 'get');
    expect(manifest.apis.single.isStatic, isFalse);
    expect(manifest.apis.single.appliesToSubtypes, isTrue);
    expect(manifest.apis.single.confidence.wireName, 'possible_throw');
    expect(manifest.apis.single.isAsync, isFalse);
    expect(manifest.apis.single.exceptionTypes, ['DioException']);
  });

  test('parses manifest confidence and async metadata', () {
    final result = ThrowingApiManifest.parseResult('''
apis:
  - package: dio
    library: package:dio/dio.dart
    class: Dio
    method: get
    confidence: async_error
    async: true
''');
    expect(result, isA<Ok<ThrowingApiManifest, ManifestFailure>>());
    final manifest = result.valueOrNull!;

    expect(manifest.apis.single.confidence.wireName, 'async_error');
    expect(manifest.apis.single.isAsync, isTrue);
  });

  test('returns error for invalid callable declarations', () {
    final result = ThrowingApiManifest.parseResult('''
apis:
  - package: dio
    library: package:dio/dio.dart
''');
    expect(result, isA<Err<ThrowingApiManifest, ManifestFailure>>());
  });

  test('returns error when manifest root is not a YAML map', () {
    final result = ThrowingApiManifest.parseResult('- not-a-map');
    expect(result, isA<Err<ThrowingApiManifest, ManifestFailure>>());
  });

  test('returns error when apis is not a list', () {
    final result = ThrowingApiManifest.parseResult('''
apis:
  package: dio
''');
    expect(result, isA<Err<ThrowingApiManifest, ManifestFailure>>());
  });

  test('returns error for invalid confidence wire value', () {
    final result = ThrowingApiManifest.parseResult('''
apis:
  - package: dio
    library: package:dio/dio.dart
    class: Dio
    method: get
    confidence: not_supported
''');
    expect(result, isA<Err<ThrowingApiManifest, ManifestFailure>>());
    expect(result.errorOrNull, isA<ManifestWireParseFailure>());
  });

  test('returns error for non-string exception type entries', () {
    final result = ThrowingApiManifest.parseResult('''
apis:
  - package: dio
    library: package:dio/dio.dart
    class: Dio
    method: get
    exception_types:
      - DioException
      - 42
''');
    expect(result, isA<Err<ThrowingApiManifest, ManifestFailure>>());
  });

  test('returns error for missing required package field', () {
    final result = ThrowingApiManifest.parseResult('''
apis:
  - library: package:dio/dio.dart
    class: Dio
    method: get
''');
    expect(result, isA<Err<ThrowingApiManifest, ManifestFailure>>());
  });

  test('converts manifest file read errors to Err', () {
    final tempRoot = Directory.systemTemp.createTempSync(
      'dart_exception_lint_manifest_',
    );
    addTearDown(() => tempRoot.deleteSync(recursive: true));

    final manifestDir = Directory(
      '${tempRoot.path}/${ThrowingApiManifest.defaultRelativePath}',
    );
    manifestDir.createSync(recursive: true);

    final result = ThrowingApiManifest.loadResult(packageRoot: tempRoot.path);
    expect(result, isA<Err<ThrowingApiManifest, ManifestFailure>>());
    expect(result.errorOrNull, isA<ManifestFileReadFailure>());
  });
}
