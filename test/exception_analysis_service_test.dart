import 'dart:io';

import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/error/listener.dart';
import 'package:analyzer/source/file_source.dart';
import 'package:analyzer/workspace/workspace.dart';
import 'package:dart_exception_lint/src/engine/exception_analysis_service.dart';
import 'package:test/test.dart';

void main() {
  test(
    'registration shares a service with no current unit and reloads config',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'exception-service-',
      );
      AnalysisContextCollection? collection;
      try {
        final file = File('${directory.path}/main.dart');
        await file.writeAsString('void f() {}');
        collection = AnalysisContextCollection(includedPaths: [directory.path]);
        final session = collection.contextFor(file.path).currentSession;
        final result =
            await session.getResolvedUnit(file.path) as ResolvedUnitResult;
        final resource = session.resourceProvider.getFile(file.path);
        final unit = RuleContextUnit(
          file: resource,
          content: result.content,
          diagnosticReporter: DiagnosticReporter(
            DiagnosticListener.nullListener,
            FileSource(resource),
          ),
          unit: result.unit,
        );
        final context = _RegistrationContext(result.libraryElement, [unit]);
        expect(context.currentUnit, isNull);
        final first = ExceptionAnalysisService.forContext(context);
        expect(ExceptionAnalysisService.forContext(context), same(first));

        final options = File(
          '${directory.path}/tool/dart_exception_lint/exception_analysis.yaml',
        );
        await options.parent.create(recursive: true);
        await options.writeAsString(
          'exception_analysis:\n  max_call_depth: 2\n',
        );
        final changed = ExceptionAnalysisService.forContext(context);
        expect(changed, isNot(same(first)));
        expect(changed.options.maxCallDepth, 2);

        // A changed part invalidates the library service even when its defining
        // AST and library element are unchanged.
        final part = RuleContextUnit(
          file: resource,
          content: 'void g() {}',
          diagnosticReporter: unit.diagnosticReporter,
          unit: parseString(content: 'void g() {}').unit,
        );
        expect(
          ExceptionAnalysisService.forContext(
            _RegistrationContext(result.libraryElement, [unit, part]),
          ),
          isNot(same(changed)),
        );
      } finally {
        await collection?.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
}

final class _RegistrationContext implements RuleContext {
  _RegistrationContext(this.libraryElement, this.allUnits);
  @override
  final LibraryElement libraryElement;
  @override
  final List<RuleContextUnit> allUnits;
  @override
  RuleContextUnit get definingUnit => allUnits.first;
  @override
  RuleContextUnit? get currentUnit => null;
  @override
  WorkspacePackage? get package => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
