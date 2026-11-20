import 'dart:convert';
import 'dart:io';

/// Verifies plugin installation through Flutter and executes the same consumer
/// in a browser. Run with Flutter and Chrome or Chromium available.
Future<void> main() async {
  final consumer = await Directory.systemTemp.createTemp('exception-flutter-');
  final pluginRoot = Directory.current.absolute.path;
  Future<void> write(String name, String contents) async {
    final file = File('${consumer.path}/$name');
    await file.parent.create(recursive: true);
    await file.writeAsString(contents);
  }

  Future<ProcessResult> flutter(List<String> arguments) => Process.run(
    'flutter',
    ['--suppress-analytics', ...arguments],
    workingDirectory: consumer.path,
  );

  try {
    await write('pubspec.yaml', '''
name: exception_flutter_consumer
publish_to: none
environment:
  sdk: ^3.11.0
dependencies:
  flutter:
    sdk: flutter
dev_dependencies:
  flutter_test:
    sdk: flutter
''');
    await write('analysis_options.yaml', '''
plugins:
  dart_exception_lint:
    path: ${jsonEncode(pluginRoot)}
''');
    await write('lib/exception_probe.dart', _source);
    await write('test/exception_probe_test.dart', _test);
    final pub = await flutter(['pub', 'get']);
    if (pub.exitCode != 0) {
      throw StateError(
        'Flutter dependency resolution failed.\n${pub.stdout}\n${pub.stderr}',
      );
    }

    final analysis = await flutter(['analyze', '--no-pub']);
    final diagnosticLine = RegExp(
      r'^\s*(info|warning|error)\s*•.*\s•\s*(.+):(\d+):\d+\s*•\s*(\w+)\s*$',
    );
    final diagnostics = const LineSplitter()
        .convert(analysis.stdout as String)
        .map(diagnosticLine.firstMatch)
        .whereType<RegExpMatch>()
        .toList();
    bool diagnosed(String code, String sourceLine) {
      final line = _source.split('\n').indexOf(sourceLine) + 1;
      return diagnostics.any(
        (item) =>
            item.group(4) == code &&
            item.group(2)!.endsWith('exception_probe.dart') &&
            item.group(3) == '$line',
      );
    }

    const inferred = 'catch_inferred_throwing_calls';
    if (analysis.exitCode == 0 ||
        diagnostics.any((item) => item.group(1) == 'error') ||
        !diagnosed(
          'no_manual_throw',
          "Never explicit() => throw 'plugin probe';",
        ) ||
        !diagnosed(
          inferred,
          'int unchecked(String input) => parseInput(input);',
        ) ||
        diagnosed(inferred, '    return parseInput(input);')) {
      throw StateError(
        'Unexpected Flutter diagnostics.\n${analysis.stdout}\n${analysis.stderr}',
      );
    }
    stdout.writeln('Flutter analysis verified escaping and contained effects.');

    final browser = await flutter([
      'test',
      '--no-pub',
      '--platform',
      'chrome',
      '--reporter',
      'expanded',
    ]);
    if (browser.exitCode != 0) {
      throw StateError(
        'Flutter browser test failed.\n${browser.stdout}\n${browser.stderr}',
      );
    }
    stdout.writeln('Flutter browser verified successful and handled input.');
  } finally {
    await consumer.delete(recursive: true);
  }
}

const _source = '''
import 'package:flutter/widgets.dart';

int parseInput(String input) => int.parse(input);
int unchecked(String input) => parseInput(input);
Never explicit() => throw 'plugin probe';

int handled(String input) {
  try {
    return parseInput(input);
  } on FormatException {
    return -1;
  }
}

class ExceptionProbe extends StatelessWidget {
  const ExceptionProbe({super.key, required this.input});

  final String input;

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: Text(handled(input).toString()),
  );
}
''';

const _test = '''
import 'package:exception_flutter_consumer/exception_probe.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders valid and handled input', (tester) async {
    await tester.pumpWidget(const ExceptionProbe(input: '42'));
    expect(find.text('42'), findsOneWidget);
    await tester.pumpWidget(const ExceptionProbe(input: 'invalid'));
    expect(find.text('-1'), findsOneWidget);
  });
}
''';
