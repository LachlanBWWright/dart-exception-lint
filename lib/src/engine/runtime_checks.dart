import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

import '../analysis/throw_summary.dart';

/// Implicit downcasts inserted by the language at typed value boundaries.
/// Promotion is reflected in the resolved source type supplied by analyzer.
final class RuntimeChecks {
  static ThrowSource? covarianceCheck(
    Expression value,
    FormalParameterElement? parameter,
  ) {
    if (parameter == null) return null;
    final baseType = parameter.baseElement.type;
    final genericClassParameter =
        parameter.enclosingElement is! ConstructorElement &&
        baseType is TypeParameterType &&
        baseType.element.enclosingElement is InterfaceElement;
    final source = value.staticType;
    final narrowed =
        parameter.isCovariant &&
        source != null &&
        parameter.library?.typeSystem.isSubtypeOf(source, parameter.type) !=
            true;
    if (!genericClassParameter && !narrowed) return null;
    return const ThrowSource(
      kind: ThrowSourceKind.asCast,
      confidence: ThrowConfidence.possibleThrow,
      displayName: 'covariant invocation check',
      exceptionTypes: ['TypeError'],
    );
  }

  static Iterable<ThrowSource> dispatchChecks(
    AstNode node,
    ExecutableElement target,
  ) sync* {
    final arguments = switch (node) {
      MethodInvocation(:final argumentList) => argumentList.arguments,
      FunctionExpressionInvocation(:final argumentList) =>
        argumentList.arguments,
      _ => null,
    };
    if (arguments == null) return;
    final positional = target.formalParameters
        .where((parameter) => parameter.isPositional)
        .toList();
    var index = 0;
    for (final argument in arguments) {
      final parameter = argument is NamedArgument
          ? target.formalParameters
                .where((parameter) => parameter.name == argument.name.lexeme)
                .firstOrNull
          : index < positional.length
          ? positional[index++]
          : null;
      final source = covarianceCheck(argument.argumentExpression, parameter);
      if (source != null) yield source;
    }
  }

  /// Substituting a callback body must preserve the invocation's argument
  /// and result checks, including checks at dynamic value boundaries.
  static Iterable<ThrowSource> boundCallbackChecks(
    AstNode node,
    ExecutableElement target,
  ) sync* {
    final arguments = switch (node) {
      MethodInvocation() => node.argumentList.arguments,
      FunctionExpressionInvocation() => node.argumentList.arguments,
      _ => null,
    };
    if (arguments == null) return;
    if (node is Expression) {
      final expected = node.staticType;
      final actual = target.returnType;
      if (expected != null &&
          expected is! DynamicType &&
          expected is! VoidType &&
          !(actual is! DynamicType &&
              target.library.typeSystem.isSubtypeOf(actual, expected)) &&
          !(actual is DynamicType &&
              expected is InterfaceType &&
              expected.isDartCoreObject &&
              expected.nullabilitySuffix.name == 'question')) {
        yield const ThrowSource(
          kind: ThrowSourceKind.asCast,
          confidence: ThrowConfidence.possibleThrow,
          displayName: 'callback result check',
          exceptionTypes: ['TypeError'],
        );
      }
    }
    final positional = target.formalParameters
        .where((parameter) => parameter.isPositional)
        .toList();
    var index = 0;
    for (final argument in arguments) {
      final parameter = argument is NamedArgument
          ? target.formalParameters
                .where(
                  (parameter) =>
                      parameter.isNamed &&
                      parameter.name == argument.name.lexeme,
                )
                .firstOrNull
          : index < positional.length
          ? positional[index++]
          : null;
      if (parameter == null) continue;
      final expected = parameter.type;
      final actual = argument.argumentExpression.staticType;
      if (expected is DynamicType ||
          expected is VoidType ||
          (actual != null &&
              actual is! DynamicType &&
              target.library.typeSystem.isSubtypeOf(actual, expected))) {
        continue;
      }
      if (actual is DynamicType &&
          expected is InterfaceType &&
          expected.isDartCoreObject &&
          expected.nullabilitySuffix.name == 'question') {
        continue;
      }
      yield const ThrowSource(
        kind: ThrowSourceKind.asCast,
        confidence: ThrowConfidence.possibleThrow,
        displayName: 'callback argument check',
        exceptionTypes: ['TypeError'],
      );
    }
  }

  static ThrowSource? castPattern(CastPattern node) {
    final source = node.matchedValueType;
    final target = node.type.type;
    final library = target?.element?.library;
    if (source != null &&
        target != null &&
        library != null &&
        library.typeSystem.isSubtypeOf(source, target)) {
      return null;
    }
    return ThrowSource(
      kind: ThrowSourceKind.asCast,
      confidence: ThrowConfidence.possibleThrow,
      displayName:
          'pattern cast to ${target?.getDisplayString() ?? node.type.toSource()}',
      exceptionTypes: const ['TypeError'],
    );
  }

  static ThrowSource? nullAssertPattern(NullAssertPattern node) {
    final type = node.matchedValueType;
    if (type != null &&
        (type.element?.library?.typeSystem.isNonNullable(type) == true ||
            (type is FunctionType && type.nullabilitySuffix.name == 'none'))) {
      return null;
    }
    return const ThrowSource(
      kind: ThrowSourceKind.nullAssertion,
      confidence: ThrowConfidence.possibleThrow,
      displayName: 'pattern null assertion',
      exceptionTypes: ['TypeError'],
    );
  }

  static ThrowSource? implicitCast(Expression expression, DartType? target) {
    if (expression.staticType is! DynamicType ||
        target == null ||
        target is DynamicType ||
        target is VoidType ||
        (target is InterfaceType &&
            target.isDartCoreObject &&
            target.nullabilitySuffix.name == 'question')) {
      return null;
    }
    return ThrowSource(
      kind: ThrowSourceKind.asCast,
      confidence: ThrowConfidence.possibleThrow,
      displayName: 'implicit cast to ${target.getDisplayString()}',
      exceptionTypes: const ['TypeError'],
    );
  }

  static DartType? returnType(AstNode node) {
    AstNode? parent = node.parent;
    while (parent != null) {
      final ExecutableElement? element = switch (parent) {
        FunctionExpression() => parent.declaredFragment?.element,
        MethodDeclaration() => parent.declaredFragment?.element,
        _ => null,
      };
      if (element != null) {
        final type = element.returnType;
        final body = switch (parent) {
          FunctionExpression() => parent.body,
          MethodDeclaration() => parent.body,
          _ => null,
        };
        return body?.isAsynchronous == true
            ? element.library.typeSystem.flatten(type)
            : type;
      }
      parent = parent.parent;
    }
    return null;
  }
}
