// ignore_for_file: non_constant_identifier_names

import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:analyzer/src/lint/registry.dart';
import 'package:dart_exception_lint/src/rules/no_null_assertion_rule.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(NoNullAssertionRuleTest);
  });
}

@reflectiveTest
class NoNullAssertionRuleTest extends AnalysisRuleTest {
  @override
  String get analysisRule => _rule.name;

  @override
  void setUp() {
    Registry.ruleRegistry.registerLintRule(_rule);
    super.setUp();
  }

  static final NoNullAssertionRule _rule = NoNullAssertionRule();

  Future<void> test_argumentList() async {
    const code = r'''
void f(String value) {}

void g(String? maybe) {
  f(maybe!);
}
''';

    await assertDiagnostics(code, [lint(code.indexOf('!'), 1)]);
  }

  Future<void> test_cascadeAndChain() async {
    const code = r'''
class Box {
  String? value;
}

void f(Box? box) {
  box!..value = 'ok';
}
''';

    await assertDiagnostics(code, [lint(code.indexOf('!'), 1)]);
  }

  Future<void> test_collectionLiteral_multipleAssertions() async {
    const code = r'''
List<String> f(String? first, String? second) {
  return [first!, second!];
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('!'), 1),
      lint(code.lastIndexOf('!'), 1),
    ]);
  }

  Future<void> test_functionCallResult() async {
    const code = r'''
String? load() => null;

void f() {
  print(load()!);
}
''';

    await assertDiagnostics(code, [lint(code.indexOf('!'), 1)]);
  }

  Future<void> test_localVariable() async {
    const code = r'''
void f(String? maybe) {
  print(maybe!);
}
''';

    await assertDiagnostics(code, [lint(code.indexOf('!'), 1)]);
  }

  Future<void> test_nestedPropertyChain_reportsEachAssertion() async {
    const code = r'''
class Box {
  final Box? child;
  final String? value;

  Box(this.child, this.value);
}

void f(Box? box) {
  print(box!.child!.value);
}
''';

    await assertDiagnostics(code, [
      lint(code.indexOf('!'), 1),
      lint(code.lastIndexOf('!'), 1),
    ]);
  }

  Future<void> test_logicalNot_notReported() async {
    await assertNoDiagnostics(r'''
void f(bool condition) {
  if (!condition) {}
}
''');
  }

  Future<void> test_nullAware_notReported() async {
    await assertNoDiagnostics(r'''
void f(String? maybe) {
  print(maybe?.length);
}
''');
  }

  Future<void> test_nullableTypeSyntax_notReported() async {
    await assertNoDiagnostics(r'''
typedef Builder = String? Function(String?)?;

Builder builder = (String? value) => value;
''');
  }

  Future<void> test_propertyAccess() async {
    const code = r'''
class Box {
  final String? value;

  Box(this.value);
}

void f(Box? box) {
  print(box!.value);
}
''';

    await assertDiagnostics(code, [lint(code.indexOf('!'), 1)]);
  }
}
