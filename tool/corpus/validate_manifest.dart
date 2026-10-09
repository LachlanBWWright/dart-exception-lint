import 'dart:io';

void main() {
  final file = File('tool/corpus/projects.tsv');
  final seenIds = <String>{};
  final seenUrls = <String>{};
  var valid = true;
  var entries = 0;
  final lines = file.readAsLinesSync();
  for (var lineNumber = 1; lineNumber <= lines.length; lineNumber++) {
    final line = lines[lineNumber - 1];
    if (line.trim().isEmpty || line.startsWith('#')) continue;
    final fields = line.split('\t');
    if (fields.length != 4 || fields.any((field) => field.trim().isEmpty)) {
      stderr.writeln('Invalid corpus row at line $lineNumber: $line');
      valid = false;
      continue;
    }
    entries++;
    if (!seenIds.add(fields[0])) {
      stderr.writeln('Duplicate corpus id: ${fields[0]}');
      valid = false;
    }
    if (!seenUrls.add(fields[1])) {
      stderr.writeln('Duplicate repository URL: ${fields[1]}');
      valid = false;
    }
    if (fields[1] != fields[1].trim() ||
        !fields[1].startsWith('https://github.com/') ||
        !fields[1].endsWith('.git')) {
      stderr.writeln('Unsupported repository URL at line $lineNumber');
      valid = false;
    }
    if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(fields[3])) {
      stderr.writeln(
        'Corpus revision must be a full commit hash at line $lineNumber',
      );
      valid = false;
    }
    if (fields[2] != 'dart' && fields[2] != 'flutter') {
      stderr.writeln('Unsupported package manager at line $lineNumber');
      valid = false;
    }
  }
  if (entries < 50) {
    stderr.writeln(
      'Corpus contains only $entries entries; at least 50 required.',
    );
    valid = false;
  }
  if (!valid) exitCode = 1;
  stdout.writeln('Validated $entries corpus entries.');
}
