/// Tarjan's algorithm, in dependency-first component order. Edges to nodes
/// outside the indexed graph are incomplete boundaries, not recursive members.
List<Set<String>> stronglyConnectedComponents(Map<String, Set<String>> graph) {
  final indices = <String, int>{};
  final lowLinks = <String, int>{};
  final stack = <String>[];
  final onStack = <String>{};
  final components = <Set<String>>[];
  final traversal = <({String node, Iterator<String> edges})>[];
  var nextIndex = 0;

  void enter(String node) {
    indices[node] = nextIndex;
    lowLinks[node] = nextIndex++;
    stack.add(node);
    onStack.add(node);
    traversal.add((node: node, edges: graph[node]!.iterator));
  }

  for (final root in graph.keys) {
    if (indices.containsKey(root)) continue;
    enter(root);
    // The complete indexed graph can contain much longer chains than the
    // per-call inference depth. Keep traversal state off the call stack.
    while (traversal.isNotEmpty) {
      final (node: node, edges: edges) = traversal.last;
      if (edges.moveNext()) {
        final target = edges.current;
        if (!graph.containsKey(target)) continue;
        if (!indices.containsKey(target)) {
          enter(target);
        } else if (onStack.contains(target) &&
            indices[target]! < lowLinks[node]!) {
          lowLinks[node] = indices[target]!;
        }
        continue;
      }

      traversal.removeLast();
      final lowLink = lowLinks[node]!;
      if (traversal.isNotEmpty) {
        final parent = traversal.last.node;
        if (lowLink < lowLinks[parent]!) lowLinks[parent] = lowLink;
      }
      if (lowLink != indices[node]) continue;
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
  return components;
}
