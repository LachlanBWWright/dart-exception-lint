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
  if (receiver.staticType?.isDartCoreString != true) return false;
  final variable = _localVariable(receiver);
  if (variable == null) return false;
  return _guardedBranches(operation).any(
    (branch) =>
        _provesNonempty(branch.$1, variable, branch.$2) &&
        _retainsValue(branch.$1, variable),
  );
}

/// A single-argument substring permits an offset from zero through length.
bool isProvenSubstringStart(
  AstNode operation,
  Expression receiver,
  Expression start,
) {
  if (start case IntegerLiteral(value: final offset?)) {
    return offset >= 0 &&
        (offset == 0 ||
            receiver is SimpleStringLiteral && offset <= receiver.value.length);
  }
  final receiverVariable = _localVariable(receiver);
  final startVariable = _localVariable(start);
  if (receiverVariable == null ||
      startVariable == null ||
      receiver.staticType?.isDartCoreString != true ||
      start.staticType?.isDartCoreInt != true) {
    return false;
  }
  for (final (condition, truth) in _guardedBranches(operation)) {
    if (!_guardImplies(condition, truth, (lower, upper) {
      return _localVariable(lower) == startVariable &&
          _isStringLength(upper, receiver: receiverVariable);
    })) {
      continue;
    }
    if (!_retainsValue(condition, receiverVariable) ||
        !_retainsValue(condition, startVariable)) {
      continue;
    }
    if (_guardImplies(condition, truth, (lower, upper) {
          return lower is IntegerLiteral &&
              (lower.value ?? -1) >= 0 &&
              _localVariable(upper) == startVariable;
        }) ||
        _localHasNonnegativeValues(startVariable, condition)) {
      return true;
    }
  }
  return false;
}

LocalVariableElement? _declaredLocal(Expression expression) =>
    switch (expression) {
      SimpleIdentifier(element: final LocalVariableElement element) => element,
      _ => null,
    };

VariableElement? _localVariable(Expression expression) => switch (expression) {
  SimpleIdentifier(element: final FormalParameterElement element) => element,
  _ => _declaredLocal(expression),
};

Iterable<(Expression, bool)> _guardedBranches(AstNode operation) sync* {
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
    if (branch != null) yield branch;
    child = parent;
  }
}

bool _guardImplies(
  Expression condition,
  bool truth,
  bool Function(Expression lower, Expression upper) accepts,
) {
  switch (condition) {
    case ParenthesizedExpression(:final expression):
      return _guardImplies(expression, truth, accepts);
    case PrefixExpression(:final operator, :final operand)
        when operator.lexeme == '!':
      return _guardImplies(operand, !truth, accepts);
    case BinaryExpression(
          :final leftOperand,
          :final rightOperand,
          :final operator,
        )
        when truth && operator.lexeme == '&&' ||
            !truth && operator.lexeme == '||':
      return _guardImplies(leftOperand, truth, accepts) ||
          _guardImplies(rightOperand, truth, accepts);
    case BinaryExpression(
          :final element,
          :final leftOperand,
          :final rightOperand,
          :final operator,
        )
        when element?.library.uri.toString() == 'dart:core' &&
            leftOperand.staticType?.isDartCoreInt == true &&
            rightOperand.staticType?.isDartCoreInt == true:
      return switch ((operator.lexeme, truth)) {
        ('<' || '<=', true) ||
        ('>' || '>=', false) => accepts(leftOperand, rightOperand),
        ('>' || '>=', true) ||
        ('<' || '<=', false) => accepts(rightOperand, leftOperand),
        _ => false,
      };
    default:
      return false;
  }
}

bool _isStringLength(Expression expression, {Element? receiver}) {
  final (target, getter) = switch (expression) {
    PropertyAccess(:final realTarget, :final propertyName) => (
      realTarget,
      propertyName.element,
    ),
    PrefixedIdentifier(:final prefix, :final identifier) => (
      prefix,
      identifier.element,
    ),
    _ => (null, null),
  };
  return target != null &&
      (receiver == null || _localVariable(target) == receiver) &&
      getter is GetterElement &&
      getter.library.uri.toString() == 'dart:core' &&
      getter.enclosingElement.name == 'String' &&
      getter.name == 'length';
}

bool _localHasNonnegativeValues(Element variable, Expression guard) {
  if (variable is! LocalVariableElement) return false;
  final body = guard.thisOrAncestorOfType<FunctionBody>();
  if (body == null) return false;
  final index = _IntegerWrites(variable);
  body.accept(index);
  if (!_nonnegativeLiteral(index.initializer)) return false;
  // The initializer establishes the invariant. Every later assignment must
  // preserve it, including assignments in a loop that starts from this value.
  return index.writes.every((write) {
    if (write is! AssignmentExpression || write.operator.lexeme != '=') {
      return false;
    }
    final value = write.rightHandSide;
    return _nonnegativeLiteral(value) ||
        _boundedLoopSuccessor(value, variable, body);
  });
}

bool _nonnegativeLiteral(Expression? expression) =>
    expression is IntegerLiteral && (expression.value ?? -1) >= 0;

bool _boundedLoopSuccessor(
  Expression expression,
  LocalVariableElement preserved,
  FunctionBody body,
) {
  if (expression is! BinaryExpression ||
      expression.operator.lexeme != '+' ||
      expression.element?.library.uri.toString() != 'dart:core' ||
      expression.leftOperand.staticType?.isDartCoreInt != true ||
      expression.rightOperand is! IntegerLiteral ||
      (expression.rightOperand as IntegerLiteral).value != 1) {
    return false;
  }
  final counter = _declaredLocal(expression.leftOperand);
  if (counter == null) return false;
  final loop = expression.thisOrAncestorOfType<ForStatement>();
  final parts = loop?.forLoopParts;
  if (loop == null ||
      parts is! ForPartsWithDeclarations ||
      !identical(expression.thisOrAncestorOfType<FunctionBody>(), body) ||
      expression.offset < loop.body.offset ||
      expression.end > loop.body.end) {
    return false;
  }
  final declaration = parts.variables.variables.singleOrNull;
  final initial = declaration?.initializer;
  final condition = parts.condition;
  final update = parts.updaters.singleOrNull;
  if (declaration?.declaredFragment?.element != counter ||
      initial == null ||
      !(_nonnegativeLiteral(initial) || _localVariable(initial) == preserved) ||
      condition is! BinaryExpression ||
      condition.element?.library.uri.toString() != 'dart:core' ||
      condition.operator.lexeme != '<' ||
      _localVariable(condition.leftOperand) != counter ||
      !_isStringLength(condition.rightOperand) ||
      !_incrementsCounter(update, counter)) {
    return false;
  }
  final writes = _IntegerWrites(counter);
  body.accept(writes);
  // A strictly smaller String offset has room for one increment. The same
  // bound holds when the condition succeeds again before the next iteration.
  return identical(writes.writes.singleOrNull, update);
}

bool _incrementsCounter(Expression? expression, Element counter) =>
    switch (expression) {
      PrefixExpression(:final operand, :final operator) ||
      PostfixExpression(
        :final operand,
        :final operator,
      ) => operator.lexeme == '++' && _localVariable(operand) == counter,
      _ => false,
    };

final class _IntegerWrites extends RecursiveAstVisitor<void> {
  _IntegerWrites(this.variable);

  final LocalVariableElement variable;
  final writes = <AstNode>[];
  Expression? initializer;

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    if (node.declaredFragment?.element == variable) {
      initializer = node.initializer;
    }
    super.visitVariableDeclaration(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (node.element == variable && node.inSetterContext()) {
      writes.add(node.parent!);
    }
  }

  @override
  void visitAssignedVariablePattern(AssignedVariablePattern node) {
    if (node.element == variable) writes.add(node);
  }
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
    if (node.element == variable && node.inSetterContext()) {
      _write(node.offset);
    }
  }

  @override
  void visitAssignedVariablePattern(AssignedVariablePattern node) {
    if (node.element == variable) _write(node.offset);
  }

  void _write(int offset) {
    if (offset >= guardOffset || _nestedFunctions > 0) {
      mayChange = true;
    }
  }
}
