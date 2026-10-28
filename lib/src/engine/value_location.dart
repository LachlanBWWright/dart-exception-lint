/// A statically selected slot within a stored value. Record field names and
/// literal collection keys distinguish independent error obligations. Unknown
/// selections never fall back to consuming an arbitrary sibling slot.
final class ValueLocation {
  ValueLocation(this.root, [Iterable<Object> selectors = const []])
    : selectors = List.unmodifiable(selectors);

  final Object root;
  final List<Object> selectors;

  ValueLocation select(Object selector) =>
      ValueLocation(root, [...selectors, selector]);

  @override
  bool operator ==(Object other) =>
      other is ValueLocation &&
      root == other.root &&
      selectors.length == other.selectors.length &&
      Iterable<int>.generate(
        selectors.length,
      ).every((index) => selectors[index] == other.selectors[index]);

  @override
  int get hashCode => Object.hash(root, Object.hashAll(selectors));
}
