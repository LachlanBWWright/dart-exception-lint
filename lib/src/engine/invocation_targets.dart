import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

/// Executables called by syntax that does not look like a method invocation.
/// Compound writes execute a read, an operator, and a write independently.
Iterable<Element?> invocationTargets(
  AstNode node,
  LibraryElement library,
) sync* {
  switch (node) {
    case AssignmentExpression():
      if (node.readElement is ExecutableElement) yield node.readElement;
      if (node.element != null) yield node.element;
      if (node.writeElement is ExecutableElement) yield node.writeElement;
      if (node.writeElement == null &&
          node.leftHandSide is PropertyAccess &&
          (node.leftHandSide as PropertyAccess).realTarget.staticType
              is DynamicType) {
        yield null;
      }
    case PrefixExpression():
      if (node.readElement is ExecutableElement) yield node.readElement;
      if (node.element != null || node.operand.staticType is DynamicType) {
        yield node.element;
      }
      if (node.writeElement is ExecutableElement) yield node.writeElement;
    case PostfixExpression():
      if (node.readElement is ExecutableElement) yield node.readElement;
      if (node.element != null || node.operand.staticType is DynamicType) {
        yield node.element;
      }
      if (node.writeElement is ExecutableElement) yield node.writeElement;
    case InterpolationExpression():
      final type = node.expression.staticType;
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
