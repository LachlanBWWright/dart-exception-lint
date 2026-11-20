import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Verify the current workspace contents as a clean release snapshot, without
/// committing the user's worktree or publishing anything.
Future<void> main() async {
  final root = Directory.current.path;
  final files = await Process.run('git', [
    'ls-files',
    '--cached',
    '--others',
    '--exclude-standard',
    '-z',
  ], workingDirectory: root);
  if (files.exitCode != 0) throw StateError('${files.stderr}');
  final directory = await Directory.systemTemp.createTemp('exception-release-');
  try {
    final snapshot = Directory(p.join(directory.path, 'plugin'));
    await snapshot.create();
    for (final relative
        in (files.stdout as String)
            .split('\x00')
            .where((file) => file.isNotEmpty)
            .toSet()) {
      final source = File(p.join(root, relative));
      if (!await source.exists()) continue;
      final destination = File(p.join(snapshot.path, relative));
      await destination.parent.create(recursive: true);
      await source.copy(destination.path);
    }
    Future<ProcessResult> run(
      String executable,
      List<String> args,
      String cwd,
    ) async {
      final result = await Process.run(executable, args, workingDirectory: cwd);
      if (result.exitCode != 0) {
        throw StateError(
          '$executable ${args.join(' ')} failed (${result.exitCode}):\n${result.stdout}\n${result.stderr}',
        );
      }
      return result;
    }

    await run('git', ['init', '--quiet'], snapshot.path);
    await run('git', ['add', '.'], snapshot.path);
    await run('git', [
      '-c',
      'user.name=Release verification',
      '-c',
      'user.email=verification@example.invalid',
      'commit',
      '--quiet',
      '-m',
      'Temporary verification snapshot',
    ], snapshot.path);
    final dart = Platform.resolvedExecutable;
    await run(dart, ['pub', 'get'], snapshot.path);
    final publish = await run(dart, [
      'pub',
      'publish',
      '--dry-run',
    ], snapshot.path);
    stdout.writeln(
      (publish.stdout as String)
          .split('\n')
          .where(
            (line) => line.contains('Package has') || line.contains('warning'),
          )
          .join('\n'),
    );

    final consumer = Directory(p.join(directory.path, 'consumer'));
    await consumer.create();
    await File(
      p.join(consumer.path, 'pubspec.yaml'),
    ).writeAsString('name: release_consumer\nenvironment:\n  sdk: ^3.11.0\n');
    final source = File(p.join(consumer.path, 'lib', 'main.dart'));
    await source.parent.create();
    await source.writeAsString(
      "void failure() { throw 'failure'; }\nvoid caller() { failure(); }\n",
    );
    await run(dart, ['pub', 'get'], consumer.path);
    // The standalone CLI must work before the target enables the plugin.
    final baseline = p.join(directory.path, 'baseline.json');
    final cliArgs = [
      'run',
      'bin/dart_exception_lint.dart',
      '--root',
      consumer.path,
      'lib',
      '--write-baseline',
      baseline,
    ];
    final cli = await Process.run(
      dart,
      cliArgs,
      workingDirectory: snapshot.path,
    );
    final report = jsonDecode(cli.stdout as String) as Map<String, dynamic>;
    if (cli.exitCode != 1 ||
        report['status'] != 'completed' ||
        !(report['findings'] as List).any(
          (finding) => finding['symbol'] == 'function:caller',
        )) {
      throw StateError(
        'Standalone CLI did not report consumer effects:\n${cli.stdout}\n${cli.stderr}',
      );
    }
    final comparison = await run(dart, [
      'run',
      'bin/dart_exception_lint.dart',
      '--root',
      consumer.path,
      'lib',
      '--baseline',
      baseline,
    ], snapshot.path);
    final compared =
        jsonDecode(comparison.stdout as String) as Map<String, dynamic>;
    if (compared['baseline']['new'] != 0 ||
        compared['baseline']['existing'] == 0) {
      throw StateError(
        'Standalone CLI baseline comparison failed: ${comparison.stdout}',
      );
    }
    await File(p.join(consumer.path, 'analysis_options.yaml')).writeAsString(
      'plugins:\n  dart_exception_lint:\n    path: ${snapshot.path}\n',
    );
    final analysis = await Process.run(dart, [
      'analyze',
      '--fatal-infos',
    ], workingDirectory: consumer.path);
    final output = '${analysis.stdout}\n${analysis.stderr}';
    if (analysis.exitCode == 0 ||
        !output.contains('no_manual_throw') ||
        !output.contains('catch_inferred_throwing_calls')) {
      throw StateError(
        'Enable-only consumer did not enforce exception policy:\n$output',
      );
    }
    stdout.writeln(
      'Clean snapshot dry-run, standalone CLI/baseline, and enable-only consumer enforcement passed.',
    );
  } finally {
    await directory.delete(recursive: true);
  }
}
