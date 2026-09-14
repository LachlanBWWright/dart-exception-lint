// ignore_for_file: implementation_imports

import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/src/dart/ast/utilities.dart';

import '../config/exception_analysis_options.dart';
import '../config/throwing_api_manifest.dart';
import 'resolved_callable.dart';
import 'throw_protection.dart';
import 'throw_source_catalog.dart';
import 'throw_summary.dart';
import 'exception_annotations.dart';

final class InferredCallAnalysis {
  const InferredCallAnalysis({
    required this.displayName,
    required this.confidence,
    required this.isAsync,
    this.isDeferred = false,
    this.exceptionTypes = const [],
    this.origin,
  });

  final String displayName;
  final ThrowConfidence confidence;
  final bool isAsync;
  final bool isDeferred;
  final List<String> exceptionTypes;
  final ThrowOrigin? origin;
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
       _parsedUnits = Map<String, CompilationUnit>.from(knownUnits),
       _knownExecutables = _collectKnownExecutables(knownUnits.values);

  final ThrowingApiManifest manifest;
  final ExceptionAnalysisOptions options;
  final String? packageRootPath;
  final FeatureSet _featureSet;
  final Map<String, ThrowSummary> _summaryCache = {};
  final Map<String, CompilationUnit> _parsedUnits;
  final List<ExecutableElement> _knownExecutables;

  // Rule visitors are created per analyzed unit and per diagnostic. Keep the
  // expensive source parsing shared between those short-lived analyzers, but
  // key entries by modification time so edits are picked up immediately.
  static final Map<String, _ParsedUnitCacheEntry> _sharedParsedUnits = {};
  static const _maxSharedParsedUnits = 512;

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

    if (isInsideExceptionBoundary(node)) {
      return null;
    }

    if (hasExceptionBoundaryAnnotation(executable)) {
      return null;
    }

    final summary = _summaryForDispatch(
      executable,
      summarizeExecutable(executable),
      node,
    );
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
        origin: _firstOrigin(filteredSummary),
      );
    }

    if (filteredSummary.canThrowSynchronously) {
      return InferredCallAnalysis(
        displayName: _displayNameForExecutable(executable),
        confidence: filteredSummary.confidence,
        isAsync: false,
        exceptionTypes: _exceptionTypesFrom(filteredSummary),
        origin: _firstOrigin(filteredSummary),
      );
    }

    if (filteredSummary.canCompleteWithDeferredError) {
      return InferredCallAnalysis(
        displayName: _displayNameForExecutable(executable),
        confidence: filteredSummary.confidence,
        isAsync: false,
        isDeferred: true,
        exceptionTypes: _exceptionTypesFrom(filteredSummary),
        origin: _firstOrigin(filteredSummary),
      );
    }

    if (filteredSummary.canCompleteWithAsyncError) {
      return InferredCallAnalysis(
        displayName: _displayNameForExecutable(executable),
        confidence: ThrowConfidence.asyncError,
        isAsync: true,
        exceptionTypes: _exceptionTypesFrom(filteredSummary),
        origin: _firstOrigin(filteredSummary),
      );
    }

    if (filteredSummary.confidence == ThrowConfidence.unknown) {
      return InferredCallAnalysis(
        displayName: _displayNameForExecutable(executable),
        confidence: ThrowConfidence.unknown,
        isAsync: false,
        exceptionTypes: _exceptionTypesFrom(filteredSummary),
        origin: _firstOrigin(filteredSummary),
      );
    }

    return null;
  }

  InferredCallAnalysis? analyzeInlineFunctionInvocation(
    FunctionExpressionInvocation node,
  ) {
    final function = switch (node.function) {
      FunctionExpression() => node.function as FunctionExpression,
      ParenthesizedExpression(:final expression)
          when expression is FunctionExpression =>
        expression,
      _ => null,
    };
    if (function == null) return null;

    final visitor = _InlineThrowSourceVisitor();
    function.body.accept(visitor);
    final summary = ThrowSummary.merge(
      'inline:${node.offset}',
      visitor.sources,
      dependencyElementKeys: const [],
      complete: true,
    );
    if (!summary.canThrowSynchronously) return null;
    return InferredCallAnalysis(
      displayName: 'inline closure',
      confidence: summary.confidence,
      isAsync: false,
      exceptionTypes: _exceptionTypesFrom(summary),
    );
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

    if (executable.metadata.hasAlwaysThrows) {
      return _summaryCache[elementKey] = ThrowSummary.merge(
        elementKey,
        [
          ThrowSource(
            kind: ThrowSourceKind.explicitThrow,
            confidence: ThrowConfidence.definiteThrow,
            displayName: _displayNameForExecutable(executable),
          ),
        ],
        dependencyElementKeys: const [],
        complete: true,
      );
    }

    // Public contracts are authoritative for source-unavailable APIs and are
    // also useful for documenting deliberately broader behavior than the
    // implementation currently exposes.
    final contract = exceptionContractFor(executable);
    if (contract != null) {
      if (contract.kind == ExceptionContractKind.doesNotThrow) {
        return _summaryCache[elementKey] = ThrowSummary.noObviousThrow(
          elementKey,
        );
      }
      final isAsync = contract.kind == ExceptionContractKind.failingFuture;
      return _summaryCache[elementKey] = ThrowSummary.merge(
        elementKey,
        [
          ThrowSource(
            kind: ThrowSourceKind.manifestOverride,
            confidence: isAsync
                ? ThrowConfidence.asyncError
                : ThrowConfidence.possibleThrow,
            displayName: _displayNameForExecutable(executable),
            isAsync: isAsync,
            exceptionTypes: contract.exceptionTypes,
          ),
        ],
        dependencyElementKeys: const [],
        complete: true,
      );
    }

    // A resolved `Never` return type is an analyzer-level guarantee that the
    // invocation cannot complete normally. This remains useful for external,
    // native, and source-unavailable declarations where body inspection is
    // impossible. Treat it as a definite synchronous source; callers can
    // still protect it with the ordinary catch analysis.
    if (executable.returnType is NeverType) {
      return _summaryCache[elementKey] = ThrowSummary.merge(
        elementKey,
        [
          ThrowSource(
            kind: ThrowSourceKind.explicitThrow,
            confidence: ThrowConfidence.definiteThrow,
            displayName: _displayNameForExecutable(executable),
          ),
        ],
        dependencyElementKeys: const [],
        complete: true,
      );
    }

    final manifestOverride = _manifestSummaryForElement(executable, elementKey);
    if (manifestOverride != null) {
      return _summaryCache[elementKey] = manifestOverride;
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
    final constructorClass = executable is ConstructorElement
        ? _findClassDeclaration(executable.enclosingElement)
        : null;
    if (body == null && constructorClass == null) {
      return ThrowSummary.unknown(elementKey, reason: 'source_unavailable');
    }

    final visitor = _BodySummaryVisitor(
      analyzer: this,
      executable: executable,
      depth: depth,
      activeKeys: activeKeys,
    );
    body?.accept(visitor);

    // Constructor execution includes initializer-list expressions and the
    // instance field initializers that run before its body. Include those
    // effects in the constructor summary instead of treating the body as the
    // complete execution surface.
    if (executable is ConstructorElement) {
      if (constructorClass != null) {
        for (final field
            in constructorClass.body.members.whereType<FieldDeclaration>()) {
          for (final variable in field.fields.variables) {
            variable.initializer?.accept(visitor);
          }
        }
      }
      if (declaration case final ConstructorDeclaration constructor) {
        constructor.initializers.accept(visitor);
      }
    }

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
    Element? resolvedElement,
    required int depth,
    required Set<String> activeKeys,
    required bool isAsyncObserved,
  }) {
    final inlineFunction = switch (node) {
      FunctionExpressionInvocation(:final function) => switch (function) {
        FunctionExpression() => function,
        ParenthesizedExpression(:final expression)
            when expression is FunctionExpression =>
          expression,
        _ => null,
      },
      _ => null,
    };
    if (inlineFunction != null) {
      final visitor = _BodySummaryVisitor(
        analyzer: this,
        executable: currentExecutable,
        depth: depth,
        activeKeys: activeKeys,
      );
      inlineFunction.body.accept(visitor);
      return ThrowSummary.merge(
        node.toSource(),
        visitor.sources,
        dependencyElementKeys: visitor.dependencies,
        complete: visitor.complete,
        truncationReason: visitor.truncationReason,
      );
    }

    final directBinary = node is BinaryExpression
        ? ThrowSourceCatalog.matchBinaryExpression(node, options)
        : null;
    if (directBinary != null) {
      return ThrowSummary.merge(
        directBinary.displayName,
        [directBinary],
        dependencyElementKeys: const [],
        complete: true,
      );
    }
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

    final resolved =
        _toExecutableElement(resolvedElement) ??
        _resolveBodyCall(node, currentExecutable);
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
    final dispatchSummary = _summaryForDispatch(resolved, summary, node);

    final propagatedSources = <ThrowSource>[];
    if (dispatchSummary.canThrowSynchronously) {
      propagatedSources.add(
        ThrowSource(
          kind: ThrowSourceKind.inferredCall,
          confidence: dispatchSummary.confidence,
          displayName: _displayNameForExecutable(resolved),
          intent: _strongestIntentFrom(
            summary.sources,
            where: (source) =>
                source.effectiveTiming == ThrowTiming.synchronous &&
                source.confidence.isThrowing,
          ),
          exceptionTypes: _exceptionTypesFrom(dispatchSummary),
          origin: _firstOrigin(dispatchSummary),
        ),
      );
    }
    if (dispatchSummary.canCompleteWithDeferredError) {
      propagatedSources.add(
        ThrowSource(
          kind: ThrowSourceKind.inferredCall,
          confidence: dispatchSummary.confidence,
          displayName: _displayNameForExecutable(resolved),
          timing: ThrowTiming.deferred,
          intent: _strongestIntentFrom(
            summary.sources,
            where: (source) =>
                source.effectiveTiming == ThrowTiming.deferred &&
                source.confidence.isThrowing,
          ),
          exceptionTypes: _exceptionTypesFrom(dispatchSummary),
          origin: _firstOrigin(dispatchSummary),
        ),
      );
    }
    if (dispatchSummary.canCompleteWithAsyncError && isAsyncObserved) {
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
          exceptionTypes: _exceptionTypesFrom(dispatchSummary),
          origin: _firstOrigin(dispatchSummary),
        ),
      );
    }
    if (dispatchSummary.confidence == ThrowConfidence.unknown &&
        propagatedSources.isEmpty &&
        options.reportUnknown) {
      propagatedSources.add(
        ThrowSource(
          kind: ThrowSourceKind.unresolvedCall,
          confidence: ThrowConfidence.unknown,
          displayName: _displayNameForExecutable(resolved),
          intent: _strongestIntentFrom(dispatchSummary.sources),
          exceptionTypes: _exceptionTypesFrom(dispatchSummary),
        ),
      );
    }

    return ThrowSummary.merge(
      dependencyKey,
      propagatedSources,
      dependencyElementKeys: [dependencyKey, ...summary.dependencyElementKeys],
      complete: dispatchSummary.complete,
      truncationReason: dispatchSummary.truncationReason,
    );
  }

  ThrowSummary _summaryForDispatch(
    ExecutableElement declared,
    ThrowSummary baseSummary,
    AstNode callSite,
  ) {
    if (declared is! MethodElement || declared.isStatic) {
      return baseSummary;
    }

    final receiverType = switch (callSite) {
      MethodInvocation(:final target) => target?.staticType,
      PropertyAccess(:final target) => target?.staticType,
      _ => null,
    };
    final receiverElement = receiverType is InterfaceType
        ? receiverType.element
        : declared.enclosingElement is InterfaceElement
        ? declared.enclosingElement as InterfaceElement
        : null;
    if (receiverElement == null) return baseSummary;

    final candidates = _knownExecutables.where((candidate) {
      if (candidate is! MethodElement || candidate.isStatic) return false;
      if (candidate.name != declared.name) return false;
      final enclosing = candidate.enclosingElement;
      if (enclosing is! InterfaceElement) return false;
      if (enclosing == declared.enclosingElement) return false;
      return enclosing.allSupertypes.any(
        (type) => type.element == receiverElement,
      );
    });

    final candidateSummaries = <ThrowSummary>[];
    for (final candidate in candidates) {
      final callable = ResolvedCallable.tryCreate(candidate);
      final key =
          callable?.elementKey ??
          '${candidate.library.uri}::${candidate.displayName}';
      final summary =
          _summaryCache[key] ??
          _summarizeExecutableInternal(
            candidate.baseElement,
            elementKey: key,
            depth: 1,
            activeKeys: {baseSummary.elementKey, key},
          );
      _summaryCache[key] = summary;
      candidateSummaries.add(summary);
    }
    if (candidateSummaries.isEmpty) return baseSummary;

    return ThrowSummary.merge(
      baseSummary.elementKey,
      [
        ...baseSummary.sources,
        for (final summary in candidateSummaries) ...summary.sources,
      ],
      dependencyElementKeys: [
        ...baseSummary.dependencyElementKeys,
        for (final summary in candidateSummaries)
          ...summary.dependencyElementKeys,
      ],
      complete:
          baseSummary.complete &&
          candidateSummaries.every((summary) => summary.complete),
      truncationReason: baseSummary.truncationReason,
    );
  }

  static List<ExecutableElement> _collectKnownExecutables(
    Iterable<CompilationUnit> units,
  ) {
    final elements = <ExecutableElement>[];
    final elementSet = <ExecutableElement>{};
    final libraries = <LibraryElement>{};
    for (final unit in units) {
      final collected = <ExecutableElement>[];
      final collector = _ExecutableCollector(collected);
      unit.accept(collector);
      for (final element in collected) {
        if (elementSet.add(element)) elements.add(element);
        libraries.add(element.library);
      }
    }

    // A library can expose implementations through several layers of
    // imports/exports. Walk the reachable graph rather than only the first
    // import layer, while retaining a hard bound for pathological package
    // graphs.
    final pending = <LibraryElement>[...libraries];
    final visitedLibraries = <LibraryElement>{};
    const maxLibraries = 2048;
    while (pending.isNotEmpty && visitedLibraries.length < maxLibraries) {
      final library = pending.removeLast();
      if (!visitedLibraries.add(library)) continue;
      final fragment = library.firstFragment;
      pending
        ..addAll(fragment.importedLibraries)
        ..addAll(library.exportedLibraries);

      for (final type in [
        ...library.classes,
        ...library.enums,
        ...library.mixins,
      ]) {
        for (final member in [
          ...type.methods,
          ...type.getters,
          ...type.setters,
        ]) {
          if (elementSet.add(member)) elements.add(member);
        }
      }
    }
    return elements;
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
    final path = fragment.libraryFragment.source.fullName;
    if (path.isEmpty) {
      return null;
    }
    if (!_parsedUnits.containsKey(path) && !File(path).existsSync()) {
      return null;
    }

    final unit = _parsedUnits[path] ??= _parseSharedUnitSafely(path);
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

  ClassDeclaration? _findClassDeclaration(InterfaceElement element) {
    final fragment = element.firstFragment;
    final path = fragment.libraryFragment.source.fullName;
    if (path.isEmpty) return null;
    if (!_parsedUnits.containsKey(path) && !File(path).existsSync()) {
      return null;
    }
    final unit = _parsedUnits[path] ??= _parseSharedUnitSafely(path);
    final node = NodeLocator2(
      fragment.nameOffset ?? fragment.offset,
    ).searchWithin(unit);
    return node?.thisOrAncestorMatching(
          (candidate) => candidate is ClassDeclaration,
        )
        as ClassDeclaration?;
  }

  CompilationUnit _parseSharedUnit(String path) {
    // Analyzer test contexts can provide virtual units whose paths do not
    // exist on disk. Those units must never reach FileStat/parseFile.
    if (_parsedUnits[path] case final knownUnit?) {
      return knownUnit;
    }

    final stat = FileStat.statSync(path);
    final modified = stat.modified;
    final fingerprint = Object.hashAll(File(path).readAsBytesSync());
    final shared = _sharedParsedUnits[path];
    final parsedUnit =
        shared != null &&
            shared.modified == modified &&
            shared.size == stat.size &&
            shared.fingerprint == fingerprint
        ? shared.unit
        : parseFile(
            path: path,
            featureSet: _featureSet,
            throwIfDiagnostics: false,
          ).unit;
    _sharedParsedUnits[path] = _ParsedUnitCacheEntry(
      modified: modified,
      size: stat.size,
      fingerprint: fingerprint,
      unit: parsedUnit,
    );
    if (_sharedParsedUnits.length > _maxSharedParsedUnits) {
      _sharedParsedUnits.remove(_sharedParsedUnits.keys.first);
    }
    return parsedUnit;
  }

  CompilationUnit _parseSharedUnitSafely(String path) {
    // Analysis may race with an editor save/rename. A lint must not crash the
    // analyzer process because a source file disappeared between the
    // existence check and parsing. Returning an empty unit makes the caller
    // conservatively treat the declaration as unavailable.
    try {
      return _parseSharedUnit(path);
    } on FileSystemException {
      return parseString(content: '', path: path, featureSet: _featureSet).unit;
    } on FormatException {
      return parseString(content: '', path: path, featureSet: _featureSet).unit;
    }
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
    if (spec.packageName != callable.packageName) {
      return -1;
    }

    if (spec.functionName case final functionName?) {
      return spec.libraryUri == callable.libraryUri &&
              callable.kind == CallableKind.topLevelFunction &&
              callable.callableName == functionName
          ? 10
          : -1;
    }

    if (spec.constructorName case final constructorName?) {
      if (spec.libraryUri != callable.libraryUri ||
          callable.kind != CallableKind.constructor ||
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
      '${spec.libraryUri}::$specClassName',
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

  static ThrowOrigin? _firstOrigin(ThrowSummary summary) {
    for (final source in summary.sources) {
      if (source.origin case final origin?) return origin;
    }
    return null;
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

final class _ParsedUnitCacheEntry {
  const _ParsedUnitCacheEntry({
    required this.modified,
    required this.size,
    required this.fingerprint,
    required this.unit,
  });

  final DateTime modified;
  final int size;
  final int fingerprint;
  final CompilationUnit unit;
}

final class _ExecutableCollector extends RecursiveAstVisitor<void> {
  _ExecutableCollector(this.elements);

  final List<ExecutableElement> elements;

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    final element = node.declaredFragment?.element;
    if (element != null) elements.add(element);
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    final element = node.declaredFragment?.element;
    if (element != null) elements.add(element);
    super.visitMethodDeclaration(node);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    final element = node.declaredFragment?.element;
    if (element != null) elements.add(element);
    super.visitConstructorDeclaration(node);
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
  int _conditionalDepth = 0;

  bool get _isAsyncContext => executable.firstFragment.isAsynchronous;

  @override
  void visitFunctionExpression(FunctionExpression node) {
    // A closure body is not executed merely because the closure is created.
    // Analyze an immediately invoked closure at its call site, but do not
    // attribute callback/tear-off bodies to the enclosing executable.
    if (node.parent case FunctionExpressionInvocation(
      :final function,
    ) when identical(function, node)) {
      super.visitFunctionExpression(node);
    }
  }

  @override
  void visitBlock(Block node) {
    // Do not let unreachable statements leak effects into the enclosing
    // callable. This is deliberately a small, sound subset of CFG analysis:
    // it recognizes only unconditional terminators and otherwise continues
    // visiting normally. More complex branches remain conservative.
    for (final statement in node.statements) {
      statement.accept(this);
      if (_alwaysTerminates(statement)) {
        break;
      }
    }
  }

  @override
  void visitAsExpression(AsExpression node) {
    final source = ThrowSourceCatalog.matchAsExpression(node, analyzer.options);
    if (source != null && !_isProtected(node, source)) {
      sources.add(_normalize(source, node));
    }
    super.visitAsExpression(node);
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    _recordCall(node);
    super.visitFunctionExpressionInvocation(node);
  }

  @override
  void visitIfStatement(IfStatement node) {
    final constant = _constantBoolean(node.expression);
    if (constant == null) {
      node.expression.accept(this);
      _conditionalDepth++;
      node.thenStatement.accept(this);
      node.elseStatement?.accept(this);
      _conditionalDepth--;
      return;
    }

    node.expression.accept(this);
    if (constant) {
      node.thenStatement.accept(this);
    } else {
      node.elseStatement?.accept(this);
    }
  }

  @override
  void visitIndexExpression(IndexExpression node) {
    final source = ThrowSourceCatalog.matchIndexAccess(node, analyzer.options);
    if (source != null && !_isProtected(node, source)) {
      sources.add(_normalize(source, node));
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
  void visitPropertyAccess(PropertyAccess node) {
    _recordCall(node);
    super.visitPropertyAccess(node);
  }

  @override
  void visitBinaryExpression(BinaryExpression node) {
    _recordCall(node);
    super.visitBinaryExpression(node);
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
        sources.add(_normalize(source, node));
      }
    }
    super.visitPostfixExpression(node);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    _recordCall(node);
    super.visitPrefixedIdentifier(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final source = ThrowSourceCatalog.matchLateInitializationRead(
      node,
      analyzer.options,
    );
    if (source != null && !_isProtected(node, source)) {
      sources.add(_normalize(source, node));
    }
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitRethrowExpression(RethrowExpression node) {
    const source = ThrowSource(
      kind: ThrowSourceKind.rethrowExpression,
      confidence: ThrowConfidence.definiteThrow,
      displayName: 'rethrow',
    );
    if (!_isProtected(node, source)) {
      sources.add(_normalize(source, node));
    }
  }

  @override
  void visitThrowExpression(ThrowExpression node) {
    final thrownType = node.expression.staticType;
    final exceptionTypes = _exceptionTypeNames(thrownType);
    final source = ThrowSource(
      kind: ThrowSourceKind.explicitThrow,
      confidence: ThrowConfidence.definiteThrow,
      displayName: 'throw ${node.expression.toSource()}',
      exceptionTypes: exceptionTypes,
    );
    if (!_isProtected(node, source)) {
      sources.add(_normalize(source, node));
    }
    super.visitThrowExpression(node);
  }

  List<String> _exceptionTypeNames(DartType? type) {
    if (type is! InterfaceType) {
      return [if (type != null) type.getDisplayString()];
    }
    return {
      type.element.name,
      for (final supertype in type.allSupertypes) supertype.element.name,
    }.whereType<String>().toList();
  }

  void _recordCall(AstNode node) {
    final summary = analyzer.inferCallFromBody(
      node,
      currentExecutable: executable,
      resolvedElement: _elementForNode(node),
      depth: depth,
      activeKeys: activeKeys,
      isAsyncObserved: _isAsyncObserved(node),
    );
    if (summary.sources.isEmpty) {
      return;
    }

    sources.addAll(
      summary.sources
          // Unknown boundaries remain unknown to callers even when the
          // implementation happens to catch the dynamic failure locally.
          .where(
            (source) =>
                source.confidence == ThrowConfidence.unknown ||
                !_isProtected(node, source),
          )
          .map((source) => _normalize(source, node)),
    );
    dependencies.addAll(summary.dependencyElementKeys);
    complete = complete && summary.complete;
    truncationReason ??= summary.truncationReason;
  }

  Element? _elementForNode(AstNode node) {
    return switch (node) {
      MethodInvocation(:final methodName) => methodName.element,
      FunctionExpressionInvocation() => node.element,
      InstanceCreationExpression(:final constructorName) =>
        constructorName.element,
      PropertyAccess(:final propertyName) => propertyName.element,
      PrefixedIdentifier(:final identifier) => identifier.element,
      BinaryExpression() => node.element,
      IndexExpression() => node.element,
      _ => null,
    };
  }

  bool _isProtected(AstNode node, ThrowSource source) {
    if (hasExceptionBoundaryAnnotation(executable) ||
        isInsideExceptionBoundary(node)) {
      return true;
    }
    return isProtectedByCatch(
      node,
      requireAsyncProtection: source.isAsync,
      exceptionTypes: source.exceptionTypes,
    );
  }

  ThrowSource _normalize(ThrowSource source, [AstNode? node]) {
    final contextualConfidence = !_isAsyncContext || source.isAsync
        ? source.confidence
        : switch (source.confidence) {
            ThrowConfidence.definiteThrow ||
            ThrowConfidence.possibleThrow => ThrowConfidence.asyncError,
            _ => source.confidence,
          };
    final confidence =
        _conditionalDepth > 0 &&
            contextualConfidence == ThrowConfidence.definiteThrow
        ? ThrowConfidence.possibleThrow
        : contextualConfidence;
    return ThrowSource(
      kind: source.kind,
      confidence: confidence,
      displayName: source.displayName,
      intent: source.intent,
      isAsync: confidence == ThrowConfidence.asyncError,
      timing:
          source.timing ??
          (executable.firstFragment.isGenerator && !_isAsyncContext
              ? ThrowTiming.deferred
              : null),
      exceptionTypes: source.exceptionTypes,
      origin:
          source.origin ??
          (node == null
              ? null
              : ThrowOrigin(
                  displayName: source.displayName,
                  filePath: executable.library.firstFragment.source.fullName,
                  offset: node.offset,
                  length: node.length,
                )),
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

  bool? _constantBoolean(Expression expression) {
    if (expression is BooleanLiteral) return expression.value;
    if (expression case ParenthesizedExpression(:final expression)) {
      return _constantBoolean(expression);
    }
    if (expression case PrefixExpression(
      :final operator,
      :final operand,
    ) when operator.lexeme == '!') {
      final value = _constantBoolean(operand);
      return value == null ? null : !value;
    }
    if (expression case BinaryExpression(
      :final leftOperand,
      :final operator,
      :final rightOperand,
    ) when operator.lexeme == '&&' || operator.lexeme == '||') {
      return _constantLogicalBoolean(
        leftOperand,
        operator.lexeme,
        rightOperand,
      );
    }
    return null;
  }

  bool? _constantLogicalBoolean(
    Expression left,
    String operator,
    Expression right,
  ) {
    final leftValue = _constantBoolean(left);
    final rightValue = _constantBoolean(right);
    if (leftValue == null || rightValue == null) return null;
    return operator == '&&' ? leftValue && rightValue : leftValue || rightValue;
  }

  bool _alwaysTerminates(Statement statement) {
    return switch (statement) {
      ReturnStatement() || BreakStatement() || ContinueStatement() => true,
      ExpressionStatement(:final expression) =>
        expression is ThrowExpression || expression is RethrowExpression,
      _ => false,
    };
  }
}

/// Minimal fallback for immediately-invoked closures, whose closure elements
/// are intentionally absent from analyzer resolution. Nested closures are not
/// executed by the outer closure and are therefore not traversed.
final class _InlineThrowSourceVisitor extends RecursiveAstVisitor<void> {
  _InlineThrowSourceVisitor();
  final List<ThrowSource> sources = [];

  @override
  void visitFunctionExpression(FunctionExpression node) {
    if (node.parent case FunctionExpressionInvocation(
      :final function,
    ) when identical(function, node)) {
      super.visitFunctionExpression(node);
    }
  }

  @override
  void visitThrowExpression(ThrowExpression node) {
    sources.add(
      ThrowSource(
        kind: ThrowSourceKind.explicitThrow,
        confidence: ThrowConfidence.definiteThrow,
        displayName: 'inline throw',
      ),
    );
  }

  @override
  void visitRethrowExpression(RethrowExpression node) {
    sources.add(
      const ThrowSource(
        kind: ThrowSourceKind.rethrowExpression,
        confidence: ThrowConfidence.definiteThrow,
        displayName: 'inline rethrow',
      ),
    );
  }

  @override
  void visitPostfixExpression(PostfixExpression node) {
    if (node.operator.lexeme == '!') {
      sources.add(
        const ThrowSource(
          kind: ThrowSourceKind.nullAssertion,
          confidence: ThrowConfidence.possibleThrow,
          displayName: 'inline null assertion',
        ),
      );
    }
    super.visitPostfixExpression(node);
  }
}
