import 'package:analyzer/error/error.dart';

final class DartExceptionLintDiagnostics {
  static const LintCode noNullAssertion = LintCode(
    'no_null_assertion',
    "Avoid null assertions with '!'.",
    correctionMessage: "Try handling the nullable value without '!'.",
  );

  static const LintCode noManualThrow = LintCode(
    'no_manual_throw',
    'Avoid manually throwing {0}.',
    correctionMessage:
        'Try returning an error value or handling the failure without throw.',
  );

  static const LintCode catchThrowingThirdPartyCalls = LintCode(
    'catch_throwing_third_party_calls',
    '{0} is configured as throwing and should be called inside try/catch.',
    correctionMessage:
        'Try wrapping this call in try/catch or moving it behind a safer boundary.',
  );

  static const LintCode catchRuntimeThrowSources = LintCode(
    'catch_runtime_throw_sources',
    '{0} can throw at runtime and should be protected.',
    correctionMessage:
        'Try wrapping this operation in try/catch or using a safer alternative.',
  );

  static const LintCode catchAsyncErrorSources = LintCode(
    'catch_async_error_sources',
    '{0} can complete with an error and should be handled.',
    correctionMessage:
        'Try awaiting it inside try/catch or attaching an async error handler.',
  );

  static const LintCode catchInferredThrowingCalls = LintCode(
    'catch_inferred_throwing_calls',
    '{0} can propagate a {1} from its implementation and should be called inside try/catch.',
    correctionMessage:
        'Try wrapping this call in try/catch or moving it behind a safer boundary.',
  );

  static const LintCode catchUnknownDynamicCalls = LintCode(
    'catch_unknown_dynamic_calls',
    '{0} could not be resolved safely and should be protected or avoided.',
    correctionMessage:
        'Try adding type information, using a known safe API, or protecting this call.',
  );
}
