// ignore_for_file: implementation_imports

import 'dart:io';
import 'dart:typed_data';

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
import '../engine/invocation_targets.dart';
import '../engine/list_literals.dart';
import '../engine/runtime_checks.dart';
import '../engine/numeric_checks.dart';
import '../engine/exception_effect.dart';
import '../engine/effect_containment.dart';
import '../engine/statement_completion.dart';
import '../engine/syntax_coverage.dart';
import '../engine/callback_models.dart';
import '../engine/callback_values.dart';
import '../engine/strongly_connected_components.dart';
import '../engine/future_forwarding.dart';

final class InferredCallAnalysis {
  const InferredCallAnalysis({
    required this.displayName,
    required this.confidence,
    required this.isAsync,
    this.isDeferred = false,
    this.exceptionTypes = const [],
    this.resolvedExceptionTypes = const [],
    this.exceptionSupertypes = const {},
    this.origin,
    this.unknownReason,
    this.channel,
    this.sources = const [],
  });

  final String displayName;
  final ThrowConfidence confidence;
  final bool isAsync;
  final bool isDeferred;
  final List<String> exceptionTypes;
  final List<DartType> resolvedExceptionTypes;
  final Map<String, List<String>> exceptionSupertypes;
  final ThrowOrigin? origin;
  final String? unknownReason;
  final ExceptionChannel? channel;
  final List<ThrowSource> sources;

  bool isProtectedAt(AstNode node, {bool requireAsyncProtection = false}) {
    if (sources.isEmpty) {
      return isProtectedByCatch(
        node,
        requireAsyncProtection: requireAsyncProtection,
        channel: channel,
        exceptionTypes: exceptionTypes,
        resolvedExceptionTypes: resolvedExceptionTypes,
        exceptionSupertypes: exceptionSupertypes,
      );
    }
    return residualEffects(node, sources).isEmpty;
  }
}

enum CodeOrigin { internal, thirdParty }

final class InferredThrowAnalyzer {
  InferredThrowAnalyzer({
    required this.manifest,
    required this.options,
    required FeatureSet featureSet,
    required this.packageRootPath,
    Map<String, CompilationUnit> knownUnits = const {},
    this.resolveDependency,
    this.resolutionIsCurrent,
  }) : _featureSet = featureSet,
       _featureSetKey = featureSet.toString(),
       _resolvedPaths = knownUnits.keys.toSet(),
       _parsedUnits = Map<String, CompilationUnit>.from(knownUnits),
       _dispatchIndex = _collectKnownExecutables(knownUnits.values),
       _callbackBindings = const {},
       _callbackContexts = _CallbackContexts(),
       _rootDepth = 0;

  InferredThrowAnalyzer._withCallbacks(
    InferredThrowAnalyzer parent,
    this._callbackBindings,
    this._rootDepth,
  ) : manifest = parent.manifest,
      options = parent.options,
      packageRootPath = parent.packageRootPath,
      resolveDependency = parent.resolveDependency,
      resolutionIsCurrent = parent.resolutionIsCurrent,
      _featureSet = parent._featureSet,
      _featureSetKey = parent._featureSetKey,
      _resolvedPaths = {...parent._resolvedPaths},
      _parsedUnits = {...parent._parsedUnits},
      _dispatchIndex = parent._dispatchIndex,
      _callbackContexts = parent._callbackContexts;

  final ThrowingApiManifest manifest;
  final ExceptionAnalysisOptions options;
  final String? packageRootPath;
  final Map<String, CompilationUnit>? Function(LibraryElement)?
  resolveDependency;
  final bool Function()? resolutionIsCurrent;
  final FeatureSet _featureSet;
  final String _featureSetKey;
  final Map<String, ThrowSummary> _summaryCache = {};
  final Map<String, ExecutableElement> _summaryElements = {};
  final Set<String> _recursiveKeys = {};
  final Map<String, Set<String>> _directDependencies = {};
  bool _solvingRecursiveComponent = false;
  final Map<String, CompilationUnit> _parsedUnits;
  final Set<String> _resolvedPaths;
  final Map<String, int?> _dependencyFingerprints = {};
  final _DispatchIndex _dispatchIndex;
  final Map<FormalParameterElement, CallbackValue> _callbackBindings;
  CallbackValueResolver? _callbackValueResolver;
  final _CallbackContexts _callbackContexts;
  final int _rootDepth;

  /// A bounded supporting dependency path for an already inferred source.
  /// This is an explanation of cached inference, not a runtime stack or an
  /// exhaustive enumeration of paths. Context-specialized summaries may not
  /// have a corresponding context-independent cache entry.
  List<ThrowOrigin> explainSource(String elementKey, ThrowSource source) {
    final origin = source.origin;
    final frames = <ThrowOrigin>[];
    final visited = <String>{};
    var key = elementKey;
    while (visited.length < 64 && visited.add(key)) {
      final element = _summaryElements[key];
      if (element != null) {
        frames.add(
          ThrowOrigin(
            displayName: _displayNameForExecutable(element),
            filePath: element.firstFragment.libraryFragment.source.fullName,
            offset:
                element.firstFragment.nameOffset ??
                element.firstFragment.offset,
            length: element.firstFragment.name?.length ?? 0,
          ),
        );
      }
      if (origin == null) break;
      final candidates = (_directDependencies[key] ?? const <String>{}).toList()
        ..sort();
      String? next;
      for (final candidate in candidates) {
        if (visited.contains(candidate)) continue;
        if (_summaryCache[candidate]?.sources.any(
              (item) =>
                  item.origin?.filePath == origin.filePath &&
                  item.origin?.offset == origin.offset &&
                  item.origin?.displayName == origin.displayName,
            ) ==
            true) {
          next = candidate;
          break;
        }
      }
      if (next == null) break;
      key = next;
    }
    if (origin != null) frames.add(origin);
    return List.unmodifiable(frames);
  }

  // Rule visitors are created per analyzed unit and per diagnostic. Keep the
  // expensive source parsing shared between those short-lived analyzers, but
  // key entries by modification time so edits are picked up immediately.
  static final Map<String, _ParsedUnitCacheEntry> _sharedParsedUnits = {};
  static const _maxSharedParsedUnits = 512;

  /// Disk dependencies may change while the importing resolved AST survives.
  /// Never reuse a proof made against old dependency contents.
  bool get dependenciesAreCurrent {
    if (resolutionIsCurrent?.call() == false) return false;
    for (final entry in _dependencyFingerprints.entries) {
      if (_sourceFingerprint(entry.key) != entry.value) return false;
    }
    return true;
  }

  static int? _sourceFingerprint(String path) {
    try {
      return _bytesFingerprint(File(path).readAsBytesSync());
    } on FileSystemException {
      return null;
    }
  }

  static int _bytesFingerprint(Uint8List bytes) {
    final alignedLength =
        bytes.length - bytes.length % Uint32List.bytesPerElement;
    return Object.hash(
      bytes.length,
      Object.hashAll(Uint32List.sublistView(bytes, 0, alignedLength)),
      Object.hashAll(Uint8List.sublistView(bytes, alignedLength)),
    );
  }

  InferredCallAnalysis? analyzeResolvedCall(
    AstNode node, {
    required Element? element,
    required bool treatUnknownAsReportable,
    required bool requireObservedAsyncError,
    bool includeManifestOverrides = true,
    bool includeDirectSource = true,
  }) {
    if (node is BinaryExpression && isNullComparison(node)) return null;
    if ((node is PropertyAccess || node is PrefixedIdentifier) &&
        element is ExecutableElement &&
        element is! PropertyAccessorElement) {
      return null;
    }
    if (node is FunctionExpressionInvocation &&
        ThrowSourceCatalog.jsonDecodingInvocation(node, element) == null) {
      // Resolve the value actually invoked, rather than a visitor's stale
      // initializer alias. Getter-returned and mutated values remain unknown.
      final value = _callbackValues.resolve(node.function);
      if (isInsideExceptionBoundary(node)) return null;
      final summary = _callbackValueInvocationSummary(value, node);
      if (value.targets.isNotEmpty) {
        return _projectSummaryForCall(
          value.targets.first,
          summary,
          treatUnknownAsReportable: treatUnknownAsReportable,
          requireObservedAsyncError: requireObservedAsyncError,
        );
      }
      if (treatUnknownAsReportable &&
          options.treatDynamicInvocationAsThrowing) {
        return InferredCallAnalysis(
          displayName: 'unverified callback invocation',
          confidence: ThrowConfidence.unknown,
          isAsync: false,
          unknownReason: 'unverified_callback_value',
          sources: summary.sources,
        );
      }
      return null;
    }
    final executable =
        _toExecutableElement(element) ??
        (node is FunctionExpressionInvocation
            ? _inlineFunction(node.function)?.declaredFragment?.element
            : null);
    if (executable == null) {
      if (treatUnknownAsReportable &&
          options.treatDynamicInvocationAsThrowing &&
          _looksLikeUnknownTarget(node, element)) {
        return InferredCallAnalysis(
          displayName: 'dynamic invocation',
          confidence: ThrowConfidence.unknown,
          isAsync: false,
          unknownReason: 'dynamic_or_unresolved_call',
          sources: _unknownInvocationSources(node),
        );
      }
      return null;
    }

    if (isInsideExceptionBoundary(node)) {
      return null;
    }

    // Direct manifest policy diagnostics belong to the manifest adapter.
    // Async observers still need its effects to follow returned obligations;
    // callers of a wrapper continue to inherit the manifest-backed summary.
    if (!includeManifestOverrides &&
        !requireObservedAsyncError &&
        _matchingManifestSpec(executable) != null) {
      return null;
    }

    final directSource = switch (node) {
      IndexExpression() => ThrowSourceCatalog.matchIndexAccess(node, options),
      BinaryExpression() => ThrowSourceCatalog.matchBinaryExpression(
        node,
        options,
      ),
      AssignmentExpression()
          when element?.baseElement == node.element?.baseElement =>
        ThrowSourceCatalog.matchAssignmentExpression(node, options),
      _ => ThrowSourceCatalog.matchResolvedInvocation(node, element, options),
    };
    if (node is IndexExpression &&
        directSource?.confidence == ThrowConfidence.noObviousThrow) {
      return null;
    }
    // The native proof covers the actual operator or SDK method at
    // this call site, including implicit arguments to increment and decrement.
    // Its internal SDK implementations cannot add an unrelated source effect.
    if (directSource == null && _isProvenSafeNativeOperation(node, element)) {
      return null;
    }
    final baseSummary = _summaryForDispatch(
      executable,
      directSource == null
          ? (_specializedSummary(executable, node, depth: 0) ??
                summarizeExecutable(executable))
          : ThrowSummary.merge(
              _displayNameForExecutable(executable),
              [if (includeDirectSource) directSource],
              dependencyElementKeys: const [],
              complete: true,
            ),
      node,
    );
    final summary = ThrowSummary.merge(
      baseSummary.elementKey,
      [
        ...baseSummary.sources,
        if (node is InstanceCreationExpression)
          ?ThrowSourceCatalog.matchFutureFactoryNullCheck(node),
        ..._callbackSources(node, element, 0, {}),
      ],
      dependencyElementKeys: baseSummary.dependencyElementKeys,
      complete: baseSummary.complete,
      truncationReason: baseSummary.truncationReason,
      maxSources: options.maxSourcesPerSummary,
    );
    return _projectSummaryForCall(
      executable,
      summary,
      treatUnknownAsReportable: treatUnknownAsReportable,
      requireObservedAsyncError: requireObservedAsyncError,
    );
  }

  InferredCallAnalysis? _projectSummaryForCall(
    ExecutableElement executable,
    ThrowSummary summary, {
    required bool treatUnknownAsReportable,
    required bool requireObservedAsyncError,
  }) {
    final filteredSummary = _filterSummaryForOrigin(
      summary,
      _originForExecutable(executable),
    );
    if (!filteredSummary.hasAnyThrowSource) {
      return null;
    }

    final effects = filteredSummary.effects.toList();
    if (treatUnknownAsReportable && filteredSummary.hasUnknownEffects) {
      return _projectCall(
        executable,
        filteredSummary,
        effects.map((effect) => effect.source),
        confidence: ThrowConfidence.unknown,
        unknownReason: filteredSummary.truncationReason ?? 'incomplete_effects',
      );
    }
    final asynchronous = effects
        .where(
          (effect) =>
              effect.channel == ExceptionChannel.future ||
              effect.channel == ExceptionChannel.stream ||
              effect.channel == ExceptionChannel.scheduled,
        )
        .map((effect) => effect.source)
        .toList();
    if (requireObservedAsyncError && asynchronous.isNotEmpty) {
      return _projectCall(
        executable,
        filteredSummary,
        asynchronous,
        confidence: ThrowConfidence.asyncError,
        isAsync: true,
      );
    }
    final synchronous = effects
        .where(
          (effect) =>
              effect.channel == ExceptionChannel.synchronous &&
              effect.source.confidence.isThrowing,
        )
        .map((effect) => effect.source)
        .toList();
    if (synchronous.isNotEmpty) {
      return _projectCall(executable, filteredSummary, synchronous);
    }
    final deferred = effects
        .where(
          (effect) =>
              effect.channel == ExceptionChannel.deferred &&
              effect.source.confidence.isThrowing,
        )
        .map((effect) => effect.source)
        .toList();
    if (deferred.isNotEmpty) {
      return _projectCall(
        executable,
        filteredSummary,
        deferred,
        isDeferred: true,
      );
    }
    final knownAsync = asynchronous
        .where((source) => source.confidence.isThrowing)
        .toList();
    if (knownAsync.isNotEmpty) {
      return _projectCall(
        executable,
        filteredSummary,
        knownAsync,
        confidence: ThrowConfidence.asyncError,
        isAsync: true,
      );
    }
    return null;
  }

  InferredCallAnalysis _projectCall(
    ExecutableElement executable,
    ThrowSummary original,
    Iterable<ThrowSource> sources, {
    ThrowConfidence? confidence,
    bool isAsync = false,
    bool isDeferred = false,
    String? unknownReason,
  }) {
    final selected = ThrowSummary.merge(
      original.elementKey,
      sources,
      dependencyElementKeys: original.dependencyElementKeys,
      complete: true,
    );
    final channels = selected.effects.map((effect) => effect.channel).toSet();
    return InferredCallAnalysis(
      displayName: _displayNameForExecutable(executable),
      confidence: confidence ?? selected.confidence,
      isAsync: isAsync,
      isDeferred: isDeferred,
      sources: selected.sources,
      channel: channels.contains(ExceptionChannel.scheduled)
          ? ExceptionChannel.scheduled
          : channels.length == 1
          ? channels.single
          : null,
      exceptionTypes: _exceptionTypesFrom(selected),
      resolvedExceptionTypes: _resolvedExceptionTypesFrom(selected),
      exceptionSupertypes: _exceptionSupertypesFrom(selected),
      origin: _firstOrigin(selected),
      unknownReason: unknownReason,
    );
  }

  static FunctionExpression? _inlineFunction(Expression expression) =>
      switch (expression) {
        FunctionExpression() => expression,
        ParenthesizedExpression(:final expression) => _inlineFunction(
          expression,
        ),
        _ => null,
      };

  CallbackValueResolver get _callbackValues =>
      _callbackValueResolver ??= CallbackValueResolver(
        resolvedUnits: _parsedUnits,
        parameterBindings: _callbackBindings,
        returnedExpressions: _returnedCallbackExpressions,
      );

  /// Native possible callback targets, shared by effect and producer adapters.
  /// An outdated dependency/session proof cannot establish a callable value.
  CallbackValue resolveCallbackValue(Expression expression) {
    if (!dependenciesAreCurrent) return CallbackValue.unknown();
    final value = _callbackValues.resolve(expression);
    return dependenciesAreCurrent ? value : CallbackValue.unknown();
  }

  CallbackValue callbackValueForElement(Element? element) {
    if (!dependenciesAreCurrent) return CallbackValue.unknown();
    final value = _callbackValues.forElement(element);
    return dependenciesAreCurrent ? value : CallbackValue.unknown();
  }

  CallbackValue resolveInvokedCallback(AstNode invocation) {
    if (!dependenciesAreCurrent) return CallbackValue.unknown();
    final value = _callbackValues.resolveInvocation(invocation);
    return dependenciesAreCurrent ? value : CallbackValue.unknown();
  }

  Iterable<Expression>? _returnedCallbackExpressions(
    ExecutableElement executable,
  ) {
    if (executable.library.uri.scheme == 'dart' ||
        executable.firstFragment.isAsynchronous ||
        executable.firstFragment.isGenerator) {
      return null;
    }
    final declaration = _findDeclaration(executable);
    final body = switch (declaration) {
      FunctionDeclaration() => declaration.functionExpression.body,
      MethodDeclaration() => declaration.body,
      _ => null,
    };
    if (body is ExpressionFunctionBody) return [body.expression];
    if (body is! BlockFunctionBody ||
        statementCompletion(body.block).canCompleteNormally) {
      return null;
    }
    final collector = _ReturnedCallbackCollector();
    body.block.accept(collector);
    return collector.complete ? collector.expressions : null;
  }

  ExecutableElement? _boundExecutable(Element? element) {
    if (element is FormalParameterElement || element is LocalVariableElement) {
      final value = _callbackValues.forElement(element);
      return !value.hasUnknown && value.targets.length == 1
          ? value.targets.single
          : null;
    }
    return _toExecutableElement(element);
  }

  ThrowSummary? _specializedSummary(
    ExecutableElement executable,
    AstNode call, {
    required int depth,
    Set<String> activeKeys = const {},
  }) {
    if (executable.library.isInSdk || depth > options.maxCallDepth) return null;
    final forwarded = forwardedFutureArgument(
      call,
      maxDepth: options.maxCallDepth - depth + 1,
    );
    if (forwarded != null) {
      final target = switch (forwarded) {
        MethodInvocation(:final methodName) => methodName.element,
        InstanceCreationExpression(:final constructorName) =>
          constructorName.element,
        _ => null,
      };
      if (target is ExecutableElement) {
        final targetDepth = depth + 1;
        final direct = ThrowSourceCatalog.matchResolvedInvocation(
          forwarded,
          target,
          options,
        );
        final input = direct == null
            ? (_specializedSummary(
                    target,
                    forwarded,
                    depth: targetDepth,
                    activeKeys: activeKeys,
                  ) ??
                  _summarizeDependency(
                    target,
                    _executableKey(target),
                    targetDepth,
                    activeKeys,
                  ))
            : ThrowSummary.merge(
                'forwarded Future',
                [direct],
                dependencyElementKeys: const [],
                complete: true,
              );
        return _summaryForDispatch(
          target,
          input,
          forwarded,
          depth: targetDepth,
          activeKeys: activeKeys,
        );
      }
    }
    final parameters = executable.baseElement.formalParameters;
    if (!parameters.any((parameter) => parameter.type is FunctionType)) {
      return null;
    }
    final arguments = switch (call) {
      MethodInvocation() => call.argumentList.arguments,
      FunctionExpressionInvocation() => call.argumentList.arguments,
      InstanceCreationExpression() => call.argumentList.arguments,
      _ => null,
    };
    if (arguments == null) return null;
    final bindings = {..._callbackBindings};
    // Recursive calls can pass a different callback, or an unresolved value.
    // Never retain the previous invocation's binding for an omitted parameter.
    for (final parameter in parameters) {
      bindings.remove(parameter.baseElement);
    }
    final positional = parameters
        .where((parameter) => !parameter.isNamed)
        .toList();
    var index = 0;
    final provided = <FormalParameterElement>{};
    for (final argument in arguments) {
      final parameter = argument is NamedArgument
          ? parameters
                .where(
                  (parameter) =>
                      parameter.isNamed &&
                      parameter.name == argument.name.lexeme,
                )
                .firstOrNull
          : index < positional.length
          ? positional[index++]
          : null;
      if (parameter == null || parameter.type is! FunctionType) continue;
      provided.add(parameter.baseElement);
      final value = _callbackValues.resolve(argument.argumentExpression);
      if (value.targets.isNotEmpty) bindings[parameter.baseElement] = value;
    }
    for (final parameter in parameters) {
      if (parameter.type is FunctionType &&
          parameter.hasDefaultValue &&
          !provided.contains(parameter.baseElement)) {
        final target = parameter.computeConstantValue()?.toFunctionValue();
        if (target != null) {
          bindings[parameter.baseElement] = CallbackValue(targets: [target]);
        }
      }
    }
    // Parameter writes, including writes in captured closures, invalidate a
    // binding. A later value-flow pass may prove individual writes unreachable.
    final mutation = _CallbackMutationVisitor();
    _findDeclaration(executable)?.accept(mutation);
    for (final parameter in mutation.written) {
      bindings.remove(parameter);
    }
    if (bindings.length == _callbackBindings.length &&
        bindings.entries.every(
          (entry) => _callbackBindings[entry.key] == entry.value,
        )) {
      return null;
    }
    final callableKey =
        ResolvedCallable.tryCreate(executable)?.elementKey ??
        '${executable.library.uri}:${executable.firstFragment.offset}';
    // Reusing existing contexts remains possible at the limit, but fresh
    // callback identities must not grow the index after the budget is full.
    if (_callbackContexts.analyzers.length >= _CallbackContexts.maxContexts &&
        (!_callbackContexts.contains(executable.baseElement) ||
            bindings.entries.any(
              (entry) =>
                  !_callbackContexts.contains(entry.key) ||
                  entry.value.targets.any(
                    (target) => !_callbackContexts.contains(target),
                  ),
            ))) {
      return _unknownCallbackContext(
        executable,
        callableKey,
        'max_callback_contexts',
      );
    }
    final entries =
        bindings.entries
            .map(
              (entry) =>
                  '${_callbackContexts.id(entry.key)}:${entry.value.hasUnknown}:${(entry.value.targets.map(_callbackContexts.id).toList()..sort()).join(",")}',
            )
            .toList()
          ..sort();
    final key =
        '$depth:${_callbackContexts.id(executable.baseElement)}:${entries.join("|")}';
    var specialized = _callbackContexts.analyzers[key];
    if (specialized == null) {
      if (_callbackContexts.analyzers.length >= _CallbackContexts.maxContexts) {
        return _unknownCallbackContext(
          executable,
          callableKey,
          'max_callback_contexts',
        );
      }
      specialized = InferredThrowAnalyzer._withCallbacks(this, bindings, depth);
      _callbackContexts.analyzers[key] = specialized;
    }
    final summary = specialized.summarizeExecutable(executable);
    _dependencyFingerprints.addAll(specialized._dependencyFingerprints);
    return summary;
  }

  ThrowSummary _unknownCallbackContext(
    ExecutableElement executable,
    String key,
    String reason,
  ) => ThrowSummary.unknown(
    key,
    reason: reason,
    sources: [
      ..._unknownSourcesForType(
        executable.returnType,
        kind: ThrowSourceKind.truncation,
        displayName: _displayNameForExecutable(executable),
      ),
      const ThrowSource(
        kind: ThrowSourceKind.truncation,
        confidence: ThrowConfidence.unknown,
        displayName: 'unverified callback scheduling',
        isAsync: true,
        channel: ExceptionChannel.scheduled,
      ),
    ],
  );

  List<ThrowSource> _unknownCallbackValueSources(AstNode node) => [
    ..._unknownInvocationSources(node),
    const ThrowSource(
      kind: ThrowSourceKind.unresolvedCall,
      confidence: ThrowConfidence.unknown,
      displayName: 'unverified callback scheduling',
      isAsync: true,
      channel: ExceptionChannel.scheduled,
    ),
  ];

  static const _unverifiedCallbackScheduling = ThrowSource(
    kind: ThrowSourceKind.unresolvedCall,
    confidence: ThrowConfidence.unknown,
    displayName: 'unverified callback scheduling',
    isAsync: true,
    channel: ExceptionChannel.scheduled,
  );

  static bool _isProvenSafeNativeOperation(AstNode node, Element? element) =>
      switch (node) {
        BinaryExpression()
            when element?.baseElement == node.element?.baseElement =>
          isNullComparison(node) ||
              ThrowSourceCatalog.isNativeStringEquality(node) ||
              NumericChecks.modelsBinary(node) &&
                  NumericChecks.binary(node) == null,
        AssignmentExpression()
            when element?.baseElement == node.element?.baseElement =>
          NumericChecks.modelsAssignment(node) &&
              NumericChecks.assignment(node) == null,
        PrefixExpression()
            when element?.baseElement == node.element?.baseElement =>
          NumericChecks.isSafePrefix(node) ||
              NumericChecks.isSafeIncrement(node.operator.lexeme, element),
        PostfixExpression()
            when element?.baseElement == node.element?.baseElement =>
          NumericChecks.isSafeIncrement(node.operator.lexeme, element),
        InterpolationExpression() => NumericChecks.isNativeToString(element),
        _ =>
          NumericChecks.modelsInvocation(node, element) &&
              NumericChecks.invocation(node, element) == null,
      };

  ThrowSummary _callbackValueInvocationSummary(
    CallbackValue value,
    FunctionExpressionInvocation node,
  ) {
    final sources = <ThrowSource>[];
    final dependencies = <String>{};
    var complete = !value.hasUnknown;
    for (final target in value.targets) {
      final numericSource = options.treatArithmeticAsThrowing
          ? NumericChecks.invocation(node, target)
          : null;
      final summary = _summaryForDispatch(
        target,
        numericSource != null
            ? ThrowSummary.merge(
                node.toSource(),
                [numericSource],
                dependencyElementKeys: const [],
                complete: true,
              )
            : _isProvenSafeNativeOperation(node, target)
            ? ThrowSummary.noObviousThrow(node.toSource())
            : (_specializedSummary(target, node, depth: 0) ??
                  summarizeExecutable(target)),
        node.function,
      );
      complete &= summary.complete;
      if (!summary.complete) sources.add(_unverifiedCallbackScheduling);
      dependencies.addAll(summary.dependencyElementKeys);
      sources.addAll(RuntimeChecks.boundCallbackChecks(node, target));
      sources.addAll(_callbackSources(node, target, 0, {}));
      for (final source in summary.sources) {
        sources.add(
          node.staticType is VoidType &&
                  source.channel == ExceptionChannel.future
              ? _sourceWithChannel(source, ExceptionChannel.scheduled)
              : source,
        );
      }
    }
    if (value.hasUnknown) sources.addAll(_unknownCallbackValueSources(node));
    return ThrowSummary.merge(
      node.toSource(),
      sources,
      dependencyElementKeys: dependencies,
      complete: complete,
      truncationReason: value.hasUnknown ? 'unverified_callback_value' : null,
      maxSources: options.maxSourcesPerSummary,
    );
  }

  static ThrowSource _sourceWithChannel(
    ThrowSource source,
    ExceptionChannel channel,
  ) => ThrowSource(
    kind: source.kind,
    evidence: source.evidenceKinds,
    confidence: source.confidence,
    displayName: source.displayName,
    intent: source.effectiveIntent,
    isAsync: channel != ExceptionChannel.synchronous,
    timing: channel == ExceptionChannel.deferred
        ? ThrowTiming.deferred
        : channel == ExceptionChannel.synchronous
        ? ThrowTiming.synchronous
        : ThrowTiming.asynchronous,
    channel: channel,
    certainty: source.certainty,
    exceptionTypes: source.exceptionTypes,
    resolvedExceptionTypes: source.resolvedExceptionTypes,
    exceptionSupertypes: source.exceptionSupertypes,
    origin: source.origin,
  );

  static List<ThrowSource> _unknownInvocationSources(AstNode node) => [
    ..._unknownSourcesForType(
      node is Expression ? node.staticType : null,
      kind: ThrowSourceKind.dynamicInvocation,
      displayName: 'unverified invocation',
    ),
    // A void callback may be async-void or discard a Future. Its signature
    // does not promise that failures happen before the invocation returns.
    if (node is Expression && node.staticType is VoidType)
      const ThrowSource(
        kind: ThrowSourceKind.dynamicInvocation,
        confidence: ThrowConfidence.unknown,
        displayName: 'unverified void callback execution',
        isAsync: true,
        channel: ExceptionChannel.scheduled,
      ),
  ];

  static List<ThrowSource> _unknownSourcesForType(
    DartType? type, {
    required ThrowSourceKind kind,
    required String displayName,
  }) {
    final mayReturnFuture =
        type is DynamicType ||
        (type is InterfaceType &&
            (type.isDartAsyncFuture || type.isDartAsyncFutureOr));
    return [
      ThrowSource(
        kind: kind,
        confidence: ThrowConfidence.unknown,
        displayName: displayName,
      ),
      if (mayReturnFuture)
        ThrowSource(
          kind: kind,
          confidence: ThrowConfidence.unknown,
          displayName: '$displayName returned Future',
          isAsync: true,
          channel: ExceptionChannel.future,
        ),
    ];
  }

  ThrowSummary _unknownExecutableSummary(
    ExecutableElement executable,
    String elementKey,
    String reason, {
    ThrowSourceKind kind = ThrowSourceKind.unresolvedCall,
  }) => ThrowSummary.unknown(
    elementKey,
    reason: reason,
    sources: [
      ..._unknownSourcesForType(
        executable.returnType,
        kind: kind,
        displayName: _displayNameForExecutable(executable),
      ),
      if (reason == 'max_call_depth' &&
          executable.formalParameters.any(
            (parameter) => parameter.type is FunctionType,
          ))
        _unverifiedCallbackScheduling,
    ],
  );

  ThrowSummary summarizeExecutable(ExecutableElement executable) {
    executable = executable.baseElement;
    final callable = ResolvedCallable.tryCreate(executable);
    final elementKey =
        callable?.elementKey ??
        '${executable.library.uri}::${executable.runtimeType}:${executable.firstFragment.offset}:${executable.displayName}';

    _summaryElements[elementKey] = executable;
    _directDependencies.putIfAbsent(elementKey, () => {});
    if (_summaryCache[elementKey] case final cached?) {
      return cached;
    }

    _summaryCache[elementKey] = _summarizeWithContracts(
      executable,
      elementKey: elementKey,
      depth: _rootDepth,
      activeKeys: {elementKey},
    );
    _solveRecursiveSummaries();
    return _summaryCache[elementKey]!;
  }

  ThrowSummary _summarizeWithContracts(
    ExecutableElement executable, {
    required String elementKey,
    required int depth,
    required Set<String> activeKeys,
  }) {
    if (executable.metadata.hasAlwaysThrows) {
      return ThrowSummary.merge(
        elementKey,
        [
          ThrowSource(
            kind: ThrowSourceKind.explicitThrow,
            evidence: const {EffectEvidence.annotationContract},
            confidence: ThrowConfidence.definiteThrow,
            displayName: _displayNameForExecutable(executable),
          ),
        ],
        dependencyElementKeys: const [],
        complete: true,
      );
    }

    final contracts = exceptionContractsFor(executable).toList();
    if (contracts.isNotEmpty) {
      final implementation = _summarizeExecutableInternal(
        executable,
        elementKey: elementKey,
        depth: depth,
        activeKeys: activeKeys,
      );
      final hasResolvedBody = _resolvedPaths.contains(
        executable.firstFragment.libraryFragment.source.fullName,
      );
      return ThrowSummary.merge(
        elementKey,
        [
          if (hasResolvedBody ||
              contracts.any(
                (contract) =>
                    contract.kind == ExceptionContractKind.doesNotThrow,
              ))
            ...implementation.sources,
          for (final contract in contracts)
            if (contract.kind != ExceptionContractKind.doesNotThrow)
              ThrowSource(
                kind: ThrowSourceKind.manifestOverride,
                evidence: const {EffectEvidence.annotationContract},
                confidence: contract.kind == ExceptionContractKind.failingFuture
                    ? ThrowConfidence.asyncError
                    : ThrowConfidence.possibleThrow,
                displayName: _displayNameForExecutable(executable),
                isAsync: contract.kind == ExceptionContractKind.failingFuture,
                channel:
                    contract.kind == ExceptionContractKind.failingFuture &&
                        executable.returnType is InterfaceType &&
                        (executable.returnType as InterfaceType).element.name ==
                            'Stream' &&
                        (executable.returnType as InterfaceType)
                                .element
                                .library
                                .uri
                                .toString() ==
                            'dart:async'
                    ? ExceptionChannel.stream
                    : null,
                exceptionTypes: contract.exceptionTypes,
                resolvedExceptionTypes: contract.resolvedExceptionTypes,
                exceptionSupertypes: contract.exceptionSupertypes,
              ),
        ],
        dependencyElementKeys: implementation.dependencyElementKeys,
        complete: hasResolvedBody
            ? implementation.complete
            : !contracts.any(
                (contract) =>
                    contract.kind == ExceptionContractKind.doesNotThrow,
              ),
      );
    }

    final manifestOverride = _manifestSummaryForElement(executable, elementKey);
    if (manifestOverride != null) {
      return manifestOverride;
    }

    // Reading a constant does not execute its initializer at runtime, even
    // when the resolved declaration comes from an unavailable dependency.
    if (executable is GetterElement &&
        ((executable.isOriginVariable && executable.variable.isConst) ||
            NumericChecks.isKnownBigIntValueGetter(executable))) {
      return ThrowSummary.noObviousThrow(elementKey);
    }

    if (executable.isExternal || executable.isAbstract) {
      final sources = _unknownSourcesForType(
        executable.returnType,
        kind: ThrowSourceKind.externalCall,
        displayName: _displayNameForExecutable(executable),
      );
      return ThrowSummary.unknown(
        elementKey,
        reason: 'external_or_abstract',
        sources: options.treatExternalCallsAsThrowing ? sources : const [],
      );
    }

    final uri = executable.library.uri;
    if (uri.scheme == 'dart' && !options.analyzeSdkSource) {
      return _unknownExecutableSummary(
        executable,
        elementKey,
        'sdk_analysis_disabled',
      );
    }

    if (!options.analyzeThirdPartySource &&
        !_isWithinCurrentPackage(
          executable.firstFragment.libraryFragment.source.fullName,
        )) {
      return _unknownExecutableSummary(
        executable,
        elementKey,
        'third_party_analysis_disabled',
      );
    }

    return _summarizeExecutableInternal(
      executable,
      elementKey: elementKey,
      depth: depth,
      activeKeys: activeKeys,
    );
  }

  void _solveRecursiveSummaries() {
    if (_solvingRecursiveComponent || _recursiveKeys.isEmpty) return;
    _solvingRecursiveComponent = true;
    try {
      final components = stronglyConnectedComponents(_directDependencies);
      for (final component in components) {
        if (!component.any(_recursiveKeys.contains)) continue;
        final cyclic =
            component.length > 1 ||
            _directDependencies[component.single]!.contains(component.single);
        var converged = !cyclic;
        for (var iteration = 0; iteration < (cyclic ? 64 : 1); iteration++) {
          var changed = false;
          for (final key in component) {
            final element = _summaryElements[key];
            if (element == null) continue;
            final previous =
                _summaryCache[key] ?? ThrowSummary.noObviousThrow(key);
            final next = _summarizeWithContracts(
              element,
              elementKey: key,
              depth: _rootDepth,
              activeKeys: {key},
            );
            final merged = ThrowSummary.merge(
              key,
              [...previous.sources, ...next.sources],
              dependencyElementKeys: {
                ...previous.dependencyElementKeys,
                ...next.dependencyElementKeys,
              },
              complete: previous.complete && next.complete,
              truncationReason: next.truncationReason,
              maxSources: options.maxSourcesPerSummary,
            );
            changed =
                changed || !previous.hasSameEffectsAndDependencies(merged);
            _summaryCache[key] = merged;
          }
          if (!changed) {
            converged = true;
            break;
          }
        }
        if (!converged) {
          for (final key in component) {
            final previous = _summaryCache[key];
            _summaryCache[key] = ThrowSummary.merge(
              key,
              previous?.sources ?? const [],
              dependencyElementKeys:
                  previous?.dependencyElementKeys ?? const [],
              complete: false,
              truncationReason: 'recursive_fixed_point_budget',
            );
          }
        }
      }
      _recursiveKeys.clear();
    } finally {
      _solvingRecursiveComponent = false;
    }
  }

  ThrowSummary summarizeImplementation(ExecutableElement executable) {
    final key =
        ResolvedCallable.tryCreate(executable)?.elementKey ??
        '${executable.library.uri}::${executable.runtimeType}:${executable.firstFragment.offset}:${executable.displayName}';
    return _summarizeExecutableInternal(
      executable,
      elementKey: key,
      depth: 0,
      activeKeys: {key},
    );
  }

  ThrowSummary _summarizeExecutableInternal(
    ExecutableElement executable, {
    required String elementKey,
    required int depth,
    required Set<String> activeKeys,
  }) {
    if (depth > options.maxCallDepth) {
      return _unknownExecutableSummary(
        executable,
        elementKey,
        'max_call_depth',
        kind: ThrowSourceKind.truncation,
      );
    }
    if (executable is ConstructorElement &&
        executable.library.uri.toString() == 'dart:core' &&
        const {
          'Object',
          'Exception',
          'FormatException',
          'StateError',
          'UnsupportedError',
          'UnimplementedError',
        }.contains(executable.enclosingElement.name)) {
      return ThrowSummary.noObviousThrow(elementKey);
    }
    if (executable is PropertyAccessorElement && executable.isOriginVariable) {
      final variable = executable.variable;
      if (executable is SetterElement) {
        return variable.isLate && variable.isFinal
            ? ThrowSummary.merge(
                elementKey,
                [
                  ThrowSource(
                    kind: ThrowSourceKind.lateInitializationRead,
                    confidence: ThrowConfidence.possibleThrow,
                    displayName: 'late final write',
                    exceptionTypes: const ['LateInitializationError'],
                  ),
                ],
                dependencyElementKeys: const [],
                complete: true,
              )
            : ThrowSummary.noObviousThrow(elementKey);
      }
      if (!variable.hasInitializer ||
          (!variable.isLate && !variable.isStatic)) {
        return variable.isLate
            ? ThrowSummary.merge(
                elementKey,
                [
                  ThrowSource(
                    kind: ThrowSourceKind.lateInitializationRead,
                    confidence: ThrowConfidence.possibleThrow,
                    displayName: 'late read',
                    exceptionTypes: const ['LateInitializationError'],
                  ),
                ],
                dependencyElementKeys: const [],
                complete: true,
              )
            : ThrowSummary.noObviousThrow(elementKey);
      }
      final declaration = _findVariableDeclaration(variable);
      final initializer = declaration?.initializer;
      if (initializer == null) {
        return ThrowSummary.unknown(
          elementKey,
          reason: 'initializer_unavailable',
        );
      }
      final visitor = _BodySummaryVisitor(
        analyzer: this,
        executable: executable,
        depth: depth,
        activeKeys: activeKeys,
      );
      initializer.accept(visitor);
      final resolved = _resolvedPaths.contains(
        variable.firstFragment.libraryFragment.source.fullName,
      );
      return ThrowSummary.merge(
        elementKey,
        visitor.sources,
        dependencyElementKeys: visitor.dependencies,
        complete: resolved && visitor.complete,
        truncationReason: resolved
            ? visitor.truncationReason
            : 'initializer_not_resolved',
      );
    }
    final declaration = _findDeclaration(executable);
    final body = declaration == null ? null : _bodyForDeclaration(declaration);
    final constructorClass = executable is ConstructorElement
        ? _findClassDeclaration(executable.enclosingElement)
        : null;
    if (body == null && constructorClass == null) {
      return _unknownExecutableSummary(
        executable,
        elementKey,
        'source_unavailable',
      );
    }

    final visitor = _BodySummaryVisitor(
      analyzer: this,
      executable: executable,
      depth: depth,
      activeKeys: activeKeys,
    );
    if (executable is ConstructorElement && !executable.isFactory) {
      if (visitor._visitConstructorInputs(
        executable,
        declaration is ConstructorDeclaration ? declaration : null,
        constructorClass,
      )) {
        body?.accept(visitor);
      }
    } else {
      body?.accept(visitor);
      if (executable is ConstructorElement &&
          executable.redirectedConstructor != null) {
        visitor._recordCall(
          declaration ?? constructorClass!,
          element: executable.redirectedConstructor,
        );
      }
    }

    if (!_resolvedPaths.contains(
      executable.firstFragment.libraryFragment.source.fullName,
    )) {
      visitor.sources.add(
        ThrowSource(
          kind: ThrowSourceKind.unresolvedCall,
          confidence: ThrowConfidence.unknown,
          displayName: 'unresolved dependency body',
        ),
      );
      visitor.complete = false;
      visitor.truncationReason ??= 'dependency_not_resolved';
    }

    return ThrowSummary.merge(
      elementKey,
      visitor.sources,
      dependencyElementKeys: visitor.dependencies,
      complete: visitor.complete,
      truncationReason: visitor.truncationReason,
      maxSources: options.maxSourcesPerSummary,
    );
  }

  ThrowSummary inferCallFromBody(
    AstNode node, {
    required ExecutableElement currentExecutable,
    Element? resolvedElement,
    required int depth,
    required Set<String> activeKeys,
    required bool isAsyncObserved,
    bool callbackInvocation = false,
  }) {
    if (!callbackInvocation &&
        (resolvedElement is FormalParameterElement ||
            resolvedElement is LocalVariableElement ||
            node is FunctionExpressionInvocation)) {
      final value = node is FunctionExpressionInvocation
          ? _callbackValues.resolve(node.function)
          : _callbackValues.forElement(resolvedElement);
      final alternatives = [
        for (final target in value.targets)
          inferCallFromBody(
            node,
            currentExecutable: currentExecutable,
            resolvedElement: target,
            depth: depth,
            activeKeys: activeKeys,
            isAsyncObserved: isAsyncObserved,
            callbackInvocation: true,
          ),
      ];
      return ThrowSummary.merge(
        node.toSource(),
        [
          for (final summary in alternatives) ...summary.sources,
          if (value.hasUnknown) ..._unknownCallbackValueSources(node),
        ],
        dependencyElementKeys: {
          for (final summary in alternatives) ...summary.dependencyElementKeys,
        },
        complete:
            !value.hasUnknown &&
            alternatives.every((summary) => summary.complete),
        truncationReason: value.hasUnknown
            ? 'unverified_callback_value'
            : alternatives
                  .map((summary) => summary.truncationReason)
                  .whereType<String>()
                  .firstOrNull,
        maxSources: options.maxSourcesPerSummary,
      );
    }
    final callbackSources = _callbackSources(
      node,
      resolvedElement,
      depth,
      activeKeys,
    );
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
    if (inlineFunction != null && !callbackInvocation) {
      final visitor = _BodySummaryVisitor(
        analyzer: this,
        executable:
            inlineFunction.declaredFragment?.element ?? currentExecutable,
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

    if (node is IndexExpression) {
      final indexSource = ThrowSourceCatalog.matchIndexAccess(node, options);
      if (indexSource != null) {
        return ThrowSummary.merge(
          indexSource.displayName,
          [indexSource],
          dependencyElementKeys: const [],
          complete: true,
        );
      }
    }
    final directNumeric = switch (node) {
      BinaryExpression() => ThrowSourceCatalog.matchBinaryExpression(
        node,
        options,
      ),
      AssignmentExpression()
          when resolvedElement?.baseElement == node.element?.baseElement =>
        ThrowSourceCatalog.matchAssignmentExpression(node, options),
      _ => null,
    };
    if (directNumeric != null) {
      return ThrowSummary.merge(
        directNumeric.displayName,
        [directNumeric],
        dependencyElementKeys: const [],
        complete: true,
      );
    }
    final directSource = ThrowSourceCatalog.matchResolvedInvocation(
      node,
      resolvedElement,
      options,
    );
    if (directSource != null) {
      final channel = ExceptionEffect.fromSource(directSource).channel;
      final route =
          channel == ExceptionChannel.future ||
              channel == ExceptionChannel.stream
          ? asyncValueRoute(node, channel)
          : null;
      final discardedFuture =
          route != null &&
          (route.channel == ExceptionChannel.scheduled ||
              route.channel == ExceptionChannel.future &&
                  route.consumer is ExpressionStatement);
      final shouldKeep =
          !directSource.isAsync ||
          isAsyncObserved ||
          discardedFuture ||
          channel == ExceptionChannel.stream && isReturnedStreamPayload(node) ||
          directSource.channel == ExceptionChannel.scheduled;
      final nullCheck = node is InstanceCreationExpression
          ? ThrowSourceCatalog.matchFutureFactoryNullCheck(node)
          : null;
      if (shouldKeep || nullCheck != null) {
        return ThrowSummary.merge(
          directSource.displayName,
          [if (shouldKeep) directSource, ?nullCheck, ...callbackSources],
          dependencyElementKeys: const [],
          complete: true,
        );
      }
    }

    if (_isProvenSafeNativeOperation(node, resolvedElement)) {
      return ThrowSummary.merge(
        node.toSource(),
        callbackSources,
        dependencyElementKeys: const [],
        complete: true,
      );
    }

    final resolved = _boundExecutable(resolvedElement);
    if (resolved == null) {
      if (_looksLikeUnknownTarget(node, null) &&
          options.treatDynamicInvocationAsThrowing) {
        return ThrowSummary.merge(
          node.toSource(),
          _unknownInvocationSources(node),
          dependencyElementKeys: const [],
          complete: false,
          truncationReason: 'dynamic_or_unresolved_call',
        );
      }
      return ThrowSummary.noObviousThrow(node.toSource());
    }

    final dependencyKey = _executableKey(resolved);
    final currentKey = _executableKey(currentExecutable);
    _recordDependency(currentKey, dependencyKey, resolved);
    final invokedDepth = depth + 1;
    final summary =
        _specializedSummary(
          resolved,
          node,
          depth: invokedDepth,
          activeKeys: activeKeys,
        ) ??
        _summarizeDependency(resolved, dependencyKey, invokedDepth, activeKeys);
    final dispatchSummary = _summaryForDispatch(
      resolved,
      summary,
      node,
      depth: invokedDepth,
      activeKeys: activeKeys,
      callerKey: currentKey,
    );

    // Propagate each source separately. Collapsing types and channels at a
    // call site can let a catch for one effect hide another independent effect.
    final boundCallback =
        callbackInvocation ||
        (resolvedElement is FormalParameterElement &&
            _callbackBindings.containsKey(resolvedElement.baseElement));
    final propagatedSources = <ThrowSource>[
      ...callbackSources,
      if (boundCallback) ...RuntimeChecks.boundCallbackChecks(node, resolved),
      if (boundCallback && !dispatchSummary.complete)
        _unverifiedCallbackScheduling,
    ];
    for (final effect in dispatchSummary.effects) {
      final source = effect.source;
      final route =
          effect.channel == ExceptionChannel.future ||
              effect.channel == ExceptionChannel.stream
          ? asyncValueRoute(node, effect.channel)
          : null;
      final discardedCallbackFuture =
          route != null &&
          (route.channel == ExceptionChannel.scheduled ||
              route.channel == ExceptionChannel.future &&
                  ((boundCallback && !isAsyncObserved) ||
                      route.consumer is ExpressionStatement ||
                      (boundCallback &&
                          (currentExecutable.returnType is VoidType &&
                              route.consumer is! AwaitExpression))));
      if ((effect.channel == ExceptionChannel.future ||
              effect.channel == ExceptionChannel.stream) &&
          !isAsyncObserved &&
          effect.certainty != ExceptionCertainty.unknown &&
          !discardedCallbackFuture) {
        continue;
      }
      propagatedSources.add(
        ThrowSource(
          kind: effect.certainty == ExceptionCertainty.unknown
              ? ThrowSourceKind.unresolvedCall
              : effect.channel == ExceptionChannel.future ||
                    effect.channel == ExceptionChannel.stream
              ? ThrowSourceKind.awaitedAsyncDependency
              : ThrowSourceKind.inferredCall,
          confidence: source.confidence,
          evidence: source.evidenceKinds,
          displayName: _displayNameForExecutable(resolved),
          intent: source.effectiveIntent,
          isAsync: source.isAsync,
          timing: source.effectiveTiming,
          channel: discardedCallbackFuture
              ? ExceptionChannel.scheduled
              : effect.channel,
          certainty: effect.certainty,
          exceptionTypes: source.exceptionTypes,
          resolvedExceptionTypes: source.resolvedExceptionTypes,
          exceptionSupertypes: source.exceptionSupertypes,
          origin: source.origin,
        ),
      );
    }

    return ThrowSummary.merge(
      dependencyKey,
      propagatedSources,
      dependencyElementKeys: [
        dependencyKey,
        ...dispatchSummary.dependencyElementKeys,
      ],
      complete: dispatchSummary.complete,
      truncationReason: dispatchSummary.truncationReason,
    );
  }

  static DartType? _callbackReturnedPayload(DartType? type) {
    // Future adoption flattens Future layers, but does not execute a Stream
    // or Iterable carried as the successfully completed value.
    for (var depth = 0; depth < 64; depth++) {
      if (type is! InterfaceType ||
          !(type.isDartAsyncFuture || type.isDartAsyncFutureOr) ||
          type.typeArguments.isEmpty) {
        return type;
      }
      type = type.typeArguments.first;
    }
    return type;
  }

  Iterable<ThrowSource> _callbackSources(
    AstNode node,
    Element? element,
    int depth,
    Set<String> activeKeys,
  ) sync* {
    for (final callback in callbackExecutions(node, element)) {
      Expression expression = callback.expression;
      while (expression is ParenthesizedExpression) {
        expression = expression.expression;
      }
      if (expression is NullLiteral ||
          expression.staticType?.isDartCoreNull == true) {
        continue;
      }
      final value = _callbackValues.resolve(expression);
      final alternatives = <ThrowSummary>[];
      for (final target in value.targets) {
        final key =
            ResolvedCallable.tryCreate(target)?.elementKey ??
            '${target.library.uri}::${target.runtimeType}:${target.firstFragment.offset}:${target.displayName}';
        alternatives.add(
          activeKeys.contains(key)
              ? ThrowSummary.unknown(
                  key,
                  reason: 'recursive_callback',
                  sources: _unknownCallbackValueSources(node),
                )
              : _summaryForDispatch(
                  target,
                  _summarizeWithContracts(
                    target,
                    elementKey: key,
                    depth: depth + 1,
                    activeKeys: {...activeKeys, key},
                  ),
                  expression,
                  depth: depth + 1,
                  activeKeys: activeKeys,
                ),
        );
      }
      final summary = ThrowSummary.merge(
        'callback',
        [
          for (final alternative in alternatives) ...alternative.sources,
          if (value.hasUnknown) ..._unknownCallbackValueSources(node),
        ],
        dependencyElementKeys: {
          for (final alternative in alternatives)
            ...alternative.dependencyElementKeys,
        },
        complete:
            !value.hasUnknown &&
            alternatives.every((alternative) => alternative.complete),
        truncationReason: value.hasUnknown ? 'unverified_callback_value' : null,
        maxSources: options.maxSourcesPerSummary,
      );
      if (!summary.complete) {
        yield _unverifiedCallbackScheduling;
      }
      final callbackType = expression.staticType;
      final returnedType = _callbackReturnedPayload(
        callbackType is FunctionType ? callbackType.returnType : null,
      );
      final latentIterable =
          !callback.consumesReturnedIterable &&
          ((returnedType is InterfaceType && returnedType.isDartCoreIterable) ||
              summary.effects.any(
                (effect) => effect.channel == ExceptionChannel.deferred,
              ));
      final latentStream =
          !callback.consumesReturnedStream &&
          ((returnedType is InterfaceType && returnedType.isDartAsyncStream) ||
              summary.effects.any(
                (effect) => effect.channel == ExceptionChannel.stream,
              ));
      if (latentIterable || latentStream) {
        // Returning a lazy value does not execute it. Nested returned-value
        // ownership is not yet proven; an await/catch on the outer SDK result
        // cannot establish containment of later iteration or subscription.
        yield const ThrowSource(
          kind: ThrowSourceKind.unresolvedCall,
          confidence: ThrowConfidence.unknown,
          displayName: 'unverified callback returned lazy value',
          isAsync: true,
          channel: ExceptionChannel.scheduled,
        );
      }
      for (final effect in summary.effects) {
        final source = effect.source;
        // Errors in an async-void callback escape through its zone even when
        // the scheduler otherwise converts callback failures into a Future.
        final channel =
            effect.channel == ExceptionChannel.scheduled ||
                (effect.channel == ExceptionChannel.future &&
                    !callback.assimilatesReturnedFuture)
            ? ExceptionChannel.scheduled
            : effect.channel == ExceptionChannel.deferred &&
                      !callback.consumesReturnedIterable ||
                  effect.channel == ExceptionChannel.stream &&
                      !callback.consumesReturnedStream
            ? effect.channel
            : callback.channel;
        yield ThrowSource(
          kind: source.kind,
          evidence: Set.unmodifiable({
            ...source.evidenceKinds,
            EffectEvidence.sdkModel,
          }),
          confidence: effect.certainty == ExceptionCertainty.unknown
              ? ThrowConfidence.unknown
              : channel == ExceptionChannel.future ||
                    channel == ExceptionChannel.stream ||
                    channel == ExceptionChannel.scheduled
              ? ThrowConfidence.asyncError
              : ThrowConfidence.possibleThrow,
          displayName: 'callback in ${element?.displayName ?? node.toSource()}',
          intent: source.effectiveIntent,
          channel: channel,
          timing: channel == ExceptionChannel.deferred
              ? ThrowTiming.deferred
              : channel == ExceptionChannel.synchronous
              ? ThrowTiming.synchronous
              : ThrowTiming.asynchronous,
          isAsync:
              channel != ExceptionChannel.synchronous &&
              channel != ExceptionChannel.deferred,
          certainty: effect.certainty == ExceptionCertainty.unknown
              ? ExceptionCertainty.unknown
              : ExceptionCertainty.possible,
          exceptionTypes: source.exceptionTypes,
          resolvedExceptionTypes: source.resolvedExceptionTypes,
          exceptionSupertypes: source.exceptionSupertypes,
          origin: source.origin,
          callbackInvocation: node is MethodInvocation ? node : null,
        );
      }
    }
  }

  ThrowSummary _summaryForDispatch(
    ExecutableElement declared,
    ThrowSummary baseSummary,
    AstNode callSite, {
    int depth = 0,
    Set<String> activeKeys = const {},
    String? callerKey,
  }) {
    if ((declared is! MethodElement && declared is! PropertyAccessorElement) ||
        declared.isStatic ||
        declared.enclosingElement is! InterfaceElement ||
        declared.enclosingElement is ExtensionTypeElement) {
      return baseSummary;
    }
    if (callSite is MethodInvocation &&
        literalListAddReceiver(callSite) != null) {
      return baseSummary;
    }

    final receiver = switch (callSite) {
      MethodInvocation() => callSite.realTarget,
      PropertyAccess() => callSite.realTarget,
      PrefixedIdentifier() => callSite.prefix,
      BinaryExpression() => callSite.leftOperand,
      PrefixExpression() => callSite.operand,
      PostfixExpression() => callSite.operand,
      IndexExpression() => callSite.realTarget,
      AssignmentExpression(:final leftHandSide) => switch (leftHandSide) {
        PropertyAccess() => leftHandSide.realTarget,
        PrefixedIdentifier() => leftHandSide.prefix,
        IndexExpression() => leftHandSide.realTarget,
        _ => null,
      },
      InterpolationExpression() => callSite.expression,
      ConstantPattern() => callSite.expression,
      _ => null,
    };
    final receiverType = receiver?.staticType;
    Expression? allocation = receiver;
    while (allocation is ParenthesizedExpression) {
      allocation = allocation.expression;
    }
    // These calls select a concrete implementation. Subclass overrides cannot
    // execute on an exact generative allocation or through a super invocation.
    if (receiver is SuperExpression ||
        allocation is InstanceCreationExpression &&
            allocation.constructorName.element?.isFactory == false) {
      return baseSummary;
    }
    final receiverElement = receiverType is InterfaceType
        ? receiverType.element
        : declared.enclosingElement is InterfaceElement
        ? declared.enclosingElement as InterfaceElement
        : null;
    if (receiverElement == null) return baseSummary;

    final depthLimited = depth > options.maxCallDepth;
    final candidateLimit = depthLimited || options.maxDispatchCandidates < 0
        ? 0
        : options.maxDispatchCandidates;
    final candidates = <ExecutableElement>[];
    var dispatchWasTruncated = false;
    final declaredType = declared.baseElement.runtimeType;
    for (final candidate in _dispatchIndex.membersNamed(declared.name)) {
      if (candidate.runtimeType != declaredType) continue;
      final owner = candidate.enclosingElement;
      if (owner is! InterfaceElement || owner == declared.enclosingElement) {
        continue;
      }
      if (owner != receiverElement &&
          !owner.allSupertypes.any((type) => type.element == receiverElement)) {
        continue;
      }
      if (candidates.length == candidateLimit) {
        dispatchWasTruncated = true;
        break;
      }
      candidates.add(candidate);
    }
    final candidateSummaries = <ThrowSummary>[];
    for (final candidate in candidates) {
      final callable = ResolvedCallable.tryCreate(candidate);
      final key =
          callable?.elementKey ??
          '${candidate.library.uri}::${candidate.runtimeType}:${candidate.firstFragment.offset}:${candidate.displayName}';
      if (callerKey != null) _recordDependency(callerKey, key, candidate);
      final summary = _summarizeDependency(candidate, key, depth, activeKeys);
      candidateSummaries.add(
        ThrowSummary.merge(
          key,
          [
            ...summary.sources,
            if (options.treatAsCastsAsThrowing)
              ...RuntimeChecks.dispatchChecks(callSite, candidate),
          ],
          dependencyElementKeys: summary.dependencyElementKeys,
          complete: summary.complete,
          truncationReason: summary.truncationReason,
        ),
      );
    }
    // A concrete static receiver type still permits overriding subclasses.
    // Only an exact generative allocation or a closed hierarchy proves the
    // dispatch set complete; sealed roots with open leaves remain open.
    final closedRoot =
        receiverElement is EnumElement ||
        (receiverElement is ClassElement &&
            (receiverElement.isFinal ||
                receiverElement.isSealed ||
                receiverElement.isPrivate));
    final incompleteAbstractDispatch =
        !_dispatchIndex.complete ||
        !closedRoot ||
        _dispatchIndex.hasOpenLeaf(receiverElement);
    if (candidateSummaries.isEmpty &&
        !incompleteAbstractDispatch &&
        !dispatchWasTruncated) {
      return baseSummary;
    }

    final dispatchSources = <ThrowSource>[
      ...baseSummary.sources,
      for (final summary in candidateSummaries) ...summary.sources,
      if (dispatchWasTruncated)
        ..._unknownSourcesForType(
          declared.returnType,
          kind: ThrowSourceKind.truncation,
          displayName: 'additional virtual targets',
        ),
      if (incompleteAbstractDispatch)
        ThrowSource(
          kind: ThrowSourceKind.unresolvedCall,
          confidence: ThrowConfidence.unknown,
          displayName:
              'incomplete dispatch for ${receiverElement.displayName}.${declared.name}',
          intent: ThrowIntent.possible,
        ),
    ];

    return ThrowSummary.merge(
      baseSummary.elementKey,
      dispatchSources,
      dependencyElementKeys: [
        ...baseSummary.dependencyElementKeys,
        for (final summary in candidateSummaries) ...[
          summary.elementKey,
          ...summary.dependencyElementKeys,
        ],
      ],
      complete:
          baseSummary.complete &&
          candidateSummaries.every((summary) => summary.complete) &&
          !dispatchWasTruncated &&
          !incompleteAbstractDispatch,
      truncationReason: dispatchWasTruncated
          ? (depthLimited ? 'max_call_depth' : 'max_dispatch_candidates')
          : incompleteAbstractDispatch
          ? 'open_dispatch_incomplete'
          : baseSummary.truncationReason,
    );
  }

  void _recordDependency(
    String callerKey,
    String dependencyKey,
    ExecutableElement executable,
  ) {
    _summaryElements[dependencyKey] = executable.baseElement;
    (_directDependencies[callerKey] ??= {}).add(dependencyKey);
    _directDependencies.putIfAbsent(dependencyKey, () => {});
  }

  static String _executableKey(ExecutableElement executable) =>
      ResolvedCallable.tryCreate(executable)?.elementKey ??
      '${executable.library.uri}::${executable.runtimeType}:${executable.firstFragment.offset}:${executable.displayName}';

  ThrowSummary _summarizeDependency(
    ExecutableElement executable,
    String key,
    int depth,
    Set<String> activeKeys,
  ) {
    if (activeKeys.contains(key)) {
      _recursiveKeys.addAll(activeKeys);
      return _summaryCache[key] ?? ThrowSummary.noObviousThrow(key);
    }
    if (_summaryCache[key] case final cached?) return cached;
    final summary = _summarizeWithContracts(
      executable.baseElement,
      elementKey: key,
      depth: depth,
      activeKeys: {...activeKeys, key},
    );
    if (depth <= options.maxCallDepth) _summaryCache[key] = summary;
    return summary;
  }

  static _DispatchIndex _collectKnownExecutables(
    Iterable<CompilationUnit> units,
  ) {
    final elements = <ExecutableElement>[];
    final elementSet = <ExecutableElement>{};
    final libraries = <LibraryElement>{};
    for (final unit in units) {
      if (unit.declaredFragment?.element case final library?) {
        libraries.add(library);
      }
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
    final types = <InterfaceElement>{};
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
        types.add(type);
        for (final member in [
          ...type.methods,
          ...type.getters,
          ...type.setters,
        ]) {
          if (elementSet.add(member)) elements.add(member);
        }
      }
    }
    return _DispatchIndex(
      elements,
      types,
      libraries.isNotEmpty && pending.isEmpty,
    );
  }

  ThrowSummary? _manifestSummaryForElement(
    ExecutableElement executable,
    String elementKey,
  ) {
    final match = _matchingManifestSpec(executable);
    if (match == null) {
      return null;
    }

    return ThrowSummary.merge(
      elementKey,
      match.sources,
      dependencyElementKeys: const [],
      complete: true,
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
      final score = spec.matchScore(callable);
      if (score > bestScore) {
        bestScore = score;
        bestMatch = spec;
      }
    }
    return bestScore >= 0 ? bestMatch : null;
  }

  VariableDeclaration? _findVariableDeclaration(
    PropertyInducingElement variable,
  ) {
    _loadResolvedDependency(variable.library);
    final fragment = variable.firstFragment;
    final path = fragment.libraryFragment.source.fullName;
    final unit =
        _parsedUnits[path] ??
        (File(path).existsSync()
            ? (_parsedUnits[path] = _parseSharedUnitSafely(path))
            : null);
    return unit == null
        ? null
        : NodeLocator(
            fragment.nameOffset ?? fragment.offset,
          ).searchWithin(unit)?.thisOrAncestorOfType<VariableDeclaration>();
  }

  AstNode? _findDeclaration(ExecutableElement executable) {
    // Deferred imports expose a synthetic loadLibrary executable without a
    // source offset. Loading can fail, but there is no Dart body to inspect.
    if (executable is TopLevelFunctionElement &&
        executable.isOriginLoadLibrary) {
      return null;
    }
    _loadResolvedDependency(executable.library);
    final fragment = executable.firstFragment;
    final path = fragment.libraryFragment.source.fullName;
    if (path.isEmpty) {
      return null;
    }
    if (!_parsedUnits.containsKey(path) && !File(path).existsSync()) {
      return null;
    }

    final unit = _parsedUnits[path] ??= _parseSharedUnitSafely(path);
    // Body summaries use the analyzer's V1 visitors and parent accessors.
    // Locate the declaration in that same view, including accessor wrappers.
    final declarationNode = NodeLocator(
      fragment.nameOffset ?? fragment.offset,
    ).searchWithin(unit);
    if (declarationNode == null) {
      return null;
    }

    return declarationNode.thisOrAncestorMatching((node) {
      return node is FunctionDeclaration ||
          node is FunctionExpression ||
          node is MethodDeclaration ||
          node is ConstructorDeclaration;
    });
  }

  ClassDeclaration? _findClassDeclaration(InterfaceElement element) {
    _loadResolvedDependency(element.library);
    final fragment = element.firstFragment;
    final path = fragment.libraryFragment.source.fullName;
    if (path.isEmpty) return null;
    if (!_parsedUnits.containsKey(path) && !File(path).existsSync()) {
      return null;
    }
    final unit = _parsedUnits[path] ??= _parseSharedUnitSafely(path);
    final node = NodeLocator(
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
    final fingerprint = _bytesFingerprint(File(path).readAsBytesSync());
    final shared = _sharedParsedUnits[path];
    final parsedUnit =
        shared != null &&
            shared.modified == modified &&
            shared.size == stat.size &&
            shared.fingerprint == fingerprint &&
            shared.featureSetKey == _featureSetKey
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
      featureSetKey: _featureSetKey,
      unit: parsedUnit,
    );
    if (_sharedParsedUnits.length > _maxSharedParsedUnits) {
      _sharedParsedUnits.remove(_sharedParsedUnits.keys.first);
    }
    return parsedUnit;
  }

  void _loadResolvedDependency(LibraryElement library) {
    final path = library.firstFragment.source.fullName;
    if (_resolvedPaths.contains(path)) return;
    final units = resolveDependency?.call(library);
    if (units == null) return;
    _dispatchIndex.addTypes([
      ...library.classes,
      ...library.enums,
      ...library.mixins,
    ]);
    for (final entry in units.entries) {
      _parsedUnits[entry.key] = entry.value;
      _resolvedPaths.add(entry.key);
      _dependencyFingerprints[entry.key] = _sourceFingerprint(entry.key);
    }
    // The initial dispatch index already walks imported library elements.
    // Add newly bound local declarations without duplicating that whole graph
    // for every resolved dependency (duplicates also consume dispatch budgets).
    for (final unit in units.values) {
      final collected = <ExecutableElement>[];
      unit.accept(_ExecutableCollector(collected));
      _dispatchIndex.addMembers(collected);
    }
  }

  CompilationUnit _parseSharedUnitSafely(String path) {
    // Analysis may race with an editor save/rename. A lint must not crash the
    // analyzer process because a source file disappeared between the
    // existence check and parsing. Returning an empty unit makes the caller
    // conservatively treat the declaration as unavailable.
    if (!_resolvedPaths.contains(path)) {
      _dependencyFingerprints[path] = _sourceFingerprint(path);
    }
    try {
      return _parseSharedUnit(path);
    } on FileSystemException {
      return parseString(content: '', path: path, featureSet: _featureSet).unit;
    } on FormatException {
      return parseString(content: '', path: path, featureSet: _featureSet).unit;
    } catch (_) {
      // Analyzer plugins run while files and generated sources are being
      // rewritten. Unknown parser/filesystem failures must widen the result to
      // source-unavailable rather than bringing down the analysis server.
      return parseString(content: '', path: path, featureSet: _featureSet).unit;
    }
  }

  FunctionBody? _bodyForDeclaration(AstNode declaration) {
    return switch (declaration) {
      FunctionDeclaration(:final functionExpression) => functionExpression.body,
      FunctionExpression(:final body) => body,
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
      return node is MethodInvocation ||
          node is FunctionExpressionInvocation ||
          node is InstanceCreationExpression ||
          node is SuperConstructorInvocation ||
          node is RedirectingConstructorInvocation ||
          (node is PropertyAccess && node.target?.staticType is DynamicType) ||
          (node is PrefixedIdentifier &&
              node.prefix.staticType is DynamicType) ||
          (node is BinaryExpression &&
              !const {'&&', '||', '??'}.contains(node.operator.lexeme) &&
              node.leftOperand.staticType is DynamicType) ||
          (node is PrefixExpression &&
              node.operator.lexeme != '!' &&
              node.operand.staticType is DynamicType) ||
          (node is PostfixExpression &&
              node.operator.lexeme != '!' &&
              node.operand.staticType is DynamicType) ||
          (node is AssignmentExpression &&
              (node.readType is DynamicType ||
                  node.leftHandSide.staticType is DynamicType ||
                  (node.leftHandSide is PropertyAccess &&
                      (node.leftHandSide as PropertyAccess)
                              .realTarget
                              .staticType
                          is DynamicType))) ||
          (node is IndexExpression &&
              node.realTarget.staticType is DynamicType) ||
          (node is InterpolationExpression &&
              node.expression.staticType is DynamicType) ||
          (node is PatternField && node.parent is ObjectPattern) ||
          node is RelationalPattern ||
          node is ConstantPattern;
    }

    if (element is TopLevelFunctionElement ||
        element is MethodElement ||
        element is ConstructorElement ||
        element is PropertyAccessorElement) {
      return false;
    }

    return true;
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

  static List<DartType> _resolvedExceptionTypesFrom(ThrowSummary summary) {
    if (summary.sources.any(
      (source) => source.resolvedExceptionTypes.isEmpty,
    )) {
      return const [];
    }
    return {
      for (final source in summary.sources) ...source.resolvedExceptionTypes,
    }.toList();
  }

  static List<String> _exceptionTypesFrom(ThrowSummary summary) {
    // A source with unknown thrown types must not disappear when merged with
    // a known source. Only a universal catch can discharge that combined set.
    if (summary.sources.any((source) => source.exceptionTypes.isEmpty)) {
      return const [];
    }
    return {
      for (final source in summary.sources) ...source.exceptionTypes,
    }.toList()..sort();
  }

  static Map<String, List<String>> _exceptionSupertypesFrom(
    ThrowSummary summary,
  ) => {for (final source in summary.sources) ...source.exceptionSupertypes};

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
      complete:
          summary.complete ||
          (minimum != ThrowIntent.unknown &&
              !filteredSources.any(
                (source) => source.confidence == ThrowConfidence.unknown,
              )),
      truncationReason: summary.truncationReason,
    );
  }

  CodeOrigin _originForExecutable(ExecutableElement executable) {
    final path = executable.firstFragment.libraryFragment.source.fullName;
    return _isWithinCurrentPackage(path)
        ? CodeOrigin.internal
        : CodeOrigin.thirdParty;
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

/// Return expressions belong to the factory, never to nested callable bodies.
/// This is a value union; creation effects remain in the ordinary body summary.
final class _ReturnedCallbackCollector extends GeneralizingAstVisitor<void> {
  final expressions = <Expression>[];
  var complete = true;
  var _remainingNodes = 4096;

  @override
  void visitNode(AstNode node) {
    if (!complete) return;
    if (_remainingNodes-- <= 0) {
      complete = false;
      return;
    }
    super.visitNode(node);
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {}

  @override
  void visitReturnStatement(ReturnStatement node) {
    final expression = node.expression;
    if (expression == null || expressions.length >= 64) {
      complete = false;
      return;
    }
    expressions.add(expression);
  }
}

final class _ParsedUnitCacheEntry {
  const _ParsedUnitCacheEntry({
    required this.modified,
    required this.size,
    required this.fingerprint,
    required this.featureSetKey,
    required this.unit,
  });

  final DateTime modified;
  final int size;
  final int fingerprint;
  final String featureSetKey;
  final CompilationUnit unit;
}

final class _DispatchIndex {
  _DispatchIndex(
    Iterable<ExecutableElement> executables,
    this._types,
    this.complete,
  ) {
    addMembers(executables);
  }

  final _members = <String?, Set<ExecutableElement>>{};
  final Set<InterfaceElement> _types;
  final _openLeaves = <InterfaceElement, bool>{};
  final bool complete;

  Iterable<ExecutableElement> membersNamed(String? name) =>
      _members[name] ?? const [];

  void addMembers(Iterable<ExecutableElement> executables) {
    for (final member in executables) {
      if (!member.isStatic && member.enclosingElement is InterfaceElement) {
        (_members[member.name] ??= {}).add(member);
      }
    }
  }

  void addTypes(Iterable<InterfaceElement> types) {
    final previousSize = _types.length;
    _types.addAll(types);
    if (_types.length != previousSize) _openLeaves.clear();
  }

  bool hasOpenLeaf(InterfaceElement receiver) => _openLeaves.putIfAbsent(
    receiver,
    () => _types.any(
      (owner) =>
          owner != receiver &&
          owner is ClassElement &&
          !owner.isFinal &&
          !owner.isSealed &&
          !owner.isPrivate &&
          owner.allSupertypes.any((type) => type.element == receiver),
    ),
  );
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

final class _CallbackContexts {
  static const maxContexts = 64;
  final Map<String, InferredThrowAnalyzer> analyzers = {};
  final Map<Element, int> _ids = {};
  bool contains(Element element) => _ids.containsKey(element);
  int id(Element element) => _ids.putIfAbsent(element, () => _ids.length);
}

final class _CallbackMutationVisitor extends RecursiveAstVisitor<void> {
  final Set<FormalParameterElement> written = {};
  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    final target = node.leftHandSide;
    if (target is SimpleIdentifier &&
        target.element is FormalParameterElement) {
      written.add((target.element as FormalParameterElement).baseElement);
    }
    super.visitAssignmentExpression(node);
  }
}

final class _BodySummaryVisitor extends GeneralizingAstVisitor<void> {
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
  final Set<AwaitExpression> _verifiedImmediateAwaits = {};
  bool complete = true;
  String? truncationReason;
  int _conditionalDepth = 0;

  bool get _isAsyncContext => executable.firstFragment.isAsynchronous;

  bool _visitConstructorInputs(
    ConstructorElement constructor,
    ConstructorDeclaration? declaration,
    ClassDeclaration? owner,
  ) {
    final initializers =
        declaration?.initializers ?? const <ConstructorInitializer>[];
    final redirecting = initializers.any(
      (initializer) => initializer is RedirectingConstructorInvocation,
    );
    if (owner != null && !redirecting) {
      for (final initializer in constructorFieldInitializers(owner)) {
        initializer.accept(this);
        if (!expressionCanCompleteNormally(initializer)) return false;
      }
    }
    for (final initializer in initializers) {
      initializer.accept(this);
      if (!constructorInitializerCanCompleteNormally(initializer)) return false;
    }
    if (!redirecting &&
        !initializers.any((node) => node is SuperConstructorInvocation)) {
      final target =
          constructor.superConstructor ??
          constructor.enclosingElement.supertype?.element.unnamedConstructor;
      final site = declaration ?? owner;
      if (target != null && site != null) {
        _recordInvocation(site, target);
      }
    }
    return true;
  }

  @override
  void visitSuperConstructorInvocation(SuperConstructorInvocation node) {
    if (isReachable(node)) _recordInvocation(node, node.element);
    super.visitSuperConstructorInvocation(node);
  }

  @override
  void visitRedirectingConstructorInvocation(
    RedirectingConstructorInvocation node,
  ) {
    if (isReachable(node)) _recordInvocation(node, node.element);
    super.visitRedirectingConstructorInvocation(node);
  }

  @override
  void visitPatternField(PatternField node) {
    for (final target in invocationTargets(node, executable.library)) {
      _recordInvocation(node, target);
    }
    super.visitPatternField(node);
  }

  @override
  void visitConstantPattern(ConstantPattern node) {
    for (final target in invocationTargets(node, executable.library)) {
      _recordInvocation(node, target);
    }
    super.visitConstantPattern(node);
  }

  @override
  void visitRelationalPattern(RelationalPattern node) {
    for (final target in invocationTargets(node, executable.library)) {
      _recordInvocation(node, target);
    }
    _recordImplicitCast(
      node.operand,
      node.element?.formalParameters.firstOrNull?.type,
    );
    super.visitRelationalPattern(node);
  }

  @override
  void visitCastPattern(CastPattern node) {
    if (analyzer.options.treatAsCastsAsThrowing) {
      final source = RuntimeChecks.castPattern(node);
      if (source != null && !_isProtected(node, source)) {
        sources.add(_normalize(source, node));
      }
    }
    super.visitCastPattern(node);
  }

  @override
  void visitNullAssertPattern(NullAssertPattern node) {
    final source = RuntimeChecks.nullAssertPattern(node);
    if (source != null && !_isProtected(node, source)) {
      sources.add(_normalize(source, node));
    }
    super.visitNullAssertPattern(node);
  }

  @override
  void visitNode(AstNode node) {
    if (SyntaxCoverageInventory.requiresUnknown(node)) {
      final source = ThrowSource(
        kind: ThrowSourceKind.unresolvedCall,
        confidence: ThrowConfidence.unknown,
        displayName:
            'unmodeled ${SyntaxCoverageInventory.kind(node)} semantics',
      );
      if (!_isProtected(node, source)) {
        sources.add(_normalize(source, node));
        complete = false;
        truncationReason ??= 'unmodeled_syntax';
      }
    }
    super.visitNode(node);
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {
    // Creation does not execute the body. Immediate calls are summarized by
    // inferCallFromBody with the closure's own async/generator context.
  }

  @override
  void visitBlock(Block node) {
    var canSkipStatement = false;
    for (final statement in node.statements) {
      _visitWithCertainty(statement, conditional: canSkipStatement);
      final completion = statementCompletion(statement);
      if (!completion.canCompleteNormally) break;
      canSkipStatement |= completion.transfers.any(
        (transfer) => switch (transfer.kind) {
          CompletionKind.returned ||
          CompletionKind.broke ||
          CompletionKind.continued => true,
          _ => false,
        },
      );
    }
  }

  @override
  void visitAsExpression(AsExpression node) {
    final target = node.type.type;
    if (target != null &&
        node.expression.staticType != null &&
        executable.library.typeSystem.isSubtypeOf(
          node.expression.staticType!,
          target,
        )) {
      node.expression.accept(this);
      return;
    }
    final source = ThrowSourceCatalog.matchAsExpression(node, analyzer.options);
    if (source != null && !_isProtected(node, source)) {
      sources.add(_normalize(source, node));
    }
    super.visitAsExpression(node);
  }

  @override
  void visitAssertStatement(AssertStatement node) =>
      _visitAssertion(node, node.condition, node.message);

  @override
  void visitAssertInitializer(AssertInitializer node) =>
      _visitAssertion(node, node.condition, node.message);

  void _visitAssertion(
    AstNode node,
    Expression condition,
    Expression? message,
  ) {
    // The language permits runtimes to disable assertions entirely.
    _conditionalDepth++;
    _visitBoolean(condition);
    message?.accept(this);
    final source = ThrowSourceCatalog.matchAssertion(condition, message);
    if (source != null && !_isProtected(node, source)) {
      sources.add(_normalize(source, node));
    }
    _conditionalDepth--;
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    _recordCall(node);
    super.visitFunctionExpressionInvocation(node);
  }

  @override
  void visitIfStatement(IfStatement node) {
    _visitIfBranches(
      node.expression,
      node.caseClause,
      node.thenStatement,
      node.elseStatement,
    );
  }

  @override
  void visitIfElement(IfElement node) {
    _visitIfBranches(
      node.expression,
      node.caseClause,
      node.thenElement,
      node.elseElement,
    );
  }

  void _visitIfBranches(
    Expression subject,
    CaseClause? clause,
    AstNode thenNode,
    AstNode? elseNode,
  ) {
    if (clause == null) {
      _visitBoolean(subject);
    } else {
      subject.accept(this);
      clause.accept(this);
    }
    final selection = ifBranchSelection(subject, clause);
    if (selection.selects) {
      _visitWithCertainty(thenNode, conditional: selection.fallsThrough);
    }
    if (selection.fallsThrough) {
      _visitWithCertainty(
        elseNode,
        conditional: selection.selects || selection.canStop,
      );
    }
  }

  @override
  void visitGuardedPattern(GuardedPattern node) {
    node.pattern.accept(this);
    final guard = node.whenClause;
    if (guard == null) return;
    final subject = switch (node.parent?.parent) {
      IfStatement(:final expression) ||
      IfElement(:final expression) ||
      SwitchExpression(:final expression) ||
      SwitchStatement(:final expression) => expression,
      _ => null,
    };
    _visitWithCertainty(
      guard,
      conditional:
          subject == null || simplePatternMatch(subject, node.pattern) != true,
    );
  }

  @override
  void visitWhenClause(WhenClause node) => _visitBoolean(node.expression);

  void _visitWithCertainty(AstNode? node, {required bool conditional}) {
    if (conditional) _conditionalDepth++;
    node?.accept(this);
    if (conditional) _conditionalDepth--;
  }

  @override
  void visitSpreadElement(SpreadElement node) {
    if (node.expression.staticType is DynamicType) {
      final source = ThrowSource(
        kind: ThrowSourceKind.dynamicInvocation,
        confidence: ThrowConfidence.unknown,
        displayName: 'dynamic spread',
      );
      if (!_isProtected(node, source)) sources.add(_normalize(source, node));
    }
    super.visitSpreadElement(node);
  }

  @override
  void visitSwitchStatement(SwitchStatement node) {
    node.expression.accept(this);
    _conditionalDepth++;
    for (final member in node.members) {
      member.accept(this);
    }
    _conditionalDepth--;
  }

  @override
  void visitSwitchExpression(SwitchExpression node) {
    final subject = node.expression;
    subject.accept(this);
    var canSkipArm = false;
    for (final arm in node.cases) {
      final clause = arm.guardedPattern;
      _visitWithCertainty(clause, conditional: canSkipArm);
      final selection = guardedPatternSelection(subject, clause);
      if (selection.selects) {
        _visitWithCertainty(
          arm.expression,
          conditional: canSkipArm || selection.fallsThrough,
        );
      }
      if (!selection.fallsThrough) break;
      canSkipArm |= selection.selects || selection.canStop;
    }
  }

  @override
  void visitForElement(ForElement node) =>
      _visitForLoop(node.forLoopParts, node.body);

  @override
  void visitMapLiteralEntry(MapLiteralEntry node) {
    node.key.accept(this);
    _visitWithCertainty(
      node.value,
      conditional: node.keyQuestion != null && !isDefinitelyNonNull(node.key),
    );
  }

  @override
  void visitForStatement(ForStatement node) =>
      _visitForLoop(node.forLoopParts, node.body);

  void _visitForLoop(ForLoopParts parts, AstNode body) {
    if (parts is! ForParts) {
      parts.accept(this);
      _visitWithCertainty(body, conditional: true);
      return;
    }
    final initializer = switch (parts) {
      ForPartsWithDeclarations(:final variables) => variables,
      ForPartsWithExpression(:final initialization) => initialization,
      ForPartsWithPattern(:final variables) => variables,
    };
    initializer?.accept(this);
    final condition = parts.condition;
    if (condition != null) _visitBoolean(condition);
    _visitWithCertainty(
      body,
      conditional: condition != null && _constantBoolean(condition) != true,
    );
    for (final updater in parts.updaters) {
      _visitWithCertainty(updater, conditional: true);
    }
  }

  @override
  void visitWhileStatement(WhileStatement node) {
    _visitBoolean(node.condition);
    final condition = _constantBoolean(node.condition);
    if (condition != false) {
      _visitWithCertainty(node.body, conditional: condition != true);
    }
  }

  @override
  void visitDoStatement(DoStatement node) {
    node.body.accept(this);
    _recordImplicitCast(
      node.condition,
      executable.library.typeProvider.boolType,
    );
    _visitWithCertainty(node.condition, conditional: true);
  }

  @override
  void visitIndexExpression(IndexExpression node) {
    if (!node.inSetterContext()) _recordCall(node);
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
    final element = node.propertyName.element;
    // Reading a method/function tearoff creates a value; its body executes
    // only when that value is called. Getters still execute on the read.
    if (!isAssignmentTarget(node) &&
        (element is! ExecutableElement || element is PropertyAccessorElement)) {
      _recordCall(node);
    }
    super.visitPropertyAccess(node);
  }

  @override
  void visitBinaryExpression(BinaryExpression node) {
    final operator = node.operator.lexeme;
    final logical = operator == '&&' || operator == '||';
    if (logical) {
      _visitBoolean(node.leftOperand);
    } else {
      node.leftOperand.accept(this);
    }
    final leftBoolean = _constantBoolean(node.leftOperand);
    if ((operator == '&&' && leftBoolean == false) ||
        (operator == '||' && leftBoolean == true)) {
      return;
    }
    if (operator == '??' && isDefinitelyNonNull(node.leftOperand)) {
      return;
    }
    final conditional = logical || operator == '??';
    if (conditional) _conditionalDepth++;
    if (logical) {
      _visitBoolean(node.rightOperand);
    } else {
      node.rightOperand.accept(this);
    }
    if (conditional) _conditionalDepth--;
    if (!conditional) _recordCall(node);
  }

  @override
  void visitConditionalExpression(ConditionalExpression node) {
    _visitBoolean(node.condition);
    final constant = _constantBoolean(node.condition);
    if (constant == true) {
      node.thenExpression.accept(this);
    } else if (constant == false) {
      node.elseExpression.accept(this);
    } else {
      _conditionalDepth++;
      node.thenExpression.accept(this);
      node.elseExpression.accept(this);
      _conditionalDepth--;
    }
  }

  void _visitBoolean(Expression expression) {
    _recordImplicitCast(expression, executable.library.typeProvider.boolType);
    expression.accept(this);
  }

  void _recordImplicitCast(Expression expression, DartType? target) {
    if (!analyzer.options.treatAsCastsAsThrowing) return;
    final source = RuntimeChecks.implicitCast(expression, target);
    if (source != null && !_isProtected(expression, source)) {
      sources.add(_normalize(source, expression));
    }
  }

  @override
  void visitListLiteral(ListLiteral node) {
    final type = node.staticType;
    if (type is InterfaceType && type.typeArguments.isNotEmpty) {
      for (final element in node.elements.whereType<Expression>()) {
        _recordImplicitCast(element, type.typeArguments.first);
      }
    }
    super.visitListLiteral(node);
  }

  @override
  void visitSetOrMapLiteral(SetOrMapLiteral node) {
    final type = node.staticType;
    if (type is InterfaceType && type.typeArguments.isNotEmpty) {
      for (final element in node.elements) {
        if (element is MapLiteralEntry && type.typeArguments.length == 2) {
          _recordImplicitCast(element.key, type.typeArguments.first);
          _recordImplicitCast(element.value, type.typeArguments.last);
        } else if (element is Expression) {
          _recordImplicitCast(element, type.typeArguments.first);
        }
      }
    }
    super.visitSetOrMapLiteral(node);
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    final initializer = node.initializer;
    if (initializer != null) {
      _recordImplicitCast(initializer, node.declaredFragment?.element.type);
    }
    super.visitVariableDeclaration(node);
  }

  @override
  void visitArgumentList(ArgumentList node) {
    for (final argument in node.arguments) {
      final value = argument.argumentExpression;
      _recordImplicitCast(value, argument.correspondingParameter?.type);
      if (analyzer.options.treatAsCastsAsThrowing) {
        final source = RuntimeChecks.covarianceCheck(
          value,
          argument.correspondingParameter,
        );
        if (source != null && !_isProtected(value, source)) {
          sources.add(_normalize(source, value));
        }
      }
    }
    super.visitArgumentList(node);
  }

  void _recordForwardedFuture(Expression expression) {
    final type = expression.staticType;
    final element = expression is SimpleIdentifier ? expression.element : null;
    if (type is InterfaceType &&
        (type.isDartAsyncFuture || type.isDartAsyncFutureOr) &&
        (element is VariableElement ||
            element is PropertyAccessorElement ||
            expression is PropertyAccess ||
            expression is IndexExpression)) {
      final source = ThrowSource(
        kind: ThrowSourceKind.awaitedAsyncDependency,
        confidence: ThrowConfidence.unknown,
        displayName: 'unverified Future value',
        isAsync: true,
        channel: ExceptionChannel.future,
      );
      if (!_isProtected(expression, source)) {
        sources.add(_normalize(source, expression));
      }
    }
  }

  @override
  void visitAwaitExpression(AwaitExpression node) {
    if (!_verifiedImmediateAwaits.contains(node)) {
      _recordForwardedFuture(node.expression);
    }
    super.visitAwaitExpression(node);
  }

  @override
  void visitReturnStatement(ReturnStatement node) {
    if (node.expression case final expression?) {
      _recordImplicitCast(expression, RuntimeChecks.returnType(node));
      _recordForwardedFuture(expression);
    }
    super.visitReturnStatement(node);
  }

  @override
  void visitExpressionFunctionBody(ExpressionFunctionBody node) {
    _recordImplicitCast(node.expression, RuntimeChecks.returnType(node));
    _recordForwardedFuture(node.expression);
    super.visitExpressionFunctionBody(node);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    final canSkipWrite =
        node.operator.lexeme == '??=' && node.readType?.isDartCoreNull != true;
    _recordImplicitCast(node.rightHandSide, node.writeType);
    final check = analyzer.options.treatAsCastsAsThrowing
        ? RuntimeChecks.assignmentCovarianceCheck(node)
        : null;
    if (check != null && !_isProtected(node, check)) {
      sources.add(_normalize(check, node, conditional: canSkipWrite));
    }
    for (final target in invocationTargets(node, executable.library)) {
      _recordInvocation(
        node,
        target,
        conditional: canSkipWrite && target == node.writeElement,
      );
    }
    node.leftHandSide.accept(this);
    _visitWithCertainty(node.rightHandSide, conditional: canSkipWrite);
  }

  @override
  void visitPrefixExpression(PrefixExpression node) {
    if (node.operator.lexeme == '!') {
      _visitBoolean(node.operand);
      return;
    }
    for (final target in invocationTargets(node, executable.library)) {
      _recordInvocation(node, target);
    }
    super.visitPrefixExpression(node);
  }

  @override
  void visitInterpolationExpression(InterpolationExpression node) {
    for (final target in invocationTargets(node, executable.library)) {
      _recordInvocation(node, target);
    }
    super.visitInterpolationExpression(node);
  }

  @override
  void visitPostfixExpression(PostfixExpression node) {
    for (final target in invocationTargets(node, executable.library)) {
      _recordInvocation(node, target);
    }
    if (node.operator.lexeme == '!' && !isDefinitelyNonNull(node.operand)) {
      const source = ThrowSource(
        kind: ThrowSourceKind.nullAssertion,
        confidence: ThrowConfidence.possibleThrow,
        displayName: 'null assertion',
        exceptionTypes: ['TypeError'],
      );
      if (!_isProtected(node, source)) {
        sources.add(_normalize(source, node));
      }
    }
    super.visitPostfixExpression(node);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    final element = node.identifier.element;
    if (!isAssignmentTarget(node) &&
        (element is! ExecutableElement || element is PropertyAccessorElement)) {
      _recordCall(node);
    }
    super.visitPrefixedIdentifier(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (unqualifiedGetter(node) case final getter?) {
      _recordInvocation(node, getter);
    }
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
      resolvedExceptionTypes: [?thrownType],
      exceptionSupertypes: _exceptionSupertypes(thrownType),
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
    return [?type.element.name];
  }

  Map<String, List<String>> _exceptionSupertypes(DartType? type) {
    if (type is! InterfaceType || type.element.name == null) return const {};
    return {
      type.element.name!: [
        for (final supertype in type.allSupertypes) ?supertype.element.name,
      ],
    };
  }

  void _recordCall(AstNode node, {Element? element}) =>
      _recordInvocation(node, element ?? _elementForNode(node));

  void _recordInvocation(
    AstNode node,
    Element? element, {
    bool conditional = false,
  }) {
    final consumer = asyncValueConsumer(node);
    final storedAwait = immediateAwaitOfStoredFuture(consumer, node);
    final summary = analyzer.inferCallFromBody(
      node,
      currentExecutable: executable,
      resolvedElement: element,
      depth: depth,
      activeKeys: activeKeys,
      isAsyncObserved:
          storedAwait != null || _isAsyncObserved(node, consumer: consumer),
    );
    if (storedAwait != null && summary.complete) {
      _verifiedImmediateAwaits.add(storedAwait);
    }
    if (summary.sources.isEmpty) {
      return;
    }

    final residualSources = <ThrowSource>[];
    for (final source in summary.sources) {
      if (_isProtected(node, source)) continue;
      final local =
          ExceptionEffect.fromSource(source).channel ==
              ExceptionChannel.deferred
          ? deferredLocalUses(node)
          : null;
      if (local == null || local.escapes) {
        residualSources.add(_normalize(source, node, conditional: conditional));
      }
      if (local == null) continue;
      final observed = InferredThrowAnalyzer._sourceWithChannel(
        source,
        ExceptionChannel.synchronous,
      );
      for (final consumer in local.consumers) {
        if (!_isProtected(consumer, observed)) {
          residualSources.add(
            _normalize(observed, consumer, conditional: true),
          );
        }
      }
    }
    if (residualSources.isEmpty) return;
    sources.addAll(residualSources);
    dependencies.addAll(summary.dependencyElementKeys);
    complete = complete && summary.complete;
    truncationReason ??= summary.truncationReason;
  }

  Element? _elementForNode(AstNode node) {
    return switch (node) {
      MethodInvocation(:final methodName) => methodName.element,
      FunctionExpressionInvocation() =>
        node.element ??
            (node.function is SimpleIdentifier
                ? (node.function as SimpleIdentifier).element
                : null),
      InstanceCreationExpression(:final constructorName) =>
        constructorName.element,
      PropertyAccess(:final propertyName) => propertyName.element,
      PrefixedIdentifier(:final identifier) => identifier.element,
      BinaryExpression() => node.element,
      IndexExpression() => node.element,
      SimpleIdentifier() => node.element,
      AssignmentExpression() => node.writeElement,
      PrefixExpression() => node.element,
      PostfixExpression() => node.element,
      _ => null,
    };
  }

  bool _isProtected(AstNode node, ThrowSource source) {
    if (isEffectContained(node, source, respectExceptionBoundary: false)) {
      return true;
    }
    if (ExceptionEffect.fromSource(source).channel != ExceptionChannel.future) {
      return false;
    }
    final awaitSite = immediateAwaitOfStoredFuture(
      asyncValueConsumer(node),
      node,
    );
    return awaitSite != null &&
        isEffectContained(awaitSite, source, respectExceptionBoundary: false);
  }

  ThrowSource _normalize(
    ThrowSource source,
    AstNode node, {
    bool conditional = false,
  }) {
    final effect = ExceptionEffect.fromSource(source);
    final route = asyncValueRoute(node, effect.channel);
    final sourceChannel = route.channel;
    final storedAwait = sourceChannel == ExceptionChannel.future
        ? immediateAwaitOfStoredFuture(route.consumer, node)
        : null;
    final bodyChannel = _isAsyncContext
        ? (executable.returnType is VoidType
              ? ExceptionChannel.scheduled
              : executable.firstFragment.isGenerator
              ? ExceptionChannel.stream
              : ExceptionChannel.future)
        : executable.firstFragment.isGenerator
        ? ExceptionChannel.deferred
        : ExceptionChannel.synchronous;
    // A synchronous failure executed by an async/generator body is delivered
    // through that body's result. Awaiting a Future likewise moves its error
    // into the enclosing body's channel. Independent scheduled work stays in
    // its zone, regardless of the enclosing body's return type.
    final unverifiedUnobservedFuture =
        sourceChannel == ExceptionChannel.future &&
        ((source.confidence == ThrowConfidence.unknown &&
                storedAwait == null &&
                !_isAsyncObserved(node, channel: sourceChannel)) ||
            route.consumer is ExpressionStatement);
    final consumer = storedAwait ?? route.consumer;
    final consumesIterator =
        sourceChannel == ExceptionChannel.deferred &&
            deferredExecutionSite(node) != null ||
        sourceChannel == ExceptionChannel.stream &&
            (consumer is ForEachParts ||
                consumer is YieldStatement && consumer.star != null);
    final channel = unverifiedUnobservedFuture
        ? ExceptionChannel.scheduled
        : sourceChannel == ExceptionChannel.synchronous ||
              consumesIterator ||
              (sourceChannel == ExceptionChannel.future &&
                  consumer is AwaitExpression)
        ? bodyChannel
        : sourceChannel;
    final contextualConfidence = !_isAsyncContext || source.isAsync
        ? source.confidence
        : switch (source.confidence) {
            ThrowConfidence.definiteThrow ||
            ThrowConfidence.possibleThrow => ThrowConfidence.asyncError,
            _ => source.confidence,
          };
    final mayNotExecute =
        conditional ||
        _conditionalDepth > 0 ||
        effect.certainty == ExceptionCertainty.definite && maySkipForNull(node);
    final confidence =
        mayNotExecute && contextualConfidence == ThrowConfidence.definiteThrow
        ? ThrowConfidence.possibleThrow
        : contextualConfidence;
    return ThrowSource(
      kind: source.kind,
      evidence: source.evidenceKinds,
      confidence: confidence,
      displayName: source.displayName,
      intent: source.intent,
      isAsync:
          source.isAsync ||
          _isAsyncContext ||
          confidence == ThrowConfidence.asyncError,
      certainty:
          mayNotExecute && effect.certainty == ExceptionCertainty.definite
          ? ExceptionCertainty.possible
          : effect.certainty,
      channel: channel,
      timing: channel == ExceptionChannel.synchronous
          ? ThrowTiming.synchronous
          : channel == ExceptionChannel.deferred
          ? ThrowTiming.deferred
          : ThrowTiming.asynchronous,
      exceptionTypes: source.exceptionTypes,
      resolvedExceptionTypes: source.resolvedExceptionTypes,
      exceptionSupertypes: source.exceptionSupertypes,
      origin:
          source.origin ??
          ThrowOrigin(
            displayName: source.displayName,
            filePath: executable.firstFragment.libraryFragment.source.fullName,
            offset: node.offset,
            length: node.length,
          ),
    );
  }

  bool _isAsyncObserved(
    AstNode node, {
    ExceptionChannel? channel,
    AstNode? consumer,
  }) {
    final parent = consumer ?? asyncValueConsumer(node);
    return (channel != ExceptionChannel.future &&
            (parent is ForEachParts ||
                parent is SpreadElement ||
                (parent is YieldStatement && parent.star != null))) ||
        parent is AwaitExpression ||
        parent is ReturnStatement ||
        (executable is GetterElement && parent is VariableDeclaration) ||
        parent is ExpressionFunctionBody;
  }

  bool? _constantBoolean(Expression expression) =>
      constantBooleanValue(expression);
}
