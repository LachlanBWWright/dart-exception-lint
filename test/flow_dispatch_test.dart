import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:dart_exception_lint/src/analysis/inferred_throw_analyzer.dart';
import 'package:dart_exception_lint/src/analysis/throw_summary.dart';
import 'package:dart_exception_lint/src/config/exception_analysis_options.dart';
import 'package:dart_exception_lint/src/config/throwing_api_manifest.dart';
import 'package:dart_exception_lint/src/engine/resolved_dependencies.dart';
import 'package:dart_exception_lint/src/engine/future_forwarding.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:test/test.dart';

void main() {
  test(
    'resolved constants control branches, loops and short circuiting',
    () async {
      await _verify(
        '''
const enabled = false;
class Flags { static const disabled = true; }
void branch() { if (enabled) throw 'bad'; }
void loop() { while (enabled) { throw 'bad'; } }
void shortCircuit() { enabled && (throw 'bad'); }
void negated() { if (!Flags.disabled) throw 'bad'; }
void positive() { if (!enabled) throw 'real'; }
void casePattern() { if (enabled case false) throw 'pattern'; }
void uncertain(bool enabled) { if (enabled) throw 'possible'; }
''',
        (summaries, _) {
          for (final name in ['branch', 'loop', 'shortCircuit', 'negated']) {
            expect(summaries[name]!.hasAnyThrowSource, isFalse, reason: name);
          }
          expect(summaries['positive']!.exceptionTypes, contains('String'));
          expect(summaries['casePattern']!.exceptionTypes, contains('String'));
          expect(summaries['uncertain']!.exceptionTypes, contains('String'));
        },
      );
    },
  );

  test('loop evaluation order retains only reachable effects', () async {
    await _verify(
      '''
bool probe() => throw 'probe';
Never stop() => throw 3;
Never? nullableBottom() => null;
void initializer() { for (int i = stop(); probe(); probe()) { probe(); } }
void condition() { for (; stop(); probe()) { probe(); } }
void iterable() { for (final item in stop()) { probe(); } }
void skippedUpdate() { for (;; probe()) { break; } }
void skippedDoCondition() { do { return; } while (probe()); }
void continuedUpdate() { outer: for (;; probe()) { continue outer; } }
void continuedDoCondition() { outer: do { continue outer; } while (probe()); }
void updateOrder() { for (;; stop(), probe()) {} }
void switchInput() { switch (stop()) { default: probe(); } }
void switchBody(int value) {
  switch (value) { case 1: return; probe(); }
}
void nullableResult() { nullableBottom(); probe(); }
void lazyInitializer() { late final int value = stop(); probe(); }
''',
      (summaries, _) {
        for (final name in [
          'initializer',
          'condition',
          'iterable',
          'updateOrder',
          'switchInput',
        ]) {
          expect(
            summaries[name]!.exceptionTypes,
            contains('int'),
            reason: name,
          );
          expect(
            summaries[name]!.exceptionTypes,
            isNot(contains('String')),
            reason: name,
          );
        }
        for (final name in [
          'skippedUpdate',
          'skippedDoCondition',
          'switchBody',
        ]) {
          expect(summaries[name]!.hasAnyThrowSource, isFalse, reason: name);
        }
        for (final name in [
          'continuedUpdate',
          'continuedDoCondition',
          'nullableResult',
          'lazyInitializer',
        ]) {
          expect(
            summaries[name]!.exceptionTypes,
            contains('String'),
            reason: name,
          );
        }
      },
    );
  });

  test(
    'loop certainty distinguishes the first iteration from optional work',
    () async {
      await _verify(
        '''
void doAlways() { do { throw 'body'; } while (false); }
void whileAlways() { while (true) { throw 'body'; } }
void forAlways() { for (;;) { throw 'body'; } }
void whileMaybe(bool enabled) { while (enabled) { throw 'body'; } }
void forUpdate(bool enabled) { for (; enabled; throw 'update') {} }
''',
        (summaries, _) {
          for (final name in ['doAlways', 'whileAlways', 'forAlways']) {
            expect(
              summaries[name]!.confidence,
              ThrowConfidence.definiteThrow,
              reason: name,
            );
          }
          for (final name in ['whileMaybe', 'forUpdate']) {
            expect(
              summaries[name]!.confidence,
              ThrowConfidence.possibleThrow,
              reason: name,
            );
          }
        },
      );
    },
  );

  test('conditional exits lower the certainty of later failures', () async {
    await _verify(
      '''
void mayReturn(bool skip) { if (skip) return; throw 'later'; }
void cannotReturn() { if (false) return; throw 'later'; }
void mayBreak(bool skip) {
  outer: { if (skip) break outer; throw 'later'; }
}
''',
      (summaries, _) {
        expect(
          summaries['mayReturn']!.confidence,
          ThrowConfidence.possibleThrow,
        );
        expect(
          summaries['cannotReturn']!.confidence,
          ThrowConfidence.definiteThrow,
        );
        expect(
          summaries['mayBreak']!.confidence,
          ThrowConfidence.possibleThrow,
        );
      },
    );
  });

  test('dynamic boolean operands have typed runtime checks', () async {
    await _verify(
      '''
void branch(dynamic value) { if (value) {} }
void loop(dynamic value) { for (; value;) { break; } }
void doLoop(dynamic value) { do {} while (value); }
bool negation(dynamic value) => !value;
bool logical(dynamic value) => value && true;
bool skipped(dynamic value) => false && value;
void stoppedConversion() { final String value = (throw 3) as dynamic; }
void stoppedCast() { ((throw 3) as dynamic) as String; }
class CheckedParameter<T> { void accept(T value, int other) {} }
void stoppedCovariance(CheckedParameter<num> target) { target.accept(1.5, throw 3); }
void pattern(dynamic value) { if (value case _) {} }
int guard(dynamic value) => switch (true) { _ when value => 1, _ => 0 };
void caught(dynamic value) { try { if (value) {} } on TypeError {} }
''',
      (summaries, _) {
        for (final name in [
          'branch',
          'loop',
          'doLoop',
          'negation',
          'logical',
          'guard',
        ]) {
          final summary = summaries[name]!;
          expect(summary.exceptionTypes.toSet(), {'TypeError'}, reason: name);
          expect(summary.hasUnknownEffects, isFalse, reason: name);
        }
        for (final name in ['skipped', 'pattern', 'caught']) {
          expect(summaries[name]!.hasAnyThrowSource, isFalse, reason: name);
        }
        for (final name in [
          'stoppedConversion',
          'stoppedCast',
          'stoppedCovariance',
        ]) {
          expect(summaries[name]!.exceptionTypes.toSet(), {
            'int',
          }, reason: name);
        }
      },
    );
  });

  test('collection evaluation keeps only reachable effects', () async {
    await _verify(
      '''
const enabled = false;
int probe() => throw 'probe';
Never stop() => throw 3;
void listItems() { [stop(), probe()]; probe(); }
void mapKey() { <int, int>{stop(): probe()}; probe(); }
void spread() { <int>[...stop(), probe()]; probe(); }
void branch() { [if (enabled) probe() else stop()]; }
void loop() { [for (var i = stop(); enabled;) probe()]; }
void maybeLoop(List<int> items) { [for (final item in items) stop(), probe()]; }
void ifCase() { [if (enabled case false) probe()]; }
void nullKey() { <int, int>{?null: probe()}; }
void maybeKey(int? key) { <int, int>{?key: probe()}; }
''',
      (summaries, _) {
        for (final name in [
          'listItems',
          'mapKey',
          'spread',
          'branch',
          'loop',
        ]) {
          expect(summaries[name]!.exceptionTypes.toSet(), {
            'int',
          }, reason: name);
        }
        expect(summaries['nullKey']!.exceptionTypes, isNot(contains('String')));
        for (final name in ['maybeLoop', 'ifCase', 'maybeKey']) {
          expect(
            summaries[name]!.exceptionTypes,
            contains('String'),
            reason: name,
          );
        }
      },
    );
  });

  test('cascade sections follow their receiver and earlier sections', () async {
    await _verify(
      '''
final class Target {
  Never stop() => throw 3;
  void fail() => throw 'section';
}
const Target? absent = null;
void after() => throw true;
void unreachableSection() { Target()..stop()..fail(); after(); }
void skippedCascade() { absent?..stop()..fail(); }
void possibleCascade(Target? target) { target?..stop()..fail(); after(); }
''',
      (summaries, _) {
        expect(summaries['unreachableSection']!.exceptionTypes.toSet(), {
          'int',
        });
        expect(summaries['skippedCascade']!.hasAnyThrowSource, isFalse);
        expect(summaries['possibleCascade']!.exceptionTypes.toSet(), {
          'int',
          'bool',
        });
      },
    );
  });

  test('null-aware selector chains reach their shared end', () async {
    await _verify(
      '''
final class Link {
  Link get next => throw 'getter';
  Link operator [](int i) => throw 'index';
  Never fail(int value) => throw 3;
  Link? get nullable => throw 'nullable getter';
}
const Link? absent = null;
Never input() => throw true;
void trailing() => throw 1.5;
void skippedMethod() { absent?.next.fail(input()); trailing(); }
void skippedIndex() { absent?[input()].fail(0); trailing(); }
void skippedAssertion() { absent?.nullable!; trailing(); }
void parenthesizedAssertion() { (absent?.nullable)!; }
void possibleChain(Link? value) { value?.next.fail(input()); trailing(); }
void genericFallback<T>(T value) { value ?? input(); }
''',
      (summaries, _) {
        for (final name in [
          'skippedMethod',
          'skippedIndex',
          'skippedAssertion',
        ]) {
          expect(summaries[name]!.exceptionTypes.toSet(), {
            'double',
          }, reason: name);
        }
        expect(
          summaries['parenthesizedAssertion']!.sources.map(
            (source) => source.displayName,
          ),
          contains('null assertion'),
        );
        expect(summaries['possibleChain']!.exceptionTypes.toSet(), {
          'String',
          'bool',
          'double',
        });
        expect(summaries['genericFallback']!.exceptionTypes, contains('bool'));
      },
    );
  });

  test(
    'nullable selectors and cascades can skip otherwise definite throws',
    () async {
      await _verify(
        '''
final class Target {
  void fail() { throw 'method'; }
  void take(int value) {}
}
void optionalCall(Target? target) { target?.fail(); }
void optionalArgument(Target? target) { target?.take(throw 'argument'); }
void optionalCascade(Target? target) { target?..fail(); }
void requiredCall(Target target) { target.fail(); }
''',
        (summaries, _) {
          for (final name in [
            'optionalCall',
            'optionalArgument',
            'optionalCascade',
          ]) {
            expect(
              summaries[name]!.confidence,
              ThrowConfidence.possibleThrow,
              reason: name,
            );
          }
          expect(
            summaries['requiredCall']!.confidence,
            ThrowConfidence.definiteThrow,
          );
        },
      );
    },
  );

  test('pattern guards govern selection and fallthrough', () async {
    await _verify(
      '''
bool probe() => throw 'guard or arm';
Never stop() => throw 3;
void input() { final result = switch (stop()) { _ => probe() }; probe(); }
void firstMatch() { final result = switch (true) { true => stop(), _ => probe() }; probe(); }
void falseGuard(bool value) { final result = switch (value) { _ when false => probe(), _ => stop() }; }
void stoppedGuard(bool value) { final result = switch (value) { _ when stop() => probe(), _ => probe() }; probe(); }
void stoppedIfCase(bool value) { if (value case _ when stop()) probe(); else probe(); }
void failedIfCase() { if (false case true when probe()) probe(); else stop(); }
void possibleElse(Object value) { if (value case int _ when stop()) probe(); else probe(); }
''',
      (summaries, _) {
        for (final name in [
          'input',
          'firstMatch',
          'falseGuard',
          'stoppedGuard',
          'stoppedIfCase',
          'failedIfCase',
        ]) {
          expect(summaries[name]!.exceptionTypes.toSet(), {
            'int',
          }, reason: name);
        }
        expect(summaries['possibleElse']!.exceptionTypes.toSet(), {
          'int',
          'String',
        });
      },
    );
  });

  test('assertions evaluate inputs in order and may be disabled', () async {
    await _verify(
      '''
Never stop() => throw 3;
Never message() => throw 'message';
void passed() { assert(true, message()); }
void failed() { assert(false); }
void failedMessage() { assert(false, message()); }
void failedCondition() { assert(stop(), message()); }
class Checked { Checked() : assert(false); }
void construct() { Checked(); }
void contained() { try { assert(false); } on AssertionError {} }
''',
      (summaries, _) {
        expect(summaries['passed']!.hasAnyThrowSource, isFalse);
        expect(summaries['contained']!.hasAnyThrowSource, isFalse);
        for (final name in ['failed', 'construct']) {
          expect(summaries[name]!.exceptionTypes, contains('AssertionError'));
          expect(summaries[name]!.confidence, ThrowConfidence.possibleThrow);
        }
        expect(summaries['failedMessage']!.exceptionTypes.toSet(), {'String'});
        expect(summaries['failedCondition']!.exceptionTypes.toSet(), {'int'});
      },
    );
  });

  test('selection certainty follows collection and pattern branches', () async {
    await _verify(
      '''
void conditionalIf(bool choose) { [if (choose) throw 1]; }
void knownIf() { [if (true) throw 1]; }
void collectionFor(List<int> inputs) { [for (final input in inputs) throw 1]; }
void nullAwareKey(int? input) { <int, int>{?input: throw 1}; }
void conditionalSwitch(bool choose) {
  final result = switch (choose) { true => throw 1, false => 0 };
}
void knownSwitch() {
  final result = switch (true) { true => throw 1, false => 0 };
}
void laterGuard(bool choose) {
  final result = switch (choose) { true => 0, _ when (throw 1) => 0, _ => 0 };
}
void firstGuard(bool choose) {
  final result = switch (choose) { _ when (throw 1) => 0, _ => 0 };
}
void maybeStoppedIf(Object input) {
  if (input case int _ when (throw 1)) {} else { throw 2; }
}
''',
      (summaries, _) {
        for (final name in [
          'conditionalIf',
          'collectionFor',
          'nullAwareKey',
          'conditionalSwitch',
          'laterGuard',
          'maybeStoppedIf',
        ]) {
          expect(
            summaries[name]!.confidence,
            ThrowConfidence.possibleThrow,
            reason: name,
          );
        }
        for (final name in ['knownIf', 'knownSwitch', 'firstGuard']) {
          expect(
            summaries[name]!.confidence,
            ThrowConfidence.definiteThrow,
            reason: name,
          );
        }
      },
    );
  });

  test('switch statements sequence guards, case groups, and exits', () async {
    await _verify(
      '''
Never stop() => throw 3;
bool guard() => throw 'guard';
void skippedGuard() {
  switch (false) {
    case true when guard(): throw 'unreachable case';
    default: stop();
  }
  throw 'unreachable tail';
}
void stoppedGuard(bool value) {
  switch (value) {
    case _ when stop(): throw 'unreachable case';
    default: throw 'unreachable default';
  }
  throw 'unreachable tail';
}
void groupedCase() {
  switch (true) {
    case true:
    case false: stop();
  }
  throw 'unreachable tail';
}
void continuedCase() {
  switch (true) {
    case true: continue otherCase;
    otherCase:
    case false: stop();
  }
}
const Object unmatched = false;
void unmatchedCase() {
  switch (unmatched) { case true: guard(); }
  stop();
}
void exhaustive(bool value) {
  switch (value) { case true: return; case false: return; }
  throw 'unreachable tail';
}
void openSubject(Object value) {
  switch (value) { case true: return; case false: return; }
  throw 'reachable tail';
}
void guardedSubject(bool value, bool allow) {
  switch (value) {
    case true when allow: return;
    case false: return;
    default: break;
  }
  throw 'reachable tail';
}
''',
      (summaries, _) {
        for (final name in [
          'skippedGuard',
          'stoppedGuard',
          'groupedCase',
          'continuedCase',
          'unmatchedCase',
        ]) {
          expect(summaries[name]!.exceptionTypes.toSet(), {
            'int',
          }, reason: name);
        }
        expect(summaries['exhaustive']!.hasAnyThrowSource, isFalse);
        for (final name in ['openSubject', 'guardedSubject']) {
          expect(summaries[name]!.exceptionTypes.toSet(), {'String'});
        }
      },
    );
  });

  test('constructors sequence fields, initializer lists, and calls', () async {
    await _verify(
      '''
Never stop() => throw 3;
class Base {
  Base.named() { throw 'super'; }
  Base.withInput(int input) { throw 'super'; }
}
class FieldStops extends Base {
  final int first = stop();
  final int second = throw 'later field';
  FieldStops() : super.named() { throw true; }
}
class InitializerStops extends Base {
  final int field;
  InitializerStops() : field = stop(), super.named() { throw true; }
}
class SuperInputStops extends Base {
  SuperInputStops() : super.withInput(stop()) { throw true; }
}
class SuperRuns extends Base { SuperRuns() : super.named(); }
class Redirects {
  Redirects.target(int input) { throw 'target'; }
  Redirects() : this.target(1);
  Redirects.blocked() : this.target(stop());
}
void stoppedField() { FieldStops(); }
void stoppedInitializer() { InitializerStops(); }
void stoppedSuperInput() { SuperInputStops(); }
void canReachSuper() { SuperRuns(); }
void canReachRedirect() { Redirects(); }
void blockedRedirect() { Redirects.blocked(); }
''',
      (summaries, _) {
        for (final name in [
          'stoppedField',
          'stoppedInitializer',
          'stoppedSuperInput',
          'blockedRedirect',
        ]) {
          expect(summaries[name]!.exceptionTypes.toSet(), {
            'int',
          }, reason: name);
        }
        for (final name in ['canReachSuper', 'canReachRedirect']) {
          expect(summaries[name]!.exceptionTypes.toSet(), {
            'String',
          }, reason: name);
        }
      },
    );
  });

  test('assignment effects follow evaluation and short circuits', () async {
    await _verify(
      '''
final class Number {
  Number operator +(Number other) => throw 1.5;
}
final class Holder {
  Number get item => throw 'get';
  set item(Number value) { throw true; }
}
const Holder? absent = null;
Never stop() => throw 3;
void write() { Holder().item = stop(); throw 1.0; }
void compound() { Holder().item += stop(); throw 1.0; }
void normalCompound() { Holder().item += Number(); }
void nullAware() { absent?.item = stop(); }
void coalescing() { Holder().item ??= stop(); }
void lateWrite() { late int value; value = 3; }
''',
      (summaries, _) {
        expect(summaries['write']!.exceptionTypes.toSet(), {'int'});
        expect(summaries['compound']!.exceptionTypes.toSet(), {
          'String',
          'int',
        });
        expect(summaries['normalCompound']!.exceptionTypes.toSet(), {
          'String',
          'bool',
          'double',
        });
        expect(summaries['nullAware']!.hasAnyThrowSource, isFalse);
        expect(summaries['coalescing']!.exceptionTypes.toSet(), {'String'});
        expect(summaries['lateWrite']!.hasAnyThrowSource, isFalse);
      },
    );
  });

  test('coalescing assignments can skip the operand and setter', () async {
    await _verify(
      '''
final class Holder {
  Holder(this.current);
  final int? current;
  int? get item => current;
  set item(int? value) { throw 'setter'; }
}
void skippedSetter(int? current) { Holder(current).item ??= 1; }
void skippedOperand(int? current) { Holder(current).item ??= throw 3; }
''',
      (summaries, _) {
        final setter = summaries['skippedSetter']!;
        final operand = summaries['skippedOperand']!;
        expect(setter.exceptionTypes.toSet(), {'String'});
        expect(operand.exceptionTypes.toSet(), {'int'});
        expect(setter.confidence, ThrowConfidence.possibleThrow);
        expect(operand.confidence, ThrowConfidence.possibleThrow);
      },
    );
  });

  test('String bounds follow nonempty guards for stable values', () async {
    await _verify(
      '''
void guarded(String value) {
  if (value.isNotEmpty && value.codeUnitAt(0) == 65) value[0];
}
void guardedAfterWrite(String value) {
  value = value.trim();
  if (!value.isEmpty) value[0];
}
void guardedElse(String value) {
  if (value.isEmpty) {} else { value[0]; }
}
void overwritten(String value) {
  if (value.isNotEmpty) { value = ''; value[0]; }
}
void patternWrite(String value) {
  if (value.isNotEmpty) { (value,) = ('',); value[0]; }
}
void captured(String value) {
  void clear() { value = ''; }
  if (value.isNotEmpty) { clear(); value[0]; }
}
void capturedPattern(String value) {
  void clear() { (value,) = ('',); }
  if (value.isNotEmpty) { clear(); value[0]; }
}
void differentIndex(String value) {
  if (value.isNotEmpty) value[1];
}
void falsePattern(String value) {
  if (value.isNotEmpty case false) value[0];
}
''',
      (summaries, _) {
        for (final name in ['guarded', 'guardedAfterWrite', 'guardedElse']) {
          expect(
            summaries[name]!.exceptionTypes,
            isNot(contains('RangeError')),
            reason: name,
          );
        }
        for (final name in [
          'overwritten',
          'patternWrite',
          'captured',
          'capturedPattern',
          'differentIndex',
          'falsePattern',
        ]) {
          expect(
            summaries[name]!.exceptionTypes,
            contains('RangeError'),
            reason: name,
          );
        }
      },
    );
  });

  test('substring start follows guards and bounded loop updates', () async {
    await _verify(
      '''
void guarded(String text, int start) {
  if (start >= 0 && start <= text.length) text.substring(start);
}
void loop(String text) {
  var start = 0;
  if (text.isNotEmpty) start = 1;
  for (var i = start; i < text.length; i++) {
    if (i == 2) start = i + 1;
  }
  if (start < text.length) text.substring(start);
}
void literal(String text) { text.substring(0); 'x'.substring(1); }
void negative(String text, int start) {
  if (start < text.length) text.substring(start);
}
void differentString(String text, String other, int start) {
  if (start >= 0 && start <= other.length) text.substring(start);
}
void changed(String text, int start) {
  if (start >= 0 && start <= text.length) { start = -1; text.substring(start); }
}
void changedCounter(String text) {
  var start = 0;
  for (var i = start; i < text.length; i++) {
    i = -2;
    start = i + 1;
    break;
  }
  if (start < text.length) text.substring(start);
}
void badEnd(String text, int start) {
  if (start >= 0 && start <= text.length) text.substring(start, start - 1);
}
''',
      (summaries, _) {
        for (final name in ['guarded', 'loop', 'literal']) {
          expect(
            summaries[name]!.exceptionTypes,
            isNot(contains('RangeError')),
            reason: name,
          );
        }
        for (final name in [
          'negative',
          'differentString',
          'changed',
          'changedCounter',
          'badEnd',
        ]) {
          expect(
            summaries[name]!.exceptionTypes,
            contains('RangeError'),
            reason: name,
          );
        }
      },
    );
  });

  test('String reads follow bounded loop counters on the same value', () async {
    await _verify(
      '''
void bounded(String text) {
  var start = 0;
  for (var i = start; i < text.length; i++) {
    text[i]; text.codeUnitAt(i); start = i + 1;
  }
}
void literal() { 'ab'[1]; 'ab'.codeUnitAt(1); }
void changedString(String text) {
  for (var i = 0; i < text.length; i++) { text = ''; text[i]; }
}
void differentString(String text, String other) {
  for (var i = 0; i < other.length; i++) { text[i]; }
}
void changedCounter(String text) {
  for (var i = 0; i < text.length; i++) { (i,) = (-1,); text.codeUnitAt(i); }
}
void negativeSeed(String text) {
  for (var i = -1; i < text.length; i++) { text[i]; }
}
''',
      (summaries, _) {
        for (final name in ['bounded', 'literal']) {
          expect(
            summaries[name]!.exceptionTypes,
            isNot(contains('RangeError')),
            reason: name,
          );
        }
        for (final name in [
          'changedString',
          'differentString',
          'changedCounter',
          'negativeSeed',
        ]) {
          expect(
            summaries[name]!.exceptionTypes,
            contains('RangeError'),
            reason: name,
          );
        }
      },
    );
  });

  test('substring ranges preserve a start before a bounded counter', () async {
    await _verify(
      '''
void bounded(String text) {
  var start = 0;
  if (text.isNotEmpty) start = 1;
  for (var i = start; i < text.length; i++) {
    if (text[i] == '/') {
      text.substring(start, i);
      start = i + 1;
    }
  }
}
void literal() { 'ab'.substring(1, 2); }
void reversedLiteral() { 'ab'.substring(2, 1); }
void afterUpdate(String text) {
  var start = 0;
  for (var i = start; i < text.length; i++) {
    start = i + 1;
    text.substring(start, i);
  }
}
void repeated(String text) {
  var start = 0;
  for (var i = start; i < text.length; i++) {
    var remaining = 2;
    while (remaining-- > 0) {
      text.substring(start, i);
      start = i + 1;
    }
  }
}
''',
      (summaries, _) {
        for (final name in ['bounded', 'literal']) {
          expect(
            summaries[name]!.exceptionTypes,
            isNot(contains('RangeError')),
            reason: name,
          );
        }
        for (final name in ['reversedLiteral', 'afterUpdate', 'repeated']) {
          expect(
            summaries[name]!.exceptionTypes,
            contains('RangeError'),
            reason: name,
          );
        }
      },
    );
  });

  test('immutable literal indices retain their bounds after storage', () async {
    await _verify(
      '''
int constant() { const items = [1, 2]; return items[1]; }
int finalConstant() { final items = const [1, 2]; return items[1]; }
int outside() { const items = [1, 2]; return items[2]; }
int resized() { final items = [1, 2]; items.clear(); return items[1]; }
''',
      (summaries, _) {
        expect(summaries['constant']!.hasAnyThrowSource, isFalse);
        expect(summaries['finalConstant']!.hasAnyThrowSource, isFalse);
        expect(summaries['outside']!.exceptionTypes.toSet(), {'RangeError'});
        expect(summaries['resized']!.exceptionTypes, contains('RangeError'));
      },
    );
  });

  test(
    'List.add uses the allocation type of a proven literal receiver',
    () async {
      await _verify(
        '''
void growable(String value) {
  final items = <String>[];
  if (value.isNotEmpty) items.add(value[0]);
}
void constant() { const items = <String>[]; items.add('value'); }
void narrower() { final List<num> items = <int>[]; items.add(1.5); }
void unknown(List<String> other) {
  var items = <String>[];
  items = other;
  items.add('value');
}
''',
        (summaries, _) {
          expect(summaries['growable']!.hasAnyThrowSource, isFalse);
          expect(summaries['constant']!.exceptionTypes.toSet(), {
            'UnsupportedError',
          });
          expect(summaries['narrower']!.exceptionTypes.toSet(), {'TypeError'});
          expect(summaries['unknown']!.hasUnknownEffects, isTrue);
        },
      );
    },
  );

  test('index assignment models the read and write that can execute', () async {
    await _verify(
      '''
final class Indexed {
  num operator [](int index) => throw 'read';
  void operator []=(int index, num value) { throw true; }
}
Never stop() => throw 3;
void blockedSdkWrite(List<num> values) { values[0] = stop(); }
void blockedSdkCompound(List<num> values) { values[0] += stop(); }
void sdkWrite(List<num> values) { values[0] = 1; }
void sdkPostfix(List<num> values) { values[0]--; }
void nestedSdkRead(List<num> values) { values[0] += values[1]; }
void blockedUserWrite(Indexed values) { values[0] = stop(); }
void blockedUserCompound(Indexed values) { values[0] += stop(); }
void userWrite(Indexed values) { values[0] = 1; }
''',
      (summaries, _) {
        for (final name in ['blockedSdkWrite', 'blockedUserWrite']) {
          expect(summaries[name]!.exceptionTypes.toSet(), {
            'int',
          }, reason: name);
        }
        final sdkCompound = summaries['blockedSdkCompound']!;
        expect(
          sdkCompound.exceptionTypes.toSet(),
          {'int', 'RangeError'},
          reason: sdkCompound.sources
              .map(
                (source) => '${source.displayName}: ${source.exceptionTypes}',
              )
              .join('\n'),
        );
        expect(summaries['blockedUserCompound']!.exceptionTypes.toSet(), {
          'int',
          'String',
        });
        for (final name in ['sdkWrite', 'sdkPostfix', 'nestedSdkRead']) {
          expect(
            summaries[name]!.exceptionTypes,
            containsAll(['RangeError', 'TypeError', 'UnsupportedError']),
            reason: name,
          );
        }
        expect(summaries['userWrite']!.exceptionTypes.toSet(), {'bool'});
      },
    );
  });

  test(
    'unresolved compound operators stay separate from resolved setters',
    () async {
      await _verify(
        '''
final class Holder {
  dynamic get item => 1;
  set item(dynamic next) {}
}
Never stop() => throw 'operand';
void unresolved() { Holder().item += 1; }
void stopped() { Holder().item += stop(); }
void coalescing() { Holder().item ??= 1; }
''',
        (summaries, _) {
          expect(summaries['unresolved']!.hasUnknownEffects, isTrue);
          expect(summaries['stopped']!.hasUnknownEffects, isFalse);
          expect(summaries['stopped']!.exceptionTypes.toSet(), {'String'});
          expect(summaries['coalescing']!.hasAnyThrowSource, isFalse);
        },
      );
    },
  );

  test('exact literal throws reach the first compatible handler', () async {
    await _verify(
      '''
void contained() {
  try { throw 'failure'; } on int { throw true; } on String {}
}
void unmatched() {
  try { throw 'failure'; } on int { throw true; }
  throw 3;
}
void firstMatch() {
  try { throw true; } on Object { return; } on bool { throw 'later catch'; }
  throw 3;
}
void replacement() {
  try { throw true; } on bool { throw 'replacement'; }
}
''',
      (summaries, _) {
        expect(summaries['contained']!.hasAnyThrowSource, isFalse);
        expect(summaries['firstMatch']!.hasAnyThrowSource, isFalse);
        expect(summaries['unmatched']!.exceptionTypes.toSet(), {'String'});
        expect(summaries['replacement']!.exceptionTypes.toSet(), {'String'});
      },
    );
  });

  test('catch bodies require a possible throwing transfer', () async {
    await _verify(
      '''
void unreachableHandler() { try { return; } catch (_) { throw 'unreachable'; } }
void unreachableAfterTry() { try { return; } catch (_) {} throw 'unreachable'; }
void reachableHandler(dynamic input) {
  try { final String value = input; } catch (_) { throw 'replacement'; }
}
void finallyReturns() {
  try { throw 'contained'; } finally { try { return; } catch (_) {} }
}
''',
      (summaries, _) {
        for (final name in [
          'unreachableHandler',
          'unreachableAfterTry',
          'finallyReturns',
        ]) {
          expect(summaries[name]!.hasAnyThrowSource, isFalse, reason: name);
        }
        expect(
          summaries['reachableHandler']!.exceptionTypes,
          contains('String'),
        );
      },
    );
  });

  test(
    'null assertion effects carry TypeError and honor typed catches',
    () async {
      await _verify(
        '''
String escaping(String? value) => value!;
String handled(String? value) {
  try { return value!; } on TypeError { return ''; }
}
String wrongCatch(String? value) {
  try { return value!; } on Exception { return ''; }
}
String redundant(String value) => value!;
''',
        (summaries, _) {
          expect(summaries['escaping']!.exceptionTypes, ['TypeError']);
          expect(summaries['wrongCatch']!.exceptionTypes, ['TypeError']);
          expect(summaries['handled']!.hasAnyThrowSource, isFalse);
          expect(summaries['redundant']!.hasAnyThrowSource, isFalse);
        },
      );
    },
  );

  test('invocation effects follow receiver and argument evaluation', () async {
    await _verify(
      '''
Never argument() => throw 42;
void callee(int first, [int? second]) => throw 'callee';
class C {
  C(int value) { throw 'constructor'; }
  void invoke(int value) { throw 'method'; }
}
const C? absent = null;
void functionCall() { callee(argument()); }
void closureCall() { ((int value) => throw 'closure')(argument()); }
void constructorCall() { C(argument()); }
void methodCall() { C(0).invoke(argument()); }
void outerThrow() { throw argument(); }
void nullAwareCall() { absent?.invoke(argument()); }
void possibleCall(bool flag) { callee(flag ? argument() : 0); }
''',
      (summaries, _) {
        for (final name in [
          'functionCall',
          'closureCall',
          'constructorCall',
          'outerThrow',
        ]) {
          final summary = summaries[name]!;
          expect(summary.exceptionTypes.toSet(), {'int'}, reason: name);
          expect(summary.hasUnknownEffects, isFalse, reason: name);
        }
        final origins = summaries['methodCall']!.sources.map(
          (source) => source.origin?.displayName,
        );
        expect(origins, contains("throw 'constructor'"));
        expect(origins, isNot(contains("throw 'method'")));
        expect(summaries['nullAwareCall']!.hasAnyThrowSource, isFalse);
        expect(
          summaries['possibleCall']!.exceptionTypes,
          containsAll(['int', 'String']),
        );
      },
    );
  });

  test(
    'exact allocations, super and extension dispatch exclude unrelated overrides',
    () async {
      await _verify(
        '''
class Base { void run() {} }
class Derived extends Base { @override void run() { throw 'derived'; } void extra() { throw 'extra'; } }
extension Extra on Base { void extra() {} }
void exact() { Base().run(); }
void parenthesized() { (Base()).run(); }
void extensionCall(Base base) { base.extra(); }
extension type View(Base base) { void run() {} }
void viewCall(View view) { view.run(); }
class Parent { void run() { throw 'parent'; } }
class Middle extends Parent {
  @override void run() { throw 42; }
  void runSuper() { super.run(); }
}
class Leaf extends Middle { @override void run() { throw true; } }
void superCall() { Middle().runSuper(); }
void open(Base base) { base.run(); }
sealed class Root { void run() {} }
class OpenLeaf extends Root {}
void openLeaf(Root root) { root.run(); }
sealed class Closed { void run() {} }
final class FinalLeaf extends Closed {}
void closedLeaf(Closed root) { root.run(); }
''',
        (summaries, _) {
          for (final name in [
            'exact',
            'parenthesized',
            'extensionCall',
            'viewCall',
            'closedLeaf',
          ]) {
            expect(
              summaries[name]!.hasAnyThrowSource,
              isFalse,
              reason:
                  '$name: ${summaries[name]!.sources.map((s) => s.displayName)}',
            );
          }
          expect(summaries['superCall']!.exceptionTypes, contains('String'));
          expect(
            summaries['superCall']!.exceptionTypes,
            isNot(anyOf(contains('int'), contains('bool'))),
          );
          expect(summaries['open']!.exceptionTypes, contains('String'));
          expect(summaries['open']!.hasUnknownEffects, isTrue);
          expect(summaries['openLeaf']!.hasUnknownEffects, isTrue);
        },
      );
    },
  );

  test(
    'mutually recursive overrides share the caller recursion guard',
    () async {
      await _verify(
        '''
abstract class First { void first(Second other, bool fail); }
abstract class Second { void second(First other, bool fail); }
class FirstImpl extends First {
  @override
  void first(Second other, bool fail) => other.second(this, fail);
}
class SecondImpl extends Second {
  @override
  void second(First other, bool fail) {
    if (fail) throw 'recursive failure';
    other.first(this, fail);
  }
}
void entry(First first, Second second, bool fail) => first.first(second, fail);
''',
        (summaries, _) {
          final entry = summaries['entry']!;
          expect(entry.exceptionTypes, contains('String'));
          expect(entry.hasUnknownEffects, isTrue);
          expect(
            entry.dependencyElementKeys.map((key) => key.split(':').last),
            unorderedEquals(['first', 'first', 'second', 'second']),
          );
        },
      );
    },
  );

  test(
    'zero dispatch candidates retain uncertainty in a closed hierarchy',
    () async {
      await _verify(
        '''
sealed class Base { void run() {} }
final class Implementation extends Base {
  @override
  void run() { throw 'override'; }
}
void entry(Base input) => input.run();
''',
        (summaries, _) {
          final entry = summaries['entry']!;
          expect(entry.hasUnknownEffects, isTrue);
          expect(entry.truncationReason, 'max_dispatch_candidates');
          expect(entry.exceptionTypes, isEmpty);
        },
        options: const ExceptionAnalysisOptions(maxDispatchCandidates: 0),
      );
    },
  );

  test('the call depth budget also bounds lazy getter initializers', () async {
    await _verify(
      '''
final String first = second;
final String second = throw 'initializer failure';
String entry() => first;
''',
      (summaries, _) {
        final entry = summaries['entry']!;
        expect(entry.hasUnknownEffects, isTrue);
        expect(entry.truncationReason, 'max_call_depth');
        expect(entry.exceptionTypes, isEmpty);
      },
      options: const ExceptionAnalysisOptions(maxCallDepth: 0),
    );
  });

  test(
    'top-level accessor bodies use the same AST view as inference',
    () async {
      await _verify(
        '''
int get value => throw 'getter';
set value(int next) { throw false; }
int read() => value;
void write() { value = 1; }
''',
        (summaries, _) {
          expect(summaries['read']!.exceptionTypes.toSet(), {'String'});
          expect(summaries['write']!.exceptionTypes.toSet(), {'bool'});
        },
      );
    },
  );

  test(
    'forwarding proof accepts immediate async adoption and rejects delayed, mutation, virtual, cyclic, dynamic and side effect bodies',
    () async {
      await _verify(
        '''
Future<void> good(Future<void> input) => input;
Future<void> asyncReturn(Future<void> input) async => input;
Future<void> bridge(Future<void> input) => asyncReturn(input);
Future<void> asyncAwait(Future<void> input) async => await (input);
Future<void> asyncStatement(Future<void> input) async { await input; }
Future<void> asyncDelegate(Future<void> input) async { return await asyncReturn(input); }
Future<void> delayedBad(Future<void> input) async {
  await Future<void>.delayed(Duration.zero); return input;
}
Future<void> asyncWork(Future<void> input) async { print('work'); return input; }
Future<void> asyncCatch(Future<void> input) async { try { await input; } catch (_) {} }
Future<void> asyncFinally(Future<void> input) async { try { return await input; } finally { print('cleanup'); } }
Future<void> mutation(Future<void> input) { input = Future<void>.value(); return input; }
Future<void> sideEffect(Future<void> input) { print('side effect'); return input; }
Future<void> cycle(Future<void> input) => cycle(input);
class Virtual { Future<void> pass(Future<void> input) => input; }
Future<dynamic> dynamicBad(Future<dynamic> input) => input;
void calls(Future<void> input, Virtual instance, Future<dynamic> unknown) {
  good(input); bridge(input); asyncReturn(input); asyncAwait(input); asyncStatement(input);
  asyncDelegate(input); delayedBad(input); asyncWork(input); asyncCatch(input);
  asyncFinally(input); mutation(input); sideEffect(input);
  cycle(input); instance.pass(input); dynamicBad(unknown);
}
''',
        (_, unit) {
          final calls = _Calls();
          unit.unit.accept(calls);
          for (final call in calls.items.where(
            (c) => c.parent is ExpressionStatement,
          )) {
            expect(
              forwardedFutureArgument(call) != null,
              [
                'good',
                'asyncReturn',
                'bridge',
                'asyncAwait',
                'asyncStatement',
                'asyncDelegate',
              ].contains(call.methodName.name),
              reason: call.toSource(),
            );
            expect(
              forwardedFutureArgument(call, requireIdentity: true) != null,
              call.methodName.name == 'good',
              reason: 'Identity: ${call.toSource()}',
            );
          }
        },
      );
    },
  );

  test(
    'source Future forwarding retains typed failures in caller summaries',
    () async {
      await _verify(
        '''
Future<void> forward(Future<void> input) => input;
Future<void> adopt(Future<void> input) async => await forward(input);
Future<void> contained() async {
  try { await adopt(Future<void>.error('failure')); } on String {}
}
Future<void> escaping() async { await adopt(Future<void>.error('failure')); }
''',
        (summaries, _) {
          expect(summaries['contained']!.hasAnyThrowSource, isFalse);
          expect(summaries['escaping']!.exceptionTypes, contains('String'));
          expect(summaries['escaping']!.hasUnknownEffects, isFalse);
        },
      );
    },
  );

  test(
    'forwarding a recursive Future preserves the active call chain',
    () async {
      await _verify(
        '''
Future<void> pass(Future<void> input) => input;
Future<void> recursive(bool fail) async {
  if (fail) throw 'failure';
  await pass(recursive(fail));
}
Future<void> contained() async {
  try { await recursive(true); } on String {}
}
''',
        (summaries, _) {
          expect(summaries['recursive']!.exceptionTypes, contains('String'));
          expect(summaries['contained']!.hasAnyThrowSource, isFalse);
        },
      );
    },
  );
  test(
    'immediate local awaits preserve types and protect at the await',
    () async {
      await _verify(
        '''
Future<void> load() async { throw 'future failure'; }
Future<void> beforeFuture() { throw 3; }
Future<void> escaped() async { final pending = load(); await pending; }
Future<void> caught() async {
  final pending = (load());
  try { await (pending); } on String {}
}
Future<void> beforeAwait() async {
  final pending = beforeFuture();
  try { await pending; } on int {}
}
Future<void> unknown(Future<void> input) async {
  final pending = input;
  try { await pending; } on String {}
}
''',
        (summaries, _) {
          expect(summaries['escaped']!.exceptionTypes.toSet(), {'String'});
          expect(summaries['escaped']!.hasUnknownEffects, isFalse);
          expect(summaries['caught']!.hasAnyThrowSource, isFalse);
          expect(summaries['beforeAwait']!.exceptionTypes.toSet(), {'int'});
          expect(summaries['unknown']!.hasUnknownEffects, isTrue);
        },
      );
    },
  );
}

extension on ThrowSummary {
  Iterable<String> get exceptionTypes =>
      sources.expand((s) => s.exceptionTypes);
}

Future<void> _verify(
  String content,
  void Function(Map<String, ThrowSummary>, ResolvedUnitResult) verify, {
  ExceptionAnalysisOptions options = const ExceptionAnalysisOptions(),
}) async {
  final directory = await Directory.systemTemp.createTemp('flow-dispatch-');
  AnalysisContextCollection? collection;
  try {
    final file = File('${directory.path}/main.dart');
    await file.writeAsString(content);
    collection = AnalysisContextCollection(includedPaths: [directory.path]);
    final unit =
        await collection
                .contextFor(file.path)
                .currentSession
                .getResolvedUnit(file.path)
            as ResolvedUnitResult;
    expect(unit.diagnostics.where((d) => d.severity.name == 'error'), isEmpty);
    final dependencies = ResolvedDependencies(unit.libraryElement);
    final analyzer = InferredThrowAnalyzer(
      manifest: ThrowingApiManifest.empty(),
      options: options,
      featureSet: unit.libraryElement.featureSet,
      packageRootPath: directory.path,
      knownUnits: {file.path: unit.unit},
      resolveDependency: dependencies.resolve,
      resolutionIsCurrent: () => dependencies.isCurrent,
    );
    verify({
      for (final declaration
          in unit.unit.declarations.whereType<FunctionDeclaration>())
        declaration.name.lexeme: analyzer.summarizeExecutable(
          declaration.declaredFragment!.element,
        ),
    }, unit);
  } finally {
    await collection?.dispose();
    await directory.delete(recursive: true);
  }
}

final class _Calls extends RecursiveAstVisitor<void> {
  final items = <MethodInvocation>[];
  @override
  void visitMethodInvocation(MethodInvocation node) {
    items.add(node);
    super.visitMethodInvocation(node);
  }
}
