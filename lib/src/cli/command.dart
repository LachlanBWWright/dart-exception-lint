import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'analyze.dart';
import 'report.dart';

const _usage =
    '''Usage: dart run dart_exception_lint [options] [files or directories]

Analyze escaping callable effects; JSON is written to stdout by default.
Paths are relative to --root (default: current directory).

  --root PATH            Project/workspace root (run dart pub get there first)
  --format json|text     Output format (default: json)
  --fail-on all|known|unknown|none  Fail on new, non-exempt findings (default: all)
  --baseline PATH        Compare against a previous completed JSON report
  --write-baseline PATH  Save this completed report as a baseline
  --changed-since REF    Report tracked changes against REF plus untracked files
  --timeout SECONDS     Wall-clock budget (default: 120)
  --max-rss-mb MB        Sampled process RSS budget (default: 2048)
  --help                Show this help

Exit codes: 0 policy passed, 1 new findings, 2 failed/budget exceeded,
64 invalid arguments. Unknown effects are findings, not execution failures.
''';

Future<int> runCommand(
  List<String> arguments,
  IOSink output,
  IOSink errorOutput,
) async {
  _Options options;
  try {
    final parsed = _Options.parse(arguments);
    if (parsed == null) {
      output.write(_usage);
      return 0;
    }
    options = parsed;
  } on FormatException catch (error) {
    output.writeln(
      jsonEncode(
        emptyReport('failed', 'invalid_arguments', error.message)
          ..['exitCode'] = 64,
      ),
    );
    return 64;
  }
  Map<String, dynamic> report;
  final watch = Stopwatch()..start();
  try {
    final baseline = options.baseline == null
        ? null
        : jsonDecode(await File(options.baseline!).readAsString());
    final changes = options.changedSince == null
        ? null
        : await _changedFiles(options, watch);
    final request = <String, dynamic>{
      'root': options.root,
      'paths': options.paths,
      'explicitFiles': options.explicitFiles,
      'changedSince': options.changedSince,
      'changedFiles': changes?.files,
      'changedRevision': changes?.revision,
    };
    report = await _boundedAnalysis(request, options, watch);
    if (report['status'] == 'completed') {
      if (options.baseline != null) compareBaseline(report, baseline);
      if (options.writeBaseline case final path?) {
        _annotateReport(report, options, watch);
        final file = File(path);
        await file.parent.create(recursive: true);
        final temporary = File('$path.tmp-$pid');
        try {
          await temporary.writeAsString('${jsonEncode(report)}\n', flush: true);
          await temporary.rename(file.path);
        } finally {
          if (await temporary.exists()) await temporary.delete();
        }
      }
    }
  } on TimeoutException catch (error) {
    report = emptyReport(
      'budget_exceeded',
      'budget_exceeded',
      error.toString(),
    );
  } catch (error) {
    report = emptyReport('failed', 'execution_failed', error.toString());
  }
  final resultCode = _annotateReport(report, options, watch);
  if (options.format == 'json') {
    output.writeln(jsonEncode(report));
  } else {
    output.writeln(
      '${report['status']}: ${(report['files'] as List).length} files, ${(report['findings'] as List).length} effects',
    );
    for (final finding in report['findings'] as List) {
      output.writeln(
        '${finding['file']}:${finding['line']}:${finding['column']} ${finding['code']} [${finding['channel']}/${finding['certainty']}] ${finding['symbol']}: ${finding['message']}${finding['intentionalBoundary'] == true ? ' (intentional boundary)' : ''}${finding['baselineState'] == null ? '' : ' (${finding['baselineState']})'}',
      );
    }
    for (final error in report['errors'] as List) {
      errorOutput.writeln('${error['code']}: ${error['message']}');
    }
  }
  return resultCode;
}

int _annotateReport(
  Map<String, dynamic> report,
  _Options options,
  Stopwatch watch,
) {
  report['elapsedMs'] = watch.elapsedMilliseconds;
  final resultCode = report['status'] != 'completed'
      ? 2
      : failsPolicy(report, options.failOn)
      ? 1
      : 0;
  report['exitCode'] = resultCode;
  report['policy'] = {
    'failOn': options.failOn,
    'newFindingsOnly': options.baseline != null,
  };
  return resultCode;
}

Future<({List<String> files, String revision})> _changedFiles(
  _Options options,
  Stopwatch watch,
) async {
  Future<String> git(List<String> args) async {
    final process = await Process.start('git', ['-C', options.root, ...args]);
    try {
      final remaining = options.timeout * 1000 - watch.elapsedMilliseconds;
      if (remaining <= 0) {
        throw TimeoutException('Git scope exceeded wall-clock budget.');
      }
      final result = await Future.wait<Object>([
        process.exitCode,
        process.stdout.transform(utf8.decoder).join(),
        process.stderr.transform(utf8.decoder).join(),
      ]).timeout(Duration(milliseconds: remaining));
      if (result[0] != 0) {
        throw FormatException('Git scope failed: ${result[2]}');
      }
      return result[1] as String;
    } finally {
      process.kill();
    }
  }

  final top = (await git([
    'rev-parse',
    '--show-toplevel',
  ])).replaceFirst(RegExp(r'\r?\n$'), '');
  final revision = (await git([
    'rev-parse',
    '--verify',
    '--end-of-options',
    '${options.changedSince}^{commit}',
  ])).trim();
  final names = [
    ...(await git([
      'diff',
      '--name-only',
      '--no-renames',
      '-z',
      revision,
      '--',
      options.root,
    ])).split('\u0000'),
    ...(await git([
      'ls-files',
      '--others',
      '--exclude-standard',
      '--full-name',
      '-z',
      '--',
      options.root,
    ])).split('\u0000'),
  ];
  final files =
      names
          .where((name) => name.isNotEmpty)
          .map((name) => reportPath(p.join(top, name), root: options.root))
          .toSet()
          .toList()
        ..sort();
  return (files: files, revision: revision);
}

/// A separate isolate keeps the watchdog responsive during synchronous
/// inference. RSS covers the entire CLI process and is sampled, not an OS cap.
Future<Map<String, dynamic>> _boundedAnalysis(
  Map<String, dynamic> request,
  _Options options,
  Stopwatch watch,
) async {
  final port = ReceivePort();
  final done = Completer<Map<String, dynamic>>();
  Isolate? worker;
  Timer? watchdog;
  final subscription = port.listen((message) {
    if (!done.isCompleted) {
      if (message is Map<String, dynamic>) {
        done.complete(message);
      } else {
        done.complete(
          emptyReport(
            'failed',
            'worker_failed',
            'Analysis worker exited without a report: $message',
          ),
        );
      }
    }
  });
  try {
    void checkBudget() {
      if (done.isCompleted) return;
      final reason = watch.elapsedMilliseconds >= options.timeout * 1000
          ? 'Wall-clock budget of ${options.timeout}s exceeded.'
          : ProcessInfo.currentRss > options.maxRssMb * 1024 * 1024
          ? 'Process RSS budget of ${options.maxRssMb} MiB exceeded.'
          : null;
      if (reason != null) {
        done.complete(
          emptyReport('budget_exceeded', 'budget_exceeded', reason),
        );
      }
    }

    checkBudget();
    if (!done.isCompleted) {
      watchdog = Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => checkBudget(),
      );
      worker = await Isolate.spawn(
        _analyzeWorker,
        [port.sendPort, request],
        onError: port.sendPort,
        onExit: port.sendPort,
      );
    }
    return await done.future;
  } finally {
    worker?.kill(priority: Isolate.immediate);
    watchdog?.cancel();
    await subscription.cancel();
    port.close();
  }
}

Future<void> _analyzeWorker(List<Object> message) async {
  final port = message[0] as SendPort;
  try {
    port.send(await analyzeProject(message[1] as Map<String, dynamic>));
  } catch (error) {
    port.send(emptyReport('failed', 'analysis_failed', error.toString()));
  }
}

final class _Options {
  _Options(
    this.root,
    this.paths,
    this.explicitFiles,
    this.format,
    this.failOn,
    this.baseline,
    this.writeBaseline,
    this.changedSince,
    this.timeout,
    this.maxRssMb,
  );
  final String root;
  final List<String> paths;
  final List<String> explicitFiles;
  final String format;
  final String failOn;
  final String? baseline;
  final String? writeBaseline;
  final String? changedSince;
  final int timeout;
  final int maxRssMb;

  static _Options? parse(List<String> args) {
    const accepted = {
      'root',
      'format',
      'fail-on',
      'baseline',
      'write-baseline',
      'changed-since',
      'timeout',
      'max-rss-mb',
    };
    final values = <String, String>{};
    final inputs = <String>[];
    var positional = false;
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '--' && !positional) {
        positional = true;
        continue;
      }
      if (!arg.startsWith('-') || positional) {
        inputs.add(arg);
        continue;
      }
      if (arg == '--help' || arg == '-h') return null;
      if (!arg.startsWith('--')) throw FormatException('Unknown option: $arg');
      final equals = arg.indexOf('=');
      final name = arg.substring(2, equals < 0 ? null : equals);
      if (!accepted.contains(name) || values.containsKey(name)) {
        throw FormatException('Unknown or duplicate option: $arg');
      }
      final String value;
      if (equals >= 0) {
        value = arg.substring(equals + 1);
      } else if (i + 1 < args.length && !args[i + 1].startsWith('--')) {
        value = args[++i];
      } else {
        throw FormatException('Missing value for $arg');
      }
      if (value.isEmpty) throw FormatException('Missing value for $arg');
      values[name] = value;
    }
    final root = p.normalize(p.absolute(values['root'] ?? '.'));
    if (!Directory(root).existsSync()) {
      throw FormatException('Root directory does not exist: $root');
    }
    final paths = <String>{};
    final explicitFiles = <String>{};
    for (final input in inputs.isEmpty ? ['.'] : inputs) {
      final full = p.normalize(p.join(root, input));
      if (full != root && !p.isWithin(root, full)) {
        throw FormatException('Input is outside root: $input');
      }
      final type = FileSystemEntity.typeSync(full, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw FormatException('Input must not be a symbolic link: $input');
      }
      final relative = reportPath(full, root: root);
      if (type != FileSystemEntityType.directory) {
        if (!relative.endsWith('.dart')) {
          throw FormatException(
            'Input must be a Dart file or directory: $input',
          );
        }
        explicitFiles.add(relative);
      }
      paths.add(relative);
    }
    final format = values['format'] ?? 'json';
    final failOn = values['fail-on'] ?? 'all';
    if (!const {'json', 'text'}.contains(format)) {
      throw const FormatException('Format must be json or text.');
    }
    if (!const {'all', 'known', 'unknown', 'none'}.contains(failOn)) {
      throw const FormatException(
        'Fail policy must be all, known, unknown, or none.',
      );
    }
    int positive(String name, int fallback) {
      final value = int.tryParse(values[name] ?? '$fallback');
      if (value == null || value <= 0) {
        throw FormatException('--$name must be a positive integer.');
      }
      return value;
    }

    return _Options(
      root,
      paths.toList()..sort(),
      explicitFiles.toList()..sort(),
      format,
      failOn,
      values['baseline'],
      values['write-baseline'],
      values['changed-since'],
      positive('timeout', 120),
      positive('max-rss-mb', 2048),
    );
  }
}
