import 'dart:convert';
import 'dart:io';

import 'package:dart_exception_lint/src/cli/command.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory fixture;
  var runNumber = 0;

  Future<void> write(String path, String content) async {
    final file = File(p.join(fixture.path, path));
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  Future<({int code, Map<String, dynamic> report})> run([
    List<String> args = const [],
  ]) async {
    final output = File(p.join(fixture.path, 'report-${runNumber++}.json'));
    final errors = File('${output.path}.stderr');
    final sink = output.openWrite();
    final errorSink = errors.openWrite();
    final code = await runCommand(
      ['--root', fixture.path, ...args],
      sink,
      errorSink,
    );
    await sink.close();
    await errorSink.close();
    return (
      code: code,
      report: jsonDecode(await output.readAsString()) as Map<String, dynamic>,
    );
  }

  setUp(() async {
    fixture = await Directory.systemTemp.createTemp('exception-cli-test-');
    await write(
      'pubspec.yaml',
      'name: cli_fixture\nenvironment:\n  sdk: ^3.11.0\n',
    );
  });
  tearDown(() => fixture.delete(recursive: true));

  test(
    'scoped callers retain dependency effects and causal paths, with typed containment',
    () async {
      await write(
        'lib/dependency.dart',
        "void fail() { throw 'failure'; }\nvoid wrapper() { fail(); }",
      );
      await write(
        'lib/main.dart',
        "import 'dependency.dart';\nvoid escaping() { wrapper(); }\nvoid contained() { try { wrapper(); } on String {} }\nvoid safe() {}",
      );
      final result = await run(['lib/main.dart']);
      expect(result.code, 1);
      expect(result.report['status'], 'completed');
      expect(result.report['files'], ['lib/main.dart']);
      final findings = result.report['findings'] as List;
      expect(findings, isNotEmpty);
      expect(findings.every((f) => f['symbol'] == 'function:escaping'), isTrue);
      final finding = findings.first;
      expect(finding['exceptionTypes'], contains('String'));
      expect(finding['channel'], 'synchronous');
      expect(finding['origin']['file'], 'lib/dependency.dart');
      expect(finding['origin']['symbol'], 'function:fail');
      final frames = finding['trace'] as List;
      expect(frames.map((f) => f['name']).join(' '), contains('wrapper'));
      expect(frames.last['file'], 'lib/dependency.dart');
    },
  );

  test(
    'baseline survives line shifts and identifies new and resolved effects',
    () async {
      await write(
        'lib/main.dart',
        "void existing() { throw 'old'; }\nvoid replaced() { throw 42; }",
      );
      final baseline = p.join(fixture.path, 'baseline.json');
      expect((await run(['lib', '--write-baseline', baseline])).code, 1);
      await write(
        'lib/main.dart',
        "\n\n// moved\nvoid existing() { throw 'old'; }\nvoid replaced() {}\nvoid added() { throw true; }",
      );
      final compared = await run(['lib', '--baseline', baseline]);
      expect(compared.code, 1);
      expect(compared.report['baseline']['existing'], 1);
      expect(compared.report['baseline']['new'], 1);
      expect(compared.report['baseline']['resolved'], hasLength(1));
      await write(
        'lib/main.dart',
        "\nvoid existing() { throw 'old'; }\nvoid replaced() {}",
      );
      final fixed = await run(['lib', '--baseline', baseline]);
      expect(fixed.code, 0);
      expect(fixed.report['baseline']['new'], 0);
      expect(fixed.report['baseline']['resolved'], hasLength(1));
    },
  );

  test(
    'baseline mismatch and invalid JSON fail without replacing a baseline',
    () async {
      await write('lib/main.dart', 'void safe() {}');
      final baseline = p.join(fixture.path, 'baseline.json');
      await run(['lib', '--write-baseline', baseline]);
      final original = await File(baseline).readAsString();
      expect(
        (await run([
          'lib/main.dart',
          '--baseline',
          baseline,
          '--write-baseline',
          baseline,
        ])).code,
        2,
      );
      expect(await File(baseline).readAsString(), original);
      await File(baseline).writeAsString('{');
      expect((await run(['lib', '--baseline', baseline])).code, 2);
    },
  );

  test(
    'known, unknown and none policies remain independent from execution success',
    () async {
      await write(
        'lib/main.dart',
        'void opaque(dynamic callback) { callback(); }',
      );
      final unknown = await run(['lib', '--fail-on=unknown']);
      expect(unknown.code, 1);
      expect(unknown.report['status'], 'completed');
      expect(unknown.report['analysisComplete'], isFalse);
      expect((await run(['lib', '--fail-on=known'])).code, 0);
      expect((await run(['lib', '--fail-on=none'])).code, 0);
      await write('lib/main.dart', "void known() { throw 'failure'; }");
      expect((await run(['lib', '--fail-on=known'])).code, 1);
      expect((await run(['lib', '--fail-on=unknown'])).code, 0);
    },
  );

  test(
    'configuration and compiler errors cannot be hidden by fail-on none',
    () async {
      await write('lib/main.dart', 'void safe() {}');
      await write(
        'tool/dart_exception_lint/exception_analysis.yaml',
        'exception_analysis:\n  max_call_depth: wrong\n',
      );
      final config = await run(['lib', '--fail-on=none']);
      expect(config.code, 2);
      expect(
        config.report['errors'],
        contains(
          predicate((dynamic e) => e['code'] == 'invalid_configuration'),
        ),
      );
      await File(
        p.join(
          fixture.path,
          'tool/dart_exception_lint/exception_analysis.yaml',
        ),
      ).delete();
      await write(
        'lib/main.dart',
        "import 'dependency.dart';\nvoid caller() { fail(); }",
      );
      await write(
        'lib/dependency.dart',
        'void fail() { MissingType value = 1; print(value); }',
      );
      final brokenDependency = await run(['lib/main.dart', '--fail-on=none']);
      expect(brokenDependency.code, 2);
      expect(
        brokenDependency.report['errors'],
        contains(predicate((dynamic e) => e['file'] == 'lib/dependency.dart')),
      );
    },
  );

  test(
    'excluded and nonexistent explicit inputs cannot appear clean',
    () async {
      await write('lib/main.dart', 'void safe() {}');
      await write(
        'analysis_options.yaml',
        'analyzer:\n  exclude:\n    - lib/main.dart\n',
      );
      expect((await run(['lib/main.dart'])).code, 2);
      expect((await run(['missing.dart'])).code, 2);
      expect((await run(['missing-directory'])).code, 64);
    },
  );

  test('positional paths may look like flags or end in .dart', () async {
    await write('--help/entry.dart', "void fail() { throw 'failure'; }");
    await Directory(p.join(fixture.path, 'empty.dart')).create();
    expect((await run(['--', '--help'])).report['files'], [
      '--help/entry.dart',
    ]);
    final empty = await run(['empty.dart']);
    expect(empty.code, 0);
    expect(empty.report['files'], isEmpty);
  });

  if (!Platform.isWindows) {
    test('literal POSIX backslashes remain part of file names', () async {
      await write(r'lib/a\b.dart', "void first() { throw 'failure'; }");
      await write('lib/a/b.dart', "void second() { throw 'failure'; }");
      final result = await run(['lib']);
      expect(result.report['files'], ['lib/a/b.dart', r'lib/a\b.dart']);
      expect((await run([r'lib/a\b.dart'])).report['files'], [r'lib/a\b.dart']);
    });
  }

  test(
    'parts, constructors, getters, setters and methods are included',
    () async {
      await write(
        'lib/main.dart',
        "part 'part.dart';\nclass C { C() { throw 'ctor'; } int get value => throw 'get'; set value(int v) { throw 'set'; } void method() { throw 'method'; } }",
      );
      await write(
        'lib/part.dart',
        "part of 'main.dart';\nvoid partFunction() { throw 'part'; }",
      );
      final result = await run(['lib']);
      expect(result.code, 1);
      final callables = result.report['callables'] as List;
      expect(callables, hasLength(5));
      final part = (result.report['findings'] as List).singleWhere(
        (f) => f['symbol'] == 'function:partFunction',
      );
      expect(part['origin']['file'], 'lib/part.dart');
    },
  );

  if (Platform.version.startsWith('3.14.')) {
    test('Dart 3.14 range and promise checks preserve typed catches', () async {
      await write('lib/main.dart', '''
import 'dart:typed_data';
import 'dart:js_interop';
void range(Uint8List a, Uint8List b) { a.rangeEquals(0, 3, b); }
void caughtRange(Uint8List a, Uint8List b) {
  try { a.rangeEquals(0, 3, b); } on RangeError {}
}
void promise(JSAny value) { JSPromise.resolve(value); }
void caughtPromise(JSAny value) {
  try { JSPromise.resolve(value); } on ArgumentError {}
}
''');
      final result = await run(['lib']);
      expect(result.code, 1);
      final findings = result.report['findings'] as List;
      expect(
        {
          for (final finding in findings)
            finding['symbol']: finding['exceptionTypes'],
        },
        {
          'function:range': ['RangeError'],
          'function:promise': ['ArgumentError'],
        },
      );
    });
  }

  test(
    'intentional propagation is visible and remains an effect at callers',
    () async {
      await write(
        '.dart_tool/package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {
              'name': 'cli_fixture',
              'rootUri': '../',
              'packageUri': 'lib/',
              'languageVersion': '3.11',
            },
            {
              'name': 'dart_exception_lint',
              'rootUri': Directory.current.uri.toString(),
              'packageUri': 'lib/',
              'languageVersion': '3.11',
            },
          ],
        }),
      );
      await write(
        'lib/boundary.dart',
        "import 'package:dart_exception_lint/dart_exception_lint.dart';\n@ExceptionBoundary()\nvoid boundary() { throw 'intentional'; }",
      );
      expect((await run(['lib/boundary.dart'])).code, 0);
      await write(
        'lib/caller.dart',
        "import 'boundary.dart';\nvoid caller() { boundary(); }",
      );
      final result = await run(['lib']);
      expect(result.code, 1);
      final effects = result.report['findings'] as List;
      expect(effects.any((f) => f['intentionalBoundary'] == true), isTrue);
      expect(
        effects.any(
          (f) =>
              f['symbol'] == 'function:caller' &&
              f['intentionalBoundary'] == false,
        ),
        isTrue,
      );
    },
  );

  test(
    'budget exhaustion is structured and cannot write a clean baseline',
    () async {
      await write('lib/main.dart', 'void safe() {}');
      final baseline = p.join(fixture.path, 'budget-baseline.json');
      final result = await run([
        '--max-rss-mb=1',
        '--write-baseline',
        baseline,
      ]);
      expect(result.code, 2);
      expect(result.report['status'], 'budget_exceeded');
      expect(await File(baseline).exists(), isFalse);
    },
  );

  test(
    'Git scope includes committed, working, untracked and spaced paths',
    () async {
      Future<void> git(List<String> args) async {
        final result = await Process.run('git', ['-C', fixture.path, ...args]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }

      await write('lib/untouched.dart', "void existing() { throw 'old'; }");
      await write('lib/changed.dart', 'void changed() {}');
      await git(['init', '--quiet']);
      await git(['add', '.']);
      await git([
        '-c',
        'user.name=CLI test',
        '-c',
        'user.email=cli@example.invalid',
        'commit',
        '--quiet',
        '-m',
        'base',
      ]);
      await write('lib/changed.dart', "void changed() { throw 'new'; }");
      await write('lib/space name.dart', "void untracked() { throw true; }");
      final result = await run(['lib', '--changed-since=HEAD']);
      expect(result.code, 1);
      expect(result.report['files'], [
        'lib/changed.dart',
        'lib/space name.dart',
      ]);
      final baseline = p.join(fixture.path, 'git-baseline.json');
      await run(['lib', '--changed-since=HEAD', '--write-baseline', baseline]);
      await write('lib/changed.dart', 'void changed() {}');
      await File(p.join(fixture.path, 'lib/space name.dart')).delete();
      final empty = await run([
        'lib',
        '--changed-since=HEAD',
        '--baseline',
        baseline,
      ]);
      expect(empty.code, 0);
      expect(empty.report['files'], isEmpty);
      expect(empty.report['baseline']['resolved'], hasLength(2));
      expect((await run(['lib', '--changed-since=does-not-exist'])).code, 2);
    },
  );

  test('analyzer exclusion edits invalidate baseline comparisons', () async {
    await write('lib/main.dart', "void fail() { throw 'failure'; }");
    final baseline = p.join(fixture.path, 'baseline.json');
    await run(['lib', '--write-baseline', baseline]);
    await write(
      'analysis_options.yaml',
      'analyzer:\n  exclude:\n    - lib/main.dart\n',
    );
    expect((await run(['lib', '--baseline', baseline])).code, 2);
  });

  test('transitive analyzer option changes invalidate baselines', () async {
    await write('lib/main.dart', "void fail() { throw 'failure'; }");
    await write('.dart_tool/package_config.json', '''
{
  "configVersion": 2,
  "packages": [
    {"name": "cli_fixture", "rootUri": "../", "packageUri": "lib/", "languageVersion": "3.11"}
  ]
}
''');
    await write(
      'analysis_options.yaml',
      'include: package:cli_fixture/policies/shared.yaml\n',
    );
    await write('lib/policies/shared.yaml', 'include:\n  - strict.yaml\n');
    await write(
      'lib/policies/strict.yaml',
      'analyzer:\n  language:\n    strict-casts: false\n',
    );
    final baseline = p.join(fixture.path, 'baseline.json');
    expect((await run(['lib', '--write-baseline', baseline])).code, 1);
    expect((await run(['lib', '--baseline', baseline])).code, 0);

    await write(
      'lib/policies/strict.yaml',
      'analyzer:\n  language:\n    strict-casts: true\n',
    );
    final changed = await run(['lib', '--baseline', baseline]);
    expect(changed.code, 2);
    expect(changed.report['errors'][0]['message'], contains('configuration'));
  });

  test(
    'equivalent failures in different originating callables keep distinct identities',
    () async {
      await write(
        'lib/main.dart',
        "int first(String value) => int.parse(value);\nint second(String value) => int.parse(value);\nvoid caller(String value) { first(value); second(value); }",
      );
      final result = await run(['lib']);
      final effects = (result.report['findings'] as List)
          .where(
            (f) =>
                f['symbol'] == 'function:caller' &&
                (f['exceptionTypes'] as List).contains('FormatException'),
          )
          .toList();
      expect(effects, hasLength(2));
      expect(effects.map((f) => f['fingerprint']).toSet(), hasLength(2));
    },
  );

  test(
    'lazy initializers and implicit constructors are analysis roots',
    () async {
      await write(
        'lib/main.dart',
        "int top = int.parse('bad');\nclass Default { final value = int.parse('bad'); late int other; }",
      );
      final result = await run(['lib']);
      expect(result.code, 1);
      final effects = result.report['findings'] as List;
      expect(
        effects.any(
          (f) =>
              f['symbol'] == 'getter:top' &&
              (f['exceptionTypes'] as List).contains('FormatException'),
        ),
        isTrue,
      );
      expect(
        effects.any(
          (f) =>
              (f['symbol'] as String).startsWith('constructor:Default') &&
              (f['exceptionTypes'] as List).contains('FormatException'),
        ),
        isTrue,
      );
      expect(effects.any((f) => f['symbol'] == 'getter:Default.other'), isTrue);
    },
  );

  test(
    'shadowed local names keep distinct findings across line shifts',
    () async {
      const source = '''
void caller() {
  { void fail() => throw 'first'; fail(); }
  { void fail() => throw 'second'; fail(); }
}
''';
      await write('lib/main.dart', source);
      final baseline = p.join(fixture.path, 'shadowed-baseline.json');
      final initial = await run(['lib', '--write-baseline', baseline]);
      final findings = initial.report['findings'] as List;
      expect(
        findings
            .where((f) => f['symbol'] == 'function:caller')
            .map((f) => f['origin']['symbol']),
        unorderedEquals(['function:caller.fail#1', 'function:caller.fail#2']),
      );
      expect(findings, hasLength(4));

      await write('lib/main.dart', '\n\n$source');
      final comparison = await run(['lib', '--baseline', baseline]);
      expect(comparison.code, 0);
      expect(comparison.report['baseline']['existing'], 4);
      expect(comparison.report['baseline']['resolved'], isEmpty);
    },
  );

  test(
    'wall-clock watchdog interrupts expensive synchronous analysis',
    () async {
      await write(
        'lib/main.dart',
        List.generate(
          100000,
          (i) => 'int parse$i(String value) => int.parse(value);',
        ).join('\n'),
      );
      final result = await run(['lib', '--timeout=1', '--max-rss-mb=4096']);
      expect(result.code, 2);
      expect(result.report['status'], 'budget_exceeded');
      expect(result.report['errors'][0]['message'], contains('Wall-clock'));
    },
  );

  test(
    'invalid flags and numeric budgets return usage errors as JSON',
    () async {
      for (final args in [
        ['-'],
        ['--format=xml'],
        ['--timeout=0'],
        ['--max-rss-mb=no'],
        ['--fail-on=bad'],
        ['--root'],
      ]) {
        final result = await run(args);
        expect(result.code, 64, reason: '$args');
        expect(result.report['errors'][0]['code'], 'invalid_arguments');
      }
    },
  );

  test(
    'JSON reports evidence without upgrading unresolved SDK spellings',
    () async {
      await write(
        'lib/main.dart',
        "int modeled(String value) => int.parse(value);\nvoid direct() { throw 'failure'; }\nvoid unknown(dynamic Uri) { Uri.parse('value'); }",
      );
      final result = await run(['lib']);
      expect(result.report['schemaVersion'], 2);
      final findings = result.report['findings'] as List;
      expect(
        findings.any(
          (f) =>
              f['symbol'] == 'function:modeled' &&
              (f['evidence'] as List).contains('sdkModel'),
        ),
        isTrue,
      );
      expect(
        findings.any(
          (f) =>
              f['symbol'] == 'function:direct' &&
              (f['evidence'] as List).contains('sourceAnalysis'),
        ),
        isTrue,
      );
      final unknowns = findings.where((f) => f['symbol'] == 'function:unknown');
      expect(unknowns, isNotEmpty);
      expect(
        unknowns.every(
          (f) =>
              f['certainty'] == 'unknown' &&
              (f['evidence'] as List).contains('unresolved') &&
              !(f['evidence'] as List).contains('sdkModel'),
        ),
        isTrue,
      );
      final old = Map<String, dynamic>.from(result.report)
        ..['schemaVersion'] = 1;
      final baseline = File(p.join(fixture.path, 'old-baseline.json'));
      await baseline.writeAsString(jsonEncode(old));
      expect((await run(['lib', '--baseline', baseline.path])).code, 2);
    },
  );
}
