/// Produces a stable, compact label for diagnostic messages.
String exceptionTypeLabel(Iterable<String> types) {
  final distinct =
      types.where((type) => type.trim().isNotEmpty).toSet().toList()..sort();
  return distinct.isEmpty ? 'an exception' : distinct.join(' or ');
}
