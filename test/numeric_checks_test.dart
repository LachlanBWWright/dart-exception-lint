import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:dart_exception_lint/src/analysis/throw_summary.dart';
import 'package:dart_exception_lint/src/engine/callback_values.dart';
import 'package:dart_exception_lint/src/engine/numeric_checks.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Native numeric and BigInt checks preserve backend errors and constant safety',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'numeric-checks-',
      );
      AnalysisContextCollection? collection;
      try {
        await File('${directory.path}/lookalikes.dart').writeAsString('''
class BigInt {
  BigInt operator ~/(BigInt value) => value;
  BigInt pow(int value) => this;
  int toInt() => 1;
}
class num {
  int operator ~/(int value) => value;
  int operator %(int value) => value;
  int operator <<(int value) => value;
  int toInt() => 1;
  int round() => 1;
  int remainder(int value) => value;
  int clamp(int lower, int upper) => lower;
  int toSigned(int width) => width;
  int modPow(int exponent, int modulus) => modulus;
  String toStringAsFixed(int digits) => '';
  String toRadixString(int radix) => '';

}
class Random {
  static Random secure() => Random();
  int nextInt(int maximum) => maximum;
}
''');
        final file = File('${directory.path}/main.dart');
        await file.writeAsString('''
import 'lookalikes.dart' as fake;
import 'dart:math';
const zero = 0;
const two = 2;
const negative = -1;
const finite = 2.0;
int intZero(int value) => value ~/ zero;
int mixedZero(int value) => value ~/ 0.0;
int floatUnknown(double value) => value ~/ two;
int mixedOverflow() => 2 ~/ 1e-308;
int floatInfinity() => double.infinity ~/ 1.0;
int intSafe(int value) => value ~/ two;
int doublesSafe() => 8.0 ~/ 2.0;
int largeFiniteSafe() => 1e308 ~/ 1.0;
num intModulo(int value) => value % zero;
num floatingModulo(double value) => value % zero;
num mixedModulo(int value) => value % 0.0;
num moduloSafe(int value) => value % two;
int leftShift(int value) => value << negative;
int rightShift(int value, int amount) => value >> amount;
int unsignedShift(int value) => value >>> negative;
int shiftSafe(int value) => value << two;
int compoundDivide(int value, int divisor) { value ~/= divisor; return value; }
int compoundMixed(int value, double divisor) { value ~/= divisor; return value; }
int compoundModulo(int value, int divisor) { value %= divisor; return value; }
int compoundShift(int value, int amount) { value >>>= amount; return value; }
int compoundSafe(int value) { value <<= two; return value; }
int dynamicDivide(int value, dynamic divisor) => value ~/ divisor;
num dynamicModulo(int value, dynamic divisor) => value % divisor;
int dynamicShift(int value, dynamic amount) => value << amount;
int compoundDynamic(int value, dynamic divisor) { value ~/= divisor; return value; }
int convertUnknown(double value) => value.toInt();
int roundUnknown(num value) => value.round();
int floorUnknown(double value) => value.floor();
int ceilUnknown(double value) => value.ceil();
int truncateUnknown(double value) => value.truncate();
int convertInteger(int value) => value.toInt();
int roundInteger(int value) => value.round();
int convertFinite() => finite.toInt();
int floorFinite() => finite.floor();
int convertLargeFinite() => (1e308).toInt();
double roundNonfiniteToDouble() => double.infinity.roundToDouble();
double floorNonfiniteToDouble() => double.nan.floorToDouble();
double ceilNonfiniteToDouble() => double.infinity.ceilToDouble();
double truncateNonfiniteToDouble() => double.nan.truncateToDouble();
double toDoubleSafe(double value) => value.toDouble();
int wrongIntArity(int value) { Function convert = value.round; return convert(0); }
int wrongFloatArity(double value) { Function convert = value.toInt; return convert(0); }
double wrongDoubleNamed(double value) { Function convert = value.toDouble; return convert(unexpected: 0); }
double wrongDoubleArity(double value) { Function convert = value.roundToDouble; return convert(0); }
num remainderZero(int value) => value.remainder(zero);
num remainderSafe(int value) => value.remainder(two);
double remainderFloating(double value) => value.remainder(zero);
num remainderDynamic(int value, dynamic divisor) => value.remainder(divisor);
int unsignedUnknown(int value, int width) => value.toUnsigned(width);
int unsignedZero(int value) => value.toUnsigned(zero);
int signedZero(int value) => value.toSigned(zero);
int signedSafe(int value) => value.toSigned(two);
int modularUnknown(int value, int exponent, int modulus) => value.modPow(exponent, modulus);
int modularSafe() => 2.modPow(1, two);
int modularHugeReceiver() => 9007199254740992.modPow(1, two);
int modularHugeExponent() => 2.modPow(9007199254740992, two);
int modularHugeModulus() => 2.modPow(1, 9007199254740992);
int modularZeroExponent(int value) => value.modPow(zero, two);
int inverseUnknown(int value, int modulus) => value.modInverse(modulus);
int inverseNonCoprime() => 2.modInverse(two);
int inverseSafe() => 1.modInverse(two);
int inverseUnitModulus(int value) => value.modInverse(1);
num clampUnknown(num value, num lower, num upper) => value.clamp(lower, upper);
num clampSafe(num value) => value.clamp(0, two);
num clampReverse(num value) => value.clamp(two, 0);
num clampNaNLower(num value) => value.clamp(double.nan, two);
num clampNaNUpper(num value) => value.clamp(two, double.nan);
num clampNaNBoth(num value) => value.clamp(double.nan, double.nan);
num clampSignedZeroReverse(num value) => value.clamp(0.0, -0.0);
num clampSignedZeroSafe(num value) => value.clamp(-0.0, 0.0);
num clampDynamic(num value, dynamic lower) => value.clamp(lower, two);
String radixUnknown(int value, int radix) => value.toRadixString(radix);
String radixInvalid(int value) => value.toRadixString(1);
String radixSafe(int value) => value.toRadixString(36);
String fixedUnknown(num value, int digits) => value.toStringAsFixed(digits);
String fixedInvalid() => double.infinity.toStringAsFixed(21);
String fixedSafe(num value) => value.toStringAsFixed(20);
String exponentialUnknown(double value, int? digits) => value.toStringAsExponential(digits);
String exponentialOmitted(num value) => value.toStringAsExponential();
String exponentialNull(num value) => value.toStringAsExponential(null);
String precisionInvalid() => double.nan.toStringAsPrecision(zero);
String precisionUnknown(num value, int precision) => value.toStringAsPrecision(precision);
String precisionSafe(num value) => value.toStringAsPrecision(21);
String formattingWrongArity(num value) { Function action = value.toStringAsFixed; return action(); }
String exponentialExtra(num value) { Function action = value.toStringAsExponential; return action(1,2); }
String radixWrongNamed(int value) { Function action = value.toRadixString; return action(radix: 2); }
num userRemainder(fake.num value) => value.remainder(zero);
num userClamp(fake.num value) => value.clamp(two, zero);
int userSigned(fake.num value) => value.toSigned(zero);
int userModular(fake.num value) => value.modPow(-1, zero);
String userFormat(fake.num value) => value.toStringAsFixed(21);
String userRadix(fake.num value) => value.toRadixString(1);
double ordinaryDivide(int value) => value / zero;
double ordinaryDynamicDivide(int value, dynamic divisor) => value / divisor;
double bigFloatingDivide(BigInt value) => value / BigInt.zero;
double bigFloatingDynamicDivide(BigInt value, dynamic divisor) => value / divisor;
BigInt bigDivideZero(BigInt value) => value ~/ BigInt.zero;
BigInt bigDivideUnknown(BigInt value, BigInt divisor) => value ~/ divisor;
BigInt bigDivideSafe(BigInt value) => value ~/ BigInt.two;
BigInt bigModuloZero(BigInt value) => value % BigInt.zero;
BigInt bigModuloSafe(BigInt value) => value % BigInt.one;
BigInt bigLeftNegative(BigInt value) => value << negative;
BigInt bigRightUnknown(BigInt value, int amount) => value >> amount;
BigInt bigShiftSafe(BigInt value) => value << two;
BigInt bigCompoundDivide(BigInt value, BigInt divisor) { value ~/= divisor; return value; }
BigInt bigCompoundShift(BigInt value, int amount) { value >>= amount; return value; }
BigInt bigDynamicDivide(BigInt value, dynamic divisor) => value ~/ divisor;
BigInt bigDynamicShift(BigInt value, dynamic amount) => value << amount;
BigInt bigDynamicIntDivisor(BigInt value) { const dynamic divisor = 1; return value ~/ divisor; }
BigInt bigRemainderZero(BigInt value) => value.remainder(BigInt.zero);
BigInt bigRemainderSafe(BigInt value) => value.remainder(BigInt.two);
BigInt bigPowNegative(BigInt value) => value.pow(negative);
BigInt bigPowSafe(BigInt value) => value.pow(two);
BigInt bigPowDynamic(BigInt value, dynamic exponent) => value.pow(exponent);
BigInt bigModPowUnknown(BigInt value, BigInt exponent, BigInt modulus) => value.modPow(exponent, modulus);
BigInt bigModPowSafe(BigInt value) => value.modPow(BigInt.zero, BigInt.two);
BigInt bigInverseNonCoprime() => BigInt.two.modInverse(BigInt.two);
BigInt bigInverseSafe() => BigInt.one.modInverse(BigInt.two);
BigInt bigModPowZeroModulus(BigInt value) => value.modPow(BigInt.one, BigInt.zero);
BigInt bigInverseUnknown(BigInt value, BigInt modulus) => value.modInverse(modulus);
BigInt bigUnsignedNegative(BigInt value) => value.toUnsigned(negative);
BigInt bigUnsignedUnknown(BigInt value, int width) => value.toUnsigned(width);
BigInt bigUnsignedZero(BigInt value) => value.toUnsigned(zero);
BigInt bigSignedZero(BigInt value) => value.toSigned(zero);
BigInt bigSignedUnknown(BigInt value, int width) => value.toSigned(width);
BigInt bigSignedSafe(BigInt value) => value.toSigned(two);
String bigRadixUnknown(BigInt value, int radix) => value.toRadixString(radix);
String bigRadixInvalid(BigInt value) => value.toRadixString(1);
String bigRadixSafe(BigInt value) => value.toRadixString(36);
String bigRadixDynamic(BigInt value, dynamic radix) => value.toRadixString(radix);
BigInt bigFromUnknown(num value) => BigInt.from(value);
BigInt bigFromIntegerUnknown(int value) => BigInt.from(value);
BigInt bigFromFinite() => BigInt.from(finite);
BigInt bigFromInfinity() => BigInt.from(double.infinity);
BigInt bigFromDynamic(dynamic value) => BigInt.from(value);
int bigToInt(BigInt value) => value.toInt();
double bigToDouble(BigInt value) => value.toDouble();
int bigHugeToInt() { final huge = BigInt.one << 10000; return huge.toInt(); }
BigInt bigWrongPowMissing(BigInt value) { Function action = value.pow; return action(); }
BigInt bigWrongInverseExtra(BigInt value) { Function action = value.modInverse; return action(BigInt.one, BigInt.two); }
BigInt bigWrongNamed(BigInt value) { Function action = value.toUnsigned; return action(width: 1); }
int bigWrongConversion(BigInt value) { Function action = value.toInt; return action(1); }
fake.BigInt userBigDivide(fake.BigInt value) => value ~/ value;
fake.BigInt userBigPow(fake.BigInt value) => value.pow(negative);
int userBigConversion(fake.BigInt value) => value.toInt();
int userDivide(fake.num value) => value ~/ zero;
int userModulo(fake.num value) => value % zero;
int userShift(fake.num value) => value << negative;
int userConversion(fake.num value) => value.toInt();
int userRound(fake.num value) => value.round();
int randomNextIntPositive() => Random().nextInt(12);
int randomNextIntMaximum() => Random().nextInt(4294967296);
int randomNextIntZero() => Random().nextInt(0);
int randomNextIntNegative() => Random().nextInt(-1);
int randomNextIntTooLarge() => Random().nextInt(4294967297);
int randomNextIntUnknown(int maximum) => Random().nextInt(maximum);
Random randomSecureFactory() => Random.secure();
fake.Random userRandomSecureLookalike() => fake.Random.secure();
int userRandomNextInt(UserRandom random) => random.nextInt(0);
int randomInterfaceCustom(Random random) => random.nextInt(0);
class UserRandom implements Random {
  int nextInt(int maximum) => maximum;
  bool nextBool() => false;
  double nextDouble() => 0.0;
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
        final expected = <String, Set<String>>{
          'remainderZero': {'IntegerDivisionByZeroException'},
          'remainderDynamic': {'IntegerDivisionByZeroException', 'TypeError'},
          'unsignedUnknown': {'ArgumentError'},
          'signedZero': {'ArgumentError'},
          'modularUnknown': {'RangeError', 'TypeError'},
          'modularHugeReceiver': {'RangeError'},
          'modularHugeExponent': {'RangeError'},
          'modularHugeModulus': {'RangeError'},
          'inverseUnknown': {'RangeError', 'Exception', 'TypeError'},
          'inverseNonCoprime': {'Exception'},
          'clampUnknown': {'ArgumentError'},
          'clampReverse': {'ArgumentError'},
          'clampNaNLower': {'ArgumentError'},
          'clampSignedZeroReverse': {'ArgumentError'},
          'clampDynamic': {'ArgumentError', 'TypeError'},
          'radixUnknown': {'RangeError', 'ArgumentError'},
          'radixInvalid': {'RangeError'},
          'fixedUnknown': {'RangeError', 'TypeError'},
          'fixedInvalid': {'RangeError'},
          'exponentialUnknown': {'RangeError'},
          'precisionInvalid': {'RangeError'},
          'precisionUnknown': {'RangeError', 'ArgumentError'},
          'formattingWrongArity': {'NoSuchMethodError'},
          'exponentialExtra': {'NoSuchMethodError'},
          'radixWrongNamed': {'NoSuchMethodError'},
          'ordinaryDynamicDivide': {'TypeError'},
          'bigFloatingDynamicDivide': {'TypeError'},
          'bigDivideZero': {'IntegerDivisionByZeroException'},
          'bigDivideUnknown': {'IntegerDivisionByZeroException'},
          'bigModuloZero': {'IntegerDivisionByZeroException'},
          'bigLeftNegative': {'ArgumentError'},
          'bigRightUnknown': {'ArgumentError', 'UnsupportedError'},
          'bigCompoundDivide': {'IntegerDivisionByZeroException'},
          'bigCompoundShift': {'ArgumentError', 'UnsupportedError'},
          'bigDynamicDivide': {'IntegerDivisionByZeroException', 'TypeError'},
          'bigDynamicShift': {'ArgumentError', 'TypeError'},
          'bigDynamicIntDivisor': {
            'IntegerDivisionByZeroException',
            'TypeError',
          },
          'bigRemainderZero': {'IntegerDivisionByZeroException'},
          'bigPowNegative': {'ArgumentError'},
          'bigPowDynamic': {'ArgumentError', 'TypeError'},
          'bigModPowUnknown': {'ArgumentError'},
          'bigInverseNonCoprime': {'Exception'},
          'bigModPowZeroModulus': {'ArgumentError'},
          'bigInverseUnknown': {'ArgumentError', 'Exception'},
          'bigUnsignedNegative': {'ArgumentError'},
          'bigUnsignedUnknown': {'ArgumentError', 'UnsupportedError'},
          'bigSignedZero': {'ArgumentError'},
          'bigSignedUnknown': {'ArgumentError', 'UnsupportedError'},
          'bigRadixUnknown': {'RangeError'},
          'bigRadixInvalid': {'RangeError'},
          'bigRadixDynamic': {'RangeError', 'TypeError'},
          'bigFromUnknown': {'ArgumentError'},
          'bigFromIntegerUnknown': {'ArgumentError'},
          'bigFromInfinity': {'ArgumentError'},
          'bigFromDynamic': {'ArgumentError', 'TypeError'},
          'bigWrongPowMissing': {'NoSuchMethodError'},
          'bigWrongInverseExtra': {'NoSuchMethodError'},
          'bigWrongNamed': {'NoSuchMethodError'},
          'bigWrongConversion': {'NoSuchMethodError'},
          'intZero': {'IntegerDivisionByZeroException', 'UnsupportedError'},
          'mixedZero': {'UnsupportedError'},
          'floatUnknown': {'UnsupportedError'},
          'mixedOverflow': {'UnsupportedError'},
          'floatInfinity': {'UnsupportedError'},
          'intModulo': {'IntegerDivisionByZeroException'},
          'leftShift': {'ArgumentError'},
          'rightShift': {'ArgumentError'},
          'unsignedShift': {'ArgumentError'},
          'compoundDivide': {
            'IntegerDivisionByZeroException',
            'UnsupportedError',
          },
          'compoundMixed': {'UnsupportedError'},
          'compoundModulo': {'IntegerDivisionByZeroException'},
          'compoundShift': {'ArgumentError'},
          'dynamicDivide': {
            'IntegerDivisionByZeroException',
            'UnsupportedError',
            'TypeError',
          },
          'dynamicModulo': {'IntegerDivisionByZeroException', 'TypeError'},
          'dynamicShift': {'ArgumentError', 'TypeError'},
          'compoundDynamic': {
            'IntegerDivisionByZeroException',
            'UnsupportedError',
            'TypeError',
          },
          'convertUnknown': {'UnsupportedError'},
          'roundUnknown': {'UnsupportedError'},
          'floorUnknown': {'UnsupportedError'},
          'ceilUnknown': {'UnsupportedError'},
          'truncateUnknown': {'UnsupportedError'},
          'wrongIntArity': {'NoSuchMethodError'},
          'wrongFloatArity': {'NoSuchMethodError'},
          'wrongDoubleNamed': {'NoSuchMethodError'},
          'wrongDoubleArity': {'NoSuchMethodError'},
          'randomNextIntZero': {'RangeError'},
          'randomNextIntNegative': {'RangeError'},
          'randomNextIntTooLarge': {'RangeError'},
          'randomNextIntUnknown': {'RangeError'},
          'randomSecureFactory': {'UnsupportedError'},
        };
        for (final declaration
            in result.unit.declarations.whereType<FunctionDeclaration>()) {
          final operations = _Operations(
            CallbackValueResolver(resolvedUnits: {file.path: result.unit}),
          );
          declaration.functionExpression.body.accept(operations);
          final name = declaration.name.lexeme;
          expect(
            operations.sources,
            hasLength(
              declaration.name.lexeme == 'bigHugeToInt' ||
                      name.startsWith('randomNextInt')
                  ? 2
                  : 1,
            ),
            reason: name,
          );
          if (declaration.name.lexeme == 'bigHugeToInt') {
            expect(operations.modeled, everyElement(isTrue));
            expect(operations.sources, everyElement(isNull));
            continue;
          }
          final randomFactoryCall = name.startsWith('randomNextInt');
          if (randomFactoryCall) {
            expect(operations.modeled.first, isTrue, reason: name);
            expect(operations.modeled.last, isFalse, reason: name);
          }
          final source = randomFactoryCall
              ? operations.sources.first
              : operations.sources.single;
          if (name == 'randomInterfaceCustom') {
            expect(operations.modeled.single, isFalse, reason: name);
            expect(source, isNull, reason: name);
            continue;
          }
          final modeled = randomFactoryCall
              ? operations.modeled.first
              : operations.modeled.single;
          if (name.startsWith('user')) {
            expect(modeled, isFalse, reason: name);
          } else {
            expect(modeled, isTrue, reason: name);
          }
          final types = expected[declaration.name.lexeme];
          if (types == null) {
            expect(source, isNull, reason: declaration.name.lexeme);
          } else {
            expect(source, isNotNull, reason: declaration.name.lexeme);
            expect(
              source!.exceptionTypes.toSet(),
              types,
              reason: declaration.name.lexeme,
            );
            expect(
              source.resolvedExceptionTypes
                  .map((type) => type.element?.name)
                  .toSet(),
              types,
              reason: 'Native types: ${declaration.name.lexeme}',
            );
            if (types.contains('RangeError')) {
              expect(
                source.exceptionSupertypes['RangeError'],
                containsAll(['ArgumentError', 'Error']),
                reason: 'Range catch hierarchy: $name',
              );
            }
            if (types.contains('Exception')) {
              expect(
                source.exceptionSupertypes['Exception'],
                isNot(contains('Error')),
                reason: 'Inverse failure hierarchy: $name',
              );
            }
            if (types.contains('IntegerDivisionByZeroException')) {
              expect(
                source.exceptionSupertypes['IntegerDivisionByZeroException'],
                containsAll(['Exception', 'UnsupportedError', 'Error']),
                reason: 'Catch hierarchy: ${declaration.name.lexeme}',
              );
            }
          }
        }
      } finally {
        await collection?.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
}

final class _Operations extends RecursiveAstVisitor<void> {
  _Operations(this.resolver);

  final CallbackValueResolver resolver;
  final List<ThrowSource?> sources = [];
  final List<bool> modeled = [];

  @override
  void visitBinaryExpression(BinaryExpression node) {
    sources.add(NumericChecks.binary(node));
    modeled.add(NumericChecks.modelsBinary(node));
    super.visitBinaryExpression(node);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    sources.add(NumericChecks.assignment(node));
    modeled.add(NumericChecks.modelsAssignment(node));
    super.visitAssignmentExpression(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final target = node.constructorName.element;
    sources.add(NumericChecks.invocation(node, target));
    modeled.add(NumericChecks.modelsInvocation(node, target));
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    sources.add(NumericChecks.invocation(node, node.methodName.element));
    modeled.add(NumericChecks.modelsInvocation(node, node.methodName.element));
    super.visitMethodInvocation(node);
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    final target = resolver.resolveInvocation(node).targets.single;
    sources.add(NumericChecks.invocation(node, target));
    modeled.add(NumericChecks.modelsInvocation(node, target));
    super.visitFunctionExpressionInvocation(node);
  }
}
