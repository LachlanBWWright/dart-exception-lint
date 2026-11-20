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
    '{ do {} while (throw "failure"); }': false,
    '{ do { break; } while (throw "unreachable"); }': true,
    '{ return throw "failure"; }': false,
    '{ consume(throw "failure"); next(); }': false,
    '{ final value = (throw "failure"); next(); }': false,
    '{ late final int value = throw "lazy"; next(); }': true,
    '{ final (a, b) = throw "failure"; next(); }': false,
    '{ if (throw "failure") {} next(); }': false,
    '{ while (throw "failure") {} next(); }': false,
    '{ final value = true ? throw "failure" : 1; }': false,
    '{ final value = flag ? throw "failure" : 1; }': true,
    '{ final value = false && (throw "failure"); }': true,
    '{ final value = true && (throw "failure"); }': false,
    '{ final value = true || (throw "failure"); }': true,
    '{ final value = false || (throw "failure"); }': false,
    '{ final value = [1, throw "failure", 2]; next(); }': false,
    '{ final value = [if (false) throw "unreachable"]; }': true,
    '{ final value = [if (true) throw "failure"]; }': false,
    '{ final value = [if (flag) throw "failure" else 2]; }': true,
    '{ final value = [for (;; ) 1]; }': false,
    '{ final value = [for (; false; ) throw "unreachable"]; }': true,
    '{ final value = [for (final item in items) throw "maybe"]; }': true,
    '{ final value = [for (final item in throw "failure") item]; }': false,
    '{ final value = [...throw "failure"]; }': false,
    '{ (throw "failure")..call(); next(); }': false,
    '{ 1..call(throw "failure"); next(); }': false,
    '{ null?..call(throw "unreachable"); next(); }': true,
    '{ for (;;) { continue; } }': false,
    '{ for (;;) { break; } }': true,
    '{ for (var i = throw "failure"; false;) {} }': false,
    '{ for (; throw "failure"; ) { break; } }': false,
    '{ for (final item in throw "failure") { break; } }': false,
    '{ switch (throw "failure") { default: break; } }': false,
    '{ final result = switch (throw "failure") { _ => 0 }; }': false,
    '{ final result = switch (true) { true => throw "failure", _ => 0 }; }':
        false,
    '{ final result = switch (flag) { _ when false => throw "failure", _ => 0 }; }':
        true,
    '{ final result = switch (flag) { _ when throw "failure" => 1, _ => 0 }; }':
        false,
    '{ if (value case _ when throw "failure") {} }': false,
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
    '{ try { return; } catch (_) {} }': false,
    '{ try { while (true) {} } catch (_) {} }': false,
    '{ try { work(); return; } catch (_) {} }': true,
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
    'null?.member.consume(probe())': false,
    'null?[0].consume(probe())': false,
    'null?.member[probe()]': false,
    '(null?.member)?.consume(probe())': true,
    '(null?.member).consume(probe())': true,
    'maybe?.member.consume(probe())': true,
    '(throw "stop")[probe()]': false,
    '(1, throw "stop", probe())': false,
    '[throw "stop", probe()]': false,
    '[probe(), throw "stop"]': true,
    '[if (false) probe()]': false,
    '[if (true) 0 else probe()]': false,
    '[if (false case false) probe()]': true,
    '[if (false case true when probe()) 0]': false,
    '[if (true case _ when false) probe()]': false,
    '(switch (throw "stop") { _ => probe() })': false,
    '(switch (true) { true => 1, _ => probe() })': false,
    '(switch (flag) { _ when false => probe(), _ => 1 })': false,
    '(switch (flag) { _ when false => 1, _ => probe() })': true,
    '(switch (flag) { _ when throw "stop" => 1, _ => probe() })': false,
    '[if (throw "stop") probe()]': false,
    '[for (; false;) probe()]': false,
    '[for (var i = throw "stop"; probe();) 0]': false,
    '[for (;; probe()) throw "stop"]': false,
    '[for (final value in values) probe()]': true,
    '<int, int>{throw "stop": probe()}': false,
    '<int, int>{?null: probe()}': false,
    '<int, int>{?maybe: probe()}': true,
    '<int, int>{?null: throw "skipped", 0: probe()}': true,
    '(throw "stop")..probe()': false,
    'null?..nothing()..probe()': false,
    'value..consume(throw "stop")..probe()': false,
    'value?..nothing()..probe()': true,
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
