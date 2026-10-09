import 'dart:async';

import 'package:analysis_server_plugin/plugin.dart';
import 'package:analysis_server_plugin/registry.dart';

import 'rules/catch_async_error_sources_rule.dart';
import 'rules/catch_inferred_throwing_calls_rule.dart';
import 'rules/catch_throwing_third_party_calls_rule.dart';
import 'rules/catch_runtime_throw_sources_rule.dart';
import 'rules/catch_unknown_dynamic_calls_rule.dart';
import 'rules/no_manual_throw_rule.dart';
import 'rules/no_null_assertion_rule.dart';
import 'rules/validate_exception_analysis_config_rule.dart';
import 'rules/validate_exception_contract_rule.dart';
import 'rules/validate_exception_environment_rule.dart';
import 'engine/analysis_compatibility.dart';

class DartExceptionLintPlugin extends Plugin {
  @override
  String get name => 'dart_exception_lint';

  @override
  Future<void> register(PluginRegistry registry) async {
    await AnalysisCompatibility.initialize();
    // The registry's warning category controls default enablement separately
    // from diagnostic severity. Enabling this plugin activates its policy;
    // consumers can still disable individual diagnostics explicitly.
    registry.registerWarningRule(NoNullAssertionRule());
    registry.registerWarningRule(NoManualThrowRule());
    registry.registerWarningRule(CatchThrowingThirdPartyCallsRule());
    registry.registerWarningRule(CatchRuntimeThrowSourcesRule());
    registry.registerWarningRule(CatchAsyncErrorSourcesRule());
    registry.registerWarningRule(CatchInferredThrowingCallsRule());
    registry.registerWarningRule(CatchUnknownDynamicCallsRule());
    registry.registerWarningRule(ValidateExceptionAnalysisConfigRule());
    registry.registerWarningRule(ValidateExceptionContractRule());
    registry.registerWarningRule(ValidateExceptionEnvironmentRule());
  }
}
