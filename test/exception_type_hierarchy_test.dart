import 'package:dart_exception_lint/src/analysis/exception_type_hierarchy.dart';
import 'package:test/test.dart';

void main() {
  test('recognizes transitive SDK exception inheritance', () {
    expect(
      ExceptionTypeHierarchy.isSubtypeName('IndexError', 'Exception'),
      isTrue,
    );
    expect(
      ExceptionTypeHierarchy.isSubtypeName('SocketException', 'IOException'),
      isTrue,
    );
  });

  test('does not invent application exception inheritance', () {
    expect(
      ExceptionTypeHierarchy.isSubtypeName('ApplicationFailure', 'Exception'),
      isFalse,
    );
  });
}
