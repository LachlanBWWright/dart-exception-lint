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
final _constructorInputCompletion = Expando<bool>();

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
    case AssertStatement(:final condition):
      return {_normal, if (constantBooleanValue(condition) != true) _thrown};
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
      final selection = ifBranchSelection(expression, statement.caseClause);
      return {
        if (statement.caseClause != null ||
            selection.selects && selection.fallsThrough)
          _thrown,
        if (selection.selects) ..._statement(thenStatement),
        if (selection.fallsThrough)
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
    case SwitchStatement(:final expression):
      if (!expressionCanCompleteNormally(expression)) return {_thrown};
      final selection = _switchSelection(statement);
      final result = <CompletionTransfer>{
        _thrown,
        if (selection.noMatch) _normal,
      };
      for (final member in selection.bodies) {
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
      // The thrown transfer already includes possible implicit failures.
      if (result.contains(_thrown)) {
        if (catchClauses.any((clause) => clause.exceptionType == null)) {
          result.remove(_thrown);
        }
        for (final clause in catchClauses) {
          result.addAll(_statement(clause.body));
        }
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
  if (!_operationCanExecute(node)) return false;
  AstNode? current = node;
  while (current != null) {
    final parent = current.parent;
    if (parent is FunctionBody) {
      final declaration = parent.parent;
      return declaration is! ConstructorDeclaration ||
          (_constructorInputCompletion[declaration] ??=
              _constructorInputsCanComplete(declaration));
    }
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
    if (parent is WhileStatement &&
        identical(current, parent.body) &&
        constantBooleanValue(parent.condition) == false) {
      return false;
    }
    current = parent;
  }
  return true;
}

/// Whether an operation can be skipped by a nullable receiver in its chain.
bool maySkipForNull(AstNode node) {
  final operation = node is AssignmentExpression ? node.leftHandSide : node;
  if (operation is Expression &&
      _selectorShorting(operation) == _NullShorting.possible) {
    return true;
  }
  var child = node;
  for (var parent = child.parent; parent != null; parent = parent.parent) {
    if (parent is FunctionBody) break;
    if (parent is Expression) {
      final receiver = _selectorReceiver(parent);
      if (receiver != null &&
          !identical(child, receiver.target) &&
          _selectorShorting(parent) == _NullShorting.possible) {
        return true;
      }
    }
    if (parent is CascadeExpression &&
        parent.isNullAware &&
        !identical(child, parent.target) &&
        !isDefinitelyNonNull(parent.target)) {
      return true;
    }
    if (parent is AssignmentExpression &&
        identical(child, parent.rightHandSide) &&
        _selectorShorting(parent.leftHandSide) == _NullShorting.possible) {
      return true;
    }
    child = parent;
  }
  return false;
}

// Effects of the operation itself occur after its inputs have been evaluated.
// This check deliberately applies only to the starting node, so a failure in
// an input is still reachable when the containing operation cannot execute.
bool _operationCanExecute(AstNode node) => switch (node) {
  Expression() when _selectorReceiver(node) != null =>
    _selectorInputsCanComplete(node, allowSkipping: false),
  InstanceCreationExpression(:final argumentList) ||
  SuperConstructorInvocation(:final argumentList) ||
  RedirectingConstructorInvocation(
    :final argumentList,
  ) => _argumentsCanCompleteNormally(argumentList),
  ThrowExpression(:final expression) => expressionCanCompleteNormally(
    expression,
  ),
  ForEachParts(iterable: final expression) ||
  SpreadElement(:final expression) ||
  YieldStatement(
    :final expression,
  ) => expressionCanCompleteNormally(expression),
  _ => true,
};

bool _argumentsCanCompleteNormally(ArgumentList arguments) =>
    arguments.arguments.every(
      (argument) => expressionCanCompleteNormally(argument.argumentExpression),
    );

Iterable<Expression> constructorFieldInitializers(
  ClassDeclaration owner,
) sync* {
  for (final field in owner.body.members.whereType<FieldDeclaration>()) {
    if (field.isStatic || field.fields.lateKeyword != null) continue;
    for (final variable in field.fields.variables) {
      if (variable.initializer case final initializer?) yield initializer;
    }
  }
}

bool constructorInitializerCanCompleteNormally(
  ConstructorInitializer initializer,
) => switch (initializer) {
  ConstructorFieldInitializer(:final expression) =>
    expressionCanCompleteNormally(expression),
  SuperConstructorInvocation(:final argumentList) ||
  RedirectingConstructorInvocation(
    :final argumentList,
  ) => _argumentsCanCompleteNormally(argumentList),
  _ => true,
};

bool _constructorInputsCanComplete(
  ConstructorDeclaration declaration, {
  ConstructorInitializer? before,
}) {
  final redirecting = declaration.initializers.any(
    (initializer) => initializer is RedirectingConstructorInvocation,
  );
  if (declaration.factoryKeyword == null && !redirecting) {
    final owner = declaration.thisOrAncestorOfType<ClassDeclaration>();
    if (owner != null &&
        !constructorFieldInitializers(
          owner,
        ).every(expressionCanCompleteNormally)) {
      return false;
    }
  }
  for (final initializer in declaration.initializers) {
    if (identical(initializer, before)) break;
    if (!constructorInitializerCanCompleteNormally(initializer)) return false;
  }
  return true;
}

enum _NullShorting { none, possible, definite }

({Expression? target, bool nullAware})? _selectorReceiver(
  Expression selector,
) => switch (selector) {
  MethodInvocation(:final target, :final isNullAware) ||
  PropertyAccess(:final target, :final isNullAware) ||
  IndexExpression(
    :final target,
    :final isNullAware,
  ) => (target: target, nullAware: isNullAware),
  FunctionExpressionInvocation(:final function) => (
    target: function,
    nullAware: false,
  ),
  PostfixExpression(:final operand, :final operator)
      when operator.lexeme == '!' =>
    (target: operand, nullAware: false),
  _ => null,
};

final _selectorShortingCache = Expando<_NullShorting>();

_NullShorting _selectorShorting(Expression selector) {
  if (_selectorShortingCache[selector] case final cached?) return cached;
  // Parentheses and other non-selector expressions end the chain.
  final receiver = _selectorReceiver(selector);
  final target = receiver?.target;
  if (target == null) return _NullShorting.none;
  final inherited = _selectorShorting(target);
  if (!receiver!.nullAware || inherited == _NullShorting.definite) {
    return _selectorShortingCache[selector] = inherited;
  }
  return _selectorShortingCache[selector] = _isNull(target)
      ? _NullShorting.definite
      : isDefinitelyNonNull(target)
      ? inherited
      : _NullShorting.possible;
}

bool _selectorReceiverCanComplete(Expression selector) {
  final target = _selectorReceiver(selector)?.target;
  return target == null || expressionCanCompleteNormally(target);
}

bool _selectorInputsCanComplete(
  Expression selector, {
  required bool allowSkipping,
}) {
  if (!_selectorReceiverCanComplete(selector)) return false;
  final shorting = _selectorShorting(selector);
  if (allowSkipping && shorting != _NullShorting.none) return true;
  if (shorting == _NullShorting.definite) return false;
  return switch (selector) {
    MethodInvocation(:final argumentList) ||
    FunctionExpressionInvocation(
      :final argumentList,
    ) => _argumentsCanCompleteNormally(argumentList),
    IndexExpression(:final index) => expressionCanCompleteNormally(index),
    _ => true,
  };
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
    SwitchExpression() => _switchExpressionCanComplete(expression),
    AssignmentExpression() => _assignmentCanComplete(expression),
    MethodInvocation() ||
    FunctionExpressionInvocation() ||
    PropertyAccess() ||
    IndexExpression() => _selectorInputsCanComplete(
      expression,
      allowSkipping: true,
    ),
    InstanceCreationExpression(:final argumentList) =>
      _argumentsCanCompleteNormally(argumentList),
    AwaitExpression(:final expression) => expressionCanCompleteNormally(
      expression,
    ),
    RecordLiteral(:final fields) => fields.every(
      (field) => expressionCanCompleteNormally(field.fieldExpression),
    ),
    CascadeExpression(
      :final target,
      :final isNullAware,
      :final cascadeSections,
    ) =>
      expressionCanCompleteNormally(target) &&
          (isNullAware && !isDefinitelyNonNull(target) ||
              cascadeSections.every(expressionCanCompleteNormally)),
    ListLiteral(:final elements) || SetOrMapLiteral(:final elements) =>
      elements.every(_collectionElementCanCompleteNormally),
    _ => true,
  };
}

bool _collectionElementCanCompleteNormally(CollectionElement? element) =>
    switch (element) {
      Expression() => expressionCanCompleteNormally(element),
      SpreadElement(:final expression) ||
      NullAwareElement(
        value: final expression,
      ) => expressionCanCompleteNormally(expression),
      MapLiteralEntry(:final key, :final keyQuestion, :final value) =>
        expressionCanCompleteNormally(key) &&
            (keyQuestion != null && !isDefinitelyNonNull(key) ||
                expressionCanCompleteNormally(value)),
      IfElement(:final expression, :final thenElement, :final elseElement) =>
        expressionCanCompleteNormally(expression) &&
            _ifElementBranchCanComplete(
              ifBranchSelection(expression, element.caseClause),
              thenElement,
              elseElement,
            ),
      ForElement(:final forLoopParts) =>
        _forInputCanCompleteNormally(forLoopParts) &&
            switch (forLoopParts) {
              ForParts(:final condition) =>
                condition != null &&
                    expressionCanCompleteNormally(condition) &&
                    constantBooleanValue(condition) != true,
              ForEachParts() => true,
            },
      _ => true,
    };

typedef BranchSelection = ({bool selects, bool fallsThrough, bool canStop});

BranchSelection ifBranchSelection(Expression subject, CaseClause? clause) {
  if (clause != null) {
    return guardedPatternSelection(subject, clause.guardedPattern);
  }
  final value = constantBooleanValue(subject);
  return (selects: value != false, fallsThrough: value != true, canStop: false);
}

bool _ifElementBranchCanComplete(
  BranchSelection selection,
  CollectionElement thenElement,
  CollectionElement? elseElement,
) =>
    selection.selects && _collectionElementCanCompleteNormally(thenElement) ||
    selection.fallsThrough &&
        _collectionElementCanCompleteNormally(elseElement);

BranchSelection guardedPatternSelection(
  Expression subject,
  GuardedPattern clause,
) {
  final matches = simplePatternMatch(subject, clause.pattern);
  final guard = clause.whenClause?.expression;
  if (guard == null) return _unguardedSelection(matches);
  final completes = expressionCanCompleteNormally(guard);
  final guardValue = constantBooleanValue(guard);
  return (
    selects: matches != false && completes && guardValue != false,
    fallsThrough: matches != true || completes && guardValue != true,
    canStop: matches != false && !completes,
  );
}

BranchSelection _unguardedSelection(bool? matches) =>
    (selects: matches != false, fallsThrough: matches != true, canStop: false);

bool? _matchBooleanValue(Expression subject, Expression pattern) {
  final input = constantBooleanValue(subject);
  final expected = constantBooleanValue(pattern);
  return input == null || expected == null ? null : input == expected;
}

bool? simplePatternMatch(Expression subject, DartPattern pattern) {
  switch (pattern) {
    case WildcardPattern(type: null) || DeclaredVariablePattern(type: null):
      return true;
    case ParenthesizedPattern(:final pattern):
      return simplePatternMatch(subject, pattern);
    case ConstantPattern(:final expression):
      return _matchBooleanValue(subject, expression);
    default:
      return null;
  }
}

typedef _SwitchSelection = ({
  Set<SwitchMember> evaluated,
  Set<SwitchMember> bodies,
  bool noMatch,
});

final _switchSelections = Expando<_SwitchSelection>();

_SwitchSelection _switchSelection(SwitchStatement node) =>
    _switchSelections[node] ??= _selectSwitchMembers(node);

_SwitchSelection _selectSwitchMembers(SwitchStatement node) {
  final members = node.members;
  if (members.any((member) => member.labels.isNotEmpty)) {
    // A labeled continue may enter a case directly from another case body.
    final all = members.toSet();
    return (
      evaluated: all,
      bodies: all,
      noMatch: !members.any((member) => member is SwitchDefault),
    );
  }

  // Consecutive labels with empty bodies share the following case body.
  final memberBodies = <SwitchMember, SwitchMember>{};
  SwitchMember? body;
  SwitchDefault? defaultMember;
  for (final member in members.reversed) {
    if (body == null || member.statements.isNotEmpty) body = member;
    memberBodies[member] = body;
    if (member is SwitchDefault) defaultMember = member;
  }
  final evaluated = <SwitchMember>{};
  final bodies = <SwitchMember>{};
  var fallsThrough = true;
  for (final member in members) {
    if (!fallsThrough) break;
    if (member is SwitchDefault) continue;
    final selection = switch (member) {
      SwitchPatternCase(:final guardedPattern) => guardedPatternSelection(
        node.expression,
        guardedPattern,
      ),
      SwitchCase(:final expression) => _unguardedSelection(
        _matchBooleanValue(node.expression, expression),
      ),
      SwitchDefault() => _unguardedSelection(true),
    };
    evaluated.add(member);
    if (selection.selects) bodies.add(memberBodies[member]!);
    fallsThrough = selection.fallsThrough;
  }
  if (fallsThrough && defaultMember != null) {
    bodies.add(memberBodies[defaultMember]!);
  }
  return (
    evaluated: evaluated,
    bodies: bodies,
    noMatch: fallsThrough && defaultMember == null,
  );
}

bool _switchExpressionCanComplete(SwitchExpression node) {
  if (!expressionCanCompleteNormally(node.expression)) return false;
  for (final arm in node.cases) {
    final selection = guardedPatternSelection(
      node.expression,
      arm.guardedPattern,
    );
    if (selection.selects && expressionCanCompleteNormally(arm.expression)) {
      return true;
    }
    if (!selection.fallsThrough) return false;
  }
  return node.cases.isEmpty;
}

/// Whether the location can be evaluated before reading or writing its value.
bool assignmentTargetCanExecute(AssignmentExpression node) =>
    _assignmentTargetCanComplete(node, allowSkipping: false);

/// Whether evaluation can reach the part of an assignment that writes.
bool assignmentWriteCanExecute(AssignmentExpression node) =>
    _assignmentRightHandSideCanExecute(node) &&
    expressionCanCompleteNormally(node.rightHandSide);

bool _assignmentTargetCanComplete(
  AssignmentExpression node, {
  required bool allowSkipping,
}) => switch (node.leftHandSide) {
  final PropertyAccess access => _selectorInputsCanComplete(
    access,
    allowSkipping: allowSkipping,
  ),
  final IndexExpression access => _selectorInputsCanComplete(
    access,
    allowSkipping: allowSkipping,
  ),
  PrefixedIdentifier(:final prefix) => expressionCanCompleteNormally(prefix),
  _ => true,
};

bool _assignmentReadStops(AssignmentExpression node) {
  final type = node.readType;
  return type is NeverType && type.nullabilitySuffix == NullabilitySuffix.none;
}

bool _assignmentRightHandSideCanExecute(AssignmentExpression node) =>
    assignmentTargetCanExecute(node) &&
    !_assignmentReadStops(node) &&
    (node.operator.lexeme != '??=' || !_knownNonNullType(node.readType));

bool _assignmentCanComplete(AssignmentExpression node) {
  if (!_assignmentTargetCanComplete(node, allowSkipping: true)) return false;
  if (_selectorShorting(node.leftHandSide) != _NullShorting.none) return true;
  if (_assignmentReadStops(node)) return false;
  return node.operator.lexeme == '??=' &&
          node.readType?.isDartCoreNull != true ||
      expressionCanCompleteNormally(node.rightHandSide);
}

bool _childCanExecute(AstNode parent, AstNode child) {
  if (parent is ConstructorDeclaration && child is ConstructorInitializer) {
    return _constructorInputsCanComplete(parent, before: child);
  }
  final assertion = switch (parent) {
    AssertStatement(:final condition, :final message) ||
    AssertInitializer(:final condition, :final message) => (condition, message),
    _ => null,
  };
  if (assertion != null && identical(child, assertion.$2)) {
    return expressionCanCompleteNormally(assertion.$1) &&
        constantBooleanValue(assertion.$1) != true;
  }
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
      '??' => !isDefinitelyNonNull(parent.leftOperand),
      _ => true,
    };
  }
  if (parent is AssignmentExpression &&
      identical(child, parent.rightHandSide)) {
    return _assignmentRightHandSideCanExecute(parent);
  }
  if (parent is ConditionalExpression && !identical(child, parent.condition)) {
    if (!expressionCanCompleteNormally(parent.condition)) return false;
    final value = constantBooleanValue(parent.condition);
    if (identical(child, parent.thenExpression)) return value != false;
    if (identical(child, parent.elseExpression)) return value != true;
  }
  if (parent is Expression) {
    final receiver = _selectorReceiver(parent);
    if (receiver != null && !identical(child, receiver.target)) {
      return _selectorReceiverCanComplete(parent) &&
          _selectorShorting(parent) != _NullShorting.definite;
    }
  }
  if (parent is IfStatement && !identical(child, parent.expression)) {
    if (!expressionCanCompleteNormally(parent.expression)) return false;
    final selection = ifBranchSelection(parent.expression, parent.caseClause);
    if (identical(child, parent.thenStatement)) return selection.selects;
    if (identical(child, parent.elseStatement)) return selection.fallsThrough;
  }
  if (parent is IfElement && !identical(child, parent.expression)) {
    if (!expressionCanCompleteNormally(parent.expression)) return false;
    final selection = ifBranchSelection(parent.expression, parent.caseClause);
    if (identical(child, parent.thenElement)) return selection.selects;
    if (identical(child, parent.elseElement)) return selection.fallsThrough;
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
    if (loop is ForElement &&
        !_collectionElementCanCompleteNormally(loop.body)) {
      return false;
    }
    for (final updater in parent.updaters) {
      if (identical(updater, child)) break;
      if (!expressionCanCompleteNormally(updater)) return false;
    }
  }
  if (parent is ForLoop<AstNode> && identical(child, parent.body)) {
    final parts = parent.forLoopParts;
    if (!_forInputCanCompleteNormally(parts)) return false;
    if (parts is ForParts && parts.condition != null) {
      return expressionCanCompleteNormally(parts.condition!) &&
          constantBooleanValue(parts.condition!) != false;
    }
  }
  if (parent is SwitchStatement && child is SwitchMember) {
    if (!expressionCanCompleteNormally(parent.expression)) return false;
    final selection = _switchSelection(parent);
    return selection.evaluated.contains(child) ||
        selection.bodies.contains(child);
  }
  if (parent is SwitchMember) {
    final owner = parent.parent;
    if (owner is SwitchStatement) {
      final selection = _switchSelection(owner);
      if (child is Statement) return selection.bodies.contains(parent);
      return selection.evaluated.contains(parent);
    }
  }
  if (parent is SwitchExpression && child is SwitchExpressionCase) {
    final subject = parent.expression;
    if (!expressionCanCompleteNormally(subject)) return false;
    for (final arm in parent.cases) {
      if (identical(arm, child)) break;
      if (!guardedPatternSelection(subject, arm.guardedPattern).fallsThrough) {
        return false;
      }
    }
    return simplePatternMatch(subject, child.guardedPattern.pattern) != false;
  }
  if (parent is SwitchExpressionCase && identical(child, parent.expression)) {
    final owner = parent.parent;
    if (owner is SwitchExpression) {
      return guardedPatternSelection(
        owner.expression,
        parent.guardedPattern,
      ).selects;
    }
  }
  if (parent is GuardedPattern && child is WhenClause) {
    final subject = switch (parent.parent?.parent) {
      IfStatement(:final expression) ||
      IfElement(:final expression) ||
      SwitchExpression(:final expression) ||
      SwitchStatement(:final expression) => expression,
      _ => null,
    };
    if (subject != null) {
      return simplePatternMatch(subject, parent.pattern) != false;
    }
  }
  if (parent is TryStatement && child is CatchClause) {
    return statementCompletion(parent.body).transfers.contains(_thrown);
  }
  if (parent is RecordLiteral && child is RecordLiteralField) {
    for (final field in parent.fields) {
      if (identical(child, field)) break;
      if (!expressionCanCompleteNormally(field.fieldExpression)) return false;
    }
  }
  if (parent is CascadeExpression && !identical(child, parent.target)) {
    if (!expressionCanCompleteNormally(parent.target) ||
        parent.isNullAware && _isNull(parent.target)) {
      return false;
    }
    for (final section in parent.cascadeSections) {
      if (identical(section, child)) break;
      if (!expressionCanCompleteNormally(section)) return false;
    }
  }
  if (parent is MapLiteralEntry && identical(child, parent.value)) {
    return expressionCanCompleteNormally(parent.key) &&
        !(parent.keyQuestion != null && _isNull(parent.key));
  }
  final elements = switch (parent) {
    ListLiteral(:final elements) ||
    SetOrMapLiteral(:final elements) => elements,
    _ => null,
  };
  if (elements != null && child is CollectionElement) {
    for (final element in elements) {
      if (identical(element, child)) break;
      if (!_collectionElementCanCompleteNormally(element)) return false;
    }
  }
  return true;
}

bool _isNull(Expression expression) =>
    expression.staticType?.isDartCoreNull == true ||
    _constantVariable(expression)?.computeConstantValue()?.isNull == true ||
    expression is NullLiteral ||
    expression is ParenthesizedExpression && _isNull(expression.expression);

bool _knownNonNullType(DartType? type) =>
    (type is InterfaceType || type is FunctionType) &&
    type!.nullabilitySuffix == NullabilitySuffix.none &&
    !type.isDartCoreNull;

bool isDefinitelyNonNull(Expression expression) =>
    _knownNonNullType(expression.staticType) ||
    _constantVariable(expression)?.computeConstantValue()?.isNull == false ||
    expression is Literal && expression is! NullLiteral ||
    expression is FunctionExpression ||
    expression is ParenthesizedExpression &&
        isDefinitelyNonNull(expression.expression);

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
