import 'package:analysis_server_plugin/registry.dart';
import 'package:analysis_server_plugin/src/correction/fix_generators.dart';
import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/error/error.dart';
import 'package:dart_exception_lint/src/plugin.dart';
import 'package:test/test.dart';

void main() {
  test('plugin registers all lint rules', () {
    final registry = _FakePluginRegistry();

    DartExceptionLintPlugin().register(registry);

    expect(registry.lintRules.keys, {
      'no_null_assertion',
      'no_manual_throw',
      'catch_throwing_third_party_calls',
      'catch_runtime_throw_sources',
      'catch_async_error_sources',
      'catch_inferred_throwing_calls',
      'catch_unknown_dynamic_calls',
    });
    expect(registry.warningRules, isEmpty);
  });
}

final class _FakePluginRegistry implements PluginRegistry {
  final Map<String, AbstractAnalysisRule> lintRules = {};
  final Map<String, AbstractAnalysisRule> warningRules = {};

  @override
  void registerAssist(ProducerGenerator generator) {
    throw UnimplementedError();
  }

  @override
  void registerFixForRule(LintCode code, ProducerGenerator generator) {
    throw UnimplementedError();
  }

  @override
  void registerLintRule(AbstractAnalysisRule rule) {
    lintRules[rule.name] = rule;
  }

  @override
  void registerWarningRule(AbstractAnalysisRule rule) {
    warningRules[rule.name] = rule;
  }
}
