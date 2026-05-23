import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../analysis/throw_summary.dart';

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

  static const defaultRelativePath = 'analysis_options.yaml';

  static ExceptionAnalysisOptions load({
    String? packageRoot,
    String? currentFilePath,
  }) {
    final optionsPath = _findOptionsPath(
      packageRoot: packageRoot,
      currentFilePath: currentFilePath,
    );
    if (optionsPath == null) {
      return const ExceptionAnalysisOptions();
    }

    final file = File(optionsPath);
    if (!file.existsSync()) {
      return const ExceptionAnalysisOptions();
    }

    return parse(file.readAsStringSync());
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
    final document = loadYaml(input);
    if (document is! YamlMap) {
      return const ExceptionAnalysisOptions();
    }

    final plugins = document['plugins'];
    if (plugins is! YamlMap) {
      return const ExceptionAnalysisOptions();
    }

    final pluginConfig = plugins['dart_exception_lint'];
    if (pluginConfig is! YamlMap) {
      return const ExceptionAnalysisOptions();
    }

    final analysisConfig = pluginConfig['exception_analysis'];
    if (analysisConfig is! YamlMap) {
      return const ExceptionAnalysisOptions();
    }

    final report = analysisConfig['report'];

    return ExceptionAnalysisOptions(
      reportDefiniteThrow: _readBool(report, 'definite_throw') ?? true,
      reportPossibleThrow: _readBool(report, 'possible_throw') ?? true,
      reportAsyncError: _readBool(report, 'async_error') ?? true,
      reportUnknown: _readBool(report, 'unknown') ?? true,
      maxCallDepth: _readInt(analysisConfig, 'max_call_depth') ?? 4,
      analyzeThirdPartySource:
          _readBool(analysisConfig, 'analyze_third_party_source') ?? true,
      analyzeSdkSource: _readBool(analysisConfig, 'analyze_sdk_source') ?? true,
      treatDynamicInvocationAsThrowing:
          _readBool(analysisConfig, 'treat_dynamic_invocation_as_throwing') ??
          true,
      treatExternalCallsAsThrowing:
          _readBool(analysisConfig, 'treat_external_calls_as_throwing') ?? true,
      treatIndexAccessAsThrowing:
          _readBool(analysisConfig, 'treat_index_access_as_throwing') ?? false,
      treatParseMethodsAsThrowing:
          _readBool(analysisConfig, 'treat_parse_methods_as_throwing') ?? true,
      treatAsCastsAsThrowing:
          _readBool(analysisConfig, 'treat_as_casts_as_throwing') ?? false,
      requireAsyncErrorHandling:
          _readBool(analysisConfig, 'require_async_error_handling') ?? true,
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
}
