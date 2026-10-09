import 'package:dart_exception_lint/src/analysis/throw_summary.dart';
import 'package:dart_exception_lint/src/engine/exception_effect.dart';
import 'package:test/test.dart';

void main() {
  test('known and unknown effects survive independently in every channel', () {
    for (final channel in ExceptionChannel.values) {
      final summary = ThrowSummary.merge(
        'mixed',
        [
          ThrowSource(
            kind: ThrowSourceKind.explicitThrow,
            confidence: ThrowConfidence.definiteThrow,
            displayName: 'known',
            channel: channel,
          ),
          ThrowSource(
            kind: ThrowSourceKind.externalCall,
            confidence: ThrowConfidence.unknown,
            displayName: 'unknown',
            channel: channel,
          ),
        ],
        dependencyElementKeys: const [],
        complete: false,
      );
      expect(summary.hasUnknownEffects, isTrue);
      expect(summary.effectsFor(channel).map((effect) => effect.certainty), [
        ExceptionCertainty.definite,
        ExceptionCertainty.unknown,
      ]);
    }
  });

  test(
    'incomplete analysis cannot turn a known source into proof of safety',
    () {
      final summary = ThrowSummary.merge(
        'incomplete',
        const [
          ThrowSource(
            kind: ThrowSourceKind.parseCall,
            confidence: ThrowConfidence.possibleThrow,
            displayName: 'parse',
          ),
        ],
        dependencyElementKeys: const [],
        complete: false,
      );
      expect(summary.hasUnknownEffects, isTrue);
      expect(summary.complete, isFalse);
    },
  );

  test('unknown summaries without source details retain an unknown effect', () {
    final summary = ThrowSummary.unknown('external', reason: 'unavailable');
    expect(summary.sources, hasLength(1));
    expect(summary.effects.single.certainty, ExceptionCertainty.unknown);
  });
}
