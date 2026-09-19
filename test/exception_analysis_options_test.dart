import 'package:dart_exception_lint/src/config/exception_analysis_options.dart';
import 'package:dart_exception_lint/src/config/config_failures.dart';
import 'package:dart_exception_lint/src/analysis/throw_summary.dart';
import 'package:dart_exception_lint/src/result.dart';
import 'package:dart_exception_lint/src/utils/source_utils.dart';
import 'package:test/test.dart';

void main() {
  test('parses exception analysis options', () {
    final result = ExceptionAnalysisOptions.parseResult('''
plugins:
  dart_exception_lint:
    path: .
    exception_analysis:
      report:
        definite_throw: true
        possible_throw: false
        async_error: true
        unknown: false
      max_call_depth: 7
      max_sources_per_summary: 12
      max_dispatch_candidates: 9
      analyze_third_party_source: false
      analyze_sdk_source: false
      treat_dynamic_invocation_as_throwing: false
      treat_external_calls_as_throwing: true
      treat_index_access_as_throwing: true
      treat_collection_state_as_throwing: false
      treat_parse_methods_as_throwing: false
      treat_as_casts_as_throwing: true
      require_async_error_handling: false
      analyze_test_files: true
      analyze_generated_files: true
      strictness:
        internal: unknown
        third_party: possible
      rules:
        catch_async_error_sources:
          analyze_test_files: false
''');
    expect(
      result,
      isA<Ok<ExceptionAnalysisOptions, ExceptionAnalysisOptionsFailure>>(),
    );
    final options = result.valueOrNull!;

    expect(options.reportDefiniteThrow, isTrue);
    expect(options.reportPossibleThrow, isFalse);
    expect(options.reportAsyncError, isTrue);
    expect(options.reportUnknown, isFalse);
    expect(options.maxCallDepth, 7);
    expect(options.maxSourcesPerSummary, 12);
    expect(options.maxDispatchCandidates, 9);
    expect(options.analyzeThirdPartySource, isFalse);
    expect(options.analyzeSdkSource, isFalse);
    expect(options.treatDynamicInvocationAsThrowing, isFalse);
    expect(options.treatExternalCallsAsThrowing, isTrue);
    expect(options.treatIndexAccessAsThrowing, isTrue);
    expect(options.treatCollectionStateAsThrowing, isFalse);
    expect(options.treatParseMethodsAsThrowing, isFalse);
    expect(options.treatAsCastsAsThrowing, isTrue);
    expect(options.requireAsyncErrorHandling, isFalse);
    expect(options.analyzeTestFiles, isTrue);
    expect(options.analyzeGeneratedFiles, isTrue);
    expect(
      options.shouldAnalyzeTestFilesForRule('catch_async_error_sources'),
      isFalse,
    );
    expect(options.shouldAnalyzeTestFilesForRule('no_manual_throw'), isTrue);
    expect(options.internalStrictness, ThrowIntent.unknown);
    expect(options.thirdPartyStrictness, ThrowIntent.possible);
  });

  test('uses strictness defaults when omitted', () {
    final result = ExceptionAnalysisOptions.parseResult('''
plugins:
  dart_exception_lint:
    exception_analysis: {}
''');
    expect(
      result,
      isA<Ok<ExceptionAnalysisOptions, ExceptionAnalysisOptionsFailure>>(),
    );
    final options = result.valueOrNull!;

    expect(options.internalStrictness, ThrowIntent.possible);
    expect(options.thirdPartyStrictness, ThrowIntent.deliberate);
    expect(options.analyzeTestFiles, isFalse);
    expect(options.analyzeGeneratedFiles, isFalse);
    expect(options.shouldAnalyzeTestFilesForRule('no_manual_throw'), isFalse);
  });

  test('returns error for unsupported strictness wire value', () {
    final result = ExceptionAnalysisOptions.parseResult('''
plugins:
  dart_exception_lint:
    exception_analysis:
      strictness:
        internal: invalid
''');
    expect(
      result,
      isA<Err<ExceptionAnalysisOptions, ExceptionAnalysisOptionsFailure>>(),
    );
    expect(result.errorOrNull, isA<ExceptionAnalysisOptionsWireParseFailure>());
  });

  test('returns error for malformed scalar configuration values', () {
    final result = ExceptionAnalysisOptions.parseResult('''
exception_analysis:
  max_call_depth: -1
  analyze_generated_files: yes
''');
    expect(
      result,
      isA<Err<ExceptionAnalysisOptions, ExceptionAnalysisOptionsFailure>>(),
    );
    expect(result.errorOrNull, isA<ExceptionAnalysisOptionsValueFailure>());
  });

  test('returns error for misspelled configuration keys', () {
    final result = ExceptionAnalysisOptions.parseResult('''
exception_analysis:
  treat_parse_method_as_throwing: false
''');

    expect(
      result.errorOrNull,
      isA<ExceptionAnalysisOptionsUnknownKeyFailure>(),
    );
  });

  test('validates nested report, strictness, and rule keys', () {
    final result = ExceptionAnalysisOptions.parseResult('''
exception_analysis:
  report:
    possbile_throw: true
  strictness:
    third_pary: unknown
  rules:
    catch_runtime_throw_sources:
      analyze_test_files: true
''');

    expect(
      result.errorOrNull,
      isA<ExceptionAnalysisOptionsUnknownKeyFailure>(),
    );
  });

  test('identifies test dart files', () {
    expect(
      isTestDartFile(
        '/workspace/package/test/widget_test.dart',
        packageRoot: '/workspace/package',
      ),
      isTrue,
    );
    expect(
      isTestDartFile(
        r'C:\workspace\package\test\helpers.dart',
        packageRoot: r'C:\workspace\package',
      ),
      isTrue,
    );
    expect(
      isTestDartFile(
        '/workspace/package/test/helpers.dart',
        packageRoot: '/workspace/package/',
      ),
      isTrue,
    );
    expect(
      isTestDartFile(
        '/workspace/package/lib/src/widget_test.dart',
        packageRoot: '/workspace/package',
      ),
      isTrue,
    );
    expect(isTestDartFile('test/helpers.dart'), isTrue);
    expect(
      isTestDartFile(
        '/workspace/package/lib/src/widget.dart',
        packageRoot: '/workspace/package',
      ),
      isFalse,
    );
  });

  test('identifies common generated Dart files', () {
    for (final path in const [
      'lib/model.g.dart',
      'lib/model.freezed.dart',
      'lib/client.mocks.dart',
      'lib/schema.graphql.dart',
      'lib/api.routes.dart',
    ]) {
      expect(isGeneratedDartFile(path), isTrue, reason: path);
    }
    expect(isGeneratedDartFile('lib/handwritten.dart'), isFalse);
  });

  test('skips test files unless rule override enables them', () {
    const defaultOptions = ExceptionAnalysisOptions();
    const overrideOptions = ExceptionAnalysisOptions(
      ruleTestFileOverrides: {'no_null_assertion': true},
    );

    expect(
      shouldSkipLintRuleForFile(
        ruleName: 'no_null_assertion',
        options: defaultOptions,
        filePath: '/workspace/package/test/widget.dart',
        packageRoot: '/workspace/package',
      ),
      isTrue,
    );
    expect(
      shouldSkipLintRuleForFile(
        ruleName: 'no_null_assertion',
        options: overrideOptions,
        filePath: 'test/widget.dart',
      ),
      isFalse,
    );
    expect(
      shouldSkipLintRuleForFile(
        ruleName: 'no_manual_throw',
        options: overrideOptions,
        filePath: '/workspace/package/lib/widget.dart',
        packageRoot: '/workspace/package',
      ),
      isFalse,
    );
  });
}
