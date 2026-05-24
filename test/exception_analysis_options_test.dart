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
      analyze_third_party_source: false
      analyze_sdk_source: false
      treat_dynamic_invocation_as_throwing: false
      treat_external_calls_as_throwing: true
      treat_index_access_as_throwing: true
      treat_parse_methods_as_throwing: false
      treat_as_casts_as_throwing: true
      require_async_error_handling: false
      analyze_test_files: true
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
    expect(options.analyzeThirdPartySource, isFalse);
    expect(options.analyzeSdkSource, isFalse);
    expect(options.treatDynamicInvocationAsThrowing, isFalse);
    expect(options.treatExternalCallsAsThrowing, isTrue);
    expect(options.treatIndexAccessAsThrowing, isTrue);
    expect(options.treatParseMethodsAsThrowing, isFalse);
    expect(options.treatAsCastsAsThrowing, isTrue);
    expect(options.requireAsyncErrorHandling, isFalse);
    expect(options.analyzeTestFiles, isTrue);
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
