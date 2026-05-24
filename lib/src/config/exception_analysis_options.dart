import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../analysis/throw_summary.dart';
import '../result.dart';
import 'config_failures.dart';

final class ExceptionAnalysisOptions {
  const ExceptionAnalysisOptions({
    this.reportDefiniteThrow = true,
    this.reportPossibleThrow = true,
    this.reportAsyncError = true,
    this.reportUnknown = true,
    this.maxCallDepth = 4,
    this.analyzeThirdPartySource = true,
    this.analyzeSdkSource = true,
    this.treatDynamicInvocationAsThrowing = true,
    this.treatExternalCallsAsThrowing = true,
    this.treatIndexAccessAsThrowing = false,
    this.treatParseMethodsAsThrowing = true,
    this.treatAsCastsAsThrowing = false,
    this.requireAsyncErrorHandling = true,
    this.analyzeTestFiles = false,
    this.ruleTestFileOverrides = const {},
    this.internalStrictness = ThrowIntent.possible,
    this.thirdPartyStrictness = ThrowIntent.deliberate,
  });

  final bool reportDefiniteThrow;
  final bool reportPossibleThrow;
  final bool reportAsyncError;
  final bool reportUnknown;
  final int maxCallDepth;
  final bool analyzeThirdPartySource;
  final bool analyzeSdkSource;
  final bool treatDynamicInvocationAsThrowing;
  final bool treatExternalCallsAsThrowing;
  final bool treatIndexAccessAsThrowing;
  final bool treatParseMethodsAsThrowing;
  final bool treatAsCastsAsThrowing;
  final bool requireAsyncErrorHandling;
  final bool analyzeTestFiles;
  final Map<String, bool> ruleTestFileOverrides;
  final ThrowIntent internalStrictness;
  final ThrowIntent thirdPartyStrictness;

  static const defaultRelativePath = 'analysis_options.yaml';

  static ExceptionAnalysisOptions load({
    String? packageRoot,
    String? currentFilePath,
  }) {
    return loadResult(
      packageRoot: packageRoot,
      currentFilePath: currentFilePath,
    ).unwrapOr(const ExceptionAnalysisOptions());
  }

  static Result<ExceptionAnalysisOptions, ExceptionAnalysisOptionsFailure>
  loadResult({String? packageRoot, String? currentFilePath}) {
    final optionsPath = _findOptionsPath(
      packageRoot: packageRoot,
      currentFilePath: currentFilePath,
    );
    if (optionsPath == null) {
      return const Ok(ExceptionAnalysisOptions());
    }

    final file = File(optionsPath);
    if (!file.existsSync()) {
      return const Ok(ExceptionAnalysisOptions());
    }

    try {
      return parseResult(file.readAsStringSync(), sourcePath: optionsPath);
    } on FileSystemException catch (error) {
      return Err(
        ExceptionAnalysisOptionsFileReadFailure(
          path: optionsPath,
          message: error.message,
        ),
      );
    }
  }

  static String? _findOptionsPath({
    String? packageRoot,
    String? currentFilePath,
  }) {
    if (packageRoot != null) {
      final candidate = p.join(packageRoot, defaultRelativePath);
      if (File(candidate).existsSync()) {
        return candidate;
      }
    }

    if (currentFilePath == null) {
      return null;
    }

    var searchDirectory = p.dirname(currentFilePath);
    while (true) {
      final candidate = p.join(searchDirectory, defaultRelativePath);
      if (File(candidate).existsSync()) {
        return candidate;
      }

      final parent = p.dirname(searchDirectory);
      if (parent == searchDirectory) {
        return null;
      }
      searchDirectory = parent;
    }
  }

  static ExceptionAnalysisOptions parse(String input) {
    return parseResult(input).unwrapOr(const ExceptionAnalysisOptions());
  }

  static Result<ExceptionAnalysisOptions, ExceptionAnalysisOptionsFailure>
  parseResult(String input, {String? sourcePath}) {
    final Object? document;
    try {
      document = loadYaml(input);
    } on YamlException catch (error) {
      return Err(
        ExceptionAnalysisOptionsYamlParseFailure(
          message: error.message,
          sourcePath: sourcePath ?? defaultRelativePath,
        ),
      );
    }

    if (document is! YamlMap) {
      return const Ok(ExceptionAnalysisOptions());
    }

    final plugins = document['plugins'];
    if (plugins is! YamlMap) {
      return const Ok(ExceptionAnalysisOptions());
    }

    final pluginConfig = plugins['dart_exception_lint'];
    if (pluginConfig is! YamlMap) {
      return const Ok(ExceptionAnalysisOptions());
    }

    final analysisConfig = pluginConfig['exception_analysis'];
    if (analysisConfig is! YamlMap) {
      return const Ok(ExceptionAnalysisOptions());
    }

    final report = analysisConfig['report'];
    final strictness = analysisConfig['strictness'];
    final rules = analysisConfig['rules'];

    final internalStrictnessResult = _readThrowIntent(
      strictness,
      'internal',
      sourcePath ?? defaultRelativePath,
    );
    if (internalStrictnessResult case Err(error: final failure)) {
      return Err(failure);
    }

    final thirdPartyStrictnessResult = _readThrowIntent(
      strictness,
      'third_party',
      sourcePath ?? defaultRelativePath,
    );
    if (thirdPartyStrictnessResult case Err(error: final failure)) {
      return Err(failure);
    }

    return Ok(
      ExceptionAnalysisOptions(
        reportDefiniteThrow: _readBool(report, 'definite_throw') ?? true,
        reportPossibleThrow: _readBool(report, 'possible_throw') ?? true,
        reportAsyncError: _readBool(report, 'async_error') ?? true,
        reportUnknown: _readBool(report, 'unknown') ?? true,
        maxCallDepth: _readInt(analysisConfig, 'max_call_depth') ?? 4,
        analyzeThirdPartySource:
            _readBool(analysisConfig, 'analyze_third_party_source') ?? true,
        analyzeSdkSource:
            _readBool(analysisConfig, 'analyze_sdk_source') ?? true,
        treatDynamicInvocationAsThrowing:
            _readBool(analysisConfig, 'treat_dynamic_invocation_as_throwing') ??
            true,
        treatExternalCallsAsThrowing:
            _readBool(analysisConfig, 'treat_external_calls_as_throwing') ??
            true,
        treatIndexAccessAsThrowing:
            _readBool(analysisConfig, 'treat_index_access_as_throwing') ??
            false,
        treatParseMethodsAsThrowing:
            _readBool(analysisConfig, 'treat_parse_methods_as_throwing') ??
            true,
        treatAsCastsAsThrowing:
            _readBool(analysisConfig, 'treat_as_casts_as_throwing') ?? false,
        requireAsyncErrorHandling:
            _readBool(analysisConfig, 'require_async_error_handling') ?? true,
        analyzeTestFiles:
            _readBool(analysisConfig, 'analyze_test_files') ?? false,
        ruleTestFileOverrides: _readRuleTestFileOverrides(rules),
        internalStrictness:
            internalStrictnessResult.valueOrNull ?? ThrowIntent.possible,
        thirdPartyStrictness:
            thirdPartyStrictnessResult.valueOrNull ?? ThrowIntent.deliberate,
      ),
    );
  }

  bool shouldReport(ThrowConfidence confidence) {
    return switch (confidence) {
      ThrowConfidence.definiteThrow => reportDefiniteThrow,
      ThrowConfidence.possibleThrow => reportPossibleThrow,
      ThrowConfidence.asyncError => reportAsyncError,
      ThrowConfidence.unknown => reportUnknown,
      ThrowConfidence.noObviousThrow => false,
    };
  }

  bool shouldAnalyzeTestFilesForRule(String ruleName) {
    return ruleTestFileOverrides[ruleName] ?? analyzeTestFiles;
  }

  static bool? _readBool(Object? map, String key) {
    if (map is! YamlMap) {
      return null;
    }
    final value = map[key];
    return value is bool ? value : null;
  }

  static int? _readInt(Object? map, String key) {
    if (map is! YamlMap) {
      return null;
    }
    final value = map[key];
    return value is int ? value : null;
  }

  static Map<String, bool> _readRuleTestFileOverrides(Object? map) {
    if (map is! YamlMap) {
      return const {};
    }

    final overrides = <String, bool>{};
    for (final entry in map.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String || value is! YamlMap) {
        continue;
      }

      final analyzeTestFiles = _readBool(value, 'analyze_test_files');
      if (analyzeTestFiles != null) {
        overrides[key] = analyzeTestFiles;
      }
    }

    return Map.unmodifiable(overrides);
  }

  static Result<ThrowIntent?, ExceptionAnalysisOptionsFailure> _readThrowIntent(
    Object? map,
    String key,
    String sourcePath,
  ) {
    if (map is! YamlMap) {
      return const Ok(null);
    }
    final value = map[key];
    if (value is! String) {
      return const Ok(null);
    }

    final parsed = ThrowIntentExtension.tryParse(value);
    if (parsed case Err(error: final failure)) {
      return Err(
        ExceptionAnalysisOptionsWireParseFailure(
          key: key,
          cause: failure,
          optionsSourcePath: sourcePath,
        ),
      );
    }

    return Ok(parsed.valueOrNull);
  }
}
