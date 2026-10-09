import 'dart:io';
import 'dart:isolate';

import 'package:yaml/yaml.dart';

import 'syntax_coverage.dart';

/// An unreviewed analyzer/SDK must not look like a verified clean analysis.
final class AnalysisCompatibility {
  static Future<void>? _initialization;
  static String? warning;

  static String? checkVersions(String analyzer, String sdk) {
    if (analyzer != SyntaxCoverageInventory.analyzerVersion) {
      return 'Analyzer $analyzer has not been audited; supported analyzer is ${SyntaxCoverageInventory.analyzerVersion}.';
    }
    final version = RegExp(r'^(\d+)\.(\d+)\.(\d+)').firstMatch(sdk);
    if (version == null ||
        version.group(1) != '3' ||
        !const {'11', '12', '13'}.contains(version.group(2))) {
      return 'Dart $sdk has not been audited; supported SDK series are 3.11–3.13.';
    }
    return null;
  }

  static Future<void> initialize() => _initialization ??= _load();

  static Future<void> _load() async {
    try {
      final uri = await Isolate.resolvePackageUri(
        Uri.parse('package:analyzer/dart/ast/visitor.g.dart'),
      );
      if (uri == null) {
        warning =
            'Cannot establish the analyzer version used for exception analysis.';
        return;
      }
      final root = File.fromUri(uri).parent.parent.parent.parent;
      final manifest = loadYaml(
        await File('${root.path}/pubspec.yaml').readAsString(),
      );
      warning = checkVersions(
        manifest is YamlMap ? '${manifest['version']}' : 'unknown',
        Platform.version,
      );
    } on FileSystemException catch (error) {
      warning =
          'Cannot establish exception-analysis compatibility: ${error.message}';
    } on FormatException catch (error) {
      warning =
          'Cannot establish exception-analysis compatibility: ${error.message}';
    }
  }
}
