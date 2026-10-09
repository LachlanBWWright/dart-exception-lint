import 'package:analysis_server_plugin/registry.dart';
import 'package:analysis_server_plugin/src/correction/fix_generators.dart';
import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/src/lint/config.dart' show parseDiagnosticsSection;
import 'package:analyzer/src/lint/registry.dart'
    show RegistryBase, RegistryMixin;
import 'package:dart_exception_lint/src/plugin.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test(
    'plugin enables every rule by default and honors explicit opt-outs',
    () async {
      final registry = _FakePluginRegistry();

      await DartExceptionLintPlugin().register(registry);

      expect(registry.lintRules, isEmpty);
      expect(registry.warningRules.keys, {
        'no_null_assertion',
        'no_manual_throw',
        'catch_throwing_third_party_calls',
        'catch_runtime_throw_sources',
        'catch_async_error_sources',
        'catch_inferred_throwing_calls',
        'catch_unknown_dynamic_calls',
        'invalid_exception_analysis_config',
        'invalid_exception_contract',
        'unsupported_exception_analysis_environment',
      });
      expect(
        registry.enabled({}).map((rule) => rule.name).toSet(),
        registry.warningRules.keys.toSet(),
      );
      final configured = parseDiagnosticsSection(
        loadYamlNode('no_manual_throw: false'),
      );
      expect(
        registry.enabled(configured).map((rule) => rule.name),
        isNot(contains('no_manual_throw')),
      );
      expect(registry.enabled(configured).length, 9);
    },
  );
}

final class _FakePluginRegistry extends RegistryBase
    with RegistryMixin
    implements PluginRegistry {
  @override
  final Map<String, DiagnosticCode> codeMap = {};
  @override
  final Map<String, AbstractAnalysisRule> lintRules = {};
  @override
  final Map<String, AbstractAnalysisRule> warningRules = {};

  @override
  void registerAssist(ProducerGenerator generator) {
    // This smoke-test registry does not exercise assists.
  }

  @override
  void registerFixForRule(DiagnosticCode code, ProducerGenerator generator) {
    // This smoke-test registry does not exercise fixes.
  }
}
