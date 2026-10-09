import 'dart:io';

import 'package:dart_exception_lint/src/analysis/throw_summary.dart';
import 'package:dart_exception_lint/src/config/config_failures.dart';
import 'package:dart_exception_lint/src/config/throwing_api_manifest.dart';
import 'package:dart_exception_lint/src/result.dart';
import 'package:dart_exception_lint/src/engine/exception_effect.dart';
import 'package:dart_exception_lint/src/analysis/resolved_callable.dart';
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

  test('supports SDK library entries', () {
    final result = ThrowingApiManifest.parseResult('''
apis:
  - package: dart
    library: dart:core
    class: RegExp
    constructor: ''
''');
    expect(result, isA<Ok<ThrowingApiManifest, ManifestFailure>>());
    expect(result.valueOrNull!.apis.single.packageName, 'dart');
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

  test('returns error for duplicate entries', () {
    final result = ThrowingApiManifest.parseResult('''
apis:
  - package: demo
    library: package:demo/demo.dart
    class: Client
    method: send
  - package: demo
    library: package:demo/demo.dart
    class: Client
    method: send
''');

    expect(result, isA<Err<ThrowingApiManifest, ManifestFailure>>());
    expect(result.errorOrNull?.message, contains('duplicate'));
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
  test('models accessor effects independently in multiple channels', () {
    final result = ThrowingApiManifest.parseResult('''
apis:
  - package: example
    library: package:example/api.dart
    class: C
    getter: pending
    effects:
      - channel: synchronous
        certainty: possible
        exception_types: [StateError]
      - channel: future
        certainty: unknown
''');
    expect(result.errorOrNull, isNull);
    final spec = result.valueOrNull!.apis.single;
    expect(spec.sources.map((source) => source.channel), [
      ExceptionChannel.synchronous,
      ExceptionChannel.future,
    ]);
    final summary = ThrowSummary.merge(
      'getter',
      spec.sources,
      dependencyElementKeys: const [],
      complete: true,
    );
    expect(summary.canThrowSynchronously, isTrue);
    expect(summary.canCompleteWithAsyncError, isTrue);
    expect(summary.hasUnknownEffects, isTrue);
  });

  test('same-named classes in different libraries do not match', () {
    final spec = ThrowingApiSpecification(
      packageName: 'example',
      libraryUri: 'package:example/a.dart',
      className: 'C',
      methodName: 'run',
    );
    final callable = ResolvedCallable(
      packageName: 'example',
      libraryUri: 'package:example/b.dart',
      callableName: 'run',
      kind: CallableKind.instanceMethod,
      isStatic: false,
      enclosingClassName: 'C',
      supertypeKeys: const {},
    );
    expect(spec.matchScore(callable), -1);
  });

  test('rejects unknown manifest keys and mixed effect encodings', () {
    for (final input in [
      'unknown: []',
      'apis:\n  - package: x\n    library: package:x/x.dart\n    function: f\n    typo: true',
      'apis:\n  - package: x\n    library: package:x/x.dart\n    function: f\n    async: true\n    effects:\n      - channel: future\n        certainty: possible',
    ]) {
      expect(ThrowingApiManifest.parseResult(input).errorOrNull, isNotNull);
    }
  });
}
