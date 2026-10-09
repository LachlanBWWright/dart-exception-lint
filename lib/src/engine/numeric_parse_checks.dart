import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';

import '../analysis/throw_summary.dart';

/// Exception conditions specific to native numeric parsers.
///
/// `tryParse` suppresses malformed-text failures, but integer parsers still
/// reject radixes outside 2..36. Identity is checked against dart:core so
/// same-named application helpers do not inherit SDK behavior.
final class NumericParseChecks {
  static bool modelsInvocation(AstNode node, Element? element) {
    final target = _nativeParser(element);
    return target != null &&
        (node is MethodInvocation || node is FunctionExpressionInvocation) &&
        const {'parse', 'tryParse'}.contains(target.name);
  }

  static ThrowSource? invocation(AstNode node, Element? element) {
    final target = _nativeParser(element);
    if (target == null || !modelsInvocation(node, element)) return null;
    final List<Argument> arguments = switch (node) {
      MethodInvocation() => node.argumentList.arguments.toList(),
      FunctionExpressionInvocation() => node.argumentList.arguments.toList(),
      _ => <Argument>[],
    };
    final types = <String>{};
    final parser = target.enclosingElement?.name;
    if (parser == null) return null;

    final radixArgument = arguments
        .whereType<NamedArgument>()
        .where((argument) => argument.name.lexeme == 'radix')
        .firstOrNull;
    final radix = radixArgument == null
        ? 10
        : _constantInteger(radixArgument.argumentExpression);
    var invalidRadix = false;
    if (parser == 'int' || parser == 'BigInt') {
      if (radixArgument != null) {
        if (radix == null || radix < 2 || radix > 36) {
          types.add('RangeError');
          invalidRadix = radix != null && (radix < 2 || radix > 36);
        }
        final parameter = target.formalParameters
            .where((parameter) => parameter.name == 'radix')
            .firstOrNull;
        if (parameter != null &&
            _argumentMayFail(radixArgument.argumentExpression, parameter)) {
          types.add('TypeError');
        }
      }
    }

    final positionalParameters = target.formalParameters
        .where((parameter) => parameter.isPositional)
        .toList();
    final positionalArguments = arguments
        .where((argument) => argument is! NamedArgument)
        .toList();
    for (var index = 0; index < positionalArguments.length; index++) {
      if (index >= positionalParameters.length) continue;
      final argument = positionalArguments[index].argumentExpression;
      final parameter = positionalParameters[index];
      if (_argumentMayFail(argument, parameter)) {
        types.add('TypeError');
      }
    }

    if (target.name == 'parse' &&
        !invalidRadix &&
        _parseMayFail(
          parser,
          positionalArguments.firstOrNull,
          radixArgument,
          radix,
        )) {
      types.add('FormatException');
    }

    return types.isEmpty
        ? null
        : ThrowSource(
            kind: ThrowSourceKind.parseCall,
            confidence: ThrowConfidence.possibleThrow,
            displayName: '$parser.${target.name}',
            exceptionTypes: types.toList(),
          );
  }

  static ExecutableElement? _nativeParser(Element? element) {
    final base = element?.baseElement;
    if (base is! ExecutableElement ||
        !base.library.isInSdk ||
        base.library.uri.toString() != 'dart:core' ||
        !const {
          'int',
          'BigInt',
          'num',
          'double',
        }.contains(base.enclosingElement?.name)) {
      return null;
    }
    return base;
  }

  static int? _constantInteger(Expression expression, [int depth = 0]) {
    if (depth > 32) return null;
    if (expression is IntegerLiteral) return expression.value;
    if (expression is NullLiteral) return 10;
    if (expression is ParenthesizedExpression) {
      return _constantInteger(expression.expression, depth + 1);
    }
    final element = switch (expression) {
      SimpleIdentifier() => expression.element,
      PrefixedIdentifier() => expression.identifier.element,
      PropertyAccess() => expression.propertyName.element,
      _ => null,
    };
    final base = element?.baseElement;
    final variable = base is PropertyAccessorElement ? base.variable : base;
    if (variable is VariableElement && variable.isConst) {
      return variable.computeConstantValue()?.toIntValue();
    }
    return null;
  }

  static String? _constantString(Expression? expression, [int depth = 0]) {
    if (expression == null || depth > 32) return null;
    if (expression is StringLiteral) return expression.stringValue;
    if (expression is ParenthesizedExpression) {
      return _constantString(expression.expression, depth + 1);
    }
    final element = switch (expression) {
      SimpleIdentifier() => expression.element,
      PrefixedIdentifier() => expression.identifier.element,
      PropertyAccess() => expression.propertyName.element,
      _ => null,
    };
    final base = element?.baseElement;
    final variable = base is PropertyAccessorElement ? base.variable : base;
    if (variable is VariableElement && variable.isConst) {
      return variable.computeConstantValue()?.toStringValue();
    }
    return null;
  }

  static bool _parseMayFail(
    String parser,
    Argument? sourceArgument,
    NamedArgument? radixArgument,
    int? radix,
  ) {
    final source = _constantString(sourceArgument?.argumentExpression);
    if (source == null) return true;
    if (parser == 'int' || parser == 'BigInt') {
      if (radixArgument != null && radix != null && (radix < 2 || radix > 36)) {
        return false;
      }
      if (radix != null) {
        return !_integerTextParses(parser, source, radix);
      }
      return List<int>.generate(
        35,
        (index) => index + 2,
      ).any((candidate) => !_integerTextParses(parser, source, candidate));
    }
    return parser == 'double'
        ? double.tryParse(source) == null
        : num.tryParse(source) == null;
  }

  static bool _integerTextParses(String parser, String source, int radix) =>
      parser == 'int'
      ? int.tryParse(source, radix: radix) != null
      : BigInt.tryParse(source, radix: radix) != null;

  static bool _argumentMayFail(
    Expression argument,
    FormalParameterElement parameter,
  ) {
    if (argument is NullLiteral &&
        parameter.type.nullabilitySuffix == NullabilitySuffix.question) {
      return false;
    }
    final source = argument.staticType;
    return source == null ||
        source is DynamicType ||
        parameter.library?.typeSystem.isSubtypeOf(source, parameter.type) !=
            true;
  }
}
