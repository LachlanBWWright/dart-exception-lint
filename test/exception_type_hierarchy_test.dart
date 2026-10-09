import 'package:dart_exception_lint/src/analysis/exception_type_hierarchy.dart';
import 'package:test/test.dart';

void main() {
  test('recognizes transitive SDK exception inheritance', () {
    expect(ExceptionTypeHierarchy.isSubtypeName('IndexError', 'Error'), isTrue);
    expect(
      ExceptionTypeHierarchy.isSubtypeName('SocketException', 'IOException'),
      isTrue,
    );
  });

  test('ordinary SDK errors do not implement Exception', () {
    expect(
      ExceptionTypeHierarchy.isSubtypeName('RangeError', 'Exception'),
      isFalse,
    );
    expect(
      ExceptionTypeHierarchy.isSubtypeName('IndexError', 'Exception'),
      isFalse,
    );
    expect(
      ExceptionTypeHierarchy.isSubtypeName(
        'JsonUnsupportedObjectError',
        'Exception',
      ),
      isFalse,
    );
  });

  test('legacy division errors retain both SDK inheritance paths', () {
    for (final parent in ['UnsupportedError', 'Error', 'Exception']) {
      expect(
        ExceptionTypeHierarchy.isSubtypeName(
          'IntegerDivisionByZeroException',
          parent,
        ),
        isTrue,
        reason: parent,
      );
    }
    expect(
      ExceptionTypeHierarchy.isSubtypeName('UnsupportedError', 'Exception'),
      isFalse,
    );
  });

  test('does not invent application exception inheritance', () {
    expect(
      ExceptionTypeHierarchy.isSubtypeName('ApplicationFailure', 'Exception'),
      isFalse,
    );
  });
}
