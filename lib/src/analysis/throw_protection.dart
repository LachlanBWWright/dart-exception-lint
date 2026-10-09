import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/dart/ast/ast.dart';

import 'exception_annotations.dart';
import 'exception_type_hierarchy.dart';
import '../engine/exception_effect.dart';
import '../engine/statement_completion.dart';

bool isProtectedByCatch(
  AstNode node, {
  bool requireAsyncProtection = false,
  ExceptionChannel? channel,
  List<String> exceptionTypes = const [],
  List<DartType> resolvedExceptionTypes = const [],
  Map<String, List<String>> exceptionSupertypes = const {},
  bool respectExceptionBoundary = true,
}) {
  if (!isReachable(node)) return true;
  if (respectExceptionBoundary && isInsideExceptionBoundary(node)) {
    return true;
  }
  // Awaiting a scheduler handle does not observe errors from its callback.
  if (channel == ExceptionChannel.scheduled) return false;
  // Creating or returning a lazy value does not execute its iterator. A catch
  // at that site cannot contain failures when another function consumes it.
  if (channel == ExceptionChannel.deferred && !consumesDeferredValue(node)) {
    return false;
  }
  if (requireAsyncProtection && _hasAsyncErrorHandler(node)) {
    return true;
  }

  // Each entry is an independently possible thrown type. Ancestors belong to
  // metadata, rather than becoming additional exceptions that must be caught.
  final remainingTypes = exceptionTypes.toSet();
  final remainingResolvedTypes = resolvedExceptionTypes.toSet();
  final typeSystem =
      resolvedExceptionTypes.firstOrNull?.element?.library?.typeSystem;
  AstNode? current = node.parent;
  while (current != null) {
    if (current is TryStatement &&
        current.finallyBlock != null &&
        !_containsNode(current.finallyBlock!, node) &&
        !statementCompletion(current.finallyBlock!).canCompleteNormally &&
        (!requireAsyncProtection || _isAwaited(node, channel: channel))) {
      return true;
    }
    if (current is TryStatement &&
        _containsNode(current.body, node) &&
        (!requireAsyncProtection || _isAwaited(node, channel: channel))) {
      if (current.catchClauses.any(_isUniversalCatch)) return true;
      if (resolvedExceptionTypes.isNotEmpty && typeSystem != null) {
        remainingResolvedTypes.removeWhere(
          (type) =>
              current is TryStatement &&
              current.catchClauses.any(
                (clause) =>
                    clause.exceptionType?.type != null &&
                    typeSystem.isSubtypeOf(type, clause.exceptionType!.type!),
              ),
        );
        if (remainingResolvedTypes.isEmpty) return true;
      }
      remainingTypes.removeWhere(
        (type) =>
            current is TryStatement &&
            current.catchClauses.any(
              (clause) => _catchesType(clause, type, exceptionSupertypes),
            ),
      );
      if (resolvedExceptionTypes.isEmpty &&
          exceptionTypes.isNotEmpty &&
          remainingTypes.isEmpty) {
        return true;
      }
    }
    if (current is FunctionBody) return false;
    current = current.parent;
  }
  return false;
}

bool _isAwaited(AstNode node, {ExceptionChannel? channel}) {
  if (node is ForStatement && node.awaitKeyword != null) return true;
  AstNode? current = node;
  while (current != null) {
    if (current is AwaitExpression || current.parent is AwaitExpression) {
      // Awaiting a Stream yields the Stream object; it does not subscribe.
      if (channel != ExceptionChannel.stream) return true;
      final awaited = current is AwaitExpression ? current.expression : current;
      final type = awaited is Expression ? awaited.staticType : null;
      return type is InterfaceType && type.isDartAsyncFuture;
    }
    if (current.parent is ForEachParts) {
      final loop = current.parent?.parent;
      if (loop is ForStatement) return loop.awaitKeyword != null;
    }
    current = _forwardingFutureParent(current);
  }
  return false;
}

// Only traverse expressions that preserve this value's Future error channel.
// Merely being inside an awaited invocation's arguments proves nothing about
// whether that invocation observes, returns, or discards the supplied Future.
AstNode? _forwardingFutureParent(AstNode node) {
  final parent = node.parent;
  if (parent is ParenthesizedExpression ||
      parent is AsExpression ||
      (parent is PostfixExpression && parent.operator.lexeme == '!') ||
      (parent is AssignmentExpression &&
          identical(parent.rightHandSide, node)) ||
      (parent is ConditionalExpression &&
          (identical(parent.thenExpression, node) ||
              identical(parent.elseExpression, node)))) {
    return parent;
  }
  if (parent is MethodInvocation && identical(parent.realTarget, node)) {
    final element = parent.methodName.element;
    if (element?.library?.uri.toString() == 'dart:core' &&
        const {
          'Iterable',
          'List',
          'Set',
        }.contains(element?.enclosingElement?.name) &&
        const {
          'map',
          'where',
          'expand',
          'take',
          'skip',
          'takeWhile',
          'skipWhile',
          'followedBy',
          'cast',
        }.contains(element?.name)) {
      return parent;
    }
    if (element?.library?.uri.toString() == 'dart:async') {
      final owner = element?.enclosingElement?.name;
      final name = parent.methodName.name;
      if ((owner == 'Future' &&
              const {
                'then',
                'catchError',
                'whenComplete',
                'timeout',
                'ignore',
              }.contains(name)) ||
          (owner == 'Stream' &&
              const {
                'handleError',
                'map',
                'where',
                'take',
                'skip',
                'takeWhile',
                'skipWhile',
                'distinct',
                'asyncMap',
                'asyncExpand',
                'expand',
                'timeout',
                'toList',
                'toSet',
                'drain',
                'join',
                'fold',
                'reduce',
                'firstWhere',
                'lastWhere',
                'singleWhere',
                'elementAt',
                'any',
                'every',
                'contains',
                'forEach',
              }.contains(name))) {
        return parent;
      }
    }
  }
  if (parent is PropertyAccess && identical(parent.realTarget, node)) {
    final element = parent.propertyName.element;
    if (element?.library?.uri.toString() == 'dart:async' &&
        element?.enclosingElement?.name == 'Stream' &&
        const {
          'first',
          'last',
          'single',
          'length',
          'isEmpty',
        }.contains(parent.propertyName.name)) {
      return parent;
    }
  }
  // Future.value adopts the supplied Future rather than dropping its errors.
  if (parent is ArgumentList && parent.arguments.length == 1) {
    final invocation = parent.parent;
    final element = switch (invocation) {
      InstanceCreationExpression(:final constructorName) =>
        constructorName.element,
      MethodInvocation(:final methodName) => methodName.element,
      _ => null,
    };
    if (element?.library?.uri.toString() == 'dart:async' &&
        element?.enclosingElement?.name == 'Future' &&
        element?.name == 'value') {
      return invocation;
    }
  }
  return null;
}

/// The first consumer after expressions known to forward an async value.
AstNode? asyncValueConsumer(AstNode node) {
  var current = node;
  while (true) {
    final forwarding = _forwardingFutureParent(current);
    if (forwarding == null) return current.parent;
    current = forwarding;
  }
}

/// Whether this value reaches a verified synchronous iterator consumer.
bool consumesDeferredValue(AstNode node) {
  var forwarded = node;
  while (true) {
    final parent = _forwardingFutureParent(forwarded);
    if (parent == null) break;
    forwarded = parent;
  }
  final consumer = forwarded.parent;
  if (consumer is ForEachParts || consumer is SpreadElement) return true;
  if (consumer is YieldStatement) return consumer.star != null;
  if (consumer is ArgumentList &&
      consumer.arguments.isNotEmpty &&
      identical(consumer.arguments.first, forwarded)) {
    final invocation = consumer.parent;
    final constructor = invocation is InstanceCreationExpression
        ? invocation.constructorName.element
        : null;
    if (constructor?.library.uri.toString() == 'dart:core') {
      final owner = constructor?.enclosingElement.name;
      final name = constructor?.name;
      return (const {'List', 'Set'}.contains(owner) &&
              const {'from', 'of', 'unmodifiable'}.contains(name)) ||
          (owner == 'Map' &&
              const {'fromIterable', 'fromEntries'}.contains(name));
    }
  }
  final element = switch (consumer) {
    MethodInvocation() => consumer.methodName.element,
    PropertyAccess() => consumer.propertyName.element,
    _ => null,
  };
  if (element?.library?.uri.toString() != 'dart:core' ||
      !const {
        'Iterable',
        'List',
        'Set',
        'Iterator',
      }.contains(element?.enclosingElement?.name)) {
    return false;
  }
  return switch (consumer) {
    MethodInvocation() =>
      identical(consumer.realTarget, forwarded) &&
          const {
            'toList',
            'toSet',
            'forEach',
            'any',
            'every',
            'contains',
            'join',
            'fold',
            'reduce',
            'firstWhere',
            'lastWhere',
            'singleWhere',
            'elementAt',
          }.contains(element?.name),
    PropertyAccess() =>
      identical(consumer.realTarget, forwarded) &&
          const {
            'first',
            'last',
            'single',
            'length',
            'isEmpty',
            'isNotEmpty',
          }.contains(element?.name),
    _ => false,
  };
}

bool _containsNode(AstNode ancestor, AstNode node) =>
    node.offset >= ancestor.offset && node.end <= ancestor.end;

bool _hasAsyncErrorHandler(AstNode node) {
  AstNode? current = node;
  while (current != null) {
    if (current is MethodInvocation &&
        hasUnconditionalAsyncErrorHandler(current)) {
      return true;
    }
    current = _forwardingFutureParent(current);
  }
  return false;
}

/// Whether an SDK chain intercepts every incoming error. A filter that cannot
/// be proven true retains the error effect on the returned Future or Stream.
/// Effects produced by callbacks are analyzed separately at their own sites.
bool hasUnconditionalAsyncErrorHandler(MethodInvocation node) {
  final element = node.methodName.element;
  if (element?.library?.uri.toString() != 'dart:async') return false;
  final owner = element?.enclosingElement?.name;
  final name = node.methodName.name;
  if (owner == 'Future' && name == 'ignore') return true;
  if ((owner == 'Future' && name == 'catchError') ||
      (owner == 'Stream' && name == 'handleError')) {
    final arguments = node.argumentList.arguments;
    if (arguments.isEmpty || _isNullExpression(arguments.first)) return false;
    for (final argument in arguments.whereType<NamedArgument>()) {
      if (argument.name.lexeme == 'test' &&
          !_isAlwaysTrueFilter(argument.argumentExpression)) {
        return false;
      }
    }
    return true;
  }
  if (owner == 'Future' && name == 'then') {
    return node.argumentList.arguments.whereType<NamedArgument>().any(
      (argument) =>
          argument.name.lexeme == 'onError' &&
          !_isNullExpression(argument.argumentExpression),
    );
  }
  return false;
}

bool _isAlwaysTrueFilter(Expression expression) {
  if (_isNullExpression(expression)) return true;
  if (expression is ParenthesizedExpression) {
    return _isAlwaysTrueFilter(expression.expression);
  }
  if (expression is! FunctionExpression) return false;
  final body = expression.body;
  if (body is ExpressionFunctionBody) {
    return body.expression is BooleanLiteral &&
        (body.expression as BooleanLiteral).value;
  }
  if (body is BlockFunctionBody && body.block.statements.length == 1) {
    final statement = body.block.statements.single;
    return statement is ReturnStatement &&
        statement.expression is BooleanLiteral &&
        (statement.expression as BooleanLiteral).value;
  }
  return false;
}

bool _isNullExpression(AstNode node) =>
    node is NullLiteral ||
    (node is AsExpression && _isNullExpression(node.expression)) ||
    (node is ParenthesizedExpression && _isNullExpression(node.expression));

String? _caughtName(CatchClause clause) =>
    clause.exceptionType?.type?.element?.name ??
    clause.exceptionType?.toSource();

bool _isUniversalCatch(CatchClause clause) {
  if (clause.exceptionType == null) return true;
  final type = clause.exceptionType?.type;
  return type is DynamicType ||
      (type is InterfaceType &&
          type.element.name == 'Object' &&
          type.element.library.uri.toString() == 'dart:core');
}

bool _catchesType(
  CatchClause clause,
  String thrownType,
  Map<String, List<String>> exceptionSupertypes,
) {
  final caughtName = _caughtName(clause);
  if (caughtName == null) return true;
  // Catalog labels describe SDK types. A same-named user class is unrelated.
  final caughtType = clause.exceptionType?.type;
  if (caughtType is InterfaceType &&
      caughtType.element.library.uri.scheme != 'dart') {
    return false;
  }
  return ExceptionTypeHierarchy.isSubtypeName(thrownType, caughtName) ||
      (exceptionSupertypes[thrownType]?.contains(caughtName) ?? false);
}
