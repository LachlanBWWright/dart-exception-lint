import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';

import '../analysis/throw_summary.dart';

/// Failure conditions on resolved SDK numeric operations.
///
/// Values are proven only from literals or native const elements. Ordinary
/// variable initializers do not establish facts after writes or external calls.
/// Operator identity is checked independently from similarly named user code.
final class NumericChecks {
  static const _integerConversions = {
    'toInt',
    'round',
    'floor',
    'ceil',
    'truncate',
  };
  static const _doubleConversions = {
    'toDouble',
    'roundToDouble',
    'floorToDouble',
    'ceilToDouble',
    'truncateToDouble',
  };
  static const _primitiveMethods = {
    'remainder',
    'toSigned',
    'toUnsigned',
    'modPow',
    'modInverse',
    'clamp',
    'toRadixString',
    'toStringAsFixed',
    'toStringAsExponential',
    'toStringAsPrecision',
  };
  static const _shifts = {'<<', '>>', '>>>'};
  static const _bigIntMethods = {
    'remainder',
    'pow',
    'modPow',
    'modInverse',
    'toSigned',
    'toUnsigned',
    'toRadixString',
    'toInt',
    'toDouble',
  };

  static bool isKnownBigIntValueGetter(Element? element) {
    final base = element?.baseElement;
    return base is GetterElement &&
        base.isStatic &&
        base.library.isInSdk &&
        base.library.uri.toString() == 'dart:core' &&
        base.enclosingElement.name == 'BigInt' &&
        const {'zero', 'one', 'two'}.contains(base.name);
  }

  static bool modelsBinary(BinaryExpression node) =>
      _modelsOperator(node.operator.lexeme, node.element);

  static bool modelsAssignment(AssignmentExpression node) {
    final operator = node.operator.lexeme;
    return operator.endsWith('=') &&
        operator != '=' &&
        _modelsOperator(
          operator.substring(0, operator.length - 1),
          node.element,
        );
  }

  static bool modelsInvocation(AstNode node, Element? element) {
    final random = _nativeRandom(element);
    if (random != null) {
      return (random.name == 'secure' && node is InstanceCreationExpression) ||
          (random.name == 'nextInt' && _hasKnownRandomReceiver(node));
    }
    final target = _nativeNumeric(element);
    if (target == null) return false;
    if (target.enclosingElement?.name == 'BigInt') {
      return target is ConstructorElement &&
              target.name == 'from' &&
              (node is InstanceCreationExpression ||
                  node is MethodInvocation ||
                  node is FunctionExpressionInvocation) ||
          target is MethodElement &&
              _bigIntMethods.contains(target.name) &&
              (node is MethodInvocation ||
                  node is FunctionExpressionInvocation);
    }
    return (node is MethodInvocation || node is FunctionExpressionInvocation) &&
        (_integerConversions.contains(target.name) ||
            _doubleConversions.contains(target.name) ||
            _primitiveMethods.contains(target.name));
  }

  static bool _modelsOperator(String operator, Element? element) =>
      const {'/', '~/', '%', '<<', '>>', '>>>'}.contains(operator) &&
      _nativeNumeric(element)?.name == operator;

  static ThrowSource? binary(BinaryExpression node) => _operator(
    node.operator.lexeme,
    node.element,
    node.leftOperand,
    node.rightOperand,
  );

  static ThrowSource? assignment(AssignmentExpression node) {
    final operator = node.operator.lexeme;
    if (!operator.endsWith('=') || operator == '=') return null;
    return _operator(
      operator.substring(0, operator.length - 1),
      node.element,
      node.leftHandSide,
      node.rightHandSide,
    );
  }

  static ThrowSource? invocation(AstNode node, Element? element) {
    final random = _nativeRandom(element);
    if (random != null &&
        random.name == 'secure' &&
        node is InstanceCreationExpression) {
      return _source(random, 'Random.secure', const ['UnsupportedError']);
    }
    if (random != null &&
        random.name == 'nextInt' &&
        _hasKnownRandomReceiver(node)) {
      return _randomInvocation(node, random);
    }
    final target = _nativeNumeric(element);
    if (target == null || !modelsInvocation(node, target)) {
      return null;
    }
    final arguments = switch (node) {
      MethodInvocation() => node.argumentList.arguments,
      FunctionExpressionInvocation() => node.argumentList.arguments,
      InstanceCreationExpression() => node.argumentList.arguments,
      _ => null,
    };
    final required = target.formalParameters
        .where((parameter) => parameter.isRequiredPositional)
        .length;
    final positional = target.formalParameters
        .where((parameter) => parameter.isPositional)
        .length;
    // Native converter and BigInt methods have positional signatures. Dynamic
    // tearoffs fail before entering the body if the supplied shape is invalid.
    if (arguments == null ||
        arguments.any((argument) => argument is NamedArgument) ||
        arguments.length < required ||
        arguments.length > positional) {
      return _source(target, 'numeric conversion invocation arity', const [
        'NoSuchMethodError',
      ]);
    }
    if (target.enclosingElement?.name == 'BigInt') {
      return _bigIntInvocation(
        target,
        node,
        arguments.map((argument) => argument.argumentExpression).toList(),
      );
    }
    if (_primitiveMethods.contains(target.name)) {
      return _primitiveInvocation(
        target,
        node,
        arguments.map((argument) => argument.argumentExpression).toList(),
      );
    }
    if (_doubleConversions.contains(target.name)) return null;
    if (target.enclosingElement?.name == 'int') return null;
    final receiver =
        node is MethodInvocation &&
            node.methodName.element?.baseElement == target.baseElement
        ? node.realTarget
        : null;
    if (_kind(receiver?.staticType) == 'int') return null;
    final value = receiver == null ? null : _constantNumber(receiver);
    if (value?.isFinite == true) return null;
    return _source(
      target,
      '${target.enclosingElement?.name}.${target.name}',
      const ['UnsupportedError'],
    );
  }

  static ExecutableElement? _nativeRandom(Element? element) {
    final base = element?.baseElement;
    if (base is ExecutableElement &&
        base.library.isInSdk &&
        base.library.uri.toString() == 'dart:math' &&
        base.enclosingElement?.name == 'Random') {
      return base;
    }
    return null;
  }

  static bool _hasKnownRandomReceiver(AstNode node) {
    if (node is! MethodInvocation ||
        node.realTarget is! InstanceCreationExpression) {
      return false;
    }
    final creation = node.realTarget as InstanceCreationExpression;
    final target = creation.constructorName.element?.baseElement;
    return target is ConstructorElement &&
        target.library.isInSdk &&
        target.library.uri.toString() == 'dart:math' &&
        target.enclosingElement.name == 'Random' &&
        const {'new', 'secure'}.contains(target.name);
  }

  static ThrowSource? _randomInvocation(
    AstNode node,
    ExecutableElement target,
  ) {
    final arguments = switch (node) {
      MethodInvocation() => node.argumentList.arguments,
      FunctionExpressionInvocation() => node.argumentList.arguments,
      _ => null,
    };
    if (arguments == null ||
        arguments.length != 1 ||
        arguments.single is NamedArgument) {
      return _source(target, 'Random.nextInt invocation arity', const [
        'NoSuchMethodError',
      ]);
    }
    final argument = arguments.single.argumentExpression;
    final maximum = _constantNumber(argument);
    final types = <String>{};
    // Both pinned SDK implementations require 1 <= max <= 2^32.
    if (maximum is! int || maximum < 1 || maximum > 4294967296) {
      types.add('RangeError');
    }
    if (_argumentMayFail(argument, target.formalParameters.single)) {
      types.add('TypeError');
    }
    return types.isEmpty
        ? null
        : _source(target, 'Random.nextInt', types.toList());
  }

  static ExecutableElement? _nativeNumeric(Element? element) {
    final base = element?.baseElement;
    if (base is! ExecutableElement ||
        !base.library.isInSdk ||
        base.library.uri.toString() != 'dart:core' ||
        !const {
          'int',
          'double',
          'num',
          'BigInt',
        }.contains(base.enclosingElement?.name)) {
      return null;
    }
    return base;
  }

  static String? _kind(DartType? type) =>
      type is InterfaceType &&
          type.element.library.isInSdk &&
          type.element.library.uri.toString() == 'dart:core' &&
          const {'int', 'double', 'num'}.contains(type.element.name)
      ? type.element.name
      : null;

  static ThrowSource? _operator(
    String operator,
    Element? element,
    Expression left,
    Expression right,
  ) {
    final target = _nativeNumeric(element);
    if (target is! MethodElement || !_modelsOperator(operator, target)) {
      return null;
    }
    if (target.enclosingElement?.name == 'BigInt') {
      final types = <String>[];
      if (operator == '~/' || operator == '%') {
        final divisor = _bigInteger(right);
        if (divisor == null || divisor == BigInt.zero) {
          types.add('IntegerDivisionByZeroException');
        }
      } else if (_shifts.contains(operator)) {
        final count = _constantNumber(right);
        if (count is! int || count < 0) types.add('ArgumentError');
        if (count == null && _kind(right.staticType) == 'int') {
          // JS integer arithmetic may produce NaN/infinity without changing
          // the static type; BigInt shifting rejects those numeric artifacts.
          types.add('UnsupportedError');
        }
      }
      final parameter = target.formalParameters.firstOrNull;
      if (parameter != null && _argumentMayFail(right, parameter)) {
        types.add('TypeError');
      }
      return types.isEmpty
          ? null
          : _source(target, 'BigInt $operator operation', types);
    }
    final arithmetic = _arithmetic(target, operator, left, right);
    final value = _constantNumber(right);
    final argumentCheck =
        right.staticType is DynamicType &&
        !(_shifts.contains(operator) ? value is int : value != null);
    if (!argumentCheck) return arithmetic;
    return _source(target, arithmetic?.displayName ?? 'numeric operand check', [
      ...?arithmetic?.exceptionTypes,
      'TypeError',
    ]);
  }

  static ThrowSource? _arithmetic(
    MethodElement target,
    String operator,
    Expression left,
    Expression right,
  ) {
    if (operator == '/') return null;
    final lhs = _constantNumber(left);
    final rhs = _constantNumber(right);
    final leftKind = _kind(left.staticType);
    final rightKind = _kind(right.staticType);
    if (_shifts.contains(operator)) {
      if (rhs is int && rhs >= 0) return null;
      return _source(target, 'integer $operator operation', const [
        'ArgumentError',
      ]);
    }
    if (operator == '%') {
      // Floating modulo accepts zero/non-finite values and returns NaN. Only
      // the VM's integral modulo-by-zero path fails; JS does not throw here.
      if (leftKind == 'double' ||
          rightKind == 'double' ||
          lhs is double ||
          rhs is double ||
          rhs != null && rhs != 0) {
        return null;
      }
      return _source(target, 'integer modulo operation', const [
        'IntegerDivisionByZeroException',
      ]);
    }
    if (operator != '~/') return null;
    final bothInteger =
        (leftKind == 'int' || lhs is int) && (rightKind == 'int' || rhs is int);
    if (bothInteger && rhs != null && rhs != 0) return null;
    if (lhs != null && rhs != null && (lhs / rhs).isFinite) return null;
    // VM integral zero division is a dedicated exception, but JS throws its
    // UnsupportedError supertype. A narrow VM-only catch cannot prove safety.
    final canBeIntegral =
        leftKind != 'double' &&
        rightKind != 'double' &&
        lhs is! double &&
        rhs is! double;
    return _source(
      target,
      'numeric truncating division',
      canBeIntegral
          ? const ['IntegerDivisionByZeroException', 'UnsupportedError']
          : const ['UnsupportedError'],
    );
  }

  static ThrowSource? _bigIntInvocation(
    ExecutableElement target,
    AstNode node,
    List<Expression> arguments,
  ) {
    final types = <String>{};
    final name = target.name;
    final receiver =
        node is MethodInvocation &&
            node.methodName.element?.baseElement == target.baseElement
        ? node.realTarget
        : null;
    if (target is ConstructorElement && name == 'from') {
      final value = _constantNumber(arguments.single);
      // An int-typed result may still be non-finite on JavaScript, e.g. a large
      // BigInt.toInt result or integer modulo by zero. Require a value proof.
      if (value == null || !value.isFinite) types.add('ArgumentError');
    } else if (name == 'remainder') {
      final divisor = _bigInteger(arguments.single);
      if (divisor == null || divisor == BigInt.zero) {
        types.add('IntegerDivisionByZeroException');
      }
    } else if (name == 'pow' || name == 'toSigned' || name == 'toUnsigned') {
      final value = _constantNumber(arguments.single);
      final minimum = name == 'toSigned' ? 1 : 0;
      if (value is! int || value < minimum) types.add('ArgumentError');
      if (name != 'pow' &&
          value == null &&
          _kind(arguments.single.staticType) == 'int') {
        types.add('UnsupportedError');
      }
    } else if (name == 'toRadixString') {
      final radix = _constantNumber(arguments.single);
      if (radix is! int || radix < 2 || radix > 36) {
        types.add('RangeError');
      }
    } else if (name == 'modPow') {
      final exponent = _bigInteger(arguments[0]);
      final modulus = _bigInteger(arguments[1]);
      if (exponent == null ||
          exponent.isNegative ||
          modulus == null ||
          modulus <= BigInt.zero) {
        types.add('ArgumentError');
      }
    } else if (name == 'modInverse') {
      final modulus = _bigInteger(arguments.single);
      if (modulus == null || modulus <= BigInt.zero) types.add('ArgumentError');
      final value = receiver == null ? null : _bigInteger(receiver);
      if (modulus == null ||
          modulus > BigInt.one &&
              (value == null || value.gcd(modulus) != BigInt.one)) {
        types.add('Exception');
      }
    }
    // BigInt.toInt/toDouble clamp or return infinity on some backends without
    // throwing. Their result divergence does not establish a finite int fact.
    for (var index = 0; index < arguments.length; index++) {
      if (_argumentMayFail(arguments[index], target.formalParameters[index])) {
        types.add('TypeError');
      }
    }
    return types.isEmpty
        ? null
        : _source(target, 'BigInt.${target.name}', types.toList());
  }

  static ThrowSource? _primitiveInvocation(
    ExecutableElement target,
    AstNode node,
    List<Expression> arguments,
  ) {
    final name = target.name;
    final types = <String>{};
    final receiver =
        node is MethodInvocation &&
            node.methodName.element?.baseElement == target.baseElement
        ? node.realTarget
        : null;
    final value = receiver == null ? null : _constantNumber(receiver);
    final numbers = arguments.map(_constantNumber).toList();
    if (name == 'remainder') {
      final divisor = numbers.single;
      if (target.enclosingElement?.name != 'double' &&
          _kind(receiver?.staticType) != 'double' &&
          value is! double &&
          _kind(arguments.single.staticType) != 'double' &&
          divisor is! double &&
          (divisor == null || divisor == 0)) {
        types.add('IntegerDivisionByZeroException');
      }
    } else if (name == 'toSigned' || name == 'toUnsigned') {
      final width = numbers.single;
      if (width is! int || width < (name == 'toSigned' ? 1 : 0)) {
        types.add('ArgumentError');
      }
    } else if (name == 'modPow') {
      final exponent = numbers[0];
      final modulus = numbers[1];
      const maximum = 9007199254740991;
      if (exponent is! int ||
          exponent < 0 ||
          modulus is! int ||
          modulus <= 0 ||
          exponent != 0 &&
              (exponent > maximum ||
                  modulus > maximum ||
                  value is! int ||
                  value.abs() > maximum)) {
        types.add('RangeError');
      }
      // Unknown statically int-typed inputs can be NaN on JS, where this
      // method can complete normally; do not invent ArgumentError for them.
      if (exponent is! int && _kind(arguments[0].staticType) != 'int' ||
          modulus is! int && _kind(arguments[1].staticType) != 'int') {
        types.add('ArgumentError');
      }
    } else if (name == 'modInverse') {
      final modulus = numbers.single;
      if (modulus is! int || modulus <= 0) types.add('RangeError');
      if (modulus is! int && _kind(arguments.single.staticType) != 'int') {
        types.add('ArgumentError');
      }
      if (modulus == null ||
          modulus is int &&
              modulus > 1 &&
              (value is! int ||
                  value.abs() > 9007199254740991 ||
                  modulus > 9007199254740991 ||
                  BigInt.from(value).gcd(BigInt.from(modulus)) != BigInt.one)) {
        types.add('Exception');
      }
    } else if (name == 'clamp') {
      final lower = numbers[0];
      final upper = numbers[1];
      if (lower == null || upper == null || lower.compareTo(upper) > 0) {
        types.add('ArgumentError');
      }
    } else {
      final optional = name == 'toStringAsExponential';
      final omittedOrNull =
          optional && (arguments.isEmpty || _constantNull(arguments.single));
      if (!omittedOrNull) {
        final digits = numbers.single;
        final minimum = name == 'toRadixString'
            ? 2
            : name == 'toStringAsPrecision'
            ? 1
            : 0;
        final maximum = name == 'toRadixString'
            ? 36
            : name == 'toStringAsPrecision'
            ? 21
            : 20;
        // JS radix/precision validation also reports ArgumentError for
        // int-typed NaN, independently of ordinary range checks.
        if ((name == 'toRadixString' || name == 'toStringAsPrecision') &&
            digits is! int) {
          types.add('ArgumentError');
        }
        if (digits is! int || digits < minimum || digits > maximum) {
          types.add('RangeError');
        }
      }
    }
    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      // JS checked-entry behavior depends on the representation of an integer
      // artifact. Captured mutable int storage containing NaN can fail these
      // APIs even when a direct final expression completes normally.
      final integerArtifactCheck =
          const {'modPow', 'modInverse', 'toStringAsFixed'}.contains(name) &&
          _kind(argument.staticType) == 'int' &&
          numbers[index] == null;
      if (integerArtifactCheck ||
          _argumentMayFail(argument, target.formalParameters[index])) {
        types.add('TypeError');
      }
    }
    return types.isEmpty
        ? null
        : _source(
            target,
            '${target.enclosingElement?.name}.$name',
            types.toList(),
          );
  }

  static bool _constantNull(Expression expression, [int depth = 0]) {
    if (depth > 32) return false;
    if (expression is NullLiteral) return true;
    if (expression is ParenthesizedExpression) {
      return _constantNull(expression.expression, depth + 1);
    }
    final element = switch (expression) {
      SimpleIdentifier() => expression.element,
      PrefixedIdentifier() => expression.identifier.element,
      PropertyAccess() => expression.propertyName.element,
      _ => null,
    };
    final base = element?.baseElement;
    final variable = base is PropertyAccessorElement ? base.variable : base;
    return variable is VariableElement &&
        variable.isConst &&
        variable.computeConstantValue()?.isNull == true;
  }

  static bool _argumentMayFail(
    Expression argument,
    FormalParameterElement parameter,
  ) {
    final expected = parameter.type;
    if (_constantNull(argument) &&
        expected.nullabilitySuffix == NullabilitySuffix.question) {
      return false;
    }
    if (expected is InterfaceType &&
        expected.element.library.isInSdk &&
        expected.element.library.uri.toString() == 'dart:core') {
      if (expected.element.name == 'BigInt' && _bigInteger(argument) != null) {
        return false;
      }
      final number = _constantNumber(argument);
      // An int-typed value remains an int argument here. SDK bodies may apply
      // their documented range/coercion behavior even if JavaScript obtained
      // NaN through a backend-specific earlier operation. Dynamic or non-int
      // sources continue through the regular type check below.
      if (expected.element.name == 'int' &&
          (_kind(argument.staticType) == 'int' || number is int)) {
        return false;
      }
      if (expected.element.name == 'num' && number != null ||
          expected.element.name == 'int' && number is int) {
        return false;
      }
    }
    final source = argument.staticType;
    return source == null ||
        source is DynamicType ||
        parameter.library?.typeSystem.isSubtypeOf(source, expected) != true;
  }

  static BigInt? _bigInteger(Expression expression, [int depth = 0]) {
    if (depth > 32) return null;
    if (expression is ParenthesizedExpression) {
      return _bigInteger(expression.expression, depth + 1);
    }
    final element = switch (expression) {
      SimpleIdentifier() => expression.element,
      PrefixedIdentifier() => expression.identifier.element,
      PropertyAccess() => expression.propertyName.element,
      _ => null,
    };
    if (isKnownBigIntValueGetter(element)) {
      return switch (element!.baseElement.name) {
        'zero' => BigInt.zero,
        'one' => BigInt.one,
        'two' => BigInt.two,
        _ => null,
      };
    }
    if (expression is PrefixExpression &&
        expression.operator.lexeme == '-' &&
        _nativeNumeric(expression.element)?.enclosingElement?.name ==
            'BigInt') {
      final value = _bigInteger(expression.operand, depth + 1);
      return value == null ? null : -value;
    }
    final (target, arguments) = switch (expression) {
      InstanceCreationExpression() => (
        expression.constructorName.element,
        expression.argumentList.arguments,
      ),
      MethodInvocation() => (
        expression.methodName.element,
        expression.argumentList.arguments,
      ),
      _ => (null, null),
    };
    final native = _nativeNumeric(target);
    if (native is ConstructorElement &&
        native.enclosingElement.name == 'BigInt' &&
        native.name == 'from' &&
        arguments?.length == 1 &&
        arguments!.single is! NamedArgument) {
      final value = _constantNumber(arguments.single.argumentExpression);
      if (value?.isFinite == true) return BigInt.from(value!);
    }
    return null;
  }

  static ThrowSource _source(
    ExecutableElement target,
    String displayName,
    List<String> names,
  ) {
    final exceptionNames = names.toSet().toList();
    final types = [
      for (final name in exceptionNames)
        ?_exceptionClass(target, name)?.thisType,
    ];
    return ThrowSource(
      kind: ThrowSourceKind.arithmeticOperation,
      confidence: ThrowConfidence.possibleThrow,
      displayName: displayName,
      exceptionTypes: exceptionNames,
      resolvedExceptionTypes: types,
      exceptionSupertypes: {
        for (final type in types)
          type.element.name!: type.element.allSupertypes
              .map((type) => type.element.name!)
              .toList(),
      },
    );
  }

  static ClassElement? _exceptionClass(ExecutableElement target, String name) {
    final library = target.library;
    final local = library.getClass(name);
    if (local != null) return local;
    for (final import in library.firstFragment.libraryImports) {
      final imported = import.importedLibrary;
      if (imported?.uri.toString() == 'dart:core') {
        return imported?.getClass(name);
      }
    }
    return null;
  }

  static num? _constantNumber(Expression expression, [int depth = 0]) {
    if (depth > 32) return null;
    return switch (expression) {
      IntegerLiteral() => expression.value,
      DoubleLiteral() => expression.value,
      ParenthesizedExpression() => _constantNumber(
        expression.expression,
        depth + 1,
      ),
      PrefixExpression() when expression.operator.lexeme == '-' => _negate(
        _constantNumber(expression.operand, depth + 1),
      ),
      SimpleIdentifier() => _constantElement(expression.element),
      PrefixedIdentifier() => _constantElement(expression.identifier.element),
      PropertyAccess() => _constantElement(expression.propertyName.element),
      _ => null,
    };
  }

  static num? _negate(num? value) => value == null ? null : -value;

  static num? _constantElement(Element? element) {
    final base = element?.baseElement;
    final variable = base is PropertyAccessorElement ? base.variable : base;
    if (variable is! VariableElement || !variable.isConst) return null;
    final value = variable.computeConstantValue();
    return value?.toIntValue() ?? value?.toDoubleValue();
  }
}
