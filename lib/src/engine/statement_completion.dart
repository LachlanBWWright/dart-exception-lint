import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';

/// Structural completion facts, independent of exception-source inference.
/// Unknown expressions/statements retain normal completion. A missing normal
/// transfer is therefore a proof that subsequent statements cannot execute.
enum CompletionKind { normal, returned, thrown, broke, continued }

typedef CompletionTransfer = ({CompletionKind kind, String? label});

const _normal = (kind: CompletionKind.normal, label: null);
const _thrown = (kind: CompletionKind.thrown, label: null);

final class StatementCompletion {
  StatementCompletion(Iterable<CompletionTransfer> transfers)
    : transfers = Set.unmodifiable(transfers);

  final Set<CompletionTransfer> transfers;
  bool get canCompleteNormally => transfers.contains(_normal);
}

final _completionCache = Expando<StatementCompletion>();

StatementCompletion statementCompletion(Statement statement) =>
    _completionCache[statement] ??= StatementCompletion(_statement(statement));

Set<CompletionTransfer> _sequence(Iterable<Statement> statements) {
  var result = <CompletionTransfer>{_normal};
  for (final statement in statements) {
    if (!result.remove(_normal)) break;
    result.addAll(_statement(statement));
  }
  return result;
}

Set<CompletionTransfer> _statement(
  Statement statement, {
  Set<String> loopLabels = const {},
}) {
  switch (statement) {
    case Block(:final statements):
      return _sequence(statements);
    case ReturnStatement(:final expression):
      return {
        if (expression == null || expressionCanCompleteNormally(expression))
          (kind: CompletionKind.returned, label: null),
        if (expression != null) _thrown,
      };
    case BreakStatement(:final label):
      return {(kind: CompletionKind.broke, label: label?.name.lexeme)};
    case ContinueStatement(:final label):
      return {(kind: CompletionKind.continued, label: label?.name.lexeme)};
    case ExpressionStatement(:final expression):
      return !expressionCanCompleteNormally(expression)
          ? {_thrown}
          : {_normal, _thrown};
    case VariableDeclarationStatement(:final variables):
      if (variables.isLate) return {_normal};
      return {
        if (_variablesCanCompleteNormally(variables)) _normal,
        if (variables.variables.any((variable) => variable.initializer != null))
          _thrown,
      };
    case PatternVariableDeclarationStatement(:final declaration):
      return {
        if (expressionCanCompleteNormally(declaration.expression)) _normal,
        _thrown,
      };
    case IfStatement(
      :final expression,
      :final thenStatement,
      :final elseStatement,
    ):
      if (!expressionCanCompleteNormally(expression)) return {_thrown};
      final condition = statement.caseClause == null
          ? constantBooleanValue(expression)
          : null;
      if (condition == true) return _statement(thenStatement);
      if (condition == false) {
        return elseStatement == null ? {_normal} : _statement(elseStatement);
      }
      return {
        _thrown,
        ..._statement(thenStatement),
        if (elseStatement == null) _normal else ..._statement(elseStatement),
      };
    case LabeledStatement(:final labels, :final statement):
      final names = labels.map((label) => label.name.lexeme).toSet();
      final result = _statement(
        statement,
        loopLabels: {...loopLabels, ...names},
      );
      final exits = result
          .where(
            (transfer) =>
                transfer.kind == CompletionKind.broke &&
                names.contains(transfer.label),
          )
          .toList();
      if (exits.isNotEmpty) {
        result.removeAll(exits);
        result.add(_normal);
      }
      return result;
    case WhileStatement(:final condition, :final body):
      if (!expressionCanCompleteNormally(condition)) return {_thrown};
      if (constantBooleanValue(condition) == false) return {_normal};
      return {
        if (constantBooleanValue(condition) == null) _thrown,
        ..._loop(
          _statement(body),
          mayExitCondition: constantBooleanValue(condition) != true,
          labels: loopLabels,
        ),
      };
    case DoStatement(:final condition, :final body):
      final conditionValue = constantBooleanValue(condition);
      return _loop(
        _statement(body),
        mayExitCondition: false,
        labels: loopLabels,
        afterBody: {
          if (conditionValue == null) _thrown,
          if (conditionValue != true &&
              expressionCanCompleteNormally(condition))
            _normal,
        },
      );
    case ForStatement(:final forLoopParts, :final body):
      if (!_forInputCanCompleteNormally(forLoopParts)) return {_thrown};
      final condition = forLoopParts is ForParts
          ? forLoopParts.condition
          : null;
      final conditionValue = condition == null
          ? null
          : constantBooleanValue(condition);
      if (condition != null) {
        if (!expressionCanCompleteNormally(condition)) return {_thrown};
        if (conditionValue == false) return {_normal, _thrown};
      }
      return {
        _thrown,
        ..._loop(
          _statement(body),
          mayExitCondition:
              forLoopParts is ForEachParts ||
              (condition != null && conditionValue != true),
          labels: loopLabels,
        ),
      };
    case SwitchStatement(:final expression, :final members):
      if (!expressionCanCompleteNormally(expression)) return {_thrown};
      final result = <CompletionTransfer>{
        _thrown,
        if (!members.any((member) => member is SwitchDefault)) _normal,
      };
      for (final member in members) {
        final transfers = _sequence(member.statements);
        for (final transfer in transfers) {
          result.add(
            transfer.kind == CompletionKind.broke && transfer.label == null
                ? _normal
                : transfer,
          );
        }
      }
      return result;
    case TryStatement(:final body, :final catchClauses, :final finallyBlock):
      final result = _statement(body);
      // Catch bodies can execute after implicit failures as well as explicit
      // throws. Keep all of them unless a later interpreter proves unreachable.
      if (catchClauses.any((clause) => clause.exceptionType == null)) {
        result.remove(_thrown);
      }
      for (final clause in catchClauses) {
        result.addAll(_statement(clause.body));
      }
      if (finallyBlock == null || result.isEmpty) return result;
      final finalTransfers = _statement(finallyBlock);
      return {
        if (finalTransfers.contains(_normal)) ...result,
        ...finalTransfers.where(
          (transfer) => transfer.kind != CompletionKind.normal,
        ),
      };
    default:
      return {_normal, _thrown};
  }
}

Set<CompletionTransfer> _loop(
  Set<CompletionTransfer> body, {
  required bool mayExitCondition,
  required Set<String> labels,
  Set<CompletionTransfer> afterBody = const {},
}) {
  final result = <CompletionTransfer>{if (mayExitCondition) _normal};
  for (final transfer in body) {
    final targetsLoop =
        transfer.label == null || labels.contains(transfer.label);
    if (_continuesLoop(transfer, labels)) {
      result.addAll(afterBody);
    } else if (transfer.kind == CompletionKind.broke && targetsLoop) {
      result.add(_normal);
    } else {
      result.add(transfer);
    }
  }
  return result;
}

bool _continuesLoop(CompletionTransfer transfer, Set<String> labels) =>
    transfer.kind == CompletionKind.normal ||
    transfer.kind == CompletionKind.continued &&
        (transfer.label == null || labels.contains(transfer.label));

bool _reachesNextIteration(Statement loop, Statement body) {
  final labels = <String>{};
  for (
    var parent = loop.parent;
    parent is LabeledStatement;
    parent = parent.parent
  ) {
    labels.addAll(parent.labels.map((label) => label.name.lexeme));
  }
  return statementCompletion(
    body,
  ).transfers.any((transfer) => _continuesLoop(transfer, labels));
}

bool _variablesCanCompleteNormally(VariableDeclarationList variables) =>
    variables.isLate ||
    variables.variables.every((variable) {
      final initializer = variable.initializer;
      return initializer == null || expressionCanCompleteNormally(initializer);
    });

bool _forInputCanCompleteNormally(ForLoopParts parts) => switch (parts) {
  ForEachParts(:final iterable) => expressionCanCompleteNormally(iterable),
  ForPartsWithDeclarations(:final variables) => _variablesCanCompleteNormally(
    variables,
  ),
  ForPartsWithExpression(:final initialization) =>
    initialization == null || expressionCanCompleteNormally(initialization),
  ForPartsWithPattern(:final variables) => expressionCanCompleteNormally(
    variables.expression,
  ),
};

/// Whether lexical control flow permits execution of this node. Callable
/// bodies are separate entry points, including hoisted local declarations.
bool isReachable(AstNode node) {
  AstNode? current = node;
  while (current != null) {
    final parent = current.parent;
    if (parent is FunctionBody) return true;
    if (parent != null && !_childCanExecute(parent, current)) return false;
    final statements = switch (parent) {
      Block(:final statements) || SwitchMember(:final statements) => statements,
      _ => null,
    };
    if (statements != null && current is Statement) {
      for (final statement in statements) {
        if (identical(statement, current)) break;
        if (!statementCompletion(statement).canCompleteNormally) return false;
      }
    }
    if (parent is IfStatement && parent.caseClause == null) {
      final condition = constantBooleanValue(parent.expression);
      if ((condition == false && identical(current, parent.thenStatement)) ||
          (condition == true && identical(current, parent.elseStatement))) {
        return false;
      }
    }
    if (parent is WhileStatement &&
        identical(current, parent.body) &&
        constantBooleanValue(parent.condition) == false) {
      return false;
    }
    current = parent;
  }
  return true;
}

/// Whether an expression has any structurally possible normal result. This is
/// deliberately independent of exception inference: an opaque call may return,
/// while a throw or a resolved Never result cannot. Closures are values; their
/// bodies execute only at separate entry points.
bool expressionCanCompleteNormally(Expression expression) {
  final type = expression.staticType;
  if (type is NeverType && type.nullabilitySuffix == NullabilitySuffix.none ||
      expression is ThrowExpression ||
      expression is RethrowExpression) {
    return false;
  }
  return switch (expression) {
    ParenthesizedExpression(:final expression) ||
    AsExpression(
      :final expression,
    ) => expressionCanCompleteNormally(expression),
    PrefixExpression(:final operand) ||
    PostfixExpression(:final operand) => expressionCanCompleteNormally(operand),
    BinaryExpression(
      :final leftOperand,
      :final operator,
      :final rightOperand,
    ) =>
      expressionCanCompleteNormally(leftOperand) &&
          switch (operator.lexeme) {
            '&&' =>
              constantBooleanValue(leftOperand) != true ||
                  expressionCanCompleteNormally(rightOperand),
            '||' =>
              constantBooleanValue(leftOperand) != false ||
                  expressionCanCompleteNormally(rightOperand),
            '??' =>
              !_isNull(leftOperand) ||
                  expressionCanCompleteNormally(rightOperand),
            _ => expressionCanCompleteNormally(rightOperand),
          },
    ConditionalExpression(
      :final condition,
      :final thenExpression,
      :final elseExpression,
    ) =>
      expressionCanCompleteNormally(condition) &&
          switch (constantBooleanValue(condition)) {
            true => expressionCanCompleteNormally(thenExpression),
            false => expressionCanCompleteNormally(elseExpression),
            null =>
              expressionCanCompleteNormally(thenExpression) ||
                  expressionCanCompleteNormally(elseExpression),
          },
    MethodInvocation(:final target, :final argumentList) =>
      (target == null || expressionCanCompleteNormally(target)) &&
          (expression.isNullAware && target != null && !_isNonNull(target) ||
              argumentList.arguments.every(
                (argument) =>
                    expressionCanCompleteNormally(argument.argumentExpression),
              )),
    FunctionExpressionInvocation(:final function, :final argumentList) =>
      expressionCanCompleteNormally(function) &&
          argumentList.arguments.every(
            (argument) =>
                expressionCanCompleteNormally(argument.argumentExpression),
          ),
    InstanceCreationExpression(:final argumentList) =>
      argumentList.arguments.every(
        (argument) =>
            expressionCanCompleteNormally(argument.argumentExpression),
      ),
    AwaitExpression(:final expression) => expressionCanCompleteNormally(
      expression,
    ),
    RecordLiteral(:final fields) => fields.every(
      (field) => expressionCanCompleteNormally(field.fieldExpression),
    ),
    _ => true,
  };
}

bool _childCanExecute(AstNode parent, AstNode child) {
  if (parent is ArgumentList && child is Argument) {
    for (final argument in parent.arguments) {
      if (identical(child, argument)) break;
      if (!expressionCanCompleteNormally(argument.argumentExpression)) {
        return false;
      }
    }
  }
  if (parent is VariableDeclarationList &&
      !parent.isLate &&
      child is VariableDeclaration) {
    for (final variable in parent.variables) {
      if (identical(variable, child)) break;
      if (variable.initializer != null &&
          !expressionCanCompleteNormally(variable.initializer!)) {
        return false;
      }
    }
  }
  if (parent is BinaryExpression && identical(child, parent.rightOperand)) {
    if (!expressionCanCompleteNormally(parent.leftOperand)) return false;
    return switch (parent.operator.lexeme) {
      '&&' => constantBooleanValue(parent.leftOperand) != false,
      '||' => constantBooleanValue(parent.leftOperand) != true,
      '??' => !_isNonNull(parent.leftOperand),
      _ => true,
    };
  }
  if (parent is ConditionalExpression && !identical(child, parent.condition)) {
    if (!expressionCanCompleteNormally(parent.condition)) return false;
    final value = constantBooleanValue(parent.condition);
    if (identical(child, parent.thenExpression)) return value != false;
    if (identical(child, parent.elseExpression)) return value != true;
  }
  if (parent is MethodInvocation && identical(child, parent.argumentList)) {
    final target = parent.target;
    if (target != null && !expressionCanCompleteNormally(target)) return false;
    if (parent.isNullAware && target != null && _isNull(target)) return false;
  }
  if (parent is FunctionExpressionInvocation &&
      identical(child, parent.argumentList)) {
    return expressionCanCompleteNormally(parent.function);
  }
  if (parent is IfStatement && !identical(child, parent.expression)) {
    return expressionCanCompleteNormally(parent.expression);
  }
  if (parent is WhileStatement && identical(child, parent.body)) {
    return expressionCanCompleteNormally(parent.condition);
  }
  if (parent is DoStatement && identical(child, parent.condition)) {
    return _reachesNextIteration(parent, parent.body);
  }
  if (parent is ForParts &&
      child is Expression &&
      (identical(child, parent.condition) || parent.updaters.contains(child))) {
    if (!_forInputCanCompleteNormally(parent)) return false;
    final condition = parent.condition;
    if (identical(child, condition)) return true;
    if (condition != null &&
        (!expressionCanCompleteNormally(condition) ||
            constantBooleanValue(condition) == false)) {
      return false;
    }
    final loop = parent.parent;
    if (loop is ForStatement && !_reachesNextIteration(loop, loop.body)) {
      return false;
    }
    for (final updater in parent.updaters) {
      if (identical(updater, child)) break;
      if (!expressionCanCompleteNormally(updater)) return false;
    }
  }
  if (parent is ForStatement && identical(child, parent.body)) {
    final parts = parent.forLoopParts;
    if (!_forInputCanCompleteNormally(parts)) return false;
    if (parts is ForParts && parts.condition != null) {
      return expressionCanCompleteNormally(parts.condition!) &&
          constantBooleanValue(parts.condition!) != false;
    }
  }
  if (parent is SwitchStatement && child is SwitchMember) {
    return expressionCanCompleteNormally(parent.expression);
  }
  if (parent is RecordLiteral && child is RecordLiteralField) {
    for (final field in parent.fields) {
      if (identical(child, field)) break;
      if (!expressionCanCompleteNormally(field.fieldExpression)) return false;
    }
  }
  return true;
}

bool _isNull(Expression expression) =>
    _constantVariable(expression)?.computeConstantValue()?.isNull == true ||
    expression is NullLiteral ||
    expression is ParenthesizedExpression && _isNull(expression.expression);

bool _isNonNull(Expression expression) =>
    _constantVariable(expression)?.computeConstantValue()?.isNull == false ||
    expression is Literal && expression is! NullLiteral ||
    expression is FunctionExpression ||
    expression is ParenthesizedExpression && _isNonNull(expression.expression);

bool? constantBooleanValue(Expression expression) => switch (expression) {
  BooleanLiteral(:final value) => value,
  ParenthesizedExpression(:final expression) => constantBooleanValue(
    expression,
  ),
  PrefixExpression(:final operator, :final operand)
      when operator.lexeme == '!' =>
    switch (constantBooleanValue(operand)) {
      true => false,
      false => true,
      _ => null,
    },
  BinaryExpression(:final leftOperand, :final operator, :final rightOperand)
      when operator.lexeme == '&&' || operator.lexeme == '||' =>
    switch ((
      constantBooleanValue(leftOperand),
      operator.lexeme,
      constantBooleanValue(rightOperand),
    )) {
      (false, '&&', _) || (true, '||', _) => operator.lexeme == '||',
      (true, '&&', final value) || (false, '||', final value) => value,
      _ => null,
    },
  _ => _constantVariable(expression)?.computeConstantValue()?.toBoolValue(),
};

/// Resolved constants only: ordinary final/local initializers and getter bodies
/// cannot establish a branch fact after mutation, escape or arbitrary execution.
VariableElement? _constantVariable(Expression expression) {
  final element = switch (expression) {
    SimpleIdentifier(:final element) => element,
    PrefixedIdentifier(:final element) => element,
    PropertyAccess(:final propertyName) => propertyName.element,
    _ => null,
  };
  final variable = element is PropertyAccessorElement
      ? element.variable
      : element;
  return variable is VariableElement && variable.isConst ? variable : null;
}
