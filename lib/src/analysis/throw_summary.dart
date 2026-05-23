enum ThrowConfidence {
  definiteThrow,
  possibleThrow,
  asyncError,
  unknown,
  noObviousThrow,
}

extension ThrowConfidenceExtension on ThrowConfidence {
  String get wireName => switch (this) {
    ThrowConfidence.definiteThrow => 'definite_throw',
    ThrowConfidence.possibleThrow => 'possible_throw',
    ThrowConfidence.asyncError => 'async_error',
    ThrowConfidence.unknown => 'unknown',
    ThrowConfidence.noObviousThrow => 'no_obvious_throw',
  };

  String get label => switch (this) {
    ThrowConfidence.definiteThrow => 'definite throw',
    ThrowConfidence.possibleThrow => 'possible throw',
    ThrowConfidence.asyncError => 'async error',
    ThrowConfidence.unknown => 'unknown throwability',
    ThrowConfidence.noObviousThrow => 'no obvious throw',
  };

  bool get isThrowing =>
      this != ThrowConfidence.noObviousThrow && this != ThrowConfidence.unknown;

  bool get isAsync => this == ThrowConfidence.asyncError;

  static ThrowConfidence parse(String value) {
    return switch (value) {
      'definite_throw' => ThrowConfidence.definiteThrow,
      'possible_throw' => ThrowConfidence.possibleThrow,
      'async_error' => ThrowConfidence.asyncError,
      'unknown' => ThrowConfidence.unknown,
      'no_obvious_throw' => ThrowConfidence.noObviousThrow,
      _ => throw FormatException('Unsupported throw confidence "$value".'),
    };
  }
}

enum ThrowSourceKind {
  explicitThrow,
  rethrowExpression,
  nullAssertion,
  asCast,
  indexAccess,
  parseCall,
  decodeCall,
  collectionStateCall,
  futureError,
  completerCompleteError,
  streamAddError,
  awaitedAsyncDependency,
  inferredCall,
  manifestOverride,
  externalCall,
  dynamicInvocation,
  unresolvedCall,
  truncation,
}

final class ThrowSource {
  const ThrowSource({
    required this.kind,
    required this.confidence,
    required this.displayName,
    this.isAsync = false,
    this.exceptionTypes = const [],
  });

  final ThrowSourceKind kind;
  final ThrowConfidence confidence;
  final String displayName;
  final bool isAsync;
  final List<String> exceptionTypes;
}

final class ThrowSummary {
  ThrowSummary({
    required this.elementKey,
    required this.confidence,
    required this.canThrowSynchronously,
    required this.canCompleteWithAsyncError,
    required List<ThrowSource> sources,
    required List<String> dependencyElementKeys,
    required this.complete,
    this.truncationReason,
  }) : sources = List.unmodifiable(sources),
       dependencyElementKeys = List.unmodifiable(dependencyElementKeys);

  final String elementKey;
  final ThrowConfidence confidence;
  final bool canThrowSynchronously;
  final bool canCompleteWithAsyncError;
  final List<ThrowSource> sources;
  final List<String> dependencyElementKeys;
  final bool complete;
  final String? truncationReason;

  factory ThrowSummary.noObviousThrow(String elementKey) {
    return ThrowSummary(
      elementKey: elementKey,
      confidence: ThrowConfidence.noObviousThrow,
      canThrowSynchronously: false,
      canCompleteWithAsyncError: false,
      sources: const [],
      dependencyElementKeys: const [],
      complete: true,
    );
  }

  factory ThrowSummary.unknown(
    String elementKey, {
    required String reason,
    List<ThrowSource> sources = const [],
    List<String> dependencyElementKeys = const [],
    bool complete = false,
  }) {
    return ThrowSummary(
      elementKey: elementKey,
      confidence: ThrowConfidence.unknown,
      canThrowSynchronously: false,
      canCompleteWithAsyncError: false,
      sources: sources,
      dependencyElementKeys: dependencyElementKeys,
      complete: complete,
      truncationReason: reason,
    );
  }

  bool get hasAnyThrowSource =>
      canThrowSynchronously ||
      canCompleteWithAsyncError ||
      confidence == ThrowConfidence.unknown;

  static ThrowSummary merge(
    String elementKey,
    Iterable<ThrowSource> sources, {
    required Iterable<String> dependencyElementKeys,
    required bool complete,
    String? truncationReason,
  }) {
    final collectedSources = List<ThrowSource>.from(sources);
    final canThrowSynchronously = collectedSources.any(
      (source) => !source.isAsync && source.confidence.isThrowing,
    );
    final canCompleteWithAsyncError = collectedSources.any(
      (source) =>
          source.isAsync || source.confidence == ThrowConfidence.asyncError,
    );

    final hasDefinite = collectedSources.any(
      (source) => source.confidence == ThrowConfidence.definiteThrow,
    );
    final hasPossible = collectedSources.any(
      (source) => source.confidence == ThrowConfidence.possibleThrow,
    );
    final hasAsync = collectedSources.any(
      (source) => source.confidence == ThrowConfidence.asyncError,
    );
    final hasUnknown = collectedSources.any(
      (source) => source.confidence == ThrowConfidence.unknown,
    );

    final confidence = hasDefinite
        ? ThrowConfidence.definiteThrow
        : hasPossible
        ? ThrowConfidence.possibleThrow
        : hasAsync
        ? ThrowConfidence.asyncError
        : hasUnknown
        ? ThrowConfidence.unknown
        : ThrowConfidence.noObviousThrow;

    return ThrowSummary(
      elementKey: elementKey,
      confidence: confidence,
      canThrowSynchronously: canThrowSynchronously,
      canCompleteWithAsyncError: canCompleteWithAsyncError,
      sources: collectedSources,
      dependencyElementKeys: dependencyElementKeys.toSet().toList()..sort(),
      complete: complete,
      truncationReason: truncationReason,
    );
  }
}
