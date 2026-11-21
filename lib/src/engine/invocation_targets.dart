import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

import 'statement_completion.dart';

bool isAssignmentTarget(AstNode node) {
  final parent = node.parent;
  return parent is AssignmentExpression && identical(parent.leftHandSide, node);
}

GetterElement? unqualifiedGetter(SimpleIdentifier node) {
  final element = node.element;
  final parent = node.parent;
  if (element is! GetterElement ||
      !node.inGetterContext() ||
      isAssignmentTarget(node) ||
      parent is PrefixedIdentifier ||
      parent is PropertyAccess ||
      parent is MethodInvocation && identical(parent.methodName, node)) {
    return null;
  }
  return element;
}

/// Executables called by syntax that does not look like a method invocation.
/// Compound writes execute a read, an operator, and a write independently.
Iterable<Element?> invocationTargets(
  AstNode node,
  LibraryElement library,
) sync* {
  switch (node) {
    case AssignmentExpression():
      if (!assignmentTargetCanExecute(node)) return;
      final operator = node.operator.lexeme;
      final dynamicReceiver = switch (node.leftHandSide) {
        PropertyAccess(:final realTarget) =>
          realTarget.staticType is DynamicType,
        IndexExpression() => hasUnknownIndexAssignmentReceiver(node),
        PrefixedIdentifier(:final prefix) => prefix.staticType is DynamicType,
        _ => false,
      };
      if (node.readElement is ExecutableElement) {
        yield node.readElement;
      } else if (operator != '=' && dynamicReceiver) {
        yield null;
      }
      if (!assignmentWriteCanExecute(node)) return;
      if (node.element != null ||
          operator != '=' &&
              operator != '??=' &&
              assignmentReadType(node) is DynamicType) {
        yield node.element;
      }
      if (node.writeElement is ExecutableElement) yield node.writeElement;
      if (node.writeElement == null && dynamicReceiver) {
        yield null;
      }
    case PrefixExpression():
      if (node.operator.lexeme == '!') return;
      if (node.readElement is ExecutableElement) yield node.readElement;
      if (node.element != null || node.operand.staticType is DynamicType) {
        yield node.element;
      }
      if (node.writeElement is ExecutableElement) yield node.writeElement;
    case PostfixExpression():
      if (node.operator.lexeme == '!') return;
      if (node.readElement is ExecutableElement) yield node.readElement;
      if (node.element != null || node.operand.staticType is DynamicType) {
        yield node.element;
      }
      if (node.writeElement is ExecutableElement) yield node.writeElement;
    case InterpolationExpression():
      final type = node.expression.staticType;
      if (type?.isDartCoreString == true || type?.isDartCoreNull == true) {
        return;
      }
      if (type is InterfaceType) {
        yield type.lookUpMethod('toString', library);
      } else if (type is DynamicType) {
        yield null;
      }
    case PatternField():
      if (node.parent is ObjectPattern) yield node.element;
    case RelationalPattern():
      final type = node.matchedValueType;
      if (!_primitivePatternType(type)) yield node.element;
    case ConstantPattern():
      final type = node.expression.staticType;
      if (!_primitivePatternType(type)) {
        yield type is InterfaceType ? type.lookUpMethod('==', library) : null;
      }
  }
}

bool _primitivePatternType(DartType? type) =>
    type is InterfaceType &&
    type.element.library.uri.toString() == 'dart:core' &&
    const {
      'int',
      'double',
      'num',
      'bool',
      'String',
      'Null',
    }.contains(type.element.name);
