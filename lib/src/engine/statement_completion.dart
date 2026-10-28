import 'package:analyzer/dart/ast/ast.dart';
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
      return variables.variables.any(
            (variable) =>
                variable.initializer != null &&
                !expressionCanCompleteNormally(variable.initializer!),
          )
          ? {_thrown}
          : {
              _normal,
              if (variables.variables.any(
                (variable) => variable.initializer != null,
              ))
                _thrown,
            };
    case IfStatement(
      :final expression,
      :final thenStatement,
      :final elseStatement,
    ):
      if (!expressionCanCompleteNormally(expression)) return {_thrown};
      final condition = statement.caseClause == null
          ? _boolean(expression)
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
      if (_boolean(condition) == false) return {_normal};
      return {
        if (_boolean(condition) == null) _thrown,
        ..._loop(
          _statement(body),
          mayExitCondition: _boolean(condition) != true,
          labels: loopLabels,
        ),
      };
    case DoStatement(:final condition, :final body):
      return {
        if (_boolean(condition) == null) _thrown,
        ..._loop(
          _statement(body),
          mayExitCondition: _boolean(condition) != true,
          labels: loopLabels,
          executesOnce: true,
        ),
      };
    case ForStatement(:final forLoopParts, :final body):
      final condition = forLoopParts is ForParts
          ? forLoopParts.condition
          : null;
      final isInfinite =
          forLoopParts is ForParts &&
          (condition == null || _boolean(condition) == true);
      if (condition != null && _boolean(condition) == false) return {_normal};
      return {
        _thrown,
        ..._loop(
          _statement(body),
          mayExitCondition: !isInfinite,
          labels: loopLabels,
        ),
      };
    case SwitchStatement(:final members):
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
  bool executesOnce = false,
}) {
  final result = <CompletionTransfer>{};
  var reachesCondition = false;
  for (final transfer in body) {
    final targetsLoop =
        transfer.label == null || labels.contains(transfer.label);
    if (transfer.kind == CompletionKind.normal ||
        (transfer.kind == CompletionKind.continued && targetsLoop)) {
      reachesCondition = true;
    } else if (transfer.kind == CompletionKind.broke && targetsLoop) {
      result.add(_normal);
    } else {
      result.add(transfer);
    }
  }
  if (mayExitCondition && (!executesOnce || reachesCondition)) {
    result.add(_normal);
  }
  return result;
}

/// Whether lexical control flow permits execution of this node. Callable
/// bodies are separate entry points, including hoisted local declarations.
bool isReachable(AstNode node) {
  AstNode? current = node;
  while (current != null) {
    final parent = current.parent;
    if (parent is FunctionBody) return true;
    if (parent != null && !_childCanExecute(parent, current)) return false;
    if (parent is Block && current is Statement) {
      for (final statement in parent.statements) {
        if (identical(statement, current)) break;
        if (!statementCompletion(statement).canCompleteNormally) return false;
      }
    }
    if (parent is IfStatement && parent.caseClause == null) {
      final condition = _boolean(parent.expression);
      if ((condition == false && identical(current, parent.thenStatement)) ||
          (condition == true && identical(current, parent.elseStatement))) {
        return false;
      }
    }
    if (parent is WhileStatement &&
        identical(current, parent.body) &&
        _boolean(parent.condition) == false) {
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
  if (expression.staticType is NeverType ||
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
              _boolean(leftOperand) != true ||
                  expressionCanCompleteNormally(rightOperand),
            '||' =>
              _boolean(leftOperand) != false ||
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
          switch (_boolean(condition)) {
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
  if (parent is VariableDeclarationList && child is VariableDeclaration) {
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
      '&&' => _boolean(parent.leftOperand) != false,
      '||' => _boolean(parent.leftOperand) != true,
      '??' => !_isNonNull(parent.leftOperand),
      _ => true,
    };
  }
  if (parent is ConditionalExpression && !identical(child, parent.condition)) {
    if (!expressionCanCompleteNormally(parent.condition)) return false;
    final value = _boolean(parent.condition);
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
  if (parent is ForStatement && identical(child, parent.body)) {
    final parts = parent.forLoopParts;
    if (parts is ForParts && parts.condition != null) {
      return expressionCanCompleteNormally(parts.condition!) &&
          _boolean(parts.condition!) != false;
    }
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
    expression is NullLiteral ||
    expression is ParenthesizedExpression && _isNull(expression.expression);

bool _isNonNull(Expression expression) =>
    expression is Literal && expression is! NullLiteral ||
    expression is FunctionExpression ||
    expression is ParenthesizedExpression && _isNonNull(expression.expression);

bool? _boolean(Expression expression) => switch (expression) {
  BooleanLiteral(:final value) => value,
  ParenthesizedExpression(:final expression) => _boolean(expression),
  PrefixExpression(:final operator, :final operand)
      when operator.lexeme == '!' =>
    switch (_boolean(operand)) {
      true => false,
      false => true,
      _ => null,
    },
  BinaryExpression(:final leftOperand, :final operator, :final rightOperand)
      when operator.lexeme == '&&' || operator.lexeme == '||' =>
    switch ((_boolean(leftOperand), operator.lexeme, _boolean(rightOperand))) {
      (false, '&&', _) || (true, '||', _) => operator.lexeme == '||',
      (true, '&&', final value) || (false, '||', final value) => value,
      _ => null,
    },
  _ => null,
};
