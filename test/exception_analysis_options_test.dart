import 'package:dart_exception_lint/src/config/exception_analysis_options.dart';
import 'package:test/test.dart';

void main() {
  test('parses exception analysis options', () {
    final options = ExceptionAnalysisOptions.parse('''
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
''');

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
  });
}
