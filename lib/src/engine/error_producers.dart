import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';

import 'callback_values.dart';

/// An SDK operation whose explicit purpose is delivering an error value.
final class ErrorProducer {
  const ErrorProducer(this.displayName);

  final String displayName;
}

/// Includes producers invoked through the native `Function.apply` forwarder.
///
/// The regular invocation resolver describes the actual callee. This helper
/// adds the function `apply` executes without assigning general apply effects.
CallbackValue explicitProducerInvocationTargets(
  CallbackValue value,
  ArgumentList arguments,
  CallbackValue Function(Expression) resolveValue,
) {
  return _ApplyProducerTargets(resolveValue).resolve(
    value,
    arguments.arguments.map((argument) => argument.argumentExpression).toList(),
    0,
  );
}

final class _ApplyProducerTargets {
  _ApplyProducerTargets(this.resolveValue);

  final CallbackValue Function(Expression) resolveValue;
  int remainingSteps = 256;

  CallbackValue resolve(
    CallbackValue value,
    List<Expression> arguments,
    int depth,
  ) {
    if (depth > 16 || remainingSteps-- <= 0) {
      return CallbackValue(targets: value.targets, hasUnknown: true);
    }
    final appliesFunction = value.targets.any(
      (target) =>
          target is MethodElement &&
          target.isStatic &&
          target.library.isInSdk &&
          target.library.uri.toString() == 'dart:core' &&
          target.enclosingElement?.name == 'Function' &&
          target.name == 'apply',
    );
    if (!appliesFunction) return value;
    if (arguments.length < 2 || arguments.length > 3) {
      return CallbackValue(targets: value.targets, hasUnknown: true);
    }
    var applied = resolveValue(arguments.first);
    if (applied.targets.any(_isApply)) {
      Expression forwardedArguments = arguments[1];
      while (forwardedArguments is ParenthesizedExpression &&
          remainingSteps-- > 0) {
        forwardedArguments = forwardedArguments.expression;
      }
      if (forwardedArguments is ListLiteral &&
          forwardedArguments.staticType != null) {
        final expressions = <Expression>[];
        var complete = true;
        for (final element in forwardedArguments.elements) {
          if (remainingSteps-- <= 0 || element is! Expression) {
            complete = false;
            break;
          }
          expressions.add(element);
        }
        applied = complete
            ? resolve(applied, expressions, depth + 1)
            : CallbackValue(targets: applied.targets, hasUnknown: true);
      } else {
        applied = CallbackValue(targets: applied.targets, hasUnknown: true);
      }
    }
    final targets = {...value.targets, ...applied.targets};
    return CallbackValue(
      targets: targets.take(64),
      hasUnknown: value.hasUnknown || applied.hasUnknown || targets.length > 64,
    );
  }

  static bool _isApply(ExecutableElement target) =>
      target is MethodElement &&
      target.isStatic &&
      target.library.isInSdk &&
      target.library.uri.toString() == 'dart:core' &&
      target.enclosingElement?.name == 'Function' &&
      target.name == 'apply';
}

/// Identifies resolved SDK declarations independently of effect catalog policy.
///
/// Names alone never establish producer identity. Methods on user-defined
/// objects, opaque function parameters and unresolved dynamic values remain
/// uncertainty for the effect rules, rather than explicit producer claims.
ErrorProducer? explicitErrorProducer(Element? element) {
  final target = element?.baseElement;
  if (target is! ExecutableElement || !target.library.isInSdk) return null;
  final library = target.library.uri.toString();
  final owner = target.enclosingElement?.name;
  final name = target.name;
  final enclosing = target.enclosingElement;
  if (name == 'addError' &&
      (library == 'dart:async' || library == 'dart:io') &&
      enclosing is InterfaceElement) {
    // SDK concrete sink classes may expose their own declaration (for example
    // dart:io's private stdout sink). Require the native sink contract, never
    // a same-named user method or a user implementation of that interface.
    final contract = enclosing.allSupertypes
        .where(
          (type) =>
              type.element.library.uri.toString() == 'dart:async' &&
                  const {
                    'EventSink',
                    'StreamSink',
                    'StreamController',
                  }.contains(type.element.name) ||
              type.element.library.uri.toString() == 'dart:io' &&
                  type.element.name == 'IOSink',
        )
        .firstOrNull;
    if (contract != null && owner?.startsWith('_') == true) {
      return ErrorProducer('${contract.element.name}.addError');
    }
  }
  return switch ((library, owner, name)) {
    ('dart:core', 'Error', 'throwWithStackTrace') => const ErrorProducer(
      'Error.throwWithStackTrace',
    ),
    ('dart:async', 'Future', 'error') => const ErrorProducer('Future.error'),
    ('dart:async', 'Stream', 'error') => const ErrorProducer('Stream.error'),
    ('dart:async', 'Completer', 'completeError') => const ErrorProducer(
      'Completer.completeError',
    ),
    (
      'dart:async',
      'EventSink' ||
          'StreamSink' ||
          'StreamController' ||
          'SynchronousStreamController' ||
          'MultiStreamController',
      'addError',
    ) =>
      ErrorProducer('$owner.addError'),
    ('dart:async', 'MultiStreamController', 'addErrorSync') =>
      const ErrorProducer('MultiStreamController.addErrorSync'),
    ('dart:async', 'Zone' || 'ZoneDelegate', 'handleUncaughtError') =>
      ErrorProducer('$owner.handleUncaughtError'),
    ('dart:io', 'IOSink' || 'Socket' || 'Stdout', 'addError') => ErrorProducer(
      '$owner.addError',
    ),
    _ => null,
  };
}
