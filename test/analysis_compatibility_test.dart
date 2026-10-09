import 'package:dart_exception_lint/src/engine/analysis_compatibility.dart';
import 'package:test/test.dart';

void main() {
  test('supported SDK series with the audited analyzer are accepted', () {
    for (final version in ['3.11.0', '3.12.0', '3.13.0 (stable)']) {
      expect(AnalysisCompatibility.checkVersions('14.1.0', version), isNull);
    }
  });
  test(
    'unreviewed analyzer versions stay visible even within package bounds',
    () {
      expect(
        AnalysisCompatibility.checkVersions('14.1.1', '3.13.0'),
        contains('not been audited'),
      );
    },
  );
  test('old, future and unreadable SDK versions stay visible', () {
    for (final version in ['3.10.0', '3.14.0', '4.0.0', 'unknown']) {
      expect(AnalysisCompatibility.checkVersions('14.1.0', version), isNotNull);
    }
  });
}
