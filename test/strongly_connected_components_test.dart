import 'package:dart_exception_lint/src/engine/strongly_connected_components.dart';
import 'package:test/test.dart';

void main() {
  test('keeps callers outside recursive components in dependency order', () {
    final components = stronglyConnectedComponents({
      'caller': {'a'},
      'a': {'b'},
      'b': {'a', 'leaf'},
      'leaf': {},
      'self': {'self'},
      'other': {'unindexed'},
    });
    expect(components, [
      {'leaf'},
      {'a', 'b'},
      {'caller'},
      {'self'},
      {'other'},
    ]);
  });
  test('does not merge distinct cycles connected by a one-way edge', () {
    expect(
      stronglyConnectedComponents({
        'a': {'b'},
        'b': {'a', 'c'},
        'c': {'d'},
        'd': {'c'},
      }),
      [
        {'c', 'd'},
        {'a', 'b'},
      ],
    );
  });

  test('walks a long dependency chain without consuming the call stack', () {
    const depth = 20000;
    final components = stronglyConnectedComponents({
      for (var index = 0; index < depth; index++) '$index': {'${index + 1}'},
      '$depth': {'${depth - 1}'},
    });
    expect(components, hasLength(depth));
    expect(components.first, {'$depth', '${depth - 1}'});
    expect(components.last, {'0'});
  });
}
