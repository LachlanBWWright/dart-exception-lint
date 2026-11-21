// ignore_for_file: implementation_imports

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/src/dart/ast/utilities.dart';

/// Finds the SDK list allocated by a literal or held in a final local.
ListLiteral? literalListAddReceiver(MethodInvocation node) {
  final target = node.methodName.element;
  if (target is! MethodElement ||
      target.library.uri.toString() != 'dart:core' ||
      target.enclosingElement?.name != 'List' ||
      target.name != 'add') {
    return null;
  }
  return _literalReceiver(node.realTarget);
}

bool isKnownLiteralListIndex(Expression receiver, int index) {
  final literal = _literalReceiver(receiver, immutableLocal: true);
  return index >= 0 &&
      literal != null &&
      index < literal.elements.length &&
      literal.elements.every((element) => element is Expression);
}

ListLiteral? _literalReceiver(
  Expression? expression, {
  bool immutableLocal = false,
}) {
  var receiver = _unparenthesized(expression);
  if (receiver is SimpleIdentifier) {
    final local = receiver.element;
    if (local is! LocalVariableElement ||
        (!local.isFinal && !local.isConst) ||
        local.isLate) {
      return null;
    }
    final fragment = local.firstFragment;
    final declaration = NodeLocator(
      fragment.nameOffset ?? fragment.offset,
    ).searchWithin(receiver.root)?.thisOrAncestorOfType<VariableDeclaration>();
    if (declaration?.declaredFragment?.element != local) return null;
    receiver = _unparenthesized(declaration?.initializer);
    if (immutableLocal &&
        !local.isConst &&
        (receiver is! ListLiteral || receiver.constKeyword == null)) {
      return null;
    }
  }
  return receiver is ListLiteral ? receiver : null;
}

bool literalListAccepts(ListLiteral literal, Expression value) {
  final listType = literal.staticType;
  final valueType = value.staticType;
  if (listType is! InterfaceType || valueType == null) return false;
  final elementType = listType.typeArguments.firstOrNull;
  if (elementType == null) return false;
  if (valueType is DynamicType) {
    return elementType is DynamicType ||
        (elementType.isDartCoreObject &&
            elementType.nullabilitySuffix == NullabilitySuffix.question);
  }
  return listType.element.library.typeSystem.isSubtypeOf(
    valueType,
    elementType,
  );
}

Expression? _unparenthesized(Expression? expression) {
  while (expression is ParenthesizedExpression) {
    expression = expression.expression;
  }
  return expression;
}
