import 'package:dart_exception_lint/src/analysis/throw_summary.dart';
import 'package:dart_exception_lint/src/engine/exception_effect.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Source budget preserves omitted scheduled and other delivery channels',
    () {
      const sync = ThrowSource(
        kind: ThrowSourceKind.explicitThrow,
        confidence: ThrowConfidence.definiteThrow,
        displayName: 'synchronous failure',
        exceptionTypes: ['String'],
      );
      final summary = _merge([
        sync,
        _source(ExceptionChannel.scheduled, 0),
        _source(ExceptionChannel.scheduled, 1),
        _source(ExceptionChannel.future, 0),
        _source(ExceptionChannel.stream, 0),
        _source(ExceptionChannel.deferred, 0),
      ], maxSources: 1);
      expect(summary.sources.first, same(sync));
      expect(summary.sources, hasLength(5));
      expect(summary.complete, isFalse);
      expect(summary.canThrowSynchronously, isTrue);
      expect(summary.canCompleteWithAsyncError, isTrue);
      expect(summary.truncationReason, 'max_sources_per_summary');
      expect(
        summary.effectsFor(ExceptionChannel.synchronous).single.certainty,
        ExceptionCertainty.definite,
      );
      for (final channel in ExceptionChannel.values.where(
        (channel) => channel != ExceptionChannel.synchronous,
      )) {
        final effect = summary.effectsFor(channel).single;
        expect(effect.certainty, ExceptionCertainty.unknown);
        expect(effect.source.kind, ThrowSourceKind.truncation);
        expect(effect.source.exceptionTypes, isEmpty);
      }
      expect(
        summary
            .effectsFor(ExceptionChannel.scheduled)
            .single
            .source
            .effectiveTiming,
        ThrowTiming.asynchronous,
      );
      expect(
        summary
            .effectsFor(ExceptionChannel.deferred)
            .single
            .source
            .effectiveTiming,
        ThrowTiming.deferred,
      );
    },
  );

  test('Zero and negative budgets retain at most five channel sentinels', () {
    final sources = [
      for (var index = 0; index < 50; index++)
        for (final channel in ExceptionChannel.values) _source(channel, index),
    ];
    for (final maxSources in [0, -1]) {
      final summary = _merge(sources, maxSources: maxSources);
      expect(summary.sources, hasLength(ExceptionChannel.values.length));
      expect(
        summary.effects.map((effect) => effect.channel),
        ExceptionChannel.values,
      );
      expect(
        summary.effects.every(
          (effect) => effect.certainty == ExceptionCertainty.unknown,
        ),
        isTrue,
      );
      expect(summary.confidence, ThrowConfidence.unknown);
      expect(summary.complete, isFalse);
    }
  });

  test(
    'Legacy timing determines omitted channels without inventing sync effects',
    () {
      final summary = _merge(const [
        ThrowSource(
          kind: ThrowSourceKind.futureError,
          confidence: ThrowConfidence.asyncError,
          displayName: 'legacy future',
        ),
        ThrowSource(
          kind: ThrowSourceKind.inferredCall,
          confidence: ThrowConfidence.possibleThrow,
          timing: ThrowTiming.deferred,
          displayName: 'legacy deferred',
        ),
      ], maxSources: 0);
      expect(summary.sources, hasLength(2));
      expect(summary.effects.map((effect) => effect.channel), [
        ExceptionChannel.future,
        ExceptionChannel.deferred,
      ]);
      expect(summary.effectsFor(ExceptionChannel.synchronous), isEmpty);
      expect(summary.canThrowSynchronously, isFalse);
    },
  );

  test('Explicit channels override legacy timing during budget widening', () {
    final summary = _merge(const [
      ThrowSource(
        kind: ThrowSourceKind.inferredCall,
        confidence: ThrowConfidence.possibleThrow,
        channel: ExceptionChannel.scheduled,
        timing: ThrowTiming.synchronous,
        displayName: 'explicit scheduled',
      ),
    ], maxSources: 0);
    expect(summary.sources, hasLength(1));
    expect(summary.effects.single.channel, ExceptionChannel.scheduled);
    expect(summary.sources.single.isAsync, isTrue);
    expect(summary.sources.single.effectiveTiming, ThrowTiming.asynchronous);
    expect(summary.canThrowSynchronously, isFalse);
    expect(summary.canCompleteWithAsyncError, isTrue);
  });
}

ThrowSource _source(ExceptionChannel channel, int index) => ThrowSource(
  kind: ThrowSourceKind.inferredCall,
  confidence: ThrowConfidence.possibleThrow,
  displayName: '${channel.name} failure $index',
  channel: channel,
);

ThrowSummary _merge(Iterable<ThrowSource> sources, {required int maxSources}) =>
    ThrowSummary.merge(
      'budget',
      sources,
      dependencyElementKeys: const [],
      complete: true,
      maxSources: maxSources,
    );
