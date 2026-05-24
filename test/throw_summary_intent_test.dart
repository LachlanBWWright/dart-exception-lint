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
}
