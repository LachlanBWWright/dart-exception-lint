import 'package:dart_exception_lint/src/analysis/exception_type_labels.dart';
import 'package:test/test.dart';

void main() {
  test('removes duplicates and sorts exception names', () {
    expect(
      exceptionTypeLabel(['StateError', 'Exception', 'StateError']),
      'Exception or StateError',
    );
  });

  test('uses a useful fallback for open exception sets', () {
    expect(exceptionTypeLabel(const []), 'an exception');
    expect(exceptionTypeLabel(['']), 'an exception');
  });
}
