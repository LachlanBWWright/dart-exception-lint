import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
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
    '{ return throw "failure"; }': false,
    '{ consume(throw "failure"); next(); }': false,
    '{ final value = (throw "failure"); next(); }': false,
    '{ if (throw "failure") {} next(); }': false,
    '{ while (throw "failure") {} next(); }': false,
    '{ final value = true ? throw "failure" : 1; }': false,
    '{ final value = flag ? throw "failure" : 1; }': true,
    '{ final value = false && (throw "failure"); }': true,
    '{ final value = true && (throw "failure"); }': false,
    '{ final value = true || (throw "failure"); }': true,
    '{ final value = false || (throw "failure"); }': false,
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

  final reachability = <String, bool>{
    'false && probe()': false,
    'true || probe()': false,
    'true && probe()': true,
    'flag && probe()': true,
    '1 ?? probe()': false,
    'null ?? probe()': true,
    'true ? 1 : probe()': false,
    'false ? probe() : 1': false,
    'flag ? probe() : 1': true,
    'consume(throw "stop", probe())': false,
    'consume(probe(), throw "stop")': true,
    '(throw "stop") + probe()': false,
    '(throw "stop") ? probe() : 1': false,
    'null?.consume(probe())': false,
    '(1, throw "stop", probe())': false,
    '() { probe(); }': true,
  };
  for (final entry in reachability.entries) {
    test('expression reachability: ${entry.key}', () {
      final unit = parseString(content: 'void f() { ${entry.key}; }').unit;
      final visitor = _FindProbe();
      unit.accept(visitor);
      expect(isReachable(visitor.probe!), entry.value);
    });
  }
}

class _FindProbe extends RecursiveAstVisitor<void> {
  MethodInvocation? probe;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == 'probe') probe = node;
    super.visitMethodInvocation(node);
  }
}
