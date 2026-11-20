import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:dart_exception_lint/src/engine/future_forwarding.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late File main;
  late File helper;
  AnalysisContextCollection? collection;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('future-forwarding-');
    main = File('${directory.path}/lib/main.dart');
    helper = File('${directory.path}/lib/forward.dart');
    await main.parent.create();
    await main.writeAsString(
      "import 'forward.dart'; void caller(Future<void> input) { forward(input); }",
    );
    await helper.writeAsString(
      'Future<void> forward(Future<void> input) => input;',
    );
    await File(
      '${directory.path}/pubspec.yaml',
    ).writeAsString('name: forward_fixture\nenvironment:\n  sdk: ^3.11.0\n');
    final config = File('${directory.path}/.dart_tool/package_config.json');
    await config.parent.create();
    await config.writeAsString(
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'forward_fixture',
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
  });
  tearDown(() async {
    await collection?.dispose();
    collection = null;
    await directory.delete(recursive: true);
  });

  Future<List<MethodInvocation>> calls() async {
    collection ??= AnalysisContextCollection(includedPaths: [directory.path]);
    final result =
        await collection!
                .contextFor(main.path)
                .currentSession
                .getResolvedUnit(main.path)
            as ResolvedUnitResult;
    expect(
      result.diagnostics.where((d) => d.severity.name == 'error'),
      isEmpty,
    );
    final calls = _Calls();
    result.unit.accept(calls);
    return calls.items;
  }

  test(
    'async dependency edits invalidate old proofs and new sessions re-evaluate ownership',
    () async {
      await helper.writeAsString(
        'Future<void> forward(Future<void> input) async => await input;',
      );
      final before = (await calls()).single;
      expect(forwardedFutureArgument(before), isNotNull);
      await helper.writeAsString(
        'Future<void> forward(Future<void> input) => Future<void>.value();',
      );
      expect(forwardedFutureArgument(before), isNull);
      final context = collection!.contextFor(main.path);
      context.changeFile(helper.path);
      await context.applyPendingFileChanges();
      expect(forwardedFutureArgument((await calls()).single), isNull);
    },
  );

  test(
    'manifest overrides and invalid configuration cannot be erased by a body proof',
    () async {
      final call = (await calls()).single;
      expect(forwardedFutureArgument(call), isNotNull);
      final manifest = File(
        '${directory.path}/tool/dart_exception_lint/throwing_apis.yaml',
      );
      await manifest.parent.create(recursive: true);
      await manifest.writeAsString('''
apis:
  - package: forward_fixture
    library: package:forward_fixture/forward.dart
    function: forward
''');
      expect(forwardedFutureArgument(call), isNull);
      await manifest.writeAsString('apis: []');
      expect(forwardedFutureArgument(call), isNotNull);
      await manifest.writeAsString('apis: [');
      expect(forwardedFutureArgument(call), isNull);
    },
  );

  test(
    'annotation contracts remain authoritative and cannot be specialized away',
    () async {
      await helper.writeAsString(
        "import 'package:dart_exception_lint/dart_exception_lint.dart';\n@ReturnsFailingFuture([StateError])\nFuture<void> forward(Future<void> input) => input;",
      );
      expect(forwardedFutureArgument((await calls()).single), isNull);
    },
  );

  test(
    'long delegation chains exhaust the proof budget rather than claiming observation',
    () async {
      final options = File(
        '${directory.path}/tool/dart_exception_lint/exception_analysis.yaml',
      );
      await options.parent.create(recursive: true);
      await options.writeAsString('exception_analysis:\n  max_call_depth: 8\n');
      await helper.writeAsString(
        List.generate(
          9,
          (i) =>
              'Future<void> forward$i(Future<void> input) => ${i == 8 ? 'input' : 'forward${i + 1}(input)'};',
        ).join('\n'),
      );
      await main.writeAsString(
        "import 'forward.dart'; void caller(Future<void> input) { forward0(input); forward1(input); }",
      );
      final invocations = await calls();
      expect(forwardedFutureArgument(invocations[0]), isNull);
      expect(forwardedFutureArgument(invocations[1]), isNotNull);
      expect(forwardedFutureArgument(invocations[0]), isNull);
      await options.writeAsString('exception_analysis:\n  max_call_depth: 1\n');
      expect(forwardedFutureArgument(invocations[1]), isNull);
    },
  );
}

final class _Calls extends RecursiveAstVisitor<void> {
  final items = <MethodInvocation>[];
  @override
  void visitMethodInvocation(MethodInvocation node) {
    items.add(node);
    super.visitMethodInvocation(node);
  }
}
