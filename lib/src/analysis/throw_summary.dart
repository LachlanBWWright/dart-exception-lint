import '../result.dart';

sealed class WireParseFailure {
  const WireParseFailure(this.value);

  final String value;
}

final class ThrowConfidenceWireParseFailure extends WireParseFailure {
  const ThrowConfidenceWireParseFailure(super.value);
}

final class ThrowIntentWireParseFailure extends WireParseFailure {
  const ThrowIntentWireParseFailure(super.value);
}

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

  static Result<ThrowConfidence, WireParseFailure> tryParse(String value) {
    return switch (value) {
      'definite_throw' => const Ok(ThrowConfidence.definiteThrow),
      'possible_throw' => const Ok(ThrowConfidence.possibleThrow),
      'async_error' => const Ok(ThrowConfidence.asyncError),
      'unknown' => const Ok(ThrowConfidence.unknown),
      'no_obvious_throw' => const Ok(ThrowConfidence.noObviousThrow),
      _ => Err(ThrowConfidenceWireParseFailure(value)),
    };
  }
}

enum ThrowIntent { deliberate, probable, possible, unknown }

extension ThrowIntentExtension on ThrowIntent {
  String get wireName => switch (this) {
    ThrowIntent.deliberate => 'deliberate',
    ThrowIntent.probable => 'probable',
    ThrowIntent.possible => 'possible',
    ThrowIntent.unknown => 'unknown',
  };

  bool meets(ThrowIntent minimum) {
    return index <= minimum.index;
  }

  static Result<ThrowIntent, WireParseFailure> tryParse(String value) {
    return switch (value) {
      'deliberate' => const Ok(ThrowIntent.deliberate),
      'probable' => const Ok(ThrowIntent.probable),
      'possible' => const Ok(ThrowIntent.possible),
      'unknown' => const Ok(ThrowIntent.unknown),
      _ => Err(ThrowIntentWireParseFailure(value)),
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

extension ThrowSourceKindExtension on ThrowSourceKind {
  ThrowIntent get defaultIntent => switch (this) {
    ThrowSourceKind.explicitThrow ||
    ThrowSourceKind.rethrowExpression ||
    ThrowSourceKind.futureError ||
    ThrowSourceKind.completerCompleteError ||
    ThrowSourceKind.streamAddError ||
    ThrowSourceKind.manifestOverride => ThrowIntent.deliberate,
    ThrowSourceKind.nullAssertion ||
    ThrowSourceKind.asCast => ThrowIntent.probable,
    ThrowSourceKind.indexAccess ||
    ThrowSourceKind.parseCall ||
    ThrowSourceKind.decodeCall ||
    ThrowSourceKind.collectionStateCall => ThrowIntent.possible,
    ThrowSourceKind.externalCall ||
    ThrowSourceKind.dynamicInvocation ||
    ThrowSourceKind.unresolvedCall ||
    ThrowSourceKind.truncation ||
    ThrowSourceKind.awaitedAsyncDependency ||
    ThrowSourceKind.inferredCall => ThrowIntent.unknown,
  };
}

final class ThrowSource {
  const ThrowSource({
    required this.kind,
    required this.confidence,
    required this.displayName,
    this.intent,
    this.isAsync = false,
    this.exceptionTypes = const [],
  });

  final ThrowSourceKind kind;
  final ThrowConfidence confidence;
  final String displayName;
  final ThrowIntent? intent;
  final bool isAsync;
  final List<String> exceptionTypes;

  ThrowIntent get effectiveIntent => intent ?? kind.defaultIntent;
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
