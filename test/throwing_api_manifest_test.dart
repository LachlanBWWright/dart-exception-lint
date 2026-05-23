import 'package:dart_exception_lint/src/analysis/throw_summary.dart';
import 'package:dart_exception_lint/src/config/throwing_api_manifest.dart';
import 'package:test/test.dart';

void main() {
  test('parses manifest entries', () {
    final manifest = ThrowingApiManifest.parse('''
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
    final manifest = ThrowingApiManifest.parse('''
apis:
  - package: dio
    library: package:dio/dio.dart
    class: Dio
    method: get
    confidence: async_error
    async: true
''');

    expect(manifest.apis.single.confidence.wireName, 'async_error');
    expect(manifest.apis.single.isAsync, isTrue);
  });

  test('rejects invalid callable declarations', () {
    expect(
      () => ThrowingApiManifest.parse('''
apis:
  - package: dio
    library: package:dio/dio.dart
'''),
      throwsFormatException,
    );
  });
}
