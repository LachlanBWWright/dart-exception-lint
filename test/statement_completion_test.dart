import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:dart_exception_lint/src/engine/statement_completion.dart';
import 'package:test/test.dart';

void main() {
  final cases = <String, bool>{
    '{}': true,
    '{ return; failure(); }': false,
    '{ if (flag) return; else throw "failure"; }': false,
    '{ if (flag) return; }': true,
    '{ if (true) return; }': false,
    '{ if (false) return; }': true,
    '{ if (!false) return; }': false,
    '{ while (true) {} }': false,
    '{ while (true) { break; } }': true,
    '{ while (false) { return; } }': true,
    '{ while (flag) { return; } }': true,
    '{ do { return; } while (flag); }': false,
    '{ do { continue; } while (false); }': true,
    '{ do { continue; } while (true); }': false,
    '{ for (;;) { continue; } }': false,
    '{ for (;;) { break; } }': true,
    '{ for (final item in items) { return; } }': true,
    '{ outer: while (true) { while (true) { break outer; } } }': true,
    '{ outer: while (true) { continue outer; } }': false,
    '{ outer: { break outer; } }': true,
    '{ switch (value) { case 1: return; default: throw "failure"; } }': false,
    '{ switch (value) { case 1: return; } }': true,
    '{ switch (value) { case 1: break; default: return; } }': true,
    '{ try { return; } finally { cleanup(); } }': false,
    '{ try { work(); } finally { return; } }': false,
    '{ try { work(); } finally { if (flag) return; } }': true,
    '{ try { throw "failure"; } catch (_) {} }': true,
    '{ try { return; } catch (_) { return; } }': false,
    '{ while (true) { try { while (true) { work(); } } finally { break; } } }':
        true,
  };
  for (final entry in cases.entries) {
    test('normal completion: ${entry.key}', () {
      final unit = parseString(content: 'void f() ${entry.key}').unit;
      final function = unit.declarations.single as FunctionDeclaration;
      final block =
          (function.functionExpression.body as BlockFunctionBody).block;
      expect(statementCompletion(block).canCompleteNormally, entry.value);
    });
  }
  test('finally replaces the original transfer', () {
    final unit = parseString(
      content: 'void f() { try { return; } finally { throw "replacement"; } }',
    ).unit;
    final function = unit.declarations.single as FunctionDeclaration;
    final block = (function.functionExpression.body as BlockFunctionBody).block;
    expect(
      statementCompletion(block).transfers.map((transfer) => transfer.kind),
      [CompletionKind.thrown],
    );
  });
}
