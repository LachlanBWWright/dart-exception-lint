/// Tarjan's algorithm, in dependency-first component order. Edges to nodes
/// outside the indexed graph are incomplete boundaries, not recursive members.
List<Set<String>> stronglyConnectedComponents(Map<String, Set<String>> graph) {
  final indices = <String, int>{};
  final lowLinks = <String, int>{};
  final stack = <String>[];
  final onStack = <String>{};
  final components = <Set<String>>[];
  var nextIndex = 0;
  void visit(String node) {
    indices[node] = nextIndex;
    lowLinks[node] = nextIndex++;
    stack.add(node);
    onStack.add(node);
    for (final target in graph[node] ?? const <String>{}) {
      if (!graph.containsKey(target)) continue;
      if (!indices.containsKey(target)) {
        visit(target);
        if (lowLinks[target]! < lowLinks[node]!) {
          lowLinks[node] = lowLinks[target]!;
        }
      } else if (onStack.contains(target) &&
          indices[target]! < lowLinks[node]!) {
        lowLinks[node] = indices[target]!;
      }
    }
    if (lowLinks[node] == indices[node]) {
      final component = <String>{};
      String member;
      do {
        member = stack.removeLast();
        onStack.remove(member);
        component.add(member);
      } while (member != node);
      components.add(component);
    }
  }

  for (final node in graph.keys) {
    if (!indices.containsKey(node)) visit(node);
  }
  return components;
}
