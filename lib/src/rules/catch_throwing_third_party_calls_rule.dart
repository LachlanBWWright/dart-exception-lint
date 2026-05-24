import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/error.dart';

import '../config/config_failures.dart';
import '../config/exception_analysis_options.dart';
import '../config/throwing_api_manifest.dart';
import '../diagnostics.dart';
import '../result.dart';
import '../utils/source_utils.dart';

class CatchThrowingThirdPartyCallsRule extends AnalysisRule {
  CatchThrowingThirdPartyCallsRule({ThrowingApiManifestLoader? loader})
    : loader = loader ?? ThrowingApiManifestLoader(),
      super(
        name: DartExceptionLintDiagnostics.catchThrowingThirdPartyCalls.name,
        description:
            'Reports configured third-party throwing API calls outside try/catch.',
      );

  final ThrowingApiManifestLoader loader;

  @override
  LintCode get diagnosticCode =>
      DartExceptionLintDiagnostics.catchThrowingThirdPartyCalls;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    final options = switch (ExceptionAnalysisOptions.loadResult(
      packageRoot: context.package?.root.path,
      currentFilePath: context.currentUnit?.file.path,
    )) {
      Ok(value: final options) => options,
      Err() => const ExceptionAnalysisOptions(),
    };
    if (shouldSkipLintRuleForFile(
      ruleName: name,
      options: options,
      filePath: context.currentUnit?.file.path,
      packageRoot: context.package?.root.path,
    )) {
      return;
    }

    final manifest = switch (loader.load(
      context.package?.root.path,
      context.currentUnit?.file.path,
    )) {
      Ok(value: final manifest) => manifest,
      Err() => ThrowingApiManifest.empty(),
    };
    if (manifest.apis.isEmpty) {
      return;
    }

    final visitor = _Visitor(this, manifest);
    registry.addMethodInvocation(this, visitor);
    registry.addFunctionExpressionInvocation(this, visitor);
    registry.addInstanceCreationExpression(this, visitor);
  }
}

class ThrowingApiManifestLoader {
  const ThrowingApiManifestLoader();

  Result<ThrowingApiManifest, ManifestFailure> load(
    String? packageRoot,
    String? currentFilePath,
  ) {
    return ThrowingApiManifest.loadResult(
      packageRoot: packageRoot,
      currentFilePath: currentFilePath,
    );
  }
}

final class _Visitor extends SimpleAstVisitor<void> {
  _Visitor(this.rule, this.manifest);

  final AnalysisRule rule;
  final ThrowingApiManifest manifest;

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    _reportIfNeeded(
      node,
      element: node.element,
      diagnosticTarget: node.function,
    );
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    _reportIfNeeded(
      node,
      element: node.constructorName.element,
      diagnosticTarget: node.constructorName,
    );
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    _reportIfNeeded(
      node,
      element: node.methodName.element,
      diagnosticTarget: node.methodName,
    );
  }

  void _reportIfNeeded(
    AstNode node, {
    required Element? element,
    required AstNode diagnosticTarget,
  }) {
    final callable = ResolvedCallable.tryCreate(element);
    final matchedSpec = callable == null
        ? _findSyntaxFallback(node)
        : _findMatch(callable) ?? _findSyntaxFallback(node);
    if (matchedSpec == null || _isProtectedByTryCatch(node)) {
      return;
    }

    rule.reportAtNode(diagnosticTarget, arguments: [matchedSpec.displayName]);
  }

  ThrowingApiSpecification? _findMatch(ResolvedCallable callable) {
    ThrowingApiSpecification? bestMatch;
    var bestScore = -1;

    for (final spec in manifest.apis) {
      final score = _matchScore(spec, callable);
      if (score > bestScore) {
        bestScore = score;
        bestMatch = spec;
      }
    }

    return bestScore >= 0 ? bestMatch : null;
  }

  ThrowingApiSpecification? _findSyntaxFallback(AstNode node) {
    return switch (node) {
      FunctionExpressionInvocation(:final function) =>
        function is SimpleIdentifier
            ? _findTopLevelFunctionFallback(node, function.name)
            : null,
      MethodInvocation() => _findMethodInvocationFallback(node),
      _ => null,
    };
  }

  ThrowingApiSpecification? _findMethodInvocationFallback(
    MethodInvocation node,
  ) {
    final target = node.target;
    final methodName = node.methodName.name;

    if (target == null) {
      return _findTopLevelFunctionFallback(node, methodName);
    }

    final targetType = target.staticType;
    if (targetType is InterfaceType) {
      final className = targetType.element.name;
      if (className == null) {
        return null;
      }
      return _findInstanceMethodFallback(
        libraryUri: targetType.element.library.firstFragment.source.uri
            .toString(),
        className: className,
        methodName: methodName,
      );
    }

    if (target is SimpleIdentifier) {
      return _findClassStyleFallback(
        node,
        className: target.name,
        callableName: methodName,
      );
    }

    return null;
  }

  ThrowingApiSpecification? _findClassStyleFallback(
    AstNode node, {
    required String className,
    required String callableName,
  }) {
    for (final spec in manifest.apis) {
      if (spec.className != className) {
        continue;
      }
      if (!_isLibraryImported(node, spec.libraryUri)) {
        continue;
      }
      if (spec.constructorName == callableName ||
          (spec.methodName == callableName && (spec.isStatic ?? true))) {
        return spec;
      }
    }
    return null;
  }

  ThrowingApiSpecification? _findInstanceMethodFallback({
    required String libraryUri,
    required String className,
    required String methodName,
  }) {
    for (final spec in manifest.apis) {
      if (spec.libraryUri == libraryUri &&
          spec.className == className &&
          spec.methodName == methodName &&
          spec.isStatic != true) {
        return spec;
      }
    }
    return null;
  }

  ThrowingApiSpecification? _findTopLevelFunctionFallback(
    AstNode node,
    String functionName,
  ) {
    for (final spec in manifest.apis) {
      if (spec.functionName == functionName &&
          _isLibraryImported(node, spec.libraryUri)) {
        return spec;
      }
    }
    return null;
  }

  bool _isLibraryImported(AstNode node, String libraryUri) {
    final unit = node.thisOrAncestorOfType<CompilationUnit>();
    if (unit == null) {
      return false;
    }

    return unit.directives.whereType<ImportDirective>().any((directive) {
      return directive.uri.stringValue == libraryUri;
    });
  }

  int _matchScore(ThrowingApiSpecification spec, ResolvedCallable callable) {
    if (spec.packageName != callable.packageName ||
        spec.libraryUri != callable.libraryUri) {
      return -1;
    }

    if (spec.functionName case final functionName?) {
      return callable.kind == CallableKind.topLevelFunction &&
              callable.callableName == functionName
          ? 10
          : -1;
    }

    if (spec.constructorName case final constructorName?) {
      if (callable.kind != CallableKind.constructor ||
          !_matchesClass(spec, callable)) {
        return -1;
      }
      return callable.constructorName == constructorName ? 30 : -1;
    }

    if (spec.methodName case final methodName?) {
      if (callable.kind != CallableKind.instanceMethod &&
          callable.kind != CallableKind.staticMethod) {
        return -1;
      }
      if (!_matchesClass(spec, callable) ||
          callable.callableName != methodName) {
        return -1;
      }
      if (spec.isStatic != null && spec.isStatic != callable.isStatic) {
        return -1;
      }
      return spec.isStatic == callable.isStatic ? 40 : 35;
    }

    return -1;
  }

  bool _matchesClass(ThrowingApiSpecification spec, ResolvedCallable callable) {
    final specClassName = spec.className;
    if (specClassName == null) {
      return callable.enclosingClassName == null;
    }

    if (callable.enclosingClassName == specClassName) {
      return true;
    }

    if (!spec.appliesToSubtypes) {
      return false;
    }

    return callable.supertypeKeys.contains(
      '${callable.libraryUri}::$specClassName',
    );
  }

  bool _isProtectedByTryCatch(AstNode node) {
    AstNode? current = node.parent;
    while (current != null) {
      if (current is TryStatement &&
          current.catchClauses.isNotEmpty &&
          _containsNode(current.body, node)) {
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
}

enum CallableKind {
  topLevelFunction,
  instanceMethod,
  staticMethod,
  constructor,
}

final class ResolvedCallable {
  ResolvedCallable({
    required this.packageName,
    required this.libraryUri,
    required this.callableName,
    required this.kind,
    required this.isStatic,
    this.enclosingClassName,
    this.constructorName,
    required this.supertypeKeys,
  });

  final String packageName;
  final String libraryUri;
  final String callableName;
  final CallableKind kind;
  final bool isStatic;
  final String? enclosingClassName;
  final String? constructorName;
  final Set<String> supertypeKeys;

  static ResolvedCallable? tryCreate(Element? element) {
    switch (element) {
      case TopLevelFunctionElement():
        final sourceUri = _libraryUriFor(element);
        final packageName = _packageNameFromUri(sourceUri);
        final callableName = element.name;
        if (packageName == null || callableName == null) {
          return null;
        }
        return ResolvedCallable(
          packageName: packageName,
          libraryUri: sourceUri.toString(),
          callableName: callableName,
          kind: CallableKind.topLevelFunction,
          isStatic: true,
          supertypeKeys: const {},
        );
      case ConstructorElement():
        final sourceUri = _libraryUriFor(element);
        final packageName = _packageNameFromUri(sourceUri);
        final enclosingElement = element.enclosingElement;
        final className = enclosingElement.name;
        if (packageName == null || className == null) {
          return null;
        }
        return ResolvedCallable(
          packageName: packageName,
          libraryUri: sourceUri.toString(),
          callableName: className,
          kind: CallableKind.constructor,
          isStatic: true,
          enclosingClassName: className,
          constructorName: element.name,
          supertypeKeys: _supertypeKeys(enclosingElement),
        );
      case MethodElement():
        final sourceUri = _libraryUriFor(element);
        final packageName = _packageNameFromUri(sourceUri);
        final callableName = element.name;
        if (packageName == null || callableName == null) {
          return null;
        }
        final enclosingElement = element.enclosingElement;
        return ResolvedCallable(
          packageName: packageName,
          libraryUri: sourceUri.toString(),
          callableName: callableName,
          kind: element.isStatic
              ? CallableKind.staticMethod
              : CallableKind.instanceMethod,
          isStatic: element.isStatic,
          enclosingClassName: enclosingElement is InterfaceElement
              ? enclosingElement.name
              : null,
          supertypeKeys: enclosingElement is InterfaceElement
              ? _supertypeKeys(enclosingElement)
              : const {},
        );
      default:
        return null;
    }
  }

  static Uri _libraryUriFor(Element element) {
    return element.library!.firstFragment.source.uri;
  }

  static String? _packageNameFromUri(Uri uri) {
    if (uri.scheme != 'package' || uri.pathSegments.isEmpty) {
      return null;
    }
    return uri.pathSegments.first;
  }

  static Set<String> _supertypeKeys(InterfaceElement element) {
    return {
      for (final type in element.allSupertypes)
        if (type.element.name case final name?)
          '${type.element.library.firstFragment.source.uri}::$name',
    };
  }
}
