bool isGeneratedDartFile(String? path) {
  if (path == null) {
    return false;
  }

  return path.endsWith('.g.dart') ||
      path.endsWith('.freezed.dart') ||
      path.endsWith('.gen.dart');
}
