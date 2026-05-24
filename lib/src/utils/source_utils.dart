import '../config/exception_analysis_options.dart';

bool isGeneratedDartFile(String? path) {
  if (path == null) {
    return false;
  }

  return path.endsWith('.g.dart') ||
      path.endsWith('.freezed.dart') ||
      path.endsWith('.gen.dart');
}

bool isTestDartFile(String? path, {String? packageRoot}) {
  if (path == null || !path.endsWith('.dart')) {
    return false;
  }

  final normalizedPath = _normalizePath(path);
  if (normalizedPath.endsWith('_test.dart')) {
    return true;
  }
  if (normalizedPath.startsWith('test/')) {
    return true;
  }

  final normalizedRoot = packageRoot == null
      ? null
      : _stripTrailingSlash(_normalizePath(packageRoot));
  if (normalizedRoot != null && normalizedPath.startsWith('$normalizedRoot/')) {
    return normalizedPath.startsWith('$normalizedRoot/test/');
  }

  return normalizedPath.contains('/test/');
}

bool shouldSkipLintRuleForFile({
  required String ruleName,
  required ExceptionAnalysisOptions options,
  required String? filePath,
  String? packageRoot,
}) {
  if (isGeneratedDartFile(filePath)) {
    return true;
  }

  return isTestDartFile(filePath, packageRoot: packageRoot) &&
      !options.shouldAnalyzeTestFilesForRule(ruleName);
}

String _normalizePath(String path) {
  return path.replaceAll(r'\', '/').replaceAll(RegExp('/+'), '/');
}

String _stripTrailingSlash(String path) {
  if (path.length <= 1 || !path.endsWith('/')) {
    return path;
  }

  return path.substring(0, path.length - 1);
}
