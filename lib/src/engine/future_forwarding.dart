import 'dart:io';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:path/path.dart' as p;

import '../analysis/exception_annotations.dart';
import '../analysis/resolved_callable.dart';
import '../config/throwing_api_manifest.dart';
import '../config/exception_analysis_options.dart';

import 'resolved_dependencies.dart';

/// The input whose Future error channel a source invocation preserves.
/// One-argument static/top-level helpers must immediately return the input or
/// a proven delegate. Async helpers may await that value as their sole action.
/// Async adoption creates a new Future; this proves error ownership transfer,
/// not object identity. Chains are bounded to 8 calls, with no earlier work or
/// suspension accepted. Names and return signatures alone never establish proof.
/// Alias tracking must request [requireIdentity] to exclude async adoption,
/// including synchronous wrappers around async delegates.
Expression? forwardedFutureArgument(
  AstNode call, {
  int maxDepth = 8,
  bool requireIdentity = false,
}) {
  final candidate = _candidate(call);
  if (candidate == null) return null;
  AstNode root = call;
  while (root.parent != null) {
    root = root.parent!;
  }
  if (root is! CompilationUnit) return null;
  final library = root.declaredFragment?.element;
  if (library == null) return null;
  final path = root.declaredFragment!.source.fullName;
  final packageRoot = _packageRoot(path);
  final options = ExceptionAnalysisOptions.loadResult(
    packageRoot: packageRoot,
    currentFilePath: path,
  ).valueOrNull;
  if (options == null) return null;
  final configuredLimit = options.maxCallDepth + 1;
  final limit = [8, maxDepth, configuredLimit].reduce((a, b) => a < b ? a : b);
  if (limit <= 0) return null;
  final manifest = ThrowingApiManifest.loadResult(
    packageRoot: packageRoot,
    currentFilePath: path,
  ).valueOrNull;
  if (manifest == null) return null;
  final resolver = _resolvers[root] ??= _ForwardingResolver(root, library);
  if (resolver.manifest.cacheKey != manifest.cacheKey) {
    resolver.results.clear();
    resolver.identities.clear();
  }
  resolver.manifest = manifest;
  return resolver.isCurrent &&
          resolver.proves(candidate.$1, {}, 0, limit, requireIdentity) &&
          resolver.isCurrent
      ? candidate.$2
      : null;
}

final _resolvers = Expando<_ForwardingResolver>();

(ExecutableElement, Expression)? _candidate(AstNode call) {
  final (element, arguments) = switch (call) {
    MethodInvocation(:final methodName, :final argumentList) => (
      methodName.element,
      argumentList.arguments,
    ),
    _ => (null, null),
  };
  if (element is! ExecutableElement ||
      element.library.isInSdk ||
      !(element is TopLevelFunctionElement ||
          element is MethodElement && element.isStatic) ||
      arguments == null ||
      arguments.length != 1 ||
      element.formalParameters.length != 1) {
    return null;
  }
  if (element.metadata.hasAlwaysThrows ||
      exceptionContractsFor(element).isNotEmpty) {
    return null;
  }
  final parameter = element.formalParameters.single;
  final value = arguments.single.argumentExpression;
  Expression checked = value;
  while (checked is ParenthesizedExpression) {
    checked = checked.expression;
  }
  // A failing cast/assertion can abandon a Future before the helper starts.
  if (checked is AsExpression ||
      checked is PostfixExpression && checked.operator.lexeme == '!') {
    return null;
  }
  final source = value.staticType;
  if (!_future(source) ||
      !_future(parameter.type) ||
      !_future(element.returnType) ||
      _dynamicType(source!) ||
      _dynamicType(parameter.type) ||
      _dynamicType(element.returnType) ||
      !element.library.typeSystem.isSubtypeOf(source, parameter.type) ||
      !element.library.typeSystem.isSubtypeOf(
        parameter.type,
        element.returnType,
      )) {
    return null;
  }
  return (element, value);
}

bool _future(DartType? type) =>
    type is InterfaceType &&
    type.isDartAsyncFuture &&
    type.nullabilitySuffix.name == 'none';
bool _dynamicType(DartType type) =>
    type is DynamicType ||
    type is InterfaceType && type.typeArguments.any(_dynamicType);

final class _ForwardingResolver {
  _ForwardingResolver(CompilationUnit unit, LibraryElement library)
    : dependencies = ResolvedDependencies(library) {
    unit.accept(_Declarations(declarations));
    // The owning AST/session determines local proof lifetime. Fingerprint only
    // on-demand dependencies, avoiding a full caller-file read per invocation.
  }
  final ResolvedDependencies dependencies;
  ThrowingApiManifest manifest = ThrowingApiManifest.empty();
  final declarations = <ExecutableElement, FunctionBody>{};
  // Cache proof cost, not just success: a proof reused deeper in a chain must
  // still respect the caller's remaining budget. Depth failures are not cached.
  final results = <ExecutableElement, int>{};
  final identities = <ExecutableElement>{};
  final diskContents = <String, int?>{};

  bool get isCurrent =>
      dependencies.isCurrent &&
      diskContents.entries.every((e) => _fingerprint(e.key) == e.value);

  bool proves(
    ExecutableElement element,
    Set<ExecutableElement> active,
    int depth,
    int limit,
    bool requireIdentity,
  ) {
    if (depth >= limit || !active.add(element.baseElement)) return false;
    final callable = ResolvedCallable.tryCreate(element);
    if (callable != null &&
        manifest.apis.any((spec) => spec.matchScore(callable) >= 0)) {
      return false;
    }
    element = element.baseElement;
    if (results[element] case final cost?) {
      return depth + cost <= limit &&
          (!requireIdentity || identities.contains(element));
    }
    var body = declarations[element];
    if (body == null) {
      final units = dependencies.resolve(element.library);
      if (units == null) return false;
      for (final entry in units.entries) {
        entry.value.accept(_Declarations(declarations));
        diskContents[entry.key] = _fingerprint(entry.key);
      }
      body = declarations[element];
    }
    if (body == null ||
        body.isGenerator ||
        requireIdentity && body.isAsynchronous) {
      return false;
    }
    Expression? returned = switch (body) {
      ExpressionFunctionBody(:final expression) => expression,
      BlockFunctionBody(:final block)
          when block.statements.length == 1 &&
              block.statements.single is ReturnStatement =>
        (block.statements.single as ReturnStatement).expression,
      BlockFunctionBody(:final block)
          when body.isAsynchronous &&
              block.statements.length == 1 &&
              block.statements.single is ExpressionStatement &&
              (block.statements.single as ExpressionStatement).expression
                  is AwaitExpression =>
        (block.statements.single as ExpressionStatement).expression,
      _ => null,
    };
    while (returned is ParenthesizedExpression) {
      returned = returned.expression;
    }
    if (body.isAsynchronous && returned is AwaitExpression) {
      returned = returned.expression;
      while (returned is ParenthesizedExpression) {
        returned = returned.expression;
      }
    }
    if (returned == null) return false;
    var cost = 1;
    final delegate = _candidate(returned);
    if (delegate != null) {
      if (!proves(delegate.$1, active, depth + 1, limit, requireIdentity)) {
        return false;
      }
      cost += results[delegate.$1.baseElement]!;
      returned = delegate.$2;
      while (returned is ParenthesizedExpression) {
        returned = returned.expression;
      }
    }
    final proven =
        returned is SimpleIdentifier &&
        returned.element?.baseElement ==
            element.formalParameters.single.baseElement;
    if (proven) {
      results[element] = cost;
      if (!body.isAsynchronous &&
          (delegate == null || identities.contains(delegate.$1.baseElement))) {
        identities.add(element);
      }
    }
    return proven;
  }
}

String? _packageRoot(String path) {
  var directory = p.dirname(path);
  while (true) {
    if (File(p.join(directory, 'pubspec.yaml')).existsSync()) return directory;
    final parent = p.dirname(directory);
    if (parent == directory) return null;
    directory = parent;
  }
}

int? _fingerprint(String path) {
  try {
    return Object.hashAll(File(path).readAsBytesSync());
  } on FileSystemException {
    return null;
  }
}

final class _Declarations extends RecursiveAstVisitor<void> {
  _Declarations(this.output);
  final Map<ExecutableElement, FunctionBody> output;
  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    if (node.declaredFragment?.element case final element?) {
      output[element.baseElement] = node.functionExpression.body;
    }
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (node.declaredFragment?.element case final element?) {
      output[element.baseElement] = node.body;
    }
    super.visitMethodDeclaration(node);
  }
}
