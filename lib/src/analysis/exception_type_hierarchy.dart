/// Conservative SDK exception inheritance used when analyzer type identity is
/// unavailable in a source summary. Unknown application exceptions are never
/// guessed; only stable SDK relationships are included here.
final class ExceptionTypeHierarchy {
  const ExceptionTypeHierarchy._();

  static bool isSubtypeName(String thrownName, String caughtName) {
    if (thrownName == caughtName) return true;
    final seen = <String>{};
    final pending = <String>[thrownName];
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      if (!seen.add(current)) continue;
      final parents = _parents[current] ?? const <String>[];
      if (parents.contains(caughtName)) return true;
      pending.addAll(parents);
    }
    return false;
  }

  static const _parents = <String, List<String>>{
    'RangeError': ['ArgumentError', 'Exception'],
    'IndexError': ['RangeError', 'ArgumentError', 'Exception'],
    'FormatException': ['Exception'],
    'StateError': ['Error'],
    'ConcurrentModificationError': ['Error'],
    'AssertionError': ['Error'],
    'TypeError': ['Error'],
    'CastError': ['TypeError', 'Error'],
    'LateInitializationError': ['Error'],
    'IntegerDivisionByZeroException': ['Exception'],
    'FileSystemException': ['IOException', 'Exception'],
    'SocketException': ['IOException', 'Exception'],
    'HttpException': ['IOException', 'Exception'],
    'WebSocketException': ['IOException', 'Exception'],
    'IsolateSpawnException': ['Exception'],
    'JsonUnsupportedObjectError': ['ArgumentError', 'Exception'],
    'TimeoutException': ['Exception'],
    'SendPortException': ['Exception'],
  };
}
