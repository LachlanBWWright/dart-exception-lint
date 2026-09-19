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
    this.maxSourcesPerSummary = 64,
    this.maxDispatchCandidates = 64,
    this.analyzeThirdPartySource = true,
    this.analyzeSdkSource = true,
    this.treatDynamicInvocationAsThrowing = true,
    this.treatExternalCallsAsThrowing = true,
    this.treatIndexAccessAsThrowing = true,
    this.treatCollectionStateAsThrowing = true,
    this.treatParseMethodsAsThrowing = true,
    this.treatAsCastsAsThrowing = true,
    this.treatLateInitializationAsThrowing = true,
    this.treatArithmeticAsThrowing = true,
    this.treatIoOperationsAsThrowing = true,
    this.requireAsyncErrorHandling = true,
    this.analyzeTestFiles = false,
    this.analyzeGeneratedFiles = false,
    this.ruleTestFileOverrides = const {},
    this.internalStrictness = ThrowIntent.possible,
    this.thirdPartyStrictness = ThrowIntent.deliberate,
  });

  final bool reportDefiniteThrow;
  final bool reportPossibleThrow;
  final bool reportAsyncError;
  final bool reportUnknown;
  final int maxCallDepth;
  final int maxSourcesPerSummary;
  final int maxDispatchCandidates;
  final bool analyzeThirdPartySource;
  final bool analyzeSdkSource;
  final bool treatDynamicInvocationAsThrowing;
  final bool treatExternalCallsAsThrowing;
  final bool treatIndexAccessAsThrowing;
  final bool treatCollectionStateAsThrowing;
  final bool treatParseMethodsAsThrowing;
  final bool treatAsCastsAsThrowing;
  final bool treatLateInitializationAsThrowing;
  final bool treatArithmeticAsThrowing;
  final bool treatIoOperationsAsThrowing;
  final bool requireAsyncErrorHandling;
  final bool analyzeTestFiles;
  final bool analyzeGeneratedFiles;
  final Map<String, bool> ruleTestFileOverrides;
  final ThrowIntent internalStrictness;
  final ThrowIntent thirdPartyStrictness;

  /// Configuration owned by this plugin. Keeping it outside
  /// `analysis_options.yaml` avoids unknown-option warnings from the analyzer,
  /// whose plugin configuration schema only accepts its built-in keys.
  static const defaultRelativePath =
      'tool/dart_exception_lint/exception_analysis.yaml';

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
    final pluginConfig = plugins is YamlMap
        ? plugins['dart_exception_lint']
        : null;
    final analysisConfig = pluginConfig is YamlMap
        ? pluginConfig['exception_analysis']
        : document['exception_analysis'];
    if (analysisConfig is! YamlMap) {
      return const Ok(ExceptionAnalysisOptions());
    }

    final report = analysisConfig['report'];
    final strictness = analysisConfig['strictness'];
    final rules = analysisConfig['rules'];

    const knownKeys = {
      'report',
      'strictness',
      'rules',
      'max_call_depth',
      'max_sources_per_summary',
      'max_dispatch_candidates',
      'analyze_third_party_source',
      'analyze_sdk_source',
      'treat_dynamic_invocation_as_throwing',
      'treat_external_calls_as_throwing',
      'treat_index_access_as_throwing',
      'treat_collection_state_as_throwing',
      'treat_parse_methods_as_throwing',
      'treat_as_casts_as_throwing',
      'treat_late_initialization_as_throwing',
      'treat_arithmetic_as_throwing',
      'treat_io_operations_as_throwing',
      'require_async_error_handling',
      'analyze_test_files',
      'analyze_generated_files',
    };
    for (final key in analysisConfig.keys) {
      if (key is String && !knownKeys.contains(key)) {
        return Err(
          ExceptionAnalysisOptionsUnknownKeyFailure(
            key: key,
            sourcePath: sourcePath ?? defaultRelativePath,
          ),
        );
      }
    }

    final shapeFailure = _validateNestedShapes(
      report,
      strictness,
      rules,
      sourcePath ?? defaultRelativePath,
    );
    if (shapeFailure != null) return Err(shapeFailure);

    final scalarFailure = _validateScalarValues(
      analysisConfig,
      report,
      sourcePath ?? defaultRelativePath,
    );
    if (scalarFailure != null) return Err(scalarFailure);

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
        maxCallDepth:
            _readNonNegativeInt(analysisConfig, 'max_call_depth') ?? 4,
        maxSourcesPerSummary:
            _readNonNegativeInt(analysisConfig, 'max_sources_per_summary') ??
            64,
        maxDispatchCandidates:
            _readNonNegativeInt(analysisConfig, 'max_dispatch_candidates') ??
            64,
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
            _readBool(analysisConfig, 'treat_index_access_as_throwing') ?? true,
        treatCollectionStateAsThrowing:
            _readBool(analysisConfig, 'treat_collection_state_as_throwing') ??
            true,
        treatParseMethodsAsThrowing:
            _readBool(analysisConfig, 'treat_parse_methods_as_throwing') ??
            true,
        treatAsCastsAsThrowing:
            _readBool(analysisConfig, 'treat_as_casts_as_throwing') ?? true,
        treatLateInitializationAsThrowing:
            _readBool(
              analysisConfig,
              'treat_late_initialization_as_throwing',
            ) ??
            true,
        treatArithmeticAsThrowing:
            _readBool(analysisConfig, 'treat_arithmetic_as_throwing') ?? true,
        treatIoOperationsAsThrowing:
            _readBool(analysisConfig, 'treat_io_operations_as_throwing') ??
            true,
        requireAsyncErrorHandling:
            _readBool(analysisConfig, 'require_async_error_handling') ?? true,
        analyzeTestFiles:
            _readBool(analysisConfig, 'analyze_test_files') ?? false,
        analyzeGeneratedFiles:
            _readBool(analysisConfig, 'analyze_generated_files') ?? false,
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

  static int? _readNonNegativeInt(Object? map, String key) {
    final value = _readInt(map, key);
    return value != null && value >= 0 ? value : null;
  }

  static ExceptionAnalysisOptionsValueFailure? _validateScalarValues(
    YamlMap analysisConfig,
    Object? report,
    String sourcePath,
  ) {
    const booleans = [
      'analyze_third_party_source',
      'analyze_sdk_source',
      'treat_dynamic_invocation_as_throwing',
      'treat_external_calls_as_throwing',
      'treat_index_access_as_throwing',
      'treat_collection_state_as_throwing',
      'treat_parse_methods_as_throwing',
      'treat_as_casts_as_throwing',
      'treat_late_initialization_as_throwing',
      'treat_arithmetic_as_throwing',
      'treat_io_operations_as_throwing',
      'require_async_error_handling',
      'analyze_test_files',
      'analyze_generated_files',
    ];
    for (final key in booleans) {
      if (analysisConfig.containsKey(key) && analysisConfig[key] is! bool) {
        return ExceptionAnalysisOptionsValueFailure(
          key: key,
          expected: 'a boolean',
          sourcePath: sourcePath,
        );
      }
    }
    const integers = [
      'max_call_depth',
      'max_sources_per_summary',
      'max_dispatch_candidates',
    ];
    for (final key in integers) {
      if (analysisConfig.containsKey(key) && analysisConfig[key] is! int) {
        return ExceptionAnalysisOptionsValueFailure(
          key: key,
          expected: 'a non-negative integer',
          sourcePath: sourcePath,
        );
      }
      if (analysisConfig[key] case final int value when value < 0) {
        return ExceptionAnalysisOptionsValueFailure(
          key: key,
          expected: 'a non-negative integer',
          sourcePath: sourcePath,
        );
      }
    }
    if (report is YamlMap) {
      for (final key in const [
        'definite_throw',
        'possible_throw',
        'async_error',
        'unknown',
      ]) {
        if (report.containsKey(key) && report[key] is! bool) {
          return ExceptionAnalysisOptionsValueFailure(
            key: 'report.$key',
            expected: 'a boolean',
            sourcePath: sourcePath,
          );
        }
      }
    }
    return null;
  }

  static ExceptionAnalysisOptionsFailure? _validateNestedShapes(
    Object? report,
    Object? strictness,
    Object? rules,
    String sourcePath,
  ) {
    if (report != null && report is! YamlMap) {
      return ExceptionAnalysisOptionsValueFailure(
        key: 'report',
        expected: 'a map',
        sourcePath: sourcePath,
      );
    }
    if (strictness != null && strictness is! YamlMap) {
      return ExceptionAnalysisOptionsValueFailure(
        key: 'strictness',
        expected: 'a map',
        sourcePath: sourcePath,
      );
    }
    if (rules != null && rules is! YamlMap) {
      return ExceptionAnalysisOptionsValueFailure(
        key: 'rules',
        expected: 'a map',
        sourcePath: sourcePath,
      );
    }
    if (report is YamlMap) {
      for (final key in report.keys) {
        if (key is String &&
            !const {
              'definite_throw',
              'possible_throw',
              'async_error',
              'unknown',
            }.contains(key)) {
          return ExceptionAnalysisOptionsUnknownKeyFailure(
            key: 'report.$key',
            sourcePath: sourcePath,
          );
        }
      }
    }
    if (strictness is YamlMap) {
      for (final key in strictness.keys) {
        if (key is String && !const {'internal', 'third_party'}.contains(key)) {
          return ExceptionAnalysisOptionsUnknownKeyFailure(
            key: 'strictness.$key',
            sourcePath: sourcePath,
          );
        }
      }
    }
    if (rules is YamlMap) {
      const ruleNames = {
        'no_null_assertion',
        'no_manual_throw',
        'catch_throwing_third_party_calls',
        'catch_runtime_throw_sources',
        'catch_async_error_sources',
        'catch_inferred_throwing_calls',
        'catch_unknown_dynamic_calls',
      };
      for (final entry in rules.entries) {
        if (entry.key is! String || !ruleNames.contains(entry.key)) {
          return ExceptionAnalysisOptionsUnknownKeyFailure(
            key: 'rules.${entry.key}',
            sourcePath: sourcePath,
          );
        }
        if (entry.value is! YamlMap) {
          return ExceptionAnalysisOptionsValueFailure(
            key: 'rules.${entry.key}',
            expected: 'a map',
            sourcePath: sourcePath,
          );
        }
        for (final key in (entry.value as YamlMap).keys) {
          if (key != 'analyze_test_files') {
            return ExceptionAnalysisOptionsUnknownKeyFailure(
              key: 'rules.${entry.key}.$key',
              sourcePath: sourcePath,
            );
          }
        }
      }
    }
    return null;
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
