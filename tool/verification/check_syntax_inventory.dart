import 'dart:io';
import 'dart:isolate';
import 'package:yaml/yaml.dart';

import 'package:dart_exception_lint/src/engine/syntax_coverage.dart';

Future<void> main() async {
  final uri = await Isolate.resolvePackageUri(
    Uri.parse('package:analyzer/dart/ast/visitor.g.dart'),
  );
  if (uri == null) throw StateError('Cannot locate installed analyzer');
  final packageRoot = File.fromUri(uri).parent.parent.parent.parent;
  final version =
      (loadYaml(await File('${packageRoot.path}/pubspec.yaml').readAsString())
          as YamlMap)['version'];
  if (version != SyntaxCoverageInventory.analyzerVersion) {
    stderr.writeln(
      'Analyzer $version is not the audited ${SyntaxCoverageInventory.analyzerVersion}; review the models and syntax inventory before updating support.',
    );
    exitCode = 1;
    return;
  }
  final source = await File.fromUri(uri).readAsString();
  final recursive = source.substring(
    source.indexOf('class RecursiveAstVisitor'),
    source.indexOf('class SimpleAstVisitor'),
  );
  final actual = RegExp(
    r'visit(\w+)\(\s*\w+ node\s*,?\s*\)',
  ).allMatches(recursive).map((match) => match.group(1)!).toSet();
  final expected = SyntaxCoverageInventory.nodes.keys.toSet();
  final missing = actual.difference(expected);
  final stale = expected.difference(actual);
  if (missing.isNotEmpty || stale.isNotEmpty) {
    stderr.writeln('Unreviewed syntax: $missing; removed syntax: $stale');
    exitCode = 1;
  } else {
    stdout.writeln(
      '${actual.length} analyzer AST nodes explicitly inventoried.',
    );
  }
}
