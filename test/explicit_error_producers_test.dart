import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:dart_exception_lint/src/engine/callback_values.dart';
import 'package:dart_exception_lint/src/engine/error_producers.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Explicit producers use native SDK identities and inherited members',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'producer-matrix-',
      );
      AnalysisContextCollection? collection;
      try {
        await File('${directory.path}/lookalikes.dart').writeAsString('''
class Future { Future.error(Object error); }
class Stream { Stream.error(Object error); }
class Error { static void throwWithStackTrace(Object error, StackTrace stack) {} }
class Completer { void completeError(Object error) {} }
class EventSink { void addError(Object error) {} }
class Zone { void handleUncaughtError(Object error, StackTrace stack) {} }
class MultiStreamController { void addErrorSync(Object error) {} }
''');
        final file = File('${directory.path}/main.dart');
        await file.writeAsString('''
import 'dart:async';
import 'dart:io';
import 'lookalikes.dart' as fake;
void throwStack() => Error.throwWithStackTrace('e', StackTrace.empty);
Future<int> futureError() => Future<int>.error('e');
Stream<int> streamError() => Stream<int>.error('e');
void complete(Completer<int> value) => value.completeError('e');
void eventSink(EventSink<int> value) => value.addError('e');
void streamSink(StreamSink<int> value) => value.addError('e');
void streamController(StreamController<int> value) => value.addError('e');
void synchronousController(SynchronousStreamController<int> value) => value.addError('e');
void multiController(MultiStreamController<int> value) => value.addError('e');
void multiSync(MultiStreamController<int> value) => value.addErrorSync('e');
void zone(Zone value) => value.handleUncaughtError('e', StackTrace.empty);
void zoneDelegate(ZoneDelegate value) => value.handleUncaughtError(Zone.current, 'e', StackTrace.empty);
void ioSink(IOSink value) => value.addError('e');
void socket(Socket value) => value.addError('e');
void output(Stdout value) => value.addError('e');
Error errorValue() => Error();
Exception exceptionValue() => Exception('e');
AsyncError asyncErrorValue() => AsyncError('e', null);
ArgumentError argumentValue() => ArgumentError('e');
Object nullGuard(Object? value) => ArgumentError.checkNotNull(value);
int rangeGuard(int value) => RangeError.checkNotNegative(value);
int intervalGuard(int value) => RangeError.checkValueInInterval(value, 0, 1);
int indexGuard(int value) => RangeError.checkValidIndex(value, [1]);
int spanGuard(int value) => RangeError.checkValidRange(value, 1, 1);
int indexErrorGuard(int value) => IndexError.check(value, 1);
AsyncError? zoneIntercept(Zone value) => value.errorCallback('e', null);
void fakeFuture() { fake.Future.error('e'); }
void fakeStream() { fake.Stream.error('e'); }
void fakeError() => fake.Error.throwWithStackTrace('e', StackTrace.empty);
void fakeCompleter(fake.Completer value) => value.completeError('e');
void fakeSink(fake.EventSink value) => value.addError('e');
void fakeZone(fake.Zone value) => value.handleUncaughtError('e', StackTrace.empty);
void fakeMulti(fake.MultiStreamController value) => value.addErrorSync('e');
void references() {
  final futureReference = Future<int>.error;
  final streamReference = Stream<int>.error;
  final stackReference = Error.throwWithStackTrace;
}
''');
        collection = AnalysisContextCollection(includedPaths: [directory.path]);
        final result =
            await collection
                    .contextFor(file.path)
                    .currentSession
                    .getResolvedUnit(file.path)
                as ResolvedUnitResult;
        expect(
          result.diagnostics.where(
            (diagnostic) => diagnostic.diagnosticCode.severity.name == 'ERROR',
          ),
          isEmpty,
        );
        final declarations = result.unit.declarations
            .whereType<FunctionDeclaration>();
        final expected = {
          'throwStack': 'Error.throwWithStackTrace',
          'futureError': 'Future.error',
          'streamError': 'Stream.error',
          'complete': 'Completer.completeError',
          'eventSink': 'EventSink.addError',
          'streamSink': 'EventSink.addError',
          'streamController': 'StreamController.addError',
          'synchronousController': 'SynchronousStreamController.addError',
          'multiController': 'StreamController.addError',
          'multiSync': 'MultiStreamController.addErrorSync',
          'zone': 'Zone.handleUncaughtError',
          'zoneDelegate': 'ZoneDelegate.handleUncaughtError',
          'ioSink': 'IOSink.addError',
          'socket': 'Socket.addError',
          'output': 'IOSink.addError',
        };
        for (final declaration in declarations.where(
          (declaration) => declaration.name.lexeme != 'references',
        )) {
          final calls = _NativeCalls();
          declaration.functionExpression.body.accept(calls);
          expect(calls.elements, hasLength(1), reason: declaration.name.lexeme);
          final producer = explicitErrorProducer(calls.elements.single);
          final displayName = expected[declaration.name.lexeme];
          if (displayName == null) {
            expect(producer, isNull, reason: declaration.name.lexeme);
          } else {
            expect(producer, isNotNull, reason: declaration.name.lexeme);
            expect(
              producer!.displayName,
              displayName,
              reason: declaration.name.lexeme,
            );
            expect(
              explicitErrorProducer(
                calls.elements.single?.baseElement,
              )?.displayName,
              displayName,
              reason: 'Base declaration: ${declaration.name.lexeme}',
            );
          }
        }
        final references = _References();
        result.unit.accept(references);
        final resolver = CallbackValueResolver(
          resolvedUnits: {file.path: result.unit},
        );
        for (final entry in {
          'futureReference': 'Future.error',
          'streamReference': 'Stream.error',
          'stackReference': 'Error.throwWithStackTrace',
        }.entries) {
          final value = resolver.forElement(
            references.variables[entry.key]!.declaredFragment!.element,
          );
          expect(value.hasUnknown, isFalse, reason: entry.key);
          expect(value.targets, hasLength(1), reason: entry.key);
          expect(
            explicitErrorProducer(value.targets.single)?.displayName,
            entry.value,
            reason: entry.key,
          );
        }
        expect(explicitErrorProducer(null), isNull);
      } finally {
        await collection?.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
}

final class _NativeCalls extends RecursiveAstVisitor<void> {
  final List<Element?> elements = [];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    elements.add(node.methodName.element);
    super.visitMethodInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    elements.add(node.constructorName.element);
    super.visitInstanceCreationExpression(node);
  }
}

final class _References extends RecursiveAstVisitor<void> {
  final Map<String, VariableDeclaration> variables = {};

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    variables[node.name.lexeme] = node;
    super.visitVariableDeclaration(node);
  }
}
