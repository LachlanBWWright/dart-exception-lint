import 'package:analyzer/dart/ast/ast.dart';

import 'exception_annotations.dart';
import 'exception_type_hierarchy.dart';

bool isProtectedByCatch(
  AstNode node, {
  bool requireAsyncProtection = false,
  List<String> exceptionTypes = const [],
}) {
  if (isInsideExceptionBoundary(node)) {
    return true;
  }
  if (requireAsyncProtection && _hasAsyncErrorHandler(node)) {
    return true;
  }

  AstNode? current = node.parent;
  while (current != null) {
    if (current is TryStatement &&
        current.catchClauses.isNotEmpty &&
        _containsNode(current.body, node) &&
        (!requireAsyncProtection || _isAwaited(node)) &&
        _matchesCatch(current.catchClauses, exceptionTypes)) {
      return true;
    }
    if (current is FunctionBody) {
      return false;
    }
    current = current.parent;
  }

  return false;
}

bool _isAwaited(AstNode node) {
  AstNode? current = node;
  while (current != null) {
    if (current is AwaitExpression) {
      return true;
    }
    if (current is FunctionBody) {
      return false;
    }
    current = current.parent;
  }
  return false;
}

bool _containsNode(AstNode ancestor, AstNode node) {
  return node.offset >= ancestor.offset && node.end <= ancestor.end;
}

bool _hasAsyncErrorHandler(AstNode node) {
  AstNode? current = node;
  while (current != null) {
    if (current is MethodInvocation) {
      if (current.methodName.name == 'catchError' &&
          current.argumentList.arguments.isNotEmpty &&
          current.argumentList.arguments.first is! NullLiteral) {
        return true;
      }

      // Stream.handleError installs an error transformer before a later
      // listen/iteration operation consumes the stream.
      if (current.methodName.name == 'handleError' &&
          current.argumentList.arguments.isNotEmpty) {
        return true;
      }

      // Future.ignore() deliberately consumes the future's error channel.
      // It is the explicit counterpart to an awaited try/catch for callers
      // that intentionally discard the result.
      if (current.methodName.name == 'ignore') {
        return true;
      }

      if (current.methodName.name == 'then') {
        final arguments = current.argumentList.arguments;
        if (arguments.asMap().entries.any(
          (entry) =>
              (entry.value is NamedArgument &&
                  (entry.value as NamedArgument).name.lexeme == 'onError' &&
                  (entry.value as NamedArgument).argumentExpression
                      is! NullLiteral) ||
              (entry.key > 0 && entry.value is! NamedArgument),
        )) {
          return true;
        }
      }
    }

    if (current is FunctionBody) {
      return false;
    }
    current = current.parent;
  }

  return false;
}

bool _matchesCatch(List<CatchClause> clauses, List<String> exceptionTypes) {
  if (exceptionTypes.isEmpty) {
    return true;
  }

  for (final clause in clauses) {
    final catchType = clause.exceptionType;
    if (catchType == null) {
      return true;
    }

    final caughtName = catchType.type?.element?.name ?? catchType.toSource();
    // The manifest stores names rather than analyzer types. Treat Dart's
    // broad catch types as covering every known source, and retain exact-name
    // matching for precise catches. This avoids false reports for the common
    // `on Exception` and `on Object` forms without guessing custom hierarchies.
    if (caughtName == 'Object' ||
        caughtName == 'Exception' ||
        caughtName == 'Error' ||
        caughtName == 'dynamic' ||
        exceptionTypes.any(
          (type) => ExceptionTypeHierarchy.isSubtypeName(type, caughtName),
        )) {
      return true;
    }
  }

  return false;
}
