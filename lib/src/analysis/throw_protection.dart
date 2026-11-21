import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';

import 'exception_annotations.dart';
import 'exception_type_hierarchy.dart';
import 'throw_source_catalog.dart';
import '../engine/exception_effect.dart';
import '../engine/statement_completion.dart';
import '../engine/future_forwarding.dart';

bool isProtectedByCatch(
  AstNode node, {
  bool requireAsyncProtection = false,
  ExceptionChannel? channel,
  List<String> exceptionTypes = const [],
  List<DartType> resolvedExceptionTypes = const [],
  Map<String, List<String>> exceptionSupertypes = const {},
  bool respectExceptionBoundary = true,
  bool skipCurrentAsyncHandler = false,
}) {
  if (!isReachable(node)) return true;
  if (respectExceptionBoundary && isInsideExceptionBoundary(node)) {
    return true;
  }
  // Awaiting a scheduler handle does not observe errors from its callback.
  if (channel == ExceptionChannel.scheduled) return false;
  if (channel == ExceptionChannel.deferred) {
    final consumer = deferredExecutionSite(node);
    // Creating a lazy value does not execute its iterator. Containment must
    // apply at the operation that advances it, after that operation's inputs.
    if (consumer == null) {
      final local = deferredLocalUses(node);
      return local != null &&
          !local.escapes &&
          local.consumers.every(
            (site) => isProtectedByCatch(
              site,
              channel: ExceptionChannel.synchronous,
              exceptionTypes: exceptionTypes,
              resolvedExceptionTypes: resolvedExceptionTypes,
              exceptionSupertypes: exceptionSupertypes,
              respectExceptionBoundary: respectExceptionBoundary,
            ),
          );
    }
    if (!isReachable(consumer)) return true;
    node = consumer;
  }
  if (requireAsyncProtection &&
      _hasAsyncErrorHandler(
        node,
        channel,
        skipCurrent: skipCurrentAsyncHandler,
        exceptionTypes: exceptionTypes,
        resolvedExceptionTypes: resolvedExceptionTypes,
        exceptionSupertypes: exceptionSupertypes,
      )) {
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
  if (channel != null &&
      (channel == ExceptionChannel.future ||
          channel == ExceptionChannel.stream)) {
    final route = asyncValueRoute(node, channel);
    final consumer = route.consumer;
    final loop = consumer is ForEachParts ? consumer.parent : null;
    return route.channel == ExceptionChannel.future &&
            (node is AwaitExpression || consumer is AwaitExpression) ||
        route.channel == ExceptionChannel.stream &&
            loop is ForStatement &&
            loop.awaitKeyword != null;
  }
  AstNode? current = node;
  while (current != null) {
    if (current is AwaitExpression || current.parent is AwaitExpression) {
      return true;
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
  if (parent is NamedArgument && parent.parent is ArgumentList) {
    final invocation = parent.parent?.parent;
    if (invocation != null &&
        identical(forwardedFutureArgument(invocation), node)) {
      return invocation;
    }
  }
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
      if (ThrowSourceCatalog.isNativeFutureIgnore(element) ||
          ThrowSourceCatalog.isNativeTypedFutureHandler(element) ||
          (owner == 'Future' &&
              const {
                'then',
                'catchError',
                'asStream',
                'whenComplete',
                'timeout',
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
  if (parent is ListLiteral) {
    AstNode argument = parent;
    while (argument.parent is ParenthesizedExpression) {
      argument = argument.parent!;
    }
    final arguments = argument.parent;
    final invocation = arguments?.parent;
    if (arguments is ArgumentList &&
        identical(arguments.arguments.firstOrNull, argument) &&
        invocation is MethodInvocation &&
        _isSdkFutureJoin(invocation)) {
      return invocation;
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
    if (invocation != null &&
        identical(forwardedFutureArgument(invocation), node)) {
      return invocation;
    }
    final element = switch (invocation) {
      InstanceCreationExpression(:final constructorName) =>
        constructorName.element,
      MethodInvocation(:final methodName) => methodName.element,
      _ => null,
    };
    final owner = element?.enclosingElement?.name;
    final name = element?.name;
    if (element?.library?.uri.toString() == 'dart:async' &&
        (owner == 'Future' && name == 'value' ||
            owner == 'Stream' && name == 'fromFuture')) {
      return invocation;
    }
  }
  return null;
}

/// The first consumer after expressions known to forward an async value.
AstNode? asyncValueConsumer(AstNode node) =>
    asyncValueRoute(node, ExceptionChannel.synchronous).consumer;

/// A Stream passed to Future.syncValue remains a value inside the returned
/// Future. Returning that wrapper preserves the obligation to subscribe.
bool isReturnedStreamPayload(AstNode node) {
  final wrapper = _synchronousFutureWrapper(node);
  if (wrapper == null) return false;
  final consumer = asyncValueConsumer(wrapper);
  return consumer is ReturnStatement || consumer is ExpressionFunctionBody;
}

InstanceCreationExpression? _synchronousFutureWrapper(AstNode node) {
  var argument = node;
  while (argument.parent is ParenthesizedExpression) {
    argument = argument.parent!;
  }
  final arguments = argument.parent;
  final invocation = arguments?.parent;
  if (arguments is! ArgumentList ||
      arguments.arguments.length != 1 ||
      invocation is! InstanceCreationExpression) {
    return null;
  }
  final constructor = invocation.constructorName.element;
  if (constructor == null ||
      !constructor.library.isInSdk ||
      constructor.library.uri.toString() != 'dart:async' ||
      constructor.enclosingElement.name != 'Future' ||
      constructor.name != 'syncValue') {
    return null;
  }
  return invocation;
}

bool _discardsSynchronousFuturePayload(AstNode node) {
  final wrapper = _synchronousFutureWrapper(node);
  if (wrapper == null) return false;
  AstNode value = wrapper;
  while (value.parent is ParenthesizedExpression) {
    value = value.parent!;
  }
  final consumer = value.parent;
  if (consumer is ExpressionStatement) return true;
  if (consumer is! MethodInvocation || !identical(consumer.realTarget, value)) {
    return false;
  }
  return ThrowSourceCatalog.isNativeFutureIgnore(consumer.methodName.element);
}

/// An await of a final local before intervening code or suspension can run.
AwaitExpression? immediateAwaitOfStoredFuture(
  AstNode? consumer,
  AstNode producer,
) {
  if (consumer is! VariableDeclaration ||
      producer is AssignmentExpression ||
      producer is PrefixExpression ||
      producer is PostfixExpression) {
    return null;
  }
  Expression? initializer = consumer.initializer;
  while (initializer is ParenthesizedExpression) {
    initializer = initializer.expression;
  }
  if (!identical(initializer, producer)) return null;
  final element = consumer.declaredFragment?.element;
  if (element is! LocalVariableElement || !element.isFinal || element.isLate) {
    return null;
  }
  final type = element.type;
  if (type is! InterfaceType || !type.isDartAsyncFuture) return null;
  final group = consumer.parent;
  final declaration = group?.parent;
  final block = declaration?.parent;
  if (group is! VariableDeclarationList ||
      group.variables.length != 1 ||
      declaration is! VariableDeclarationStatement ||
      block is! Block) {
    return null;
  }
  final index = block.statements.indexOf(declaration);
  if (index < 0 || index + 1 >= block.statements.length) return null;
  var next = block.statements[index + 1];
  while (next is Block || next is TryStatement) {
    final body = next is TryStatement ? next.body : next as Block;
    if (body.statements.isEmpty) return null;
    next = body.statements.first;
  }
  final awaitExpression = switch (next) {
    ExpressionStatement(expression: final AwaitExpression expression) ||
    ReturnStatement(expression: final AwaitExpression expression) => expression,
    _ => null,
  };
  if (awaitExpression == null) return null;
  Expression operand = awaitExpression.expression;
  while (operand is ParenthesizedExpression) {
    operand = operand.expression;
  }
  return operand is SimpleIdentifier && operand.element == element
      ? awaitExpression
      : null;
}

/// Tracks SDK conversions that change how a value delivers its errors.
({AstNode? consumer, ExceptionChannel channel}) asyncValueRoute(
  AstNode node,
  ExceptionChannel channel,
) {
  var current = node;
  while (true) {
    if (channel == ExceptionChannel.future &&
        _discardsSynchronousFuturePayload(current)) {
      return (consumer: null, channel: ExceptionChannel.scheduled);
    }
    final forwarding = _forwardingFutureParent(current);
    if (forwarding == null) return (consumer: current.parent, channel: channel);
    final projected = _channelAfterForwarding(channel, forwarding);
    if (projected == null) return (consumer: null, channel: channel);
    if (projected == ExceptionChannel.scheduled && channel != projected) {
      return (consumer: null, channel: projected);
    }
    channel = projected;
    current = forwarding;
  }
}

ExceptionChannel? _channelAfterForwarding(
  ExceptionChannel channel,
  AstNode forwarding,
) {
  final projected = switch (channel) {
    ExceptionChannel.future
        when forwarding is MethodInvocation &&
            _isSdkFutureJoin(forwarding) &&
            !isReachable(forwarding) =>
      // An earlier Future exists, but the call cannot attach a listener.
      ExceptionChannel.scheduled,
    ExceptionChannel.stream when _streamTerminalFuture(forwarding) =>
      ExceptionChannel.future,
    ExceptionChannel.future when _futureToStream(forwarding) =>
      ExceptionChannel.stream,
    _ => channel,
  };
  return projected != channel &&
          projected != ExceptionChannel.scheduled &&
          !isReachable(forwarding)
      ? null
      : projected;
}

bool _isSdkFutureJoin(MethodInvocation invocation) {
  final method = invocation.methodName.element;
  return method?.library?.uri.toString() == 'dart:async' &&
      method?.enclosingElement?.name == 'Future' &&
      const {'wait', 'any'}.contains(method?.name);
}

bool _futureToStream(AstNode node) {
  final element = switch (node) {
    MethodInvocation(:final methodName) => methodName.element,
    InstanceCreationExpression(:final constructorName) =>
      constructorName.element,
    _ => null,
  };
  if (element?.library?.uri.toString() != 'dart:async') return false;
  final owner = element?.enclosingElement?.name;
  final name = element?.name;
  return owner == 'Future' && name == 'asStream' ||
      owner == 'Stream' && name == 'fromFuture';
}

bool _streamTerminalFuture(AstNode node) {
  final element = switch (node) {
    MethodInvocation(:final methodName) => methodName.element,
    PropertyAccess(:final propertyName) => propertyName.element,
    _ => null,
  };
  return element is ExecutableElement &&
      element.library.uri.toString() == 'dart:async' &&
      element.enclosingElement?.name == 'Stream' &&
      element.returnType is InterfaceType &&
      (element.returnType as InterfaceType).isDartAsyncFuture;
}

/// The operation that executes a lazy value when its inputs finish evaluating.
AstNode? deferredExecutionSite(AstNode node) =>
    _deferredConsumerAfter(_forwardedLazyValue(node));

AstNode _forwardedLazyValue(AstNode node, {bool followAssignments = true}) {
  var forwarded = node;
  while (true) {
    final parent =
        _forwardingFutureParent(forwarded) ??
        _iterableIteratorAccess(forwarded);
    if (parent == null ||
        !followAssignments && parent is AssignmentExpression) {
      return forwarded;
    }
    forwarded = parent;
  }
}

AstNode? _deferredConsumerAfter(AstNode forwarded) {
  final consumer = forwarded.parent;
  if (consumer is ForEachParts || consumer is SpreadElement) return consumer;
  if (consumer is YieldStatement && consumer.star != null) return consumer;
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
      final consumes =
          (const {'List', 'Set'}.contains(owner) &&
              const {'from', 'of', 'unmodifiable'}.contains(name)) ||
          (owner == 'Map' &&
              const {'fromIterable', 'fromEntries'}.contains(name));
      if (consumes) return invocation;
    }
  }
  final element = switch (consumer) {
    MethodInvocation() => consumer.methodName.element,
    PropertyAccess() => consumer.propertyName.element,
    _ => null,
  };
  if (element?.library?.uri.toString() != 'dart:core') return null;
  final owner = element?.enclosingElement?.name;
  if (owner == 'Iterator') {
    return consumer is MethodInvocation &&
            identical(consumer.realTarget, forwarded) &&
            element?.name == 'moveNext'
        ? consumer
        : null;
  }
  if (!const {'Iterable', 'List', 'Set'}.contains(owner)) return null;
  final consumes = switch (consumer) {
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
  return consumes ? consumer : null;
}

typedef DeferredLocalUses = ({List<AstNode> consumers, bool escapes});

final _deferredLocalUseCache = Expando<DeferredLocalUses>();
final _localReadIndex = Expando<_DeferredLocalReads>();

/// Tracks a deferred value through initialized final locals in its own body.
/// An unrecognized use or capture leaves a possible escaping value.
DeferredLocalUses? deferredLocalUses(AstNode node) {
  final value = _forwardedLazyValue(node, followAssignments: false);
  final declaration = _finalLocalReceiving(value);
  final body = declaration?.thisOrAncestorOfType<FunctionBody>();
  if (declaration == null || body == null) return null;
  return _deferredLocalUseCache[declaration] ??= _traceLocalDeferredUses(
    declaration,
    body,
    _localReadIndex[body] ??= _DeferredLocalReads(body),
  );
}

VariableDeclaration? _finalLocalReceiving(AstNode value) {
  final declaration = value.parent;
  if (declaration is! VariableDeclaration ||
      !identical(declaration.initializer, value)) {
    return null;
  }
  final element = declaration.declaredFragment?.element;
  return element is LocalVariableElement && element.isFinal && !element.isLate
      ? declaration
      : null;
}

DeferredLocalUses _traceLocalDeferredUses(
  VariableDeclaration declaration,
  FunctionBody body,
  _DeferredLocalReads index,
) {
  final pending = [declaration];
  final visited = <VariableDeclaration>{};
  final consumers = <AstNode>{};
  var escapes = index.truncated;
  while (pending.isNotEmpty) {
    final binding = pending.removeLast();
    if (!visited.add(binding)) continue;
    final element = binding.declaredFragment!.element as LocalVariableElement;
    for (final read in index.reads[element.baseElement] ?? const []) {
      if (!isReachable(read)) continue;
      if (!identical(read.thisOrAncestorOfType<FunctionBody>(), body)) {
        escapes = true;
        continue;
      }
      final value = _forwardedLazyValue(read, followAssignments: false);
      if (_finalLocalReceiving(value) case final alias?) {
        pending.add(alias);
      } else if (_deferredConsumerAfter(value) case final site?) {
        if (isReachable(site)) consumers.add(site);
      } else {
        escapes = true;
      }
    }
  }
  return (consumers: consumers.toList(), escapes: escapes);
}

final class _DeferredLocalReads extends RecursiveAstVisitor<void> {
  _DeferredLocalReads(FunctionBody body) {
    body.accept(this);
  }

  static const _maxReads = 1024;
  final reads = <LocalVariableElement, List<SimpleIdentifier>>{};
  var _count = 0;
  bool get truncated => _count > _maxReads;

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final element = node.element?.baseElement;
    if (element is LocalVariableElement &&
        element.isFinal &&
        ++_count <= _maxReads) {
      (reads[element] ??= []).add(node);
    }
  }
}

PropertyAccess? _iterableIteratorAccess(AstNode target) {
  final parent = target.parent;
  if (parent is! PropertyAccess || !identical(parent.realTarget, target)) {
    return null;
  }
  final getter = parent.propertyName.element;
  return getter?.library?.uri.toString() == 'dart:core' &&
          const {
            'Iterable',
            'List',
            'Set',
          }.contains(getter?.enclosingElement?.name) &&
          getter?.name == 'iterator'
      ? parent
      : null;
}

bool _containsNode(AstNode ancestor, AstNode node) =>
    node.offset >= ancestor.offset && node.end <= ancestor.end;

bool _hasAsyncErrorHandler(
  AstNode node,
  ExceptionChannel? channel, {
  required bool skipCurrent,
  required List<String> exceptionTypes,
  required List<DartType> resolvedExceptionTypes,
  required Map<String, List<String>> exceptionSupertypes,
}) {
  AstNode? current = node;
  while (current != null) {
    if (current is MethodInvocation &&
        (!skipCurrent || !identical(current, node)) &&
        asyncHandlerContains(
          current,
          channel: channel,
          exceptionTypes: exceptionTypes,
          resolvedExceptionTypes: resolvedExceptionTypes,
          exceptionSupertypes: exceptionSupertypes,
        )) {
      return true;
    }
    final forwarding = _forwardingFutureParent(current);
    if (channel != null && forwarding != null) {
      channel = _channelAfterForwarding(channel, forwarding);
      if (channel == null || channel == ExceptionChannel.scheduled) {
        return false;
      }
    }
    current = forwarding;
  }
  return false;
}

bool _handlerMatchesChannel(
  MethodInvocation invocation,
  ExceptionChannel? channel,
) {
  final element = invocation.methodName.element;
  final owner = element?.enclosingElement?.name;
  return switch (channel) {
    ExceptionChannel.future =>
      owner == 'Future' ||
          ThrowSourceCatalog.isNativeFutureIgnore(element) ||
          ThrowSourceCatalog.isNativeTypedFutureHandler(element),
    ExceptionChannel.stream => owner == 'Stream',
    null => true,
    _ => false,
  };
}

bool asyncHandlerContains(
  MethodInvocation node, {
  ExceptionChannel? channel,
  List<String> exceptionTypes = const [],
  List<DartType> resolvedExceptionTypes = const [],
  Map<String, List<String>> exceptionSupertypes = const {},
}) {
  if (!_handlerMatchesChannel(node, channel)) return false;
  if (hasUnconditionalAsyncErrorHandler(node)) return isReachable(node);
  final catchType = _typedFutureHandlerType(node);
  if (catchType == null || !isReachable(node)) return false;
  if (resolvedExceptionTypes.isNotEmpty) {
    final typeSystem = node.methodName.element!.library!.typeSystem;
    return resolvedExceptionTypes.every(
      (type) => typeSystem.isSubtypeOf(type, catchType),
    );
  }
  final element = catchType.element;
  final name = element?.name;
  return name != null &&
      element?.library?.uri.scheme == 'dart' &&
      exceptionTypes.isNotEmpty &&
      exceptionTypes.every(
        (type) =>
            ExceptionTypeHierarchy.isSubtypeName(type, name) ||
            (exceptionSupertypes[type]?.contains(name) ?? false),
      );
}

DartType? _typedFutureHandlerType(MethodInvocation node) {
  if (!ThrowSourceCatalog.isNativeTypedFutureHandler(node.methodName.element)) {
    return null;
  }
  final arguments = node.argumentList.arguments;
  if (arguments.isEmpty ||
      !isDefinitelyNonNull(arguments.first.argumentExpression)) {
    return null;
  }
  for (final argument in arguments.whereType<NamedArgument>()) {
    if (argument.name.lexeme == 'test' &&
        !_isAlwaysTrueFilter(argument.argumentExpression)) {
      return null;
    }
  }
  return node.typeArgumentTypes?.singleOrNull;
}

/// Whether an SDK chain intercepts every incoming error. A filter that cannot
/// be proven true retains the error effect on the returned Future or Stream.
/// Effects produced by callbacks are analyzed separately at their own sites.
bool hasUnconditionalAsyncErrorHandler(MethodInvocation node) {
  final element = node.methodName.element;
  if (element?.library?.uri.toString() != 'dart:async') return false;
  final owner = element?.enclosingElement?.name;
  final name = node.methodName.name;
  if (ThrowSourceCatalog.isNativeFutureIgnore(element)) return true;
  if (_typedFutureHandlerType(node)?.isDartCoreObject == true) return true;
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

bool _isAlwaysTrueFilter(Expression expression) =>
    _isNullExpression(expression) ||
    constantBooleanCallbackResult(expression) == true;

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
