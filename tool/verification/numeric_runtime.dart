import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:dart_exception_lint/src/analysis/inferred_throw_analyzer.dart';
import 'package:dart_exception_lint/src/config/exception_analysis_options.dart';
import 'package:dart_exception_lint/src/config/throwing_api_manifest.dart';

/// Independent runtime observations for implicit numeric failures.
Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp('numeric-runtime-');
  AnalysisContextCollection? collection;
  try {
    final file = File('${directory.path}/main.dart');
    await file.writeAsString(numericFixture);
    collection = AnalysisContextCollection(includedPaths: [directory.path]);
    final unit =
        await collection
                .contextFor(file.path)
                .currentSession
                .getResolvedUnit(file.path)
            as ResolvedUnitResult;
    final errors = unit.diagnostics.where(
      (diagnostic) => diagnostic.diagnosticCode.severity.name == 'ERROR',
    );
    if (errors.isNotEmpty) {
      throw StateError('Invalid differential fixture: ${errors.join('\n')}');
    }
    final analyzer = InferredThrowAnalyzer(
      manifest: ThrowingApiManifest.empty(),
      options: const ExceptionAnalysisOptions(),
      featureSet: unit.libraryElement.featureSet,
      packageRootPath: directory.path,
      knownUnits: {file.path: unit.unit},
    );
    for (final entry in numericExpectedTypes.entries) {
      final declaration = unit.unit.declarations
          .whereType<FunctionDeclaration>()
          .singleWhere((function) => function.name.lexeme == entry.key);
      final summary = analyzer.summarizeExecutable(
        declaration.declaredFragment!.element,
      );
      for (final type in entry.value) {
        if (!summary.sources.any(
          (source) => source.exceptionTypes.contains(type),
        )) {
          throw StateError('${entry.key} lost $type');
        }
      }
    }
    for (final name in numericSafeFunctions) {
      final declaration = unit.unit.declarations
          .whereType<FunctionDeclaration>()
          .singleWhere((function) => function.name.lexeme == name);
      if (analyzer
          .summarizeExecutable(declaration.declaredFragment!.element)
          .hasAnyThrowSource) {
        throw StateError(
          '$name lost its literal safety proof or contained effect',
        );
      }
    }
    Future<void> verify(
      String executable,
      List<String> arguments,
      String platform,
      Map<String, String> expected,
    ) async {
      final result = await Process.run(executable, arguments);
      if (result.exitCode != 0) {
        throw StateError('$platform failed: ${result.stderr}');
      }
      final observed = jsonDecode((result.stdout as String).trim());
      if (jsonEncode(observed) != jsonEncode(expected)) {
        throw StateError('$platform observed $observed; expected $expected');
      }
      stdout.writeln(
        '$platform: ${expected.length} numeric observations match.',
      );
    }

    await verify(
      Platform.resolvedExecutable,
      [file.path],
      'Dart VM',
      _vmObservations,
    );
    final output = '${directory.path}/main.js';
    final compile = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'js',
      file.path,
      '-o',
      output,
    ]);
    if (compile.exitCode != 0) {
      throw StateError('JavaScript compilation failed: ${compile.stderr}');
    }
    await verify(
      'node',
      ['-e', 'globalThis.self = globalThis; require(process.argv[1]);', output],
      'Dart JavaScript (Node)',
      _javascriptObservations,
    );
  } finally {
    await collection?.dispose();
    await directory.delete(recursive: true);
  }
}

const numericExpectedTypes = <String, List<String>>{
  'randomSecureFactory': ['UnsupportedError'],
  'randomNextIntZero': ['RangeError'],
  'randomNextIntTooLarge': ['RangeError'],
  'intDivide': ['IntegerDivisionByZeroException', 'UnsupportedError'],
  'numDivide': ['IntegerDivisionByZeroException', 'UnsupportedError'],
  'divideAssign': ['IntegerDivisionByZeroException', 'UnsupportedError'],
  'intModulo': ['IntegerDivisionByZeroException'],
  'moduloAssign': ['IntegerDivisionByZeroException'],
  'numModuloAssign': ['IntegerDivisionByZeroException'],
  'doubleDivide': ['UnsupportedError'],
  'nonfiniteDivide': ['UnsupportedError'],
  'overflowingDivide': ['UnsupportedError'],
  'convert': ['UnsupportedError'],
  'truncateValue': ['UnsupportedError'],
  'roundValue': ['UnsupportedError'],
  'floorValue': ['UnsupportedError'],
  'ceilValue': ['UnsupportedError'],
  'caughtSpecific': ['UnsupportedError'],
  'wrongCatch': ['UnsupportedError'],
  'caughtDynamicDivide': ['TypeError'],
  'caughtDynamicModulo': ['TypeError'],
  'caughtDynamicShift': ['TypeError'],
  'getterCompound': [
    'String',
    'IntegerDivisionByZeroException',
    'UnsupportedError',
  ],
  'setterCompound': [
    'String',
    'IntegerDivisionByZeroException',
    'UnsupportedError',
  ],
  'converterAlias': ['UnsupportedError'],
  'converterWrongArity': ['NoSuchMethodError'],
  'floatingConverterWrongArityCaught': ['NoSuchMethodError'],
  'leftShift': ['ArgumentError'],
  'rightShift': ['ArgumentError'],
  'unsignedShift': ['ArgumentError'],
  'leftAssign': ['ArgumentError'],
  'rightAssign': ['ArgumentError'],
  'unsignedAssign': ['ArgumentError'],
  'customOperators': ['String'],
  'customConversion': ['String'],
  'bigDivide': ['IntegerDivisionByZeroException'],
  'bigModulo': ['IntegerDivisionByZeroException'],
  'bigRemainder': ['IntegerDivisionByZeroException'],
  'bigLeft': ['ArgumentError'],
  'bigRight': ['ArgumentError'],
  'bigPower': ['ArgumentError'],
  'bigFrom': ['ArgumentError'],
  'bigDivideAssign': ['IntegerDivisionByZeroException'],
  'bigModuloAssign': ['IntegerDivisionByZeroException'],
  'bigLeftAssign': ['ArgumentError'],
  'bigRightAssign': ['ArgumentError'],
  'bigDynamicDivideCaught': ['TypeError'],
  'bigDynamicModuloCaught': ['TypeError'],
  'bigDynamicShiftCaught': ['TypeError'],
  'bigWrongCatch': ['IntegerDivisionByZeroException'],
  'bigModularPower': ['ArgumentError'],
  'bigModularInverse': ['ArgumentError', 'Exception'],
  'bigUnsigned': ['ArgumentError'],
  'bigSigned': ['ArgumentError'],
  'bigRadixInvalid': ['RangeError'],
  'bigRadixUnknown': ['RangeError'],
  'bigRadixDynamic': ['RangeError', 'TypeError'],
  'bigDynamicPowerCaught': ['TypeError'],
  'bigDynamicFromCaught': ['TypeError'],
  'bigFloatingDivideDynamicCaught': ['TypeError'],
  'regularDivideDynamicCaught': ['TypeError'],
  'bigInverseCaughtException': ['ArgumentError'],
  'intRemainder': ['IntegerDivisionByZeroException'],
  'intUnsigned': ['ArgumentError'],
  'intSigned': ['ArgumentError'],
  'intModularPower': ['RangeError'],
  'intModularInverse': ['RangeError', 'Exception'],
  'clampBounds': ['ArgumentError'],
  'clampNaNLower': ['ArgumentError'],
  'radixFormat': ['RangeError'],
  'fixedFormat': ['RangeError'],
  'exponentialFormat': ['RangeError'],
  'precisionFormat': ['RangeError'],
  'intInverseCaughtRange': ['Exception'],
  'intRemainderDynamicCaught': ['TypeError'],
  'intWidthDynamicCaught': ['TypeError'],
  'intModularDynamicCaught': ['TypeError'],
  'clampDynamicCaught': ['TypeError'],
  'formatDynamicCaught': ['TypeError'],
  'fixedFormatAlias': ['RangeError'],
};

const numericSafeFunctions = [
  'safeIntLiterals',
  'safeDoubleLiterals',
  'nonfiniteFloatingConversions',
  'nonfiniteConstantConversions',
  'floatingModuloAssign',
  'caughtSupported',
  'safeBigIntConstants',
  'bigCaughtSpecific',
  'bigCaughtSupported',
  'safeBigIntModularConstants',
  'bigRadixSafe',
  'bigFloatingDivide',
  'regularDivide',
  'doubleFloatingDivide',
  'bigModularCaughtArgument',
  'safeIntWidths',
  'safeIntModularConstants',
  'safeIntModularZeroExponent',
  'safeFormatting',
  'clampNaNUpper',
  'clampBothNaN',
  'intRemainderCaught',
  'intWidthCaught',
  'clampCaught',
  'formatCaught',
];

const _vmObservations = <String, String>{
  'random_secure_factory': 'none',
  'random_next_int_zero': 'RangeError',
  'random_next_int_too_large': 'RangeError',
  'int_divide_zero': 'IntegerDivisionByZeroException',
  'int_modulo_zero': 'IntegerDivisionByZeroException',
  'double_divide_zero': 'UnsupportedError',
  'num_divide_zero': 'IntegerDivisionByZeroException',
  'divide_nan': 'UnsupportedError',
  'divide_infinity': 'UnsupportedError',
  'divide_overflow': 'UnsupportedError',
  'divide_by_infinity': 'none',
  'left_negative': 'ArgumentError',
  'right_negative': 'ArgumentError',
  'unsigned_negative': 'ArgumentError',
  'convert_nan': 'UnsupportedError',
  'truncate_infinity': 'UnsupportedError',
  'round_nan': 'UnsupportedError',
  'floor_infinity': 'UnsupportedError',
  'ceil_nan': 'UnsupportedError',
  'divide_assign': 'IntegerDivisionByZeroException',
  'modulo_assign': 'IntegerDivisionByZeroException',
  'left_assign': 'ArgumentError',
  'right_assign': 'ArgumentError',
  'unsigned_assign': 'ArgumentError',
  'floating_modulo_assign': 'none',
  'num_modulo_assign': 'IntegerDivisionByZeroException',
  'safe_int': 'none',
  'safe_double': 'none',
  'caught_supported': 'none',
  'caught_specific': 'none',
  'wrong_catch': 'UnsupportedError',
  'dynamic_divide_type': 'TypeError',
  'dynamic_modulo_type': 'TypeError',
  'dynamic_shift_type': 'TypeError',
  'getter_compound': 'String',
  'setter_compound': 'String',
  'converter_alias': 'UnsupportedError',
  'converter_wrong_arity': 'NoSuchMethodError',
  'floating_converter_wrong_arity_caught': 'NoSuchMethodError',
  'nonfinite_floating_conversions': 'none',
  'custom_operators': 'String',
  'custom_conversion': 'String',
  'big_divide_zero': 'IntegerDivisionByZeroException',
  'big_modulo_zero': 'IntegerDivisionByZeroException',
  'big_remainder_zero': 'IntegerDivisionByZeroException',
  'big_left_negative': 'ArgumentError',
  'big_right_negative': 'ArgumentError',
  'big_power_negative': 'ArgumentError',
  'big_from_nan': 'ArgumentError',
  'big_from_infinity': 'ArgumentError',
  'big_divide_assign': 'IntegerDivisionByZeroException',
  'big_modulo_assign': 'IntegerDivisionByZeroException',
  'big_left_assign': 'ArgumentError',
  'big_right_assign': 'ArgumentError',
  'big_dynamic_divide_type': 'TypeError',
  'big_dynamic_modulo_type': 'TypeError',
  'big_dynamic_shift_type': 'TypeError',
  'big_caught_specific': 'none',
  'big_caught_supported': 'none',
  'big_wrong_catch': 'IntegerDivisionByZeroException',
  'safe_big_constants': 'none',
  'big_modular_negative_exponent': 'ArgumentError',
  'big_modular_zero_modulus': 'ArgumentError',
  'big_inverse_zero_modulus': 'ArgumentError',
  'big_inverse_non_coprime': 'Exception',
  'big_unsigned_negative': 'ArgumentError',
  'big_unsigned_zero': 'none',
  'big_signed_negative': 'ArgumentError',
  'big_signed_zero': 'ArgumentError',
  'big_dynamic_power_type': 'TypeError',
  'big_dynamic_from_type': 'TypeError',
  'big_divide_float_zero': 'none',
  'regular_divide_zero': 'none',
  'double_divide_float_zero': 'none',
  'big_float_divide_dynamic_type': 'TypeError',
  'regular_divide_dynamic_type': 'TypeError',
  'big_modular_caught_argument': 'none',
  'big_inverse_caught_exception': 'ArgumentError',
  'safe_big_modular_constants': 'none',
  'big_radix_invalid': 'RangeError',
  'big_radix_safe': 'none',
  'big_radix_dynamic_type': 'TypeError',
  'int_remainder_zero': 'IntegerDivisionByZeroException',
  'int_remainder_float_zero': 'none',
  'int_unsigned_negative': 'ArgumentError',
  'int_unsigned_zero': 'none',
  'int_signed_negative': 'ArgumentError',
  'int_signed_zero': 'ArgumentError',
  'int_modular_negative_exponent': 'RangeError',
  'int_modular_zero_modulus': 'RangeError',
  'int_inverse_zero_modulus': 'RangeError',
  'int_inverse_non_coprime': 'Exception',
  'clamp_reversed': 'ArgumentError',
  'clamp_nan_lower': 'ArgumentError',
  'clamp_nan_upper': 'none',
  'clamp_both_nan': 'none',
  'radix_low': 'RangeError',
  'radix_high': 'RangeError',
  'fixed_low': 'RangeError',
  'fixed_high': 'RangeError',
  'fixed_infinity_high': 'RangeError',
  'exponential_low': 'RangeError',
  'exponential_high': 'RangeError',
  'exponential_default': 'none',
  'precision_low': 'RangeError',
  'precision_high': 'RangeError',
  'int_modular_large_base': 'none',
  'int_modular_large_exponent': 'none',
  'int_modular_large_modulus': 'none',
  'int_modular_zero_exponent_large_base': 'none',
  'int_inverse_caught_range': 'Exception',
  'int_remainder_dynamic_type': 'TypeError',
  'int_width_dynamic_type': 'TypeError',
  'int_modular_dynamic_type': 'TypeError',
  'clamp_dynamic_type': 'TypeError',
  'format_dynamic_type': 'TypeError',
  'format_alias': 'RangeError',
  'safe_int_widths': 'none',
  'safe_int_modular_constants': 'none',
  'safe_formatting': 'none',
  'int_remainder_caught': 'none',
  'int_width_caught': 'none',
  'clamp_caught': 'none',
  'format_caught': 'none',
};

final _javascriptObservations = {
  ..._vmObservations,
  'int_divide_zero': 'UnsupportedError',
  'int_modulo_zero': 'none',
  'num_divide_zero': 'UnsupportedError',
  'divide_assign': 'UnsupportedError',
  'modulo_assign': 'none',
  'num_modulo_assign': 'none',
  'caught_specific': 'UnsupportedError',
  'int_remainder_zero': 'none',
  'int_modular_large_base': 'RangeError',
  'int_modular_large_exponent': 'RangeError',
  'int_modular_large_modulus': 'RangeError',
};

const numericFixture = r'''
import 'dart:convert';
import 'dart:math';
int randomNextIntZero() => Random().nextInt(0);
int randomNextIntTooLarge() => Random().nextInt(4294967297);
void randomSecureFactory() { Random.secure(); }
int intDivide(int divisor) => 12 ~/ divisor;
int intModulo(int divisor) => 12 % divisor;
int doubleDivide(double divisor) => 12.0 ~/ divisor;
int numDivide(num divisor) => 12 ~/ divisor;
int nonfiniteDivide(double value) => value ~/ 2;
int overflowingDivide() => 1e308 ~/ 1e-308;
int leftShift(int count) => 1 << count;
int rightShift(int count) => 1 >> count;
int unsignedShift(int count) => 1 >>> count;
int convert(double value) => value.toInt();
int truncateValue(double value) => value.truncate();
int roundValue(double value) => value.round();
int floorValue(double value) => value.floor();
int ceilValue(double value) => value.ceil();
void divideAssign(int divisor) { var value = 12; value ~/= divisor; }
void moduloAssign(int divisor) { var value = 12; value %= divisor; }
void leftAssign(int count) { var value = 1; value <<= count; }
void rightAssign(int count) { var value = 1; value >>= count; }
void unsignedAssign(int count) { var value = 1; value >>>= count; }
void floatingModuloAssign(double divisor) { var value = 12.0; value %= divisor; }
void numModuloAssign(num divisor) { num value = 12; value %= divisor; }
void safeIntLiterals() { 12 ~/ 3; 12 % 3; 1 << 0; 1 >> 1; 1 >>> 1; }
void safeDoubleLiterals() { 12.0 ~/ 3.0; 12.0 % 0.0; 12.5.toInt(); 12.5.truncate(); 12.5.round(); 12.5.floor(); 12.5.ceil(); }
void caughtSupported() { try { intDivide(0); } on UnsupportedError {} }
void caughtSpecific() { try { intDivide(0); } on IntegerDivisionByZeroException {} }
void wrongCatch() { try { doubleDivide(0); } on IntegerDivisionByZeroException {} }
void caughtDynamicDivide(dynamic divisor) { try { 12 ~/ divisor; } on UnsupportedError {} }
void caughtDynamicModulo(dynamic divisor) { try { 12 % divisor; } on IntegerDivisionByZeroException {} }
void caughtDynamicShift(dynamic count) { try { 1 << count; } on ArgumentError {} }
final class GetterFailure {
  int get value { throw 'getter'; }
  set value(int replacement) {}
}
final class SetterFailure {
  int get value => 12;
  set value(int replacement) { throw 'setter'; }
}
void getterCompound(GetterFailure cell, int divisor) { cell.value ~/= divisor; }
void setterCompound(SetterFailure cell, int divisor) { cell.value ~/= divisor; }
void converterAlias(double value) { final action = value.toInt; action(); }
void converterWrongArity(double value) { dynamic action = value.toInt; action(1); }
void floatingConverterWrongArityCaught(double value) {
  try { dynamic action = value.roundToDouble; action(1); } on UnsupportedError {}
}
void nonfiniteFloatingConversions(double value) {
  value.toDouble();
  value.truncateToDouble();
  value.roundToDouble();
  value.floorToDouble();
  value.ceilToDouble();
}
void nonfiniteConstantConversions() {
  nonfiniteFloatingConversions(double.nan);
  nonfiniteFloatingConversions(double.infinity);
}
final class Custom {
  int operator ~/(Object value) { throw 'custom'; }
  int operator %(Object value) { throw 'custom'; }
  int operator <<(Object value) { throw 'custom'; }
  int operator >>(Object value) { throw 'custom'; }
  int operator >>>(Object value) { throw 'custom'; }
  int toInt() { throw 'custom'; }
}
void customOperators(Custom value) { value ~/ 1; value % 1; value << 1; value >> 1; value >>> 1; }
void customConversion(Custom value) { value.toInt(); }
BigInt bigDivide(BigInt value, BigInt divisor) => value ~/ divisor;
BigInt bigModulo(BigInt value, BigInt divisor) => value % divisor;
BigInt bigRemainder(BigInt value, BigInt divisor) => value.remainder(divisor);
BigInt bigLeft(BigInt value, int count) => value << count;
BigInt bigRight(BigInt value, int count) => value >> count;
BigInt bigPower(BigInt value, int exponent) => value.pow(exponent);
BigInt bigFrom(num value) => BigInt.from(value);
void bigDivideAssign(BigInt value, BigInt divisor) { value ~/= divisor; }
void bigModuloAssign(BigInt value, BigInt divisor) { value %= divisor; }
void bigLeftAssign(BigInt value, int count) { value <<= count; }
void bigRightAssign(BigInt value, int count) { value >>= count; }
void bigDynamicDivideCaught(BigInt value, dynamic divisor) {
  try { value ~/ divisor; } on IntegerDivisionByZeroException {}
}
void bigDynamicModuloCaught(BigInt value, dynamic divisor) {
  try { value % divisor; } on IntegerDivisionByZeroException {}
}
void bigDynamicShiftCaught(BigInt value, dynamic count) {
  try { value << count; } on ArgumentError {}
}
void bigCaughtSpecific(BigInt value, BigInt divisor) {
  try { value ~/ divisor; } on IntegerDivisionByZeroException {}
}
void bigCaughtSupported(BigInt value, BigInt divisor) {
  try { value ~/ divisor; } on UnsupportedError {}
}
void bigWrongCatch(BigInt value, BigInt divisor) {
  try { value ~/ divisor; } on ArgumentError {}
}
void safeBigIntConstants() {
  BigInt.one ~/ BigInt.one;
  BigInt.one % BigInt.one;
  BigInt.one.remainder(BigInt.one);
  BigInt.one << 0;
  BigInt.one >> 0;
  BigInt.one.pow(0);
  BigInt.from(12);
}
BigInt bigModularPower(BigInt value, BigInt exponent, BigInt modulus) => value.modPow(exponent, modulus);
BigInt bigModularInverse(BigInt value, BigInt modulus) => value.modInverse(modulus);
BigInt bigUnsigned(BigInt value, int width) => value.toUnsigned(width);
BigInt bigSigned(BigInt value, int width) => value.toSigned(width);
String bigRadixUnknown(BigInt value, int radix) => value.toRadixString(radix);
String bigRadixInvalid(BigInt value) => value.toRadixString(1);
String bigRadixDynamic(BigInt value, dynamic radix) => value.toRadixString(radix);
void bigRadixSafe() { BigInt.one.toRadixString(36); }
void bigDynamicPowerCaught(BigInt value, dynamic exponent) {
  try { value.pow(exponent); } on ArgumentError {}
}
void bigDynamicFromCaught(dynamic value) {
  try { BigInt.from(value); } on ArgumentError {}
}
void bigFloatingDivide(BigInt value, BigInt divisor) { value / divisor; }
void regularDivide(int value, num divisor) { value / divisor; }
void doubleFloatingDivide(double value, num divisor) { value / divisor; }
void bigFloatingDivideDynamicCaught(BigInt value, dynamic divisor) {
  try { value / divisor; } on ArgumentError {}
}
void regularDivideDynamicCaught(int value, dynamic divisor) {
  try { value / divisor; } on ArgumentError {}
}
void bigModularCaughtArgument(BigInt value, BigInt exponent, BigInt modulus) {
  try { value.modPow(exponent, modulus); } on ArgumentError {}
}
void bigInverseCaughtException(BigInt value, BigInt modulus) {
  try { value.modInverse(modulus); } on Exception {}
}
void safeBigIntModularConstants() {
  BigInt.one.modPow(BigInt.one, BigInt.two);
  BigInt.one.modInverse(BigInt.two);
  BigInt.one.toUnsigned(0);
  BigInt.one.toSigned(1);
}
num intRemainder(int value, num divisor) => value.remainder(divisor);
int intUnsigned(int value, int width) => value.toUnsigned(width);
int intSigned(int value, int width) => value.toSigned(width);
int intModularPower(int value, int exponent, int modulus) => value.modPow(exponent, modulus);
int intModularInverse(int value, int modulus) => value.modInverse(modulus);
num clampBounds(num value, num lower, num upper) => value.clamp(lower, upper);
num clampNaNLower(num value) => value.clamp(double.nan, 1);
num clampNaNUpper(num value) => value.clamp(1, double.nan);
num clampBothNaN(num value) => value.clamp(double.nan, double.nan);
String radixFormat(int value, int radix) => value.toRadixString(radix);
String fixedFormat(num value, int digits) => value.toStringAsFixed(digits);
String exponentialFormat(num value, [int? digits]) => value.toStringAsExponential(digits);
String precisionFormat(num value, int precision) => value.toStringAsPrecision(precision);
void intInverseCaughtRange(int value, int modulus) {
  try { value.modInverse(modulus); } on RangeError {}
}
void intRemainderDynamicCaught(int value, dynamic divisor) {
  try { value.remainder(divisor); } on IntegerDivisionByZeroException {}
}
void intWidthDynamicCaught(int value, dynamic width) {
  try { value.toSigned(width); } on ArgumentError {}
}
void intModularDynamicCaught(int value, dynamic exponent) {
  try { value.modPow(exponent, 3); } on RangeError {}
}
void clampDynamicCaught(num value, dynamic lower) {
  try { value.clamp(lower, 1); } on ArgumentError {}
}
void formatDynamicCaught(num value, dynamic precision) {
  try { value.toStringAsPrecision(precision); } on RangeError {}
}
void fixedFormatAlias(num value, int digits) {
  final action = value.toStringAsFixed;
  action(digits);
}
void safeIntWidths(int value) { value.toUnsigned(0); value.toSigned(1); }
void safeIntModularConstants() { 1.modPow(1, 3); 1.modInverse(3); }
void safeIntModularZeroExponent(int value) { value.modPow(0, 3); }
void safeFormatting(num value) {
  1.toRadixString(2); 1.toRadixString(36);
  value.toStringAsFixed(0); value.toStringAsFixed(20);
  value.toStringAsExponential(); value.toStringAsExponential(null);
  value.toStringAsExponential(0); value.toStringAsExponential(20);
  value.toStringAsPrecision(1); value.toStringAsPrecision(21);
}
void intRemainderCaught(int value, int divisor) {
  try { value.remainder(divisor); } on IntegerDivisionByZeroException {}
}
void intWidthCaught(int value, int width) {
  try { value.toSigned(width); } on ArgumentError {}
}
void clampCaught(num value, num lower, num upper) {
  try { value.clamp(lower, upper); } on ArgumentError {}
}
void formatCaught(num value, int precision) {
  try { value.toStringAsPrecision(precision); } on ArgumentError {}
}
String capture(void Function() operation) {
  try { operation(); return 'none'; } catch(error) {
    if (error is IntegerDivisionByZeroException) return 'IntegerDivisionByZeroException';
    if (error is UnsupportedError) return 'UnsupportedError';
    if (error is RangeError) return 'RangeError';
    if (error is ArgumentError) return 'ArgumentError';
    if (error is TypeError) return 'TypeError';
    if (error is NoSuchMethodError) return 'NoSuchMethodError';
    if (error is Exception) return 'Exception';
    if (error is String) return 'String';
    return '${error.runtimeType}';
  }
}
void main() {
  print(jsonEncode({
    'random_secure_factory': capture(() { Random.secure(); }),
    'random_next_int_zero': capture(randomNextIntZero),
    'random_next_int_too_large': capture(randomNextIntTooLarge),
    'int_divide_zero': capture(() { intDivide(0); }),
    'int_modulo_zero': capture(() { intModulo(0); }),
    'double_divide_zero': capture(() { doubleDivide(0); }),
    'num_divide_zero': capture(() { numDivide(0); }),
    'divide_nan': capture(() { nonfiniteDivide(double.nan); }),
    'divide_infinity': capture(() { nonfiniteDivide(double.infinity); }),
    'divide_overflow': capture(overflowingDivide),
    'divide_by_infinity': capture(() { doubleDivide(double.infinity); }),
    'left_negative': capture(() { leftShift(-1); }),
    'right_negative': capture(() { rightShift(-1); }),
    'unsigned_negative': capture(() { unsignedShift(-1); }),
    'convert_nan': capture(() { convert(double.nan); }),
    'truncate_infinity': capture(() { truncateValue(double.infinity); }),
    'round_nan': capture(() { roundValue(double.nan); }),
    'floor_infinity': capture(() { floorValue(double.infinity); }),
    'ceil_nan': capture(() { ceilValue(double.nan); }),
    'divide_assign': capture(() { divideAssign(0); }),
    'modulo_assign': capture(() { moduloAssign(0); }),
    'left_assign': capture(() { leftAssign(-1); }),
    'right_assign': capture(() { rightAssign(-1); }),
    'unsigned_assign': capture(() { unsignedAssign(-1); }),
    'floating_modulo_assign': capture(() { floatingModuloAssign(0); }),
    'num_modulo_assign': capture(() { numModuloAssign(0); }),
    'safe_int': capture(safeIntLiterals),
    'safe_double': capture(safeDoubleLiterals),
    'caught_supported': capture(caughtSupported),
    'caught_specific': capture(caughtSpecific),
    'wrong_catch': capture(wrongCatch),
    'dynamic_divide_type': capture(() { caughtDynamicDivide('bad'); }),
    'dynamic_modulo_type': capture(() { caughtDynamicModulo('bad'); }),
    'dynamic_shift_type': capture(() { caughtDynamicShift('bad'); }),
    'getter_compound': capture(() { getterCompound(GetterFailure(), 1); }),
    'setter_compound': capture(() { setterCompound(SetterFailure(), 1); }),
    'converter_alias': capture(() { converterAlias(double.infinity); }),
    'converter_wrong_arity': capture(() { converterWrongArity(1.0); }),
    'floating_converter_wrong_arity_caught': capture(() { floatingConverterWrongArityCaught(1.0); }),
    'nonfinite_floating_conversions': capture(nonfiniteConstantConversions),
    'custom_operators': capture(() { customOperators(Custom()); }),
    'custom_conversion': capture(() { customConversion(Custom()); }),
    'big_divide_zero': capture(() { bigDivide(BigInt.one, BigInt.zero); }),
    'big_modulo_zero': capture(() { bigModulo(BigInt.one, BigInt.zero); }),
    'big_remainder_zero': capture(() { bigRemainder(BigInt.one, BigInt.zero); }),
    'big_left_negative': capture(() { bigLeft(BigInt.one, -1); }),
    'big_right_negative': capture(() { bigRight(BigInt.one, -1); }),
    'big_power_negative': capture(() { bigPower(BigInt.one, -1); }),
    'big_from_nan': capture(() { bigFrom(double.nan); }),
    'big_from_infinity': capture(() { bigFrom(double.infinity); }),
    'big_divide_assign': capture(() { bigDivideAssign(BigInt.one, BigInt.zero); }),
    'big_modulo_assign': capture(() { bigModuloAssign(BigInt.one, BigInt.zero); }),
    'big_left_assign': capture(() { bigLeftAssign(BigInt.one, -1); }),
    'big_right_assign': capture(() { bigRightAssign(BigInt.one, -1); }),
    'big_dynamic_divide_type': capture(() { bigDynamicDivideCaught(BigInt.one, 'bad'); }),
    'big_dynamic_modulo_type': capture(() { bigDynamicModuloCaught(BigInt.one, 'bad'); }),
    'big_dynamic_shift_type': capture(() { bigDynamicShiftCaught(BigInt.one, 'bad'); }),
    'big_caught_specific': capture(() { bigCaughtSpecific(BigInt.one, BigInt.zero); }),
    'big_caught_supported': capture(() { bigCaughtSupported(BigInt.one, BigInt.zero); }),
    'big_wrong_catch': capture(() { bigWrongCatch(BigInt.one, BigInt.zero); }),
    'safe_big_constants': capture(safeBigIntConstants),
    'big_modular_negative_exponent': capture(() { bigModularPower(BigInt.one, BigInt.from(-1), BigInt.two); }),
    'big_modular_zero_modulus': capture(() { bigModularPower(BigInt.one, BigInt.one, BigInt.zero); }),
    'big_inverse_zero_modulus': capture(() { bigModularInverse(BigInt.one, BigInt.zero); }),
    'big_inverse_non_coprime': capture(() { bigModularInverse(BigInt.two, BigInt.from(4)); }),
    'big_unsigned_negative': capture(() { bigUnsigned(BigInt.one, -1); }),
    'big_unsigned_zero': capture(() { bigUnsigned(BigInt.one, 0); }),
    'big_signed_negative': capture(() { bigSigned(BigInt.one, -1); }),
    'big_signed_zero': capture(() { bigSigned(BigInt.one, 0); }),
    'big_dynamic_power_type': capture(() { bigDynamicPowerCaught(BigInt.one, 'bad'); }),
    'big_dynamic_from_type': capture(() { bigDynamicFromCaught('bad'); }),
    'big_divide_float_zero': capture(() { bigFloatingDivide(BigInt.one, BigInt.zero); }),
    'regular_divide_zero': capture(() { regularDivide(1, 0); }),
    'double_divide_float_zero': capture(() { doubleFloatingDivide(1.0, 0); }),
    'big_float_divide_dynamic_type': capture(() { bigFloatingDivideDynamicCaught(BigInt.one, 'bad'); }),
    'regular_divide_dynamic_type': capture(() { regularDivideDynamicCaught(1, 'bad'); }),
    'big_modular_caught_argument': capture(() { bigModularCaughtArgument(BigInt.one, BigInt.one, BigInt.zero); }),
    'big_inverse_caught_exception': capture(() { bigInverseCaughtException(BigInt.one, BigInt.zero); }),
    'safe_big_modular_constants': capture(safeBigIntModularConstants),
    'big_radix_invalid': capture(() { bigRadixInvalid(BigInt.one); }),
    'big_radix_safe': capture(bigRadixSafe),
    'big_radix_dynamic_type': capture(() { bigRadixDynamic(BigInt.one, '2'); }),
    'int_remainder_zero': capture(() { intRemainder(1, 0); }),
    'int_remainder_float_zero': capture(() { intRemainder(1, 0.0); }),
    'int_unsigned_negative': capture(() { intUnsigned(1, -1); }),
    'int_unsigned_zero': capture(() { intUnsigned(1, 0); }),
    'int_signed_negative': capture(() { intSigned(1, -1); }),
    'int_signed_zero': capture(() { intSigned(1, 0); }),
    'int_modular_negative_exponent': capture(() { intModularPower(1, -1, 3); }),
    'int_modular_zero_modulus': capture(() { intModularPower(1, 1, 0); }),
    'int_inverse_zero_modulus': capture(() { intModularInverse(1, 0); }),
    'int_inverse_non_coprime': capture(() { intModularInverse(2, 4); }),
    'clamp_reversed': capture(() { clampBounds(1, 2, 1); }),
    'clamp_nan_lower': capture(() { clampNaNLower(1); }),
    'clamp_nan_upper': capture(() { clampNaNUpper(1); }),
    'clamp_both_nan': capture(() { clampBothNaN(1); }),
    'radix_low': capture(() { radixFormat(1, 1); }),
    'radix_high': capture(() { radixFormat(1, 37); }),
    'fixed_low': capture(() { fixedFormat(1, -1); }),
    'fixed_high': capture(() { fixedFormat(1, 21); }),
    'fixed_infinity_high': capture(() { fixedFormat(double.infinity, 21); }),
    'exponential_low': capture(() { exponentialFormat(1, -1); }),
    'exponential_high': capture(() { exponentialFormat(1, 21); }),
    'exponential_default': capture(() { exponentialFormat(1); }),
    'precision_low': capture(() { precisionFormat(1, 0); }),
    'precision_high': capture(() { precisionFormat(1, 22); }),
    'int_modular_large_base': capture(() { intModularPower(18014398509481984, 1, 3); }),
    'int_modular_large_exponent': capture(() { intModularPower(1, 18014398509481984, 3); }),
    'int_modular_large_modulus': capture(() { intModularPower(1, 1, 18014398509481984); }),
    'int_modular_zero_exponent_large_base': capture(() { safeIntModularZeroExponent(18014398509481984); }),
    'int_inverse_caught_range': capture(() { intInverseCaughtRange(2, 4); }),
    'int_remainder_dynamic_type': capture(() { intRemainderDynamicCaught(1, 'bad'); }),
    'int_width_dynamic_type': capture(() { intWidthDynamicCaught(1, 'bad'); }),
    'int_modular_dynamic_type': capture(() { intModularDynamicCaught(1, 'bad'); }),
    'clamp_dynamic_type': capture(() { clampDynamicCaught(1, 'bad'); }),
    'format_dynamic_type': capture(() { formatDynamicCaught(1, 'bad'); }),
    'format_alias': capture(() { fixedFormatAlias(1, 21); }),
    'safe_int_widths': capture(() { safeIntWidths(1); }),
    'safe_int_modular_constants': capture(safeIntModularConstants),
    'safe_formatting': capture(() { safeFormatting(double.infinity); }),
    'int_remainder_caught': capture(() { intRemainderCaught(1, 0); }),
    'int_width_caught': capture(() { intWidthCaught(1, 0); }),
    'clamp_caught': capture(() { clampCaught(1, 2, 1); }),
    'format_caught': capture(() { formatCaught(1, 0); }),
  }));
}
''';
