import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';

import '../analysis/throw_source_catalog.dart';
import 'exception_effect.dart';
import 'statement_completion.dart';

/// Callback execution is distinct from creation of the closure value.
/// Models are tied to resolved SDK declarations, never to user method names.
final class CallbackExecution {
  const CallbackExecution(
    this.expression,
    this.channel, {
    this.assimilatesReturnedFuture = false,
    this.consumesReturnedIterable = false,
    this.consumesReturnedStream = false,
  });
  final Expression expression;
  final ExceptionChannel channel;
  final bool assimilatesReturnedFuture;
  final bool consumesReturnedIterable;
  final bool consumesReturnedStream;
}

Iterable<CallbackExecution> callbackExecutions(
  AstNode node,
  Element? element,
) sync* {
  final library = element?.library?.uri.toString();
  if (library == 'dart:convert') {
    final reviver = ThrowSourceCatalog.jsonDecodingInvocation(
      node,
      element,
    )?.reviver;
    if (reviver != null) {
      yield CallbackExecution(reviver, ExceptionChannel.synchronous);
    }
    return;
  }
  final owner = element?.enclosingElement?.name;
  final name = element?.name;
  final arguments = switch (node) {
    MethodInvocation(:final argumentList) => argumentList.arguments,
    FunctionExpressionInvocation(:final argumentList) => argumentList.arguments,
    InstanceCreationExpression(:final argumentList) => argumentList.arguments,
    _ => null,
  };
  if (arguments == null) return;
  final positional = arguments
      .where((argument) => argument is! NamedArgument)
      .map((argument) => argument.argumentExpression)
      .toList();
  final named = {
    for (final argument in arguments.whereType<NamedArgument>())
      argument.name.lexeme: argument.argumentExpression,
  };
  CallbackExecution? at(int index, ExceptionChannel channel) =>
      index < positional.length
      ? CallbackExecution(
          positional[index],
          channel,
          assimilatesReturnedFuture:
              channel == ExceptionChannel.future ||
              (owner == 'Stream' &&
                  const {'asyncMap', 'asyncExpand'}.contains(name)),
          consumesReturnedIterable: name == 'expand',
          consumesReturnedStream: owner == 'Stream' && name == 'asyncExpand',
        )
      : null;
  if (library == 'dart:core') {
    if (const {'Iterable', 'List', 'Set', 'Map'}.contains(owner)) {
      if (const {
        'forEach',
        'any',
        'every',
        'firstWhere',
        'lastWhere',
        'singleWhere',
        'reduce',
        'sort',
        'removeWhere',
        'retainWhere',
      }.contains(name)) {
        final callback = at(0, ExceptionChannel.synchronous);
        if (callback != null) yield callback;
        if (named['orElse'] case final expression?) {
          yield CallbackExecution(expression, ExceptionChannel.synchronous);
        }
      } else if (name == 'fold') {
        final callback = at(1, ExceptionChannel.synchronous);
        if (callback != null) yield callback;
      } else if (const {
        'map',
        'where',
        'expand',
        'takeWhile',
        'skipWhile',
      }.contains(name)) {
        final callback = at(
          0,
          owner == 'Map'
              ? ExceptionChannel.synchronous
              : ExceptionChannel.deferred,
        );
        if (callback != null) yield callback;
      } else if (name == 'generate' &&
          (owner == 'List' || owner == 'Iterable')) {
        final callback = at(
          1,
          owner == 'List'
              ? ExceptionChannel.synchronous
              : ExceptionChannel.deferred,
        );
        if (callback != null) yield callback;
      }
    }
  } else if (library == 'dart:async') {
    if (name == 'scheduleMicrotask') {
      final callback = at(0, ExceptionChannel.scheduled);
      if (callback != null) yield callback;
    } else if (owner == 'Timer') {
      final callback = at(name == 'run' ? 0 : 1, ExceptionChannel.scheduled);
      if (callback != null) yield callback;
    } else if (node is MethodInvocation &&
        ThrowSourceCatalog.isNativeTypedFutureHandler(element) &&
        ThrowSourceCatalog.typedFutureHandlerMayRun(node)) {
      final filter = named['test'];
      if (filter == null || constantBooleanCallbackResult(filter) != false) {
        final handler = at(0, ExceptionChannel.future);
        if (handler != null) yield handler;
      }
      if (filter != null) {
        yield CallbackExecution(filter, ExceptionChannel.future);
      }
    } else if (owner == 'Future') {
      final index = switch (name) {
        '' ||
        'sync' ||
        'microtask' ||
        'then' ||
        'catchError' ||
        'whenComplete' => 0,
        'delayed' => 1,
        _ => null,
      };
      if (index != null) {
        final callback = at(index, ExceptionChannel.future);
        if (callback != null) yield callback;
      }
      // A failed wait runs cleanup through a separate, discarded Future.
      final cleanup = named['cleanUp'];
      if (name == 'wait' && cleanup != null) {
        yield CallbackExecution(cleanup, ExceptionChannel.scheduled);
      }
      final filter = named['test'];
      if (name == 'catchError' && filter != null) {
        yield CallbackExecution(filter, ExceptionChannel.future);
      }
      for (final key in const ['onError', 'onTimeout']) {
        if (named[key] case final expression?) {
          yield CallbackExecution(
            expression,
            ExceptionChannel.future,
            assimilatesReturnedFuture: true,
          );
        }
      }
    } else if (owner == 'Stream') {
      if (name == 'listen') {
        final callback = at(0, ExceptionChannel.scheduled);
        if (callback != null) yield callback;
        for (final key in const ['onError', 'onDone']) {
          if (named[key] case final expression?) {
            yield CallbackExecution(expression, ExceptionChannel.scheduled);
          }
        }
      } else if (const {
        'map',
        'where',
        'expand',
        'asyncMap',
        'asyncExpand',
        'takeWhile',
        'skipWhile',
        'distinct',
        'handleError',
      }.contains(name)) {
        final callback = at(0, ExceptionChannel.stream);
        if (callback != null) yield callback;
        final filter = named['test'];
        if (name == 'handleError' && filter != null) {
          yield CallbackExecution(filter, ExceptionChannel.stream);
        }
      }
    }
  }
}
