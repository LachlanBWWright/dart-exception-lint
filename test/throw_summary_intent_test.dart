import 'package:dart_exception_lint/src/analysis/throw_summary.dart';
import 'package:dart_exception_lint/src/result.dart';
import 'package:test/test.dart';

void main() {
  test('parses throw intent wire values', () {
    expect(
      ThrowIntentExtension.tryParse('deliberate'),
      isA<Ok<ThrowIntent, WireParseFailure>>().having(
        (ok) => ok.value,
        'value',
        ThrowIntent.deliberate,
      ),
    );
    expect(
      ThrowIntentExtension.tryParse('probable'),
      isA<Ok<ThrowIntent, WireParseFailure>>().having(
        (ok) => ok.value,
        'value',
        ThrowIntent.probable,
      ),
    );
    expect(
      ThrowIntentExtension.tryParse('possible'),
      isA<Ok<ThrowIntent, WireParseFailure>>().having(
        (ok) => ok.value,
        'value',
        ThrowIntent.possible,
      ),
    );
    expect(
      ThrowIntentExtension.tryParse('unknown'),
      isA<Ok<ThrowIntent, WireParseFailure>>().having(
        (ok) => ok.value,
        'value',
        ThrowIntent.unknown,
      ),
    );
  });

  test('returns error for unsupported throw intent wire value', () {
    final parsed = ThrowIntentExtension.tryParse('invalid');
    expect(parsed, isA<Err<ThrowIntent, WireParseFailure>>());
  });

  test('returns error for unsupported throw confidence wire value', () {
    final parsed = ThrowConfidenceExtension.tryParse('invalid');
    expect(parsed, isA<Err<ThrowConfidence, WireParseFailure>>());
  });

  test('checks intent threshold ordering', () {
    expect(ThrowIntent.deliberate.meets(ThrowIntent.deliberate), isTrue);
    expect(ThrowIntent.deliberate.meets(ThrowIntent.unknown), isTrue);
    expect(ThrowIntent.possible.meets(ThrowIntent.probable), isFalse);
    expect(ThrowIntent.unknown.meets(ThrowIntent.possible), isFalse);
  });

  test('maps source kinds to default intents', () {
    expect(ThrowSourceKind.explicitThrow.defaultIntent, ThrowIntent.deliberate);
    expect(ThrowSourceKind.assertion.defaultIntent, ThrowIntent.possible);
    expect(ThrowSourceKind.nullAssertion.defaultIntent, ThrowIntent.probable);
    expect(ThrowSourceKind.parseCall.defaultIntent, ThrowIntent.possible);
    expect(ThrowSourceKind.unresolvedCall.defaultIntent, ThrowIntent.unknown);
  });

  test('source explicit intent overrides kind default', () {
    const source = ThrowSource(
      kind: ThrowSourceKind.inferredCall,
      confidence: ThrowConfidence.definiteThrow,
      displayName: 'helper',
      intent: ThrowIntent.deliberate,
    );

    expect(source.effectiveIntent, ThrowIntent.deliberate);
  });

  test(
    'merges duplicate sources and widens when source budget is exceeded',
    () {
      const source = ThrowSource(
        kind: ThrowSourceKind.parseCall,
        confidence: ThrowConfidence.possibleThrow,
        displayName: 'int.parse',
      );
      final summary = ThrowSummary.merge(
        'test',
        [
          source,
          source,
          const ThrowSource(
            kind: ThrowSourceKind.decodeCall,
            confidence: ThrowConfidence.possibleThrow,
            displayName: 'jsonDecode',
          ),
        ],
        dependencyElementKeys: const [],
        complete: true,
        maxSources: 1,
      );

      expect(summary.sources, hasLength(2));
      expect(summary.sources.last.kind, ThrowSourceKind.truncation);
      expect(summary.complete, isFalse);
      expect(summary.truncationReason, 'max_sources_per_summary');
    },
  );

  test('defensively clamps a negative source budget', () {
    final summary = ThrowSummary.merge(
      'negative-budget',
      const [
        ThrowSource(
          kind: ThrowSourceKind.parseCall,
          confidence: ThrowConfidence.possibleThrow,
          displayName: 'parse',
        ),
      ],
      dependencyElementKeys: const [],
      complete: true,
      maxSources: -1,
    );

    expect(summary.complete, isFalse);
    expect(summary.truncationReason, 'max_sources_per_summary');
    expect(summary.confidence, ThrowConfidence.unknown);
  });

  test('retains same-named sources from different origins', () {
    final summary = ThrowSummary.merge(
      'origins',
      const [
        ThrowSource(
          kind: ThrowSourceKind.inferredCall,
          confidence: ThrowConfidence.possibleThrow,
          displayName: 'helper',
          origin: ThrowOrigin(displayName: 'helper', filePath: 'a.dart'),
        ),
        ThrowSource(
          kind: ThrowSourceKind.inferredCall,
          confidence: ThrowConfidence.possibleThrow,
          displayName: 'helper',
          origin: ThrowOrigin(displayName: 'helper', filePath: 'b.dart'),
        ),
      ],
      dependencyElementKeys: const [],
      complete: true,
    );

    expect(summary.sources, hasLength(2));
  });
}
