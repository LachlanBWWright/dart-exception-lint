import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';

/// Proves that a String read at zero follows a nonempty check on the same value.
bool isProvenStringZeroIndex(
  AstNode operation,
  Expression receiver,
  Expression index,
) {
  if (index is! IntegerLiteral || index.value != 0) return false;
  if (receiver is SimpleStringLiteral) return receiver.value.isNotEmpty;
  if (receiver is! SimpleIdentifier ||
      receiver.staticType?.isDartCoreString != true) {
    return false;
  }
  final variable = receiver.element;
  if (variable == null ||
      (variable is! LocalVariableElement &&
          variable is! FormalParameterElement)) {
    return false;
  }
  var child = operation;
  for (var parent = child.parent; parent != null; parent = parent.parent) {
    if (parent is FunctionBody) break;
    final branch = switch (parent) {
      IfStatement(
        :final expression,
        :final thenStatement,
        :final elseStatement,
        caseClause: null,
      )
          when identical(child, thenStatement) ||
              identical(child, elseStatement) =>
        (expression, identical(child, thenStatement)),
      ConditionalExpression(
        :final condition,
        :final thenExpression,
        :final elseExpression,
      )
          when identical(child, thenExpression) ||
              identical(child, elseExpression) =>
        (condition, identical(child, thenExpression)),
      BinaryExpression(:final leftOperand, :final rightOperand, :final operator)
          when identical(child, rightOperand) &&
              (operator.lexeme == '&&' || operator.lexeme == '||') =>
        (leftOperand, operator.lexeme == '&&'),
      _ => null,
    };
    if (branch != null &&
        _provesNonempty(branch.$1, variable, branch.$2) &&
        _retainsValue(branch.$1, variable)) {
      return true;
    }
    child = parent;
  }
  return false;
}

bool _provesNonempty(Expression condition, Element variable, bool truth) {
  switch (condition) {
    case ParenthesizedExpression(:final expression):
      return _provesNonempty(expression, variable, truth);
    case PrefixExpression(:final operator, :final operand)
        when operator.lexeme == '!':
      return _provesNonempty(operand, variable, !truth);
    case BinaryExpression(
          :final leftOperand,
          :final rightOperand,
          :final operator,
        )
        when truth && operator.lexeme == '&&' ||
            !truth && operator.lexeme == '||':
      return _provesNonempty(leftOperand, variable, truth) ||
          _provesNonempty(rightOperand, variable, truth);
    case PropertyAccess(
      realTarget: final SimpleIdentifier target,
      :final propertyName,
    ):
      return target.element == variable &&
          _isNonemptyGetter(propertyName.element, truth);
    case PrefixedIdentifier(:final prefix, :final identifier):
      return prefix.element == variable &&
          _isNonemptyGetter(identifier.element, truth);
    default:
      return false;
  }
}

bool _isNonemptyGetter(Element? element, bool truth) =>
    element is GetterElement &&
    element.library.uri.toString() == 'dart:core' &&
    element.enclosingElement.name == 'String' &&
    element.name == (truth ? 'isNotEmpty' : 'isEmpty');

bool _retainsValue(Expression condition, Element variable) {
  if (variable is VariableElement && variable.isFinal) return true;
  final body = condition.thisOrAncestorOfType<FunctionBody>();
  final owner = switch (body?.parent) {
    FunctionExpression(:final declaredFragment) => declaredFragment?.element,
    MethodDeclaration(:final declaredFragment) => declaredFragment?.element,
    ConstructorDeclaration(:final declaredFragment) =>
      declaredFragment?.element,
    _ => null,
  };
  if (body == null || owner == null || owner != variable.enclosingElement) {
    return false;
  }
  final writes = _StringWrites(variable, condition.offset);
  body.accept(writes);
  return !writes.mayChange;
}

final class _StringWrites extends RecursiveAstVisitor<void> {
  _StringWrites(this.variable, this.guardOffset);

  final Element variable;
  final int guardOffset;
  int _nestedFunctions = 0;
  bool mayChange = false;

  @override
  void visitFunctionExpression(FunctionExpression node) {
    if (mayChange) return;
    _nestedFunctions++;
    super.visitFunctionExpression(node);
    _nestedFunctions--;
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (node.element == variable &&
        node.inSetterContext() &&
        (node.offset >= guardOffset || _nestedFunctions > 0)) {
      mayChange = true;
    }
  }
}
