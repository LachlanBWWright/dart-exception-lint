import 'package:analyzer/dart/element/type.dart';
import '../result.dart';
import '../engine/exception_effect.dart';

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

/// When an effect becomes observable relative to the invocation.
enum ThrowTiming { synchronous, deferred, asynchronous }

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
  assertion,
  nullAssertion,
  asCast,
  lateInitializationRead,
  arithmeticOperation,
  indexAccess,
  parseCall,
  decodeCall,
  collectionStateCall,
  futureError,
  completerCompleteError,
  streamAddError,
  asyncOperation,
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
    ThrowSourceKind.assertion => ThrowIntent.possible,
    ThrowSourceKind.asyncOperation => ThrowIntent.possible,
    ThrowSourceKind.nullAssertion ||
    ThrowSourceKind.asCast => ThrowIntent.probable,
    ThrowSourceKind.lateInitializationRead ||
    ThrowSourceKind.arithmeticOperation => ThrowIntent.possible,
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
    this.timing,
    this.channel,
    this.certainty,
    this.exceptionTypes = const [],
    this.resolvedExceptionTypes = const [],
    this.exceptionSupertypes = const {},
    this.origin,
  });

  final ThrowSourceKind kind;
  final ThrowConfidence confidence;
  final String displayName;
  final ThrowIntent? intent;
  final bool isAsync;
  final ThrowTiming? timing;
  final ExceptionChannel? channel;
  final ExceptionCertainty? certainty;

  /// Independently possible thrown types; an empty list means unknown types.
  final List<String> exceptionTypes;
  final List<DartType> resolvedExceptionTypes;

  /// Known ancestors of each thrown type, retained through inferred calls.
  final Map<String, List<String>> exceptionSupertypes;
  final ThrowOrigin? origin;

  ThrowIntent get effectiveIntent => intent ?? kind.defaultIntent;

  ThrowTiming get effectiveTiming =>
      timing ??
      (isAsync || confidence == ThrowConfidence.asyncError
          ? ThrowTiming.asynchronous
          : ThrowTiming.synchronous);
}

/// The concrete source that caused an effect, retained through propagation.
final class ThrowOrigin {
  const ThrowOrigin({
    required this.displayName,
    this.filePath,
    this.offset,
    this.length,
  });

  final String displayName;
  final String? filePath;
  final int? offset;
  final int? length;
}

final class ThrowSummary {
  ThrowSummary({
    required this.elementKey,
    required this.confidence,
    required this.canThrowSynchronously,
    this.canCompleteWithDeferredError = false,
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
  final bool canCompleteWithDeferredError;
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
      canCompleteWithDeferredError: false,
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
      canCompleteWithDeferredError: false,
      canCompleteWithAsyncError: false,
      sources: sources.isEmpty
          ? [
              ThrowSource(
                kind: ThrowSourceKind.unresolvedCall,
                confidence: ThrowConfidence.unknown,
                displayName: elementKey,
              ),
            ]
          : sources,
      dependencyElementKeys: dependencyElementKeys,
      complete: complete,
      truncationReason: reason,
    );
  }

  Iterable<ExceptionEffect> get effects =>
      sources.map(ExceptionEffect.fromSource);

  bool get hasUnknownEffects =>
      sources.any((source) => source.confidence == ThrowConfidence.unknown);

  Iterable<ExceptionEffect> effectsFor(ExceptionChannel channel) =>
      effects.where((effect) => effect.channel == channel);

  bool get hasAnyThrowSource =>
      canThrowSynchronously ||
      canCompleteWithDeferredError ||
      canCompleteWithAsyncError ||
      hasUnknownEffects;

  static ThrowSummary merge(
    String elementKey,
    Iterable<ThrowSource> sources, {
    required Iterable<String> dependencyElementKeys,
    required bool complete,
    String? truncationReason,
    int maxSources = 64,
  }) {
    final uniqueSources = <String, ThrowSource>{};
    for (final source in sources) {
      if (source.confidence == ThrowConfidence.noObviousThrow) continue;
      final key = [
        source.kind,
        source.confidence,
        source.displayName,
        source.effectiveTiming,
        source.channel,
        source.certainty,
        source.resolvedExceptionTypes,
        source.exceptionTypes.join(','),
        source.exceptionSupertypes,
        source.intent,
        source.origin?.displayName,
        source.origin?.filePath,
        source.origin?.offset,
        source.origin?.length,
      ].join('|');
      uniqueSources.putIfAbsent(key, () => source);
    }
    if (!complete &&
        !uniqueSources.values.any(
          (source) => source.confidence == ThrowConfidence.unknown,
        )) {
      uniqueSources['incomplete'] = ThrowSource(
        kind: ThrowSourceKind.unresolvedCall,
        confidence: ThrowConfidence.unknown,
        displayName: truncationReason ?? 'incomplete exception analysis',
      );
    }
    final sourceLimit = maxSources < 0 ? 0 : maxSources;
    final boundedSources = uniqueSources.values.take(sourceLimit).toList();
    final wasTruncated = uniqueSources.length > boundedSources.length;
    if (wasTruncated) {
      final omittedChannels = uniqueSources.values
          .skip(sourceLimit)
          .map((source) => ExceptionEffect.fromSource(source).channel)
          .toSet();
      // Delivery channels are independent: a synchronous catch must not hide a
      // scheduled failure merely because its concrete source exceeded a budget.
      // At most one unknown sentinel per channel survives outside the budget.
      for (final channel in ExceptionChannel.values) {
        if (!omittedChannels.contains(channel)) continue;
        final timing = switch (channel) {
          ExceptionChannel.synchronous => ThrowTiming.synchronous,
          ExceptionChannel.deferred => ThrowTiming.deferred,
          _ => ThrowTiming.asynchronous,
        };
        boundedSources.add(
          ThrowSource(
            kind: ThrowSourceKind.truncation,
            confidence: ThrowConfidence.unknown,
            displayName: 'additional exception sources omitted',
            channel: channel,
            certainty: ExceptionCertainty.unknown,
            timing: timing,
            isAsync: timing == ThrowTiming.asynchronous,
          ),
        );
      }
    }
    final collectedSources = boundedSources;
    final canThrowSynchronously = collectedSources.any(
      (source) =>
          source.effectiveTiming == ThrowTiming.synchronous &&
          source.confidence.isThrowing,
    );
    final canCompleteWithDeferredError = collectedSources.any(
      (source) =>
          source.effectiveTiming == ThrowTiming.deferred &&
          source.confidence.isThrowing,
    );
    final canCompleteWithAsyncError = collectedSources.any(
      (source) => source.effectiveTiming == ThrowTiming.asynchronous,
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
      canCompleteWithDeferredError: canCompleteWithDeferredError,
      canCompleteWithAsyncError: canCompleteWithAsyncError,
      sources: collectedSources,
      dependencyElementKeys: dependencyElementKeys.toSet().toList()..sort(),
      complete: complete && !wasTruncated,
      truncationReason: wasTruncated
          ? (truncationReason ?? 'max_sources_per_summary')
          : truncationReason,
    );
  }
}
