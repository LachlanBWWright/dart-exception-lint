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

class DartExceptionLintPlugin extends Plugin {
  @override
  String get name => 'dart_exception_lint';

  @override
  FutureOr<void> register(PluginRegistry registry) {
    registry.registerLintRule(NoNullAssertionRule());
    registry.registerLintRule(NoManualThrowRule());
    registry.registerLintRule(CatchThrowingThirdPartyCallsRule());
    registry.registerLintRule(CatchRuntimeThrowSourcesRule());
    registry.registerLintRule(CatchAsyncErrorSourcesRule());
    registry.registerLintRule(CatchInferredThrowingCallsRule());
    registry.registerLintRule(CatchUnknownDynamicCallsRule());
  }
}
