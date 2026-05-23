// ignore_for_file: non_constant_identifier_names

import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:analyzer/src/lint/registry.dart';
import 'package:dart_exception_lint/src/rules/catch_async_error_sources_rule.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(CatchAsyncErrorSourcesRuleTest);
  });
}

@reflectiveTest
class CatchAsyncErrorSourcesRuleTest extends AnalysisRuleTest {
  @override
  String get analysisRule => _rule.name;

  @override
  void setUp() {
    Registry.ruleRegistry.registerLintRule(_rule);
    super.setUp();
  }

  static final CatchAsyncErrorSourcesRule _rule = CatchAsyncErrorSourcesRule();

  Future<void> test_awaitedHelperReturningFutureError_reports() async {
    const code = r'''
class BoomException implements Exception {}

Future<String> load() => Future.error(BoomException());

Future<void> f() async {
  await load();
}
''';

    await assertDiagnostics(code, [
      lint(
        code.indexOf('await'),
        'await load()'.length,
        messageContains: 'load',
      ),
    ]);
  }

  Future<void> test_awaitedHelperInsideTryCatch_notReported() async {
    await assertNoDiagnostics(r'''
class BoomException implements Exception {}

Future<String> load() => Future.error(BoomException());

Future<void> f() async {
  try {
    await load();
  } catch (_) {}
}
''');
  }

  Future<void> test_listenWithoutOnError_reports() async {
    const code = r'''
void f(Stream<int> stream) {
  stream.listen((value) {});
}
''';

    await assertDiagnostics(code, [
      lint(
        code.indexOf('listen'),
        'listen'.length,
        messageContains: 'Stream.listen',
      ),
    ]);
  }
}
