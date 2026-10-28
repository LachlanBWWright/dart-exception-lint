import 'package:test/test.dart';

import '../tool/verification/semantic_corpus.dart';

void main() {
  test(
    'labeled semantic corpus preserves known and unknown effect channels',
    () async {
      final report = await verifySemanticCorpus();
      expect(report['cases'], greaterThanOrEqualTo(20));
      expect(report['falsePositiveEffectLabels'], 0);
      expect(report['falseNegativeEffectLabels'], 0);
    },
  );
}
