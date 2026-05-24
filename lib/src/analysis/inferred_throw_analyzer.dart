// ignore_for_file: implementation_imports

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/src/dart/ast/utilities.dart';

import '../config/exception_analysis_options.dart';
import '../config/throwing_api_manifest.dart';
import 'resolved_callable.dart';
import 'throw_protection.dart';
import 'throw_source_catalog.dart';
import 'throw_summary.dart';

final class InferredCallAnalysis {
  const InferredCallAnalysis({
    required this.displayName,
    required this.confidence,
    required this.isAsync,
    this.exceptionTypes = const [],
  });

  final String displayName;
  final ThrowConfidence confidence;
  final bool isAsync;
  final List<String> exceptionTypes;
}

enum CodeOrigin { internal, thirdParty }

final class InferredThrowAnalyzer {
  InferredThrowAnalyzer({
    required this.manifest,
    required this.options,
    required FeatureSet featureSet,
    required this.packageRootPath,
    Map<String, CompilationUnit> knownUnits = const {},
  }) : _featureSet = featureSet,
       _parsedUnits = Map<String, CompilationUnit>.from(knownUnits);

  final ThrowingApiManifest manifest;
  final ExceptionAnalysisOptions options;
  final String? packageRootPath;
  final FeatureSet _featureSet;
  final Map<String, ThrowSummary> _summaryCache = {};
  final Map<String, CompilationUnit> _parsedUnits;

  InferredCallAnalysis? analyzeResolvedCall(
    AstNode node, {
    required Element? element,
    required bool treatUnknownAsReportable,
    required bool requireObservedAsyncError,
    bool includeManifestOverrides = true,
  }) {
    final override = includeManifestOverrides
        ? _manifestAnalysisForElement(element)
        : null;
    if (override != null && options.shouldReport(override.confidence)) {
      return override;
    }

    final executable = _toExecutableElement(element);
    if (executable == null) {
      if (treatUnknownAsReportable &&
          options.treatDynamicInvocationAsThrowing &&
          _looksLikeUnknownTarget(node, element)) {
        return const InferredCallAnalysis(
          displayName: 'dynamic invocation',
          confidence: ThrowConfidence.unknown,
          isAsync: false,
        );
      }
      return null;
    }

    final summary = summarizeExecutable(executable);
    final filteredSummary = _filterSummaryForOrigin(
      summary,
      _originForExecutable(executable),
    );
    if (!filteredSummary.hasAnyThrowSource) {
      return null;
    }

    if (filteredSummary.confidence == ThrowConfidence.unknown &&
        !treatUnknownAsReportable) {
      return null;
    }

    if (filteredSummary.canCompleteWithAsyncError &&
        requireObservedAsyncError) {
      return InferredCallAnalysis(
        displayName: _displayNameForExecutable(executable),
        confidence: ThrowConfidence.asyncError,
        isAsync: true,
        exceptionTypes: _exceptionTypesFrom(filteredSummary),
      );
    }

    if (filteredSummary.canThrowSynchronously) {
      return InferredCallAnalysis(
        displayName: _displayNameForExecutable(executable),
        confidence: filteredSummary.confidence,
        isAsync: false,
        exceptionTypes: _exceptionTypesFrom(filteredSummary),
      );
    }

    if (filteredSummary.confidence == ThrowConfidence.unknown) {
      return InferredCallAnalysis(
        displayName: _displayNameForExecutable(executable),
        confidence: ThrowConfidence.unknown,
        isAsync: false,
        exceptionTypes: _exceptionTypesFrom(filteredSummary),
      );
    }

    return null;
  }

  ThrowSummary summarizeExecutable(ExecutableElement executable) {
    executable = executable.baseElement;
    final callable = ResolvedCallable.tryCreate(executable);
    final elementKey =
        callable?.elementKey ??
        '${executable.library.uri}::${executable.displayName}';

    if (_summaryCache[elementKey] case final cached?) {
      return cached;
    }

    final manifestOverride = _manifestSummaryForElement(executable, elementKey);
    if (manifestOverride != null) {
      return _summaryCache[elementKey] = manifestOverride;
    }

    if (executable is ConstructorElement &&
        executable.firstFragment.isSynthetic) {
      return _summaryCache[elementKey] = ThrowSummary.noObviousThrow(
        elementKey,
      );
    }

    if (executable.isExternal || executable.isAbstract) {
      final source = ThrowSource(
        kind: ThrowSourceKind.externalCall,
        confidence: ThrowConfidence.unknown,
        displayName: _displayNameForExecutable(executable),
      );
      return _summaryCache[elementKey] = ThrowSummary.unknown(
        elementKey,
        reason: 'external_or_abstract',
        sources: options.treatExternalCallsAsThrowing ? [source] : const [],
      );
    }

    final uri = executable.library.uri;
    if (uri.scheme == 'dart' && !options.analyzeSdkSource) {
      return _summaryCache[elementKey] = ThrowSummary.unknown(
        elementKey,
        reason: 'sdk_analysis_disabled',
      );
    }

    if (!options.analyzeThirdPartySource &&
        !_isWithinCurrentPackage(
          executable.firstFragment.libraryFragment.source.fullName,
        )) {
      return _summaryCache[elementKey] = ThrowSummary.unknown(
        elementKey,
        reason: 'third_party_analysis_disabled',
      );
    }

    return _summaryCache[elementKey] = _summarizeExecutableInternal(
      executable,
      elementKey: elementKey,
      depth: 0,
      activeKeys: {elementKey},
    );
  }

  ThrowSummary _summarizeExecutableInternal(
    ExecutableElement executable, {
    required String elementKey,
    required int depth,
    required Set<String> activeKeys,
  }) {
    if (depth > options.maxCallDepth) {
      return ThrowSummary.unknown(
        elementKey,
        reason: 'max_call_depth',
        sources: const [
          ThrowSource(
            kind: ThrowSourceKind.truncation,
            confidence: ThrowConfidence.unknown,
            displayName: 'max call depth reached',
          ),
        ],
      );
    }

    final declaration = _findDeclaration(executable);
    final body = declaration == null ? null : _bodyForDeclaration(declaration);
    if (body == null) {
      return ThrowSummary.unknown(elementKey, reason: 'source_unavailable');
    }

    final visitor = _BodySummaryVisitor(
      analyzer: this,
      executable: executable,
      depth: depth,
      activeKeys: activeKeys,
    );
    body.accept(visitor);

    return ThrowSummary.merge(
      elementKey,
      visitor.sources,
      dependencyElementKeys: visitor.dependencies,
      complete: visitor.complete,
      truncationReason: visitor.truncationReason,
    );
  }

  ThrowSummary inferCallFromBody(
    AstNode node, {
    required ExecutableElement currentExecutable,
    required int depth,
    required Set<String> activeKeys,
    required bool isAsyncObserved,
  }) {
    final directSource = ThrowSourceCatalog.matchUnresolvedInvocation(
      node,
      options,
    );
    if (directSource != null) {
      final shouldKeep = !directSource.isAsync || isAsyncObserved;
      if (shouldKeep) {
        return ThrowSummary.merge(
          directSource.displayName,
          [directSource],
          dependencyElementKeys: const [],
          complete: true,
        );
      }
    }

    final resolved = _resolveBodyCall(node, currentExecutable);
    if (resolved == null) {
      if (_looksLikeUnknownTarget(node, null) &&
          options.treatDynamicInvocationAsThrowing) {
        final source = ThrowSource(
          kind: ThrowSourceKind.dynamicInvocation,
          confidence: ThrowConfidence.unknown,
          displayName: node.toSource(),
        );
        return ThrowSummary.merge(
          node.toSource(),
          [source],
          dependencyElementKeys: const [],
          complete: false,
          truncationReason: 'dynamic_or_unresolved_call',
        );
      }
      return ThrowSummary.noObviousThrow(node.toSource());
    }

    final callable = ResolvedCallable.tryCreate(resolved);
    final dependencyKey =
        callable?.elementKey ??
        '${resolved.library.uri}::${resolved.displayName}';

    if (activeKeys.contains(dependencyKey)) {
      return ThrowSummary.merge(
        dependencyKey,
        const [
          ThrowSource(
            kind: ThrowSourceKind.truncation,
            confidence: ThrowConfidence.unknown,
            displayName: 'cyclic call graph',
          ),
        ],
        dependencyElementKeys: [dependencyKey],
        complete: false,
        truncationReason: 'cycle_detected',
      );
    }

    final nextActiveKeys = {...activeKeys, dependencyKey};
    final summary =
        _summaryCache[dependencyKey] ??
        _summarizeExecutableInternal(
          resolved.baseElement,
          elementKey: dependencyKey,
          depth: depth + 1,
          activeKeys: nextActiveKeys,
        );
    _summaryCache[dependencyKey] = summary;

    final propagatedSources = <ThrowSource>[];
    if (summary.canThrowSynchronously) {
      propagatedSources.add(
        ThrowSource(
          kind: ThrowSourceKind.inferredCall,
          confidence: summary.confidence,
          displayName: _displayNameForExecutable(resolved),
          intent: _strongestIntentFrom(
            summary.sources,
            where: (source) => !source.isAsync && source.confidence.isThrowing,
          ),
          exceptionTypes: _exceptionTypesFrom(summary),
        ),
      );
    }
    if (summary.canCompleteWithAsyncError && isAsyncObserved) {
      propagatedSources.add(
        ThrowSource(
          kind: ThrowSourceKind.awaitedAsyncDependency,
          confidence: ThrowConfidence.asyncError,
          displayName: _displayNameForExecutable(resolved),
          intent: _strongestIntentFrom(
            summary.sources,
            where: (source) =>
                source.isAsync ||
                source.confidence == ThrowConfidence.asyncError,
          ),
          isAsync: true,
          exceptionTypes: _exceptionTypesFrom(summary),
        ),
      );
    }
    if (summary.confidence == ThrowConfidence.unknown &&
        propagatedSources.isEmpty &&
        options.reportUnknown) {
      propagatedSources.add(
        ThrowSource(
          kind: ThrowSourceKind.unresolvedCall,
          confidence: ThrowConfidence.unknown,
          displayName: _displayNameForExecutable(resolved),
          intent: _strongestIntentFrom(summary.sources),
          exceptionTypes: _exceptionTypesFrom(summary),
        ),
      );
    }

    return ThrowSummary.merge(
      dependencyKey,
      propagatedSources,
      dependencyElementKeys: [dependencyKey, ...summary.dependencyElementKeys],
      complete: summary.complete,
      truncationReason: summary.truncationReason,
    );
  }

  ExecutableElement? _resolveBodyCall(
    AstNode node,
    ExecutableElement currentExecutable,
  ) {
    final library = currentExecutable.library;

    final enclosingInterface = switch (currentExecutable.enclosingElement) {
      InterfaceElement interface => interface,
      _ => null,
    };

    switch (node) {
      case FunctionExpressionInvocation(:final function)
          when function is SimpleIdentifier:
        return library.getTopLevelFunction(function.name) ??
            enclosingInterface?.getMethod(function.name);
      case InstanceCreationExpression(:final constructorName):
        final classElement = _resolveClassReference(
          library,
          constructorName.type.name.lexeme,
        );
        if (classElement == null) {
          return null;
        }
        final name = constructorName.name?.name ?? '';
        return classElement.getNamedConstructor(name) ??
            classElement.constructors.where((constructor) {
              return constructor.name == name;
            }).firstOrNull;
      case MethodInvocation(:final target, :final methodName):
        final method = methodName.name;
        if (target == null) {
          final localMethod =
              enclosingInterface?.getMethod(method) ??
              library.getTopLevelFunction(method);
          if (localMethod != null) {
            return localMethod;
          }

          final constructorClass = _resolveClassReference(library, method);
          if (constructorClass != null) {
            final unnamedConstructor = constructorClass.getNamedConstructor('');
            if (unnamedConstructor != null) {
              return unnamedConstructor;
            }
            for (final constructor in constructorClass.constructors) {
              if ((constructor.name ?? '').isEmpty) {
                return constructor;
              }
            }
            return null;
          }
          return null;
        }

        if (target is ThisExpression) {
          return enclosingInterface?.getMethod(method);
        }

        if (target is SuperExpression && enclosingInterface != null) {
          for (final type in enclosingInterface.allSupertypes) {
            final member = type.element.getMethod(method);
            if (member != null) {
              return member;
            }
          }
        }

        if (target is SimpleIdentifier) {
          final importLibrary = _resolvePrefixedLibrary(library, target.name);
          if (importLibrary != null) {
            return importLibrary.getTopLevelFunction(method) ??
                _resolveClassReference(
                  importLibrary,
                  method,
                )?.getMethod(method);
          }

          final classElement = _resolveClassReference(library, target.name);
          return classElement?.getMethod(method);
        }
    }

    return null;
  }

  ClassElement? _resolveClassReference(
    LibraryElement library,
    String className,
  ) {
    final localClass = library.getClass(className);
    if (localClass != null) {
      return localClass;
    }

    for (final import in library.firstFragment.libraryImports) {
      final importedLibrary = import.importedLibrary;
      final importedClass = importedLibrary?.getClass(className);
      if (importedClass != null) {
        return importedClass;
      }
    }

    return null;
  }

  LibraryElement? _resolvePrefixedLibrary(
    LibraryElement library,
    String prefix,
  ) {
    for (final import in library.firstFragment.libraryImports) {
      if (import.prefix?.name == prefix) {
        return import.importedLibrary;
      }
    }
    return null;
  }

  ThrowSummary? _manifestSummaryForElement(
    ExecutableElement executable,
    String elementKey,
  ) {
    final match = _matchingManifestSpec(executable);
    if (match == null) {
      return null;
    }

    final confidence = match.confidence;
    final source = ThrowSource(
      kind: ThrowSourceKind.manifestOverride,
      confidence: confidence,
      displayName: match.displayName,
      isAsync: match.isAsync,
      exceptionTypes: match.exceptionTypes,
    );
    return ThrowSummary.merge(
      elementKey,
      [source],
      dependencyElementKeys: const [],
      complete: true,
    );
  }

  InferredCallAnalysis? _manifestAnalysisForElement(Element? element) {
    final executable = _toExecutableElement(element);
    if (executable == null) {
      return null;
    }

    final match = _matchingManifestSpec(executable);
    if (match == null) {
      return null;
    }

    return InferredCallAnalysis(
      displayName: match.displayName,
      confidence: match.confidence,
      isAsync: match.isAsync,
      exceptionTypes: match.exceptionTypes,
    );
  }

  ThrowingApiSpecification? _matchingManifestSpec(
    ExecutableElement executable,
  ) {
    final callable = ResolvedCallable.tryCreate(executable);
    if (callable == null) {
      return null;
    }

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

  AstNode? _findDeclaration(ExecutableElement executable) {
    final fragment = executable.firstFragment;
    if (fragment.isSynthetic) {
      return null;
    }

    final path = fragment.libraryFragment.source.fullName;
    if (path.isEmpty) {
      return null;
    }

    final unit = _parsedUnits.putIfAbsent(
      path,
      () => parseFile(
        path: path,
        featureSet: _featureSet,
        throwIfDiagnostics: false,
      ).unit,
    );
    final declarationNode = NodeLocator2(
      fragment.nameOffset ?? fragment.offset,
    ).searchWithin(unit);
    if (declarationNode == null) {
      return null;
    }

    return declarationNode.thisOrAncestorMatching((node) {
      return node is FunctionDeclaration ||
          node is MethodDeclaration ||
          node is ConstructorDeclaration;
    });
  }

  FunctionBody? _bodyForDeclaration(AstNode declaration) {
    return switch (declaration) {
      FunctionDeclaration(:final functionExpression) => functionExpression.body,
      MethodDeclaration(:final body) => body,
      ConstructorDeclaration(:final body) => body,
      _ => null,
    };
  }

  static ExecutableElement? _toExecutableElement(Element? element) {
    return switch (element) {
      ExecutableElement executable => executable,
      _ => null,
    };
  }

  static bool _looksLikeUnknownTarget(AstNode node, Element? element) {
    if (element == null) {
      if (node case MethodInvocation(:final target, :final methodName)
          when target == null &&
              methodName.name.isNotEmpty &&
              _startsWithUppercase(methodName.name)) {
        return false;
      }
      return node is MethodInvocation ||
          node is FunctionExpressionInvocation ||
          node is InstanceCreationExpression;
    }

    if (element is TopLevelFunctionElement ||
        element is MethodElement ||
        element is ConstructorElement ||
        element is PropertyAccessorElement) {
      return false;
    }

    return true;
  }

  static int _matchScore(
    ThrowingApiSpecification spec,
    ResolvedCallable callable,
  ) {
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

  static bool _matchesClass(
    ThrowingApiSpecification spec,
    ResolvedCallable callable,
  ) {
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

  static String _displayNameForExecutable(ExecutableElement executable) {
    final libraryUri = executable.library.uri;
    final packageName =
        libraryUri.scheme == 'package' && libraryUri.pathSegments.isNotEmpty
        ? libraryUri.pathSegments.first
        : libraryUri.toString();
    final enclosing = switch (executable.enclosingElement) {
      InterfaceElement(:final name?) => '$name.',
      _ => '',
    };
    final name = executable is ConstructorElement
        ? (executable.name ?? '').isEmpty
              ? '${executable.enclosingElement.name}()'
              : '${executable.enclosingElement.name}.${executable.name}'
        : '$enclosing${executable.displayName}';
    return '$packageName/$name';
  }

  static List<String> _exceptionTypesFrom(ThrowSummary summary) {
    return {
      for (final source in summary.sources) ...source.exceptionTypes,
    }.toList()..sort();
  }

  ThrowSummary _filterSummaryForOrigin(
    ThrowSummary summary,
    CodeOrigin origin,
  ) {
    final minimum = switch (origin) {
      CodeOrigin.internal => options.internalStrictness,
      CodeOrigin.thirdParty => options.thirdPartyStrictness,
    };
    final filteredSources = summary.sources
        .where((source) => source.effectiveIntent.meets(minimum))
        .toList();

    return ThrowSummary.merge(
      summary.elementKey,
      filteredSources,
      dependencyElementKeys: summary.dependencyElementKeys,
      complete: summary.complete,
      truncationReason: summary.truncationReason,
    );
  }

  CodeOrigin _originForExecutable(ExecutableElement executable) {
    final path = executable.firstFragment.libraryFragment.source.fullName;
    return _isWithinCurrentPackage(path)
        ? CodeOrigin.internal
        : CodeOrigin.thirdParty;
  }

  static ThrowIntent? _strongestIntentFrom(
    Iterable<ThrowSource> sources, {
    bool Function(ThrowSource source)? where,
  }) {
    ThrowIntent? strongest;
    for (final source in sources) {
      if (where != null && !where(source)) {
        continue;
      }
      final intent = source.effectiveIntent;
      if (strongest == null || intent.index < strongest.index) {
        strongest = intent;
      }
    }
    return strongest;
  }

  static bool _startsWithUppercase(String value) {
    final firstCodeUnit = value.codeUnitAt(0);
    return firstCodeUnit >= 65 && firstCodeUnit <= 90;
  }

  bool _isWithinCurrentPackage(String path) {
    final root = packageRootPath;
    if (root == null) {
      return false;
    }
    if (path == root) {
      return true;
    }

    final normalizedRoot = root.endsWith('/') ? root : '$root/';
    const packageSourceDirectories = ['bin', 'lib', 'test', 'tool'];
    return packageSourceDirectories.any(
      (directory) => path.startsWith('$normalizedRoot$directory/'),
    );
  }
}

final class _BodySummaryVisitor extends RecursiveAstVisitor<void> {
  _BodySummaryVisitor({
    required this.analyzer,
    required this.executable,
    required this.depth,
    required this.activeKeys,
  });

  final InferredThrowAnalyzer analyzer;
  final ExecutableElement executable;
  final int depth;
  final Set<String> activeKeys;
  final List<ThrowSource> sources = [];
  final Set<String> dependencies = {};
  bool complete = true;
  String? truncationReason;

  bool get _isAsyncContext => executable.firstFragment.isAsynchronous;

  @override
  void visitAsExpression(AsExpression node) {
    final source = ThrowSourceCatalog.matchAsExpression(node, analyzer.options);
    if (source != null && !_isProtected(node, source)) {
      sources.add(_normalize(source));
    }
    super.visitAsExpression(node);
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    _recordCall(node);
    super.visitFunctionExpressionInvocation(node);
  }

  @override
  void visitIndexExpression(IndexExpression node) {
    final source = ThrowSourceCatalog.matchIndexAccess(node, analyzer.options);
    if (source != null && !_isProtected(node, source)) {
      sources.add(_normalize(source));
    }
    super.visitIndexExpression(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    _recordCall(node);
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    _recordCall(node);
    super.visitMethodInvocation(node);
  }

  @override
  void visitPostfixExpression(PostfixExpression node) {
    if (node.operator.lexeme == '!') {
      const source = ThrowSource(
        kind: ThrowSourceKind.nullAssertion,
        confidence: ThrowConfidence.possibleThrow,
        displayName: 'null assertion',
      );
      if (!_isProtected(node, source)) {
        sources.add(_normalize(source));
      }
    }
    super.visitPostfixExpression(node);
  }

  @override
  void visitRethrowExpression(RethrowExpression node) {
    const source = ThrowSource(
      kind: ThrowSourceKind.rethrowExpression,
      confidence: ThrowConfidence.definiteThrow,
      displayName: 'rethrow',
    );
    if (!_isProtected(node, source)) {
      sources.add(_normalize(source));
    }
  }

  @override
  void visitThrowExpression(ThrowExpression node) {
    final source = ThrowSource(
      kind: ThrowSourceKind.explicitThrow,
      confidence: ThrowConfidence.definiteThrow,
      displayName: 'throw ${node.expression.toSource()}',
    );
    if (!_isProtected(node, source)) {
      sources.add(_normalize(source));
    }
    super.visitThrowExpression(node);
  }

  void _recordCall(AstNode node) {
    final summary = analyzer.inferCallFromBody(
      node,
      currentExecutable: executable,
      depth: depth,
      activeKeys: activeKeys,
      isAsyncObserved: _isAsyncObserved(node),
    );
    if (summary.sources.isEmpty) {
      return;
    }

    sources.addAll(
      summary.sources
          .where((source) => !_isProtected(node, source))
          .map(_normalize),
    );
    dependencies.addAll(summary.dependencyElementKeys);
    complete = complete && summary.complete;
    truncationReason ??= summary.truncationReason;
  }

  bool _isProtected(AstNode node, ThrowSource source) {
    return isProtectedByCatch(
      node,
      requireAsyncProtection: source.isAsync,
      exceptionTypes: source.exceptionTypes,
    );
  }

  ThrowSource _normalize(ThrowSource source) {
    if (!_isAsyncContext || source.isAsync) {
      return source;
    }

    final confidence = switch (source.confidence) {
      ThrowConfidence.definiteThrow ||
      ThrowConfidence.possibleThrow => ThrowConfidence.asyncError,
      _ => source.confidence,
    };
    return ThrowSource(
      kind: source.kind,
      confidence: confidence,
      displayName: source.displayName,
      intent: source.intent,
      isAsync: confidence == ThrowConfidence.asyncError,
      exceptionTypes: source.exceptionTypes,
    );
  }

  bool _isAsyncObserved(AstNode node) {
    final parent = node.parent;
    return parent is AwaitExpression ||
        parent is ReturnStatement ||
        identical(
          (parent is ExpressionFunctionBody ? parent.expression : null),
          node,
        );
  }
}
