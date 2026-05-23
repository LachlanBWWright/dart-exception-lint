import 'package:analyzer/dart/ast/ast.dart';

bool isProtectedByCatch(
  AstNode node, {
  bool requireAsyncProtection = false,
  List<String> exceptionTypes = const [],
}) {
  if (requireAsyncProtection && _hasAsyncErrorHandler(node)) {
    return true;
  }

  AstNode? current = node.parent;
  while (current != null) {
    if (current is TryStatement &&
        current.catchClauses.isNotEmpty &&
        _containsNode(current.body, node) &&
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

bool _containsNode(AstNode ancestor, AstNode node) {
  return node.offset >= ancestor.offset && node.end <= ancestor.end;
}

bool _hasAsyncErrorHandler(AstNode node) {
  final parent = node.parent;
  if (parent case MethodInvocation(:final methodName, :final argumentList)
      when identical(parent.target, node) &&
          methodName.name == 'catchError' &&
          argumentList.arguments.isNotEmpty) {
    return true;
  }

  if (parent case MethodInvocation(
    :final methodName,
    :final argumentList,
  ) when identical(parent.target, node) && methodName.name == 'then') {
    return argumentList.arguments.any(
      (argument) =>
          argument is NamedExpression && argument.name.label.name == 'onError',
    );
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
    if (exceptionTypes.contains(caughtName)) {
      return true;
    }
  }

  return false;
}
