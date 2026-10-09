import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../analysis/throw_summary.dart';
import '../analysis/resolved_callable.dart';
import '../engine/exception_effect.dart';
import '../result.dart';
import 'config_failures.dart';

class ThrowingApiManifest {
  static const defaultRelativePath =
      'tool/dart_exception_lint/throwing_apis.yaml';

  const ThrowingApiManifest(this.apis);

  final List<ThrowingApiSpecification> apis;

  String get cacheKey => apis
      .map(
        (api) => [
          api.packageName,
          api.libraryUri,
          api.className,
          api.methodName,
          api.constructorName,
          api.functionName,
          api.getterName,
          api.setterName,
          api.operatorName,
          api.effects.map((effect) => effect.cacheKey).join(','),
          api.isStatic,
          api.appliesToSubtypes,
          api.confidence,
          api.isAsync,
          api.exceptionTypes.join(','),
        ].join('|'),
      )
      .join('\n');

  static ThrowingApiManifest empty() => const ThrowingApiManifest([]);

  static ThrowingApiManifest load({
    String? packageRoot,
    String? currentFilePath,
  }) {
    return loadResult(
      packageRoot: packageRoot,
      currentFilePath: currentFilePath,
    ).unwrapOr(empty());
  }

  static Result<ThrowingApiManifest, ManifestFailure> loadResult({
    String? packageRoot,
    String? currentFilePath,
  }) {
    final manifestPath = _findManifestPath(
      packageRoot: packageRoot,
      currentFilePath: currentFilePath,
    );
    if (manifestPath == null) {
      return Ok(empty());
    }

    final manifestFile = File(manifestPath);
    try {
      return parseResult(
        manifestFile.readAsStringSync(),
        sourcePath: manifestFile.path,
      );
    } on FileSystemException catch (error) {
      return Err(
        ManifestFileReadFailure(
          path: manifestFile.path,
          message: error.message,
        ),
      );
    }
  }

  static String? _findManifestPath({
    String? packageRoot,
    String? currentFilePath,
  }) {
    if (packageRoot != null) {
      final manifestPath = p.join(packageRoot, defaultRelativePath);
      return _pathExists(manifestPath) ? manifestPath : null;
    }

    if (currentFilePath == null) {
      return null;
    }

    var searchDirectory = p.dirname(currentFilePath);
    while (true) {
      final manifestPath = p.join(searchDirectory, defaultRelativePath);
      if (_pathExists(manifestPath)) {
        return manifestPath;
      }

      final parentDirectory = p.dirname(searchDirectory);
      if (parentDirectory == searchDirectory) {
        return null;
      }
      searchDirectory = parentDirectory;
    }
  }

  static bool _pathExists(String path) {
    return FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;
  }

  static ThrowingApiManifest parse(String input, {String? sourcePath}) {
    return parseResult(input, sourcePath: sourcePath).unwrapOr(empty());
  }

  static Result<ThrowingApiManifest, ManifestFailure> parseResult(
    String input, {
    String? sourcePath,
  }) {
    final Object? document;
    try {
      document = loadYaml(input);
    } on YamlException catch (error) {
      return Err(
        ManifestYamlParseFailure(
          message: error.message,
          sourcePath: sourcePath ?? defaultRelativePath,
        ),
      );
    }

    if (document is! YamlMap) {
      return Err(
        ManifestStructureFailure(
          message: 'The throwing API manifest must be a YAML map.',
          sourcePath: sourcePath ?? defaultRelativePath,
        ),
      );
    }

    for (final key in document.keys) {
      if (key != 'apis') {
        return Err(
          ManifestStructureFailure(
            message: 'Unknown manifest key: $key',
            sourcePath: sourcePath ?? defaultRelativePath,
          ),
        );
      }
    }
    final rawApis = document['apis'];
    if (rawApis == null) {
      return Ok(empty());
    }
    if (rawApis is! YamlList) {
      return Err(
        ManifestStructureFailure(
          message:
              'The "apis" entry in the throwing API manifest must be a YAML list.',
          sourcePath: sourcePath ?? defaultRelativePath,
        ),
      );
    }

    final specifications = <ThrowingApiSpecification>[];
    final entrySourcePath = sourcePath ?? defaultRelativePath;
    for (final rawApi in rawApis) {
      final parsed = ThrowingApiSpecification.fromYamlResult(
        rawApi,
        sourcePath: entrySourcePath,
      );
      if (parsed case Err(error: final failure)) {
        return Err(failure);
      }
      specifications.add(parsed.valueOrNull!);
    }

    final seen = <String>{};
    for (final specification in specifications) {
      if (!seen.add(specification.identityKey)) {
        return Err(
          ManifestStructureFailure(
            message:
                'The throwing API manifest contains a duplicate entry for '
                '${specification.identityKey}.',
            sourcePath: entrySourcePath,
          ),
        );
      }
    }

    return Ok(ThrowingApiManifest(specifications));
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
    this.getterName,
    this.setterName,
    this.operatorName,
    this.effects = const [],
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
  final String? getterName;
  final String? setterName;
  final String? operatorName;
  final List<ManifestExceptionEffect> effects;
  final bool? isStatic;
  final bool appliesToSubtypes;
  final ThrowConfidence confidence;
  final bool isAsync;
  final List<String> exceptionTypes;

  String get identityKey => [
    packageName,
    libraryUri,
    className ?? '',
    methodName ?? '',
    constructorName ?? '',
    functionName ?? '',
    getterName ?? '',
    setterName ?? '',
    operatorName ?? '',
    isStatic?.toString() ?? '',
    appliesToSubtypes.toString(),
  ].join('|');

  static Result<ThrowingApiSpecification, ManifestFailure> fromYamlResult(
    Object? raw, {
    required String sourcePath,
  }) {
    if (raw is! YamlMap) {
      return Err(
        ManifestStructureFailure(
          message: 'Each manifest entry in $sourcePath must be a YAML map.',
          sourcePath: sourcePath,
        ),
      );
    }

    const knownKeys = {
      'package',
      'library',
      'class',
      'method',
      'constructor',
      'function',
      'getter',
      'setter',
      'operator',
      'static',
      'subtypes',
      'confidence',
      'async',
      'exception_types',
      'effects',
    };
    for (final key in raw.keys) {
      if (!knownKeys.contains(key)) {
        return Err(
          ManifestStructureFailure(
            message: 'Unknown API manifest key: $key',
            sourcePath: sourcePath,
          ),
        );
      }
    }
    final names = <String, String?>{};
    for (final key in ['getter', 'setter', 'operator']) {
      final result = _readOptionalString(raw, key, sourcePath);
      if (result case Err(error: final failure)) return Err(failure);
      names[key] = result.valueOrNull;
    }
    final effects = <ManifestExceptionEffect>[];
    if (raw.containsKey('effects')) {
      final rawEffects = raw['effects'];
      if (rawEffects is! YamlList || rawEffects.isEmpty) {
        return Err(
          ManifestStructureFailure(
            message: 'effects must be a nonempty list',
            sourcePath: sourcePath,
          ),
        );
      }
      if (raw.containsKey('confidence') ||
          raw.containsKey('async') ||
          raw.containsKey('exception_types')) {
        return Err(
          ManifestStructureFailure(
            message: 'effects conflicts with legacy effect fields',
            sourcePath: sourcePath,
          ),
        );
      }
      for (final entry in rawEffects) {
        final result = ManifestExceptionEffect.parse(entry, sourcePath);
        if (result case Err(error: final failure)) return Err(failure);
        effects.add(result.valueOrNull!);
      }
    }

    final packageNameResult = _readRequiredString(raw, 'package', sourcePath);
    if (packageNameResult case Err(error: final failure)) {
      return Err(failure);
    }
    final packageName = packageNameResult.valueOrNull!;

    final libraryUriResult = _readRequiredString(raw, 'library', sourcePath);
    if (libraryUriResult case Err(error: final failure)) {
      return Err(failure);
    }
    final libraryUri = libraryUriResult.valueOrNull!;

    final classNameResult = _readOptionalString(raw, 'class', sourcePath);
    if (classNameResult case Err(error: final failure)) {
      return Err(failure);
    }
    final className = classNameResult.valueOrNull;

    final methodNameResult = _readOptionalString(raw, 'method', sourcePath);
    if (methodNameResult case Err(error: final failure)) {
      return Err(failure);
    }
    final methodName = methodNameResult.valueOrNull;

    final constructorNameResult = _readOptionalString(
      raw,
      'constructor',
      sourcePath,
    );
    if (constructorNameResult case Err(error: final failure)) {
      return Err(failure);
    }
    final constructorName = constructorNameResult.valueOrNull;

    final functionNameResult = _readOptionalString(raw, 'function', sourcePath);
    if (functionNameResult case Err(error: final failure)) {
      return Err(failure);
    }
    final functionName = functionNameResult.valueOrNull;

    final isStaticResult = _readOptionalBool(raw, 'static', sourcePath);
    if (isStaticResult case Err(error: final failure)) {
      return Err(failure);
    }
    final isStatic = isStaticResult.valueOrNull;

    final appliesToSubtypesResult = _readOptionalBool(
      raw,
      'subtypes',
      sourcePath,
    );
    if (appliesToSubtypesResult case Err(error: final failure)) {
      return Err(failure);
    }
    final appliesToSubtypes = appliesToSubtypesResult.valueOrNull ?? false;

    final confidenceResult = _readOptionalConfidence(
      raw,
      'confidence',
      sourcePath,
    );
    if (confidenceResult case Err(error: final failure)) {
      return Err(failure);
    }
    final confidence = confidenceResult.valueOrNull;

    final isAsyncResult = _readOptionalBool(raw, 'async', sourcePath);
    if (isAsyncResult case Err(error: final failure)) {
      return Err(failure);
    }
    final isAsync = isAsyncResult.valueOrNull ?? false;

    final exceptionTypesResult = _readOptionalStringList(
      raw,
      'exception_types',
      sourcePath,
    );
    if (exceptionTypesResult case Err(error: final failure)) {
      return Err(failure);
    }
    final exceptionTypes = exceptionTypesResult.valueOrNull!;

    final callableFields = [
      ?methodName,
      ?constructorName,
      ?functionName,
      ...names.values.whereType<String>(),
    ];
    if (callableFields.length != 1) {
      return Err(
        ManifestStructureFailure(
          message:
              'Each manifest entry in $sourcePath must declare exactly one of '
              'function, method, constructor, getter, setter, or operator.',
          sourcePath: sourcePath,
        ),
      );
    }

    if (functionName != null && className != null) {
      return Err(
        ManifestStructureFailure(
          message:
              'Top-level function entries in $sourcePath cannot declare a class.',
          sourcePath: sourcePath,
        ),
      );
    }

    if (constructorName != null && className == null) {
      return Err(
        ManifestStructureFailure(
          message: 'Constructor entries in $sourcePath must declare a class.',
          sourcePath: sourcePath,
        ),
      );
    }

    return Ok(
      ThrowingApiSpecification(
        packageName: packageName,
        libraryUri: libraryUri,
        className: className,
        methodName: methodName,
        constructorName: constructorName,
        functionName: functionName,
        getterName: names['getter'],
        setterName: names['setter'],
        operatorName: names['operator'],
        effects: List.unmodifiable(effects),
        isStatic: isStatic,
        appliesToSubtypes: appliesToSubtypes,
        confidence:
            confidence ??
            (isAsync
                ? ThrowConfidence.asyncError
                : ThrowConfidence.possibleThrow),
        isAsync: isAsync || confidence == ThrowConfidence.asyncError,
        exceptionTypes: exceptionTypes,
      ),
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

    final member = getterName ?? setterName ?? operatorName;
    if (member != null) return '$packageName/$className.$member';
    final constructorName = this.constructorName;
    if (constructorName == null || constructorName.isEmpty) {
      return '$packageName/$className()';
    }
    return '$packageName/$className.$constructorName';
  }

  Iterable<ThrowSource> get sources sync* {
    if (effects.isEmpty) {
      yield ThrowSource(
        kind: ThrowSourceKind.manifestOverride,
        confidence: confidence,
        displayName: displayName,
        isAsync: isAsync,
        exceptionTypes: exceptionTypes,
      );
    } else {
      for (final effect in effects) {
        yield effect.toSource(displayName);
      }
    }
  }

  int matchScore(ResolvedCallable callable) {
    if (packageName != callable.packageName) return -1;
    if (functionName != null) {
      return libraryUri == callable.libraryUri &&
              callable.kind == CallableKind.topLevelFunction &&
              callable.callableName == functionName
          ? 10
          : -1;
    }
    final sameOwner =
        libraryUri == callable.libraryUri &&
        className == callable.enclosingClassName;
    final subtypeOwner =
        appliesToSubtypes &&
        callable.supertypeKeys.contains('$libraryUri::$className');
    if (!sameOwner && !subtypeOwner) return -1;
    if (isStatic != null && isStatic != callable.isStatic) return -1;
    if (constructorName != null) {
      return callable.kind == CallableKind.constructor &&
              callable.constructorName == constructorName &&
              libraryUri == callable.libraryUri
          ? 30
          : -1;
    }
    if (getterName != null) {
      return callable.kind == CallableKind.getter &&
              callable.callableName == getterName
          ? 40
          : -1;
    }
    if (setterName != null) {
      return callable.kind == CallableKind.setter &&
              callable.callableName.replaceAll('=', '') == setterName
          ? 40
          : -1;
    }
    final name = methodName ?? operatorName;
    return (callable.kind == CallableKind.instanceMethod ||
                callable.kind == CallableKind.staticMethod) &&
            callable.callableName == name
        ? 40
        : -1;
  }

  static Result<bool?, ManifestFailure> _readOptionalBool(
    YamlMap map,
    String key,
    String sourcePath,
  ) {
    final value = map[key];
    if (value == null) {
      return const Ok(null);
    }
    if (value is! bool) {
      return Err(
        ManifestStructureFailure(
          message: 'The "$key" value in $sourcePath must be a boolean.',
          sourcePath: sourcePath,
        ),
      );
    }
    return Ok(value);
  }

  static Result<List<String>, ManifestFailure> _readOptionalStringList(
    YamlMap map,
    String key,
    String sourcePath,
  ) {
    final value = map[key];
    if (value == null) {
      return const Ok([]);
    }
    if (value is! YamlList) {
      return Err(
        ManifestStructureFailure(
          message: 'The "$key" value in $sourcePath must be a list of strings.',
          sourcePath: sourcePath,
        ),
      );
    }

    final strings = <String>[];
    for (final entry in value) {
      if (entry is! String) {
        return Err(
          ManifestStructureFailure(
            message:
                'The "$key" value in $sourcePath must be a list of strings.',
            sourcePath: sourcePath,
          ),
        );
      }
      strings.add(entry);
    }

    return Ok(strings);
  }

  static Result<ThrowConfidence?, ManifestFailure> _readOptionalConfidence(
    YamlMap map,
    String key,
    String sourcePath,
  ) {
    final valueResult = _readOptionalString(map, key, sourcePath);
    if (valueResult case Err(error: final failure)) {
      return Err(failure);
    }
    final value = valueResult.valueOrNull;
    if (value == null) {
      return const Ok(null);
    }

    final parsed = ThrowConfidenceExtension.tryParse(value);
    if (parsed case Err(error: final failure)) {
      return Err(
        ManifestWireParseFailure(
          key: key,
          cause: failure,
          entrySourcePath: sourcePath,
        ),
      );
    }
    return Ok(parsed.valueOrNull);
  }

  static Result<String, ManifestFailure> _readRequiredString(
    YamlMap map,
    String key,
    String sourcePath,
  ) {
    final valueResult = _readOptionalString(map, key, sourcePath);
    if (valueResult case Err(error: final failure)) {
      return Err(failure);
    }
    final value = valueResult.valueOrNull;
    if (value == null || value.isEmpty) {
      return Err(
        ManifestStructureFailure(
          message: 'The "$key" value in $sourcePath is required.',
          sourcePath: sourcePath,
        ),
      );
    }
    return Ok(value);
  }

  static Result<String?, ManifestFailure> _readOptionalString(
    YamlMap map,
    String key,
    String sourcePath,
  ) {
    final value = map[key];
    if (value == null) {
      return const Ok(null);
    }
    if (value is! String) {
      return Err(
        ManifestStructureFailure(
          message: 'The "$key" value in $sourcePath must be a string.',
          sourcePath: sourcePath,
        ),
      );
    }
    return Ok(value);
  }
}

final class ManifestExceptionEffect {
  const ManifestExceptionEffect(
    this.channel,
    this.certainty,
    this.exceptionTypes,
  );
  final ExceptionChannel channel;
  final ExceptionCertainty certainty;
  final List<String> exceptionTypes;
  String get cacheKey =>
      '${channel.name}|${certainty.name}|${exceptionTypes.join(',')}';

  ThrowSource toSource(String displayName) => ThrowSource(
    kind: ThrowSourceKind.manifestOverride,
    confidence: switch (certainty) {
      ExceptionCertainty.definite => ThrowConfidence.definiteThrow,
      ExceptionCertainty.possible => ThrowConfidence.possibleThrow,
      ExceptionCertainty.unknown => ThrowConfidence.unknown,
    },
    certainty: certainty,
    channel: channel,
    displayName: displayName,
    isAsync:
        channel == ExceptionChannel.future ||
        channel == ExceptionChannel.stream ||
        channel == ExceptionChannel.scheduled,
    timing: channel == ExceptionChannel.deferred ? ThrowTiming.deferred : null,
    exceptionTypes: exceptionTypes,
  );

  static Result<ManifestExceptionEffect, ManifestFailure> parse(
    Object? raw,
    String path,
  ) {
    ManifestFailure failure(String message) =>
        ManifestStructureFailure(message: message, sourcePath: path);
    if (raw is! YamlMap) return Err(failure('Each effect must be a map'));
    if (raw.keys.any(
      (key) => !const {'channel', 'certainty', 'exception_types'}.contains(key),
    )) {
      return Err(failure('Unknown exception effect key'));
    }
    final channel = ExceptionChannel.values
        .where((channel) => channel.name == raw['channel'])
        .firstOrNull;
    final certainty = ExceptionCertainty.values
        .where((certainty) => certainty.name == raw['certainty'])
        .firstOrNull;
    if (channel == null || certainty == null) {
      return Err(failure('Invalid effect channel or certainty'));
    }
    final types = ThrowingApiSpecification._readOptionalStringList(
      raw,
      'exception_types',
      path,
    );
    if (types case Err(error: final failure)) return Err(failure);
    return Ok(ManifestExceptionEffect(channel, certainty, types.valueOrNull!));
  }
}
