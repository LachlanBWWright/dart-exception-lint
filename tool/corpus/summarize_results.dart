import 'dart:io';

/// Turns the corpus TSV into a stable summary suitable for CI artifacts.
/// Keeping this independent from the analyzer lets a failed package resolution
/// remain distinguishable from a package that produced zero diagnostics.
void main(List<String> arguments) {
  final input = File(
    arguments.isEmpty ? 'tool/corpus/results.tsv' : arguments.first,
  );
  if (!input.existsSync()) {
    stderr.writeln('Corpus result file not found: ${input.path}');
    exitCode = 2;
    return;
  }

  final lines = input
      .readAsLinesSync()
      .where((line) => line.trim().isNotEmpty)
      .toList();
  if (lines.isEmpty) {
    stderr.writeln('Corpus result file is empty: ${input.path}');
    exitCode = 2;
    return;
  }
  final headers = lines.first.split('\t');
  final index = <String, int>{
    for (var i = 0; i < headers.length; i++) headers[i]: i,
  };
  final rows = lines
      .skip(1)
      .map((line) => line.split('\t'))
      .where((parts) => parts.length >= headers.length)
      .toList();
  String value(List<String> row, String name, [String fallback = '']) {
    final position = index[name];
    return position == null || position >= row.length
        ? fallback
        : row[position];
  }

  final counts = <String, int>{};
  final ruleCounts = <String, int>{};
  var packageCount = 0;
  var diagnosticCount = 0;
  for (final row in rows) {
    counts.update(
      value(row, 'status'),
      (value) => value + 1,
      ifAbsent: () => 1,
    );
    packageCount += int.tryParse(value(row, 'packages')) ?? 0;
    diagnosticCount += int.tryParse(value(row, 'diagnostics')) ?? 0;
    for (final packageCounts in value(row, 'rule_counts').split(';')) {
      final separator = packageCounts.indexOf(':');
      if (separator < 0) continue;
      for (final ruleCount
          in packageCounts.substring(separator + 1).split(',')) {
        final parts = ruleCount.split(':');
        if (parts.length != 2) continue;
        final rule = parts.first;
        final amount = int.tryParse(parts.last) ?? 0;
        ruleCounts.update(
          rule,
          (value) => value + amount,
          ifAbsent: () => amount,
        );
      }
    }
  }

  final output = StringBuffer()
    ..writeln('# Corpus evaluation summary')
    ..writeln()
    ..writeln('- Repositories evaluated: ${rows.length}')
    ..writeln('- Package roots analyzed: $packageCount')
    ..writeln('- Linter diagnostics observed: $diagnosticCount')
    ..writeln('- Diagnostics by rule:');
  for (final entry
      in ruleCounts.entries.toList()..sort((a, b) => a.key.compareTo(b.key))) {
    output.writeln('  - `${entry.key}`: ${entry.value}');
  }
  output.writeln('- Status counts:');
  for (final entry
      in counts.entries.toList()..sort((a, b) => a.key.compareTo(b.key))) {
    output.writeln('  - `${entry.key}`: ${entry.value}');
  }
  output
    ..writeln()
    ..writeln('## Per-project results')
    ..writeln()
    ..writeln(
      '| Project | Status | Packages | Diagnostics | Dependency failures | Plugin failures |',
    )
    ..writeln('| --- | --- | ---: | ---: | ---: | ---: |');
  for (final row in rows) {
    output.writeln(
      '| `${value(row, 'id')}` | `${value(row, 'status')}` | '
      '${value(row, 'packages', '0')} | ${value(row, 'diagnostics', '0')} | '
      '${value(row, 'dependency_failures', '0')} | '
      '${value(row, 'plugin_failures', '0')} |',
    );
  }
  final reportPath = arguments.length > 1
      ? arguments[1]
      : 'tool/corpus/summary.md';
  File(reportPath).writeAsStringSync(output.toString());
  stdout.write(output);
}
