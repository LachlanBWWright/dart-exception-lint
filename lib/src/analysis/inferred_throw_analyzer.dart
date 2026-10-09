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
import '../engine/invocation_targets.dart';
import '../engine/runtime_checks.dart';
import '../engine/numeric_checks.dart';
import '../engine/exception_effect.dart';
import '../engine/statement_completion.dart';
import '../engine/syntax_coverage.dart';
import '../engine/callback_models.dart';
import '../engine/callback_values.dart';
import '../engine/strongly_connected_components.dart';

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
    return sources.every((source) {
      final effect = ExceptionEffect.fromSource(source);
      return isProtectedByCatch(
        node,
        requireAsyncProtection:
            effect.channel == ExceptionChannel.future ||
            effect.channel == ExceptionChannel.stream,
        channel: effect.channel,
        exceptionTypes: source.exceptionTypes,
        resolvedExceptionTypes: source.resolvedExceptionTypes,
        exceptionSupertypes: source.exceptionSupertypes,
      );
    });
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
       _knownExecutables = _collectKnownExecutables(knownUnits.values),
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
      _knownExecutables = parent._knownExecutables,
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
  final List<ExecutableElement> _knownExecutables;
  final Map<FormalParameterElement, CallbackValue> _callbackBindings;
  CallbackValueResolver? _callbackValueResolver;
  final _CallbackContexts _callbackContexts;
  final int _rootDepth;

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
      return Object.hashAll(File(path).readAsBytesSync());
    } on FileSystemException {
      return null;
    }
  }

  InferredCallAnalysis? analyzeResolvedCall(
    AstNode node, {
    required Element? element,
    required bool treatUnknownAsReportable,
    required bool requireObservedAsyncError,
    bool includeManifestOverrides = true,
  }) {
    if ((node is PropertyAccess || node is PrefixedIdentifier) &&
        element is ExecutableElement &&
        element is! PropertyAccessorElement) {
      return null;
    }
    if (node is FunctionExpressionInvocation) {
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
    final baseSummary = _summaryForDispatch(
      executable,
      directSource == null
          ? (_isProvenSafeNumeric(node, element)
                ? ThrowSummary.noObviousThrow(node.toSource())
                : (_specializedSummary(executable, node, depth: 0) ??
                      summarizeExecutable(executable)))
          : ThrowSummary.merge(
              _displayNameForExecutable(executable),
              [directSource],
              dependencyElementKeys: const [],
              complete: true,
            ),
      node,
    );
    final summary = ThrowSummary.merge(
      baseSummary.elementKey,
      [...baseSummary.sources, ..._callbackSources(node, element, 0, {})],
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
  }) {
    if (executable.library.isInSdk) return null;
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
    if (depth > options.maxCallDepth) {
      return _unknownCallbackContext(executable, callableKey, 'max_call_depth');
    }
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

  static bool _isProvenSafeNumeric(AstNode node, Element? element) =>
      switch (node) {
        BinaryExpression()
            when element?.baseElement == node.element?.baseElement =>
          NumericChecks.modelsBinary(node) &&
              NumericChecks.binary(node) == null,
        AssignmentExpression()
            when element?.baseElement == node.element?.baseElement =>
          NumericChecks.modelsAssignment(node) &&
              NumericChecks.assignment(node) == null,
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
            : _isProvenSafeNumeric(node, target)
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
    sources: _unknownSourcesForType(
      executable.returnType,
      kind: kind,
      displayName: _displayNameForExecutable(executable),
    ),
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

    // Reading a synthetic SDK const field does not execute an initializer.
    // Explicit getters and non-const fields retain their ordinary summaries.
    if (executable is GetterElement &&
        executable.library.isInSdk &&
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
                changed ||
                _summarySignature(previous) != _summarySignature(merged);
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

  String _summarySignature(ThrowSummary summary) => [
    summary.complete,
    summary.dependencyElementKeys.join(','),
    ...summary.sources.map(
      (source) => [
        source.kind,
        source.confidence,
        source.effectiveTiming,
        source.channel,
        source.certainty,
        source.resolvedExceptionTypes
            .map(
              (type) =>
                  '${type.element?.library?.uri}:${type.getDisplayString()}',
            )
            .join(','),
        source.displayName,
        source.exceptionTypes.join(','),
        source.origin?.filePath,
        source.origin?.offset,
      ].join('|'),
    ),
  ].join('\n');

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
    if (depth > options.maxCallDepth) {
      return _unknownExecutableSummary(
        executable,
        elementKey,
        'max_call_depth',
        kind: ThrowSourceKind.truncation,
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
    body?.accept(visitor);

    // Constructor execution includes initializer-list expressions and the
    // instance field initializers that run before its body. Include those
    // effects in the constructor summary instead of treating the body as the
    // complete execution surface.
    if (executable is ConstructorElement && !executable.isFactory) {
      if (constructorClass != null) {
        for (final field
            in constructorClass.body.members.whereType<FieldDeclaration>()) {
          if (field.isStatic || field.fields.lateKeyword != null) continue;
          for (final variable in field.fields.variables) {
            variable.initializer?.accept(visitor);
          }
        }
      }
      if (declaration case final ConstructorDeclaration constructor) {
        constructor.initializers.accept(visitor);
      }
      final explicitSuper =
          declaration is ConstructorDeclaration &&
          declaration.initializers.any(
            (initializer) =>
                initializer is SuperConstructorInvocation ||
                initializer is RedirectingConstructorInvocation,
          );
      final implicitSuper =
          executable.enclosingElement.supertype?.element.unnamedConstructor;
      if (!explicitSuper && implicitSuper != null) {
        visitor._recordCall(
          declaration ?? constructorClass!,
          element: implicitSuper,
        );
      }
    } else if (executable is ConstructorElement &&
        executable.redirectedConstructor != null) {
      visitor._recordCall(
        declaration ?? constructorClass!,
        element: executable.redirectedConstructor,
      );
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
    final directSource =
        ThrowSourceCatalog.matchResolvedInvocation(
          node,
          resolvedElement,
          options,
        ) ??
        (resolvedElement == null
            ? ThrowSourceCatalog.matchUnresolvedInvocation(node, options)
            : null);
    if (directSource != null) {
      final shouldKeep =
          !directSource.isAsync ||
          isAsyncObserved ||
          directSource.channel == ExceptionChannel.scheduled;
      if (shouldKeep) {
        return ThrowSummary.merge(
          directSource.displayName,
          [directSource, ...callbackSources],
          dependencyElementKeys: const [],
          complete: true,
        );
      }
    }

    if (_isProvenSafeNumeric(node, resolvedElement)) {
      return ThrowSummary.merge(
        node.toSource(),
        callbackSources,
        dependencyElementKeys: const [],
        complete: true,
      );
    }

    final resolved =
        _boundExecutable(resolvedElement) ??
        (resolvedElement == null
            ? _resolveBodyCall(node, currentExecutable)
            : null);
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

    final callable = ResolvedCallable.tryCreate(resolved);
    final dependencyKey =
        callable?.elementKey ??
        '${resolved.library.uri}::${resolved.runtimeType}:${resolved.firstFragment.offset}:${resolved.displayName}';

    _summaryElements[dependencyKey] = resolved.baseElement;
    final currentKey =
        ResolvedCallable.tryCreate(currentExecutable)?.elementKey ??
        '${currentExecutable.library.uri}::${currentExecutable.runtimeType}:${currentExecutable.firstFragment.offset}:${currentExecutable.displayName}';
    (_directDependencies[currentKey] ??= {}).add(dependencyKey);
    _directDependencies.putIfAbsent(dependencyKey, () => {});
    final specialized = _specializedSummary(resolved, node, depth: depth + 1);
    if (activeKeys.contains(dependencyKey)) {
      _recursiveKeys.addAll(activeKeys);
      return specialized ??
          _summaryCache[dependencyKey] ??
          ThrowSummary.noObviousThrow(dependencyKey);
    }

    final nextActiveKeys = {...activeKeys, dependencyKey};
    final summary =
        specialized ??
        _summaryCache[dependencyKey] ??
        _summarizeWithContracts(
          resolved.baseElement,
          elementKey: dependencyKey,
          depth: depth + 1,
          activeKeys: nextActiveKeys,
        );
    if (specialized == null) _summaryCache[dependencyKey] = summary;
    final dispatchSummary = _summaryForDispatch(resolved, summary, node);

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
      final discardedCallbackFuture =
          boundCallback &&
          effect.channel == ExceptionChannel.future &&
          (!isAsyncObserved ||
              (currentExecutable.returnType is VoidType &&
                  asyncValueConsumer(node) is! AwaitExpression));
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
      dependencyElementKeys: [dependencyKey, ...summary.dependencyElementKeys],
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
      if (expression is NullLiteral) continue;
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
        );
      }
    }
  }

  ThrowSummary _summaryForDispatch(
    ExecutableElement declared,
    ThrowSummary baseSummary,
    AstNode callSite,
  ) {
    if ((declared is! MethodElement && declared is! PropertyAccessorElement) ||
        declared.isStatic) {
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
    final receiverElement = receiverType is InterfaceType
        ? receiverType.element
        : declared.enclosingElement is InterfaceElement
        ? declared.enclosingElement as InterfaceElement
        : null;
    if (receiverElement == null) return baseSummary;

    final candidates = _knownExecutables.where((candidate) {
      if (candidate.isStatic ||
          candidate.runtimeType != declared.baseElement.runtimeType) {
        return false;
      }
      if (candidate.name != declared.name) return false;
      final enclosing = candidate.enclosingElement;
      if (enclosing is! InterfaceElement) return false;
      if (enclosing == declared.enclosingElement) return false;
      return enclosing == receiverElement ||
          enclosing.allSupertypes.any(
            (type) => type.element == receiverElement,
          );
    });

    final candidateList = candidates.toList();
    final candidateLimit = options.maxDispatchCandidates < 0
        ? 0
        : options.maxDispatchCandidates;
    final candidateSummaries = <ThrowSummary>[];
    for (final candidate in candidateList.take(candidateLimit)) {
      final callable = ResolvedCallable.tryCreate(candidate);
      final key =
          callable?.elementKey ??
          '${candidate.library.uri}::${candidate.runtimeType}:${candidate.firstFragment.offset}:${candidate.displayName}';
      final summary =
          _summaryCache[key] ??
          _summarizeWithContracts(
            candidate.baseElement,
            elementKey: key,
            depth: 1,
            activeKeys: {baseSummary.elementKey, key},
          );
      _summaryCache[key] = summary;
      candidateSummaries.add(
        ThrowSummary.merge(
          key,
          [
            ...summary.sources,
            ...RuntimeChecks.dispatchChecks(callSite, candidate),
          ],
          dependencyElementKeys: summary.dependencyElementKeys,
          complete: summary.complete,
          truncationReason: summary.truncationReason,
        ),
      );
    }
    final exactAllocation =
        receiver is InstanceCreationExpression &&
        receiver.constructorName.element?.isFactory == false;
    // A concrete static receiver type still permits overriding subclasses.
    // Only an exact generative allocation or a closed hierarchy proves the
    // dispatch set complete; sealed roots with open leaves remain open.
    final closedRoot =
        receiverElement is EnumElement ||
        (receiverElement is ClassElement &&
            (receiverElement.isFinal ||
                receiverElement.isSealed ||
                receiverElement.isPrivate));
    final openLeaf = candidateList.any((candidate) {
      final owner = candidate.enclosingElement;
      return owner is ClassElement &&
          !owner.isFinal &&
          !owner.isSealed &&
          !owner.isPrivate;
    });
    final incompleteAbstractDispatch =
        !exactAllocation && (!closedRoot || openLeaf);
    if (candidateSummaries.isEmpty && !incompleteAbstractDispatch) {
      return baseSummary;
    }

    final dispatchWasTruncated = candidateList.length > candidateLimit;
    final dispatchSources = <ThrowSource>[
      ...baseSummary.sources,
      for (final summary in candidateSummaries) ...summary.sources,
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
        for (final summary in candidateSummaries)
          ...summary.dependencyElementKeys,
      ],
      complete:
          baseSummary.complete &&
          candidateSummaries.every((summary) => summary.complete) &&
          !dispatchWasTruncated &&
          !incompleteAbstractDispatch,
      truncationReason: dispatchWasTruncated
          ? 'max_dispatch_candidates'
          : incompleteAbstractDispatch
          ? 'open_dispatch_incomplete'
          : baseSummary.truncationReason,
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
        : NodeLocator2(
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
    final declarationNode = NodeLocator2(
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
    for (final entry in units.entries) {
      _parsedUnits[entry.key] = entry.value;
      _resolvedPaths.add(entry.key);
      _dependencyFingerprints[entry.key] = _sourceFingerprint(entry.key);
    }
    // The initial dispatch index already walks imported library elements.
    // Add newly bound local declarations without duplicating that whole graph
    // for every resolved dependency (duplicates also consume dispatch budgets).
    final known = _knownExecutables.toSet();
    for (final unit in units.values) {
      final collected = <ExecutableElement>[];
      unit.accept(_ExecutableCollector(collected));
      _knownExecutables.addAll(collected.where(known.add));
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
      if (node case MethodInvocation(:final target, :final methodName)
          when target == null &&
              methodName.name.isNotEmpty &&
              _startsWithUppercase(methodName.name)) {
        return false;
      }
      return node is MethodInvocation ||
          node is FunctionExpressionInvocation ||
          node is InstanceCreationExpression ||
          (node is PropertyAccess && node.target?.staticType is DynamicType) ||
          (node is PrefixedIdentifier &&
              node.prefix.staticType is DynamicType) ||
          (node is BinaryExpression &&
              node.leftOperand.staticType is DynamicType) ||
          (node is PrefixExpression &&
              node.operand.staticType is DynamicType) ||
          (node is PostfixExpression &&
              node.operand.staticType is DynamicType) ||
          (node is AssignmentExpression &&
              (node.leftHandSide.staticType is DynamicType ||
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
  bool complete = true;
  String? truncationReason;
  int _conditionalDepth = 0;

  bool get _isAsyncContext => executable.firstFragment.isAsynchronous;

  @override
  void visitPatternField(PatternField node) {
    for (final target in invocationTargets(node, executable.library)) {
      _recordCall(node, element: target);
    }
    super.visitPatternField(node);
  }

  @override
  void visitConstantPattern(ConstantPattern node) {
    for (final target in invocationTargets(node, executable.library)) {
      _recordCall(node, element: target);
    }
    super.visitConstantPattern(node);
  }

  @override
  void visitRelationalPattern(RelationalPattern node) {
    for (final target in invocationTargets(node, executable.library)) {
      _recordCall(node, element: target);
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
    for (final statement in node.statements) {
      statement.accept(this);
      if (!statementCompletion(statement).canCompleteNormally) break;
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
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    _recordCall(node);
    super.visitFunctionExpressionInvocation(node);
  }

  @override
  void visitIfStatement(IfStatement node) {
    // The pattern and guard execute before either branch of an if-case.
    node.caseClause?.accept(this);
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
  void visitForStatement(ForStatement node) {
    node.forLoopParts.accept(this);
    _conditionalDepth++;
    node.body.accept(this);
    _conditionalDepth--;
  }

  @override
  void visitWhileStatement(WhileStatement node) {
    node.condition.accept(this);
    if (_constantBoolean(node.condition) == false) return;
    _conditionalDepth++;
    node.body.accept(this);
    _conditionalDepth--;
  }

  @override
  void visitDoStatement(DoStatement node) {
    _conditionalDepth++;
    node.body.accept(this);
    _conditionalDepth--;
    node.condition.accept(this);
  }

  @override
  void visitIndexExpression(IndexExpression node) {
    final source = ThrowSourceCatalog.matchIndexAccess(node, analyzer.options);
    if (source != null && !_isProtected(node, source)) {
      sources.add(_normalize(source, node));
    }
    _recordCall(node);
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
    if (element is! ExecutableElement || element is PropertyAccessorElement) {
      _recordCall(node);
    }
    super.visitPropertyAccess(node);
  }

  @override
  void visitBinaryExpression(BinaryExpression node) {
    node.leftOperand.accept(this);
    final operator = node.operator.lexeme;
    final leftBoolean = _constantBoolean(node.leftOperand);
    if ((operator == '&&' && leftBoolean == false) ||
        (operator == '||' && leftBoolean == true)) {
      return;
    }
    if (operator == '??' &&
        node.leftOperand.staticType != null &&
        node.leftOperand.staticType is! DynamicType &&
        node.leftOperand.staticType!.nullabilitySuffix.name == 'none') {
      return;
    }
    final conditional =
        operator == '&&' || operator == '||' || operator == '??';
    if (conditional) _conditionalDepth++;
    node.rightOperand.accept(this);
    if (conditional) _conditionalDepth--;
    _recordCall(node);
  }

  @override
  void visitConditionalExpression(ConditionalExpression node) {
    node.condition.accept(this);
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
    _recordForwardedFuture(node.expression);
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
    _recordImplicitCast(node.rightHandSide, node.writeType);
    for (final target in invocationTargets(node, executable.library)) {
      _recordCall(node, element: target);
    }
    super.visitAssignmentExpression(node);
  }

  @override
  void visitPrefixExpression(PrefixExpression node) {
    for (final target in invocationTargets(node, executable.library)) {
      _recordCall(node, element: target);
    }
    super.visitPrefixExpression(node);
  }

  @override
  void visitInterpolationExpression(InterpolationExpression node) {
    for (final target in invocationTargets(node, executable.library)) {
      _recordCall(node, element: target);
    }
    super.visitInterpolationExpression(node);
  }

  @override
  void visitPostfixExpression(PostfixExpression node) {
    for (final target in invocationTargets(node, executable.library)) {
      _recordCall(node, element: target);
    }
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
    final element = node.identifier.element;
    if (element is! ExecutableElement || element is PropertyAccessorElement) {
      _recordCall(node);
    }
    super.visitPrefixedIdentifier(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (node.inGetterContext() &&
        node.element is GetterElement &&
        node.parent is! PropertyAccess &&
        node.parent is! PrefixedIdentifier) {
      _recordCall(node);
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

  void _recordCall(AstNode node, {Element? element}) {
    final summary = analyzer.inferCallFromBody(
      node,
      currentExecutable: executable,
      resolvedElement: element ?? _elementForNode(node),
      depth: depth,
      activeKeys: activeKeys,
      isAsyncObserved: _isAsyncObserved(node),
    );
    if (summary.sources.isEmpty) {
      return;
    }

    final residualSources = summary.sources
        .where((source) => !_isProtected(node, source))
        .toList();
    if (residualSources.isEmpty) return;
    sources.addAll(residualSources.map((source) => _normalize(source, node)));
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
    return isProtectedByCatch(
      node,
      requireAsyncProtection: source.isAsync,
      channel: source.channel,
      exceptionTypes: source.exceptionTypes,
      resolvedExceptionTypes: source.resolvedExceptionTypes,
      exceptionSupertypes: source.exceptionSupertypes,
      respectExceptionBoundary: false,
    );
  }

  ThrowSource _normalize(ThrowSource source, [AstNode? node]) {
    final sourceChannel = ExceptionEffect.fromSource(source).channel;
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
        source.confidence == ThrowConfidence.unknown &&
        node != null &&
        !_isAsyncObserved(node, channel: sourceChannel);
    final consumer = node == null ? null : asyncValueConsumer(node);
    final consumesIterator =
        (sourceChannel == ExceptionChannel.stream ||
            sourceChannel == ExceptionChannel.deferred) &&
        ((sourceChannel == ExceptionChannel.deferred &&
                node != null &&
                consumesDeferredValue(node)) ||
            consumer is ForEachParts ||
            (consumer is SpreadElement &&
                sourceChannel == ExceptionChannel.deferred) ||
            (consumer is YieldStatement && consumer.star != null));
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
      isAsync:
          source.isAsync ||
          _isAsyncContext ||
          confidence == ThrowConfidence.asyncError,
      certainty:
          _conditionalDepth > 0 &&
              ExceptionEffect.fromSource(source).certainty ==
                  ExceptionCertainty.definite
          ? ExceptionCertainty.possible
          : ExceptionEffect.fromSource(source).certainty,
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

  bool _isAsyncObserved(AstNode node, {ExceptionChannel? channel}) {
    final parent = asyncValueConsumer(node);
    return (channel != ExceptionChannel.future &&
            (parent is ForEachParts ||
                parent is SpreadElement ||
                (parent is YieldStatement && parent.star != null))) ||
        parent is AwaitExpression ||
        parent is ReturnStatement ||
        (executable is GetterElement && parent is VariableDeclaration) ||
        parent is ExpressionFunctionBody;
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
}
