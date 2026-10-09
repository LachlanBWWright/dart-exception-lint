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
}
