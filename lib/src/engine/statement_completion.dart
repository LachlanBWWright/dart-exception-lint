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
        (kind: CompletionKind.returned, label: null),
        if (expression != null) _thrown,
      };
    case BreakStatement(:final label):
      return {(kind: CompletionKind.broke, label: label?.name.lexeme)};
    case ContinueStatement(:final label):
      return {(kind: CompletionKind.continued, label: label?.name.lexeme)};
    case ExpressionStatement(:final expression):
      return expression.staticType is NeverType ||
              expression is ThrowExpression ||
              expression is RethrowExpression
          ? {_thrown}
          : {_normal, _thrown};
    case VariableDeclarationStatement(:final variables):
      return variables.variables.any(
            (variable) => variable.initializer?.staticType is NeverType,
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
  _ => null,
};
