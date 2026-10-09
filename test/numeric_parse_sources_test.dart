import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:dart_exception_lint/src/analysis/throw_source_catalog.dart';
import 'package:dart_exception_lint/src/config/exception_analysis_options.dart';
import 'package:test/test.dart';

void main() {
  test(
    'numeric parse sources distinguish parse, tryParse, and lookalikes',
    () async {
      final directory = await Directory.systemTemp.createTemp('numeric-parse-');
      AnalysisContextCollection? collection;
      try {
        final file = File('${directory.path}/main.dart');
        await File('${directory.path}/lookalikes.dart').writeAsString('''
class BigInt {
  static BigInt parse(String source, {int? radix}) => BigInt();
  static BigInt? tryParse(String source, {int? radix}) => null;
}
class num {
  static num parse(String source) => num();
  static num? tryParse(String source) => null;
}
class double {
  static double parse(String source) => double();
  static double? tryParse(String source) => null;
}
''');
        await file.writeAsString('''
import 'lookalikes.dart' as fake;
void numericParsers(String input, int radix, dynamic dynamicRadix,
    dynamic dynamicText) {
  final malformedInt = int.parse('bad');
  final validInt = int.parse('123');
  final invalidIntRadix = int.parse('10', radix: 1);
  final unknownIntRadix = int.parse(input, radix: radix);
  final intTry = int.tryParse(input, radix: radix);
  final malformedIntTry = int.tryParse('bad', radix: 10);
  final invalidIntTryRadix = int.tryParse('10', radix: 1);
  final unknownIntTryRadix = int.tryParse(input, radix: radix);
  final dynamicIntTryText = int.tryParse(dynamicText);
  final dynamicIntTryRadix = int.tryParse('10', radix: dynamicRadix);
  final malformedBig = BigInt.parse('bad');
  final validBig = BigInt.parse('123');
  final invalidBigRadix = BigInt.parse('10', radix: 1);
  final unknownBigRadix = BigInt.parse(input, radix: radix);
  final bigTry = BigInt.tryParse(input, radix: radix);
  final malformedBigTry = BigInt.tryParse('bad', radix: 10);
  final invalidBigTryRadix = BigInt.tryParse('10', radix: 1);
  final unknownBigTryRadix = BigInt.tryParse(input, radix: radix);
  final dynamicBigTryText = BigInt.tryParse(dynamicText);
  final dynamicBigTryRadix = BigInt.tryParse('10', radix: dynamicRadix);
  final malformedNum = num.parse('bad');
  final validNum = num.parse('1.25');
  final numTry = num.tryParse(input);
  final malformedDouble = double.parse('bad');
  final validDouble = double.parse('1.25');
  final doubleTry = double.tryParse(input);
  final dynamicIntText = int.parse(dynamicText);
  final dynamicIntRadix = int.parse('10', radix: dynamicRadix);
  final dynamicBigText = BigInt.parse(dynamicText);
  final dynamicBigRadix = BigInt.parse('10', radix: dynamicRadix);
  final dynamicNumText = num.parse(dynamicText);
  final dynamicDoubleText = double.parse(dynamicText);
  final fakeBig = fake.BigInt.tryParse(input);
  final fakeNum = fake.num.parse(input);
  final fakeDouble = fake.double.parse(input);
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
        final visitor = _ParseCalls();
        result.unit.accept(visitor);
        const options = ExceptionAnalysisOptions();
        final expected = <String, Set<String>?>{
          'malformedInt': {'FormatException'},
          'validInt': null,
          'invalidIntRadix': {'RangeError'},
          'unknownIntRadix': {'FormatException', 'RangeError'},
          'intTry': {'RangeError'},
          'invalidIntTryRadix': {'RangeError'},
          'unknownIntTryRadix': {'RangeError'},
          'dynamicIntTryText': {'TypeError'},
          'dynamicIntTryRadix': {'TypeError', 'RangeError'},
          'malformedBig': {'FormatException'},
          'validBig': null,
          'invalidBigRadix': {'RangeError'},
          'unknownBigRadix': {'FormatException', 'RangeError'},
          'bigTry': {'RangeError'},
          'invalidBigTryRadix': {'RangeError'},
          'unknownBigTryRadix': {'RangeError'},
          'dynamicBigTryText': {'TypeError'},
          'dynamicBigTryRadix': {'TypeError', 'RangeError'},
          'malformedNum': {'FormatException'},
          'validNum': null,
          'malformedDouble': {'FormatException'},
          'validDouble': null,
          'dynamicIntText': {'FormatException', 'TypeError'},
          'dynamicIntRadix': {'RangeError', 'TypeError'},
          'dynamicBigText': {'FormatException', 'TypeError'},
          'dynamicBigRadix': {'RangeError', 'TypeError'},
          'dynamicNumText': {'FormatException', 'TypeError'},
          'dynamicDoubleText': {'FormatException', 'TypeError'},
        };
        for (final call in visitor.calls) {
          final source = ThrowSourceCatalog.matchResolvedInvocation(
            call,
            call.methodName.element,
            options,
          );
          var parent = call.parent;
          while (parent != null && parent is! VariableDeclaration) {
            parent = parent.parent;
          }
          final name = parent is VariableDeclaration
              ? parent.name.lexeme
              : call.methodName.name;
          final types = expected[name];
          if (types == null) {
            expect(source, isNull, reason: name);
          } else {
            expect(source, isNotNull, reason: name);
            expect(source!.exceptionTypes.toSet(), types, reason: name);
          }
        }
        expect(visitor.calls, hasLength(35));
      } finally {
        await collection?.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
}

final class _ParseCalls extends RecursiveAstVisitor<void> {
  final List<MethodInvocation> calls = [];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == 'parse' || node.methodName.name == 'tryParse') {
      calls.add(node);
    }
    super.visitMethodInvocation(node);
  }
}
