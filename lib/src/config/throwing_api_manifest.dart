import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../analysis/throw_summary.dart';

class ThrowingApiManifest {
  static const defaultRelativePath =
      'tool/dart_exception_lint/throwing_apis.yaml';

  const ThrowingApiManifest(this.apis);

  final List<ThrowingApiSpecification> apis;

  static ThrowingApiManifest empty() => const ThrowingApiManifest([]);

  static ThrowingApiManifest load({
    String? packageRoot,
    String? currentFilePath,
  }) {
    final manifestPath = _findManifestPath(
      packageRoot: packageRoot,
      currentFilePath: currentFilePath,
    );
    if (manifestPath == null) {
      return empty();
    }

    final manifestFile = File(manifestPath);
    return parse(
      manifestFile.readAsStringSync(),
      sourcePath: manifestFile.path,
    );
  }

  static String? _findManifestPath({
    String? packageRoot,
    String? currentFilePath,
  }) {
    if (packageRoot != null) {
      final manifestPath = p.join(packageRoot, defaultRelativePath);
      if (File(manifestPath).existsSync()) {
        return manifestPath;
      }
    }

    if (currentFilePath == null) {
      return null;
    }

    var searchDirectory = p.dirname(currentFilePath);
    while (true) {
      final manifestPath = p.join(searchDirectory, defaultRelativePath);
      if (File(manifestPath).existsSync()) {
        return manifestPath;
      }

      final parentDirectory = p.dirname(searchDirectory);
      if (parentDirectory == searchDirectory) {
        return null;
      }
      searchDirectory = parentDirectory;
    }
  }

  static ThrowingApiManifest parse(String input, {String? sourcePath}) {
    final document = loadYaml(input);
    if (document is! YamlMap) {
      throw FormatException(
        'The throwing API manifest must be a YAML map.',
        input,
      );
    }

    final rawApis = document['apis'];
    if (rawApis == null) {
      return empty();
    }
    if (rawApis is! YamlList) {
      throw FormatException(
        'The "apis" entry in the throwing API manifest must be a YAML list.',
        sourcePath ?? input,
      );
    }

    return ThrowingApiManifest([
      for (final rawApi in rawApis)
        ThrowingApiSpecification.fromYaml(
          rawApi,
          sourcePath: sourcePath ?? defaultRelativePath,
        ),
    ]);
  }
}

class ThrowingApiSpecification {
  ThrowingApiSpecification({
    required this.packageName,
    required this.libraryUri,
    this.className,
    this.methodName,
    this.constructorName,
    this.functionName,
    this.isStatic,
    this.appliesToSubtypes = false,
    this.confidence = ThrowConfidence.possibleThrow,
    this.isAsync = false,
    List<String> exceptionTypes = const [],
  }) : exceptionTypes = List.unmodifiable(exceptionTypes);

  final String packageName;
  final String libraryUri;
  final String? className;
  final String? methodName;
  final String? constructorName;
  final String? functionName;
  final bool? isStatic;
  final bool appliesToSubtypes;
  final ThrowConfidence confidence;
  final bool isAsync;
  final List<String> exceptionTypes;

  factory ThrowingApiSpecification.fromYaml(
    Object? raw, {
    required String sourcePath,
  }) {
    if (raw is! YamlMap) {
      throw FormatException(
        'Each manifest entry in $sourcePath must be a YAML map.',
      );
    }

    final packageName = _readRequiredString(raw, 'package', sourcePath);
    final libraryUri = _readRequiredString(raw, 'library', sourcePath);
    final className = _readOptionalString(raw, 'class', sourcePath);
    final methodName = _readOptionalString(raw, 'method', sourcePath);
    final constructorName = _readOptionalString(raw, 'constructor', sourcePath);
    final functionName = _readOptionalString(raw, 'function', sourcePath);
    final isStatic = _readOptionalBool(raw, 'static', sourcePath);
    final appliesToSubtypes =
        _readOptionalBool(raw, 'subtypes', sourcePath) ?? false;
    final confidence = _readOptionalConfidence(raw, 'confidence', sourcePath);
    final isAsync = _readOptionalBool(raw, 'async', sourcePath) ?? false;
    final exceptionTypes = _readOptionalStringList(
      raw,
      'exception_types',
      sourcePath,
    );

    final callableFields = [?methodName, ?constructorName, ?functionName];
    if (callableFields.length != 1) {
      throw FormatException(
        'Each manifest entry in $sourcePath must declare exactly one of '
        '"function", "method", or "constructor".',
      );
    }

    if (functionName != null && className != null) {
      throw FormatException(
        'Top-level function entries in $sourcePath cannot declare a class.',
      );
    }

    if (constructorName != null && className == null) {
      throw FormatException(
        'Constructor entries in $sourcePath must declare a class.',
      );
    }

    return ThrowingApiSpecification(
      packageName: packageName,
      libraryUri: libraryUri,
      className: className,
      methodName: methodName,
      constructorName: constructorName,
      functionName: functionName,
      isStatic: isStatic,
      appliesToSubtypes: appliesToSubtypes,
      confidence:
          confidence ??
          (isAsync
              ? ThrowConfidence.asyncError
              : ThrowConfidence.possibleThrow),
      isAsync: isAsync || confidence == ThrowConfidence.asyncError,
      exceptionTypes: exceptionTypes,
    );
  }

  String get displayName {
    if (functionName case final functionName?) {
      return '$packageName/$functionName';
    }

    final className = this.className ?? '<unknown>';
    if (methodName case final methodName?) {
      return '$packageName/$className.$methodName';
    }

    final constructorName = this.constructorName;
    if (constructorName == null || constructorName.isEmpty) {
      return '$packageName/$className()';
    }
    return '$packageName/$className.$constructorName';
  }

  static bool? _readOptionalBool(YamlMap map, String key, String sourcePath) {
    final value = map[key];
    if (value == null) {
      return null;
    }
    if (value is! bool) {
      throw FormatException(
        'The "$key" value in $sourcePath must be a boolean.',
      );
    }
    return value;
  }

  static List<String> _readOptionalStringList(
    YamlMap map,
    String key,
    String sourcePath,
  ) {
    final value = map[key];
    if (value == null) {
      return const [];
    }
    if (value is! YamlList) {
      throw FormatException(
        'The "$key" value in $sourcePath must be a list of strings.',
      );
    }

    return [
      for (final entry in value)
        if (entry is String)
          entry
        else
          throw FormatException(
            'The "$key" value in $sourcePath must be a list of strings.',
          ),
    ];
  }

  static ThrowConfidence? _readOptionalConfidence(
    YamlMap map,
    String key,
    String sourcePath,
  ) {
    final value = _readOptionalString(map, key, sourcePath);
    if (value == null) {
      return null;
    }

    try {
      return ThrowConfidenceExtension.parse(value);
    } on FormatException {
      throw FormatException(
        'The "$key" value in $sourcePath must be one of '
        'definite_throw, possible_throw, async_error, unknown, '
        'or no_obvious_throw.',
      );
    }
  }

  static String _readRequiredString(
    YamlMap map,
    String key,
    String sourcePath,
  ) {
    final value = _readOptionalString(map, key, sourcePath);
    if (value == null || value.isEmpty) {
      throw FormatException('The "$key" value in $sourcePath is required.');
    }
    return value;
  }

  static String? _readOptionalString(
    YamlMap map,
    String key,
    String sourcePath,
  ) {
    final value = map[key];
    if (value == null) {
      return null;
    }
    if (value is! String) {
      throw FormatException(
        'The "$key" value in $sourcePath must be a string.',
      );
    }
    return value;
  }
}
