import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:dart_exception_lint/src/analysis/inferred_throw_analyzer.dart';
import 'package:dart_exception_lint/src/config/exception_analysis_options.dart';
import 'package:dart_exception_lint/src/config/throwing_api_manifest.dart';
import 'package:dart_exception_lint/src/engine/exception_effect.dart';
import 'package:test/test.dart';

void main() {
  test('Method tearoffs execute through their callback channel', () async {
    final directory = await Directory.systemTemp.createTemp('tearoff-effect-');
    AnalysisContextCollection? collection;
    try {
      final file = File('${directory.path}/main.dart');
      await file.writeAsString('''
class Base {
  void action() {}
  int transform(int value) => value;
}
class Child extends Base {
  @override
  void action() { throw 'failure'; }
  @override
  int transform(int value) { throw 'failure'; }
}
final class Holder {
  void Function() get action { throw StateError('getter'); }
}
class DispatchBase { void act() {} }
class DispatchAsync extends DispatchBase {
  @override
  void act() async { throw 'scheduled'; }
}
Future<void> incompleteDispatchCatch(DispatchBase value) async {
  try { await Future<void>.sync(value.act); }
  catch (_) {}
}
void tearoffOnly(Base value) { final action = value.action; }
void parenthesizedTearoff(Base value) { final action = (value).action; }
Future<void> futureCallback(Base value) => Future.sync(value.action);
Iterable<int> lazyCallback(Base value) => [1].map(value.transform);
void getterRead(Holder value) { final action = value.action; }
Future<void> futureAlias() {
  final schedule = Future<void>.sync;
  return schedule(() { throw 'failure'; });
}
void ignoredAlias() {
  final each = [1].forEach;
  each((_) async { throw 'failure'; });
}
''');
      collection = AnalysisContextCollection(includedPaths: [directory.path]);
      final result =
          await collection
                  .contextFor(file.path)
                  .currentSession
                  .getResolvedUnit(file.path)
              as ResolvedUnitResult;
      expect(
        result.diagnostics.where(
          (diagnostic) => diagnostic.diagnosticCode.severity.name == 'ERROR',
        ),
        isEmpty,
      );
      final analyzer = InferredThrowAnalyzer(
        manifest: ThrowingApiManifest.empty(),
        options: const ExceptionAnalysisOptions(),
        featureSet: result.libraryElement.featureSet,
        packageRootPath: directory.path,
        knownUnits: {file.path: result.unit},
      );
      final summaries = {
        for (final declaration
            in result.unit.declarations.whereType<FunctionDeclaration>())
          declaration.name.lexeme: analyzer.summarizeExecutable(
            declaration.declaredFragment!.element,
          ),
      };
      for (final name in ['tearoffOnly', 'parenthesizedTearoff']) {
        expect(summaries[name]!.hasAnyThrowSource, isFalse, reason: name);
      }
      for (final entry in {
        'futureCallback': ExceptionChannel.future,
        'lazyCallback': ExceptionChannel.deferred,
      }.entries) {
        final effects = summaries[entry.key]!.effects.where(
          (effect) => effect.source.exceptionTypes.contains('String'),
        );
        expect(effects, isNotEmpty, reason: entry.key);
        expect(effects.map((effect) => effect.channel).toSet(), {
          entry.value,
        }, reason: entry.key);
      }
      expect(
        summaries['getterRead']!.effects.any(
          (effect) =>
              effect.channel == ExceptionChannel.synchronous &&
              effect.source.exceptionTypes.contains('StateError'),
        ),
        isTrue,
      );
      final nodes = _CallbackNodes();
      result.unit.accept(nodes);
      for (final entry in {
        'futureAlias': ExceptionChannel.future,
        'ignoredAlias': ExceptionChannel.scheduled,
      }.entries) {
        final invocation = nodes.invocations.singleWhere(
          (node) => nodes.enclosingFunction(node) == entry.key,
        );
        final analysis = analyzer.analyzeResolvedCall(
          invocation,
          element: invocation.element,
          treatUnknownAsReportable: true,
          requireObservedAsyncError: true,
        );
        expect(analysis, isNotNull, reason: entry.key);
        expect(
          analysis!.sources.any(
            (source) =>
                source.channel == entry.value &&
                source.exceptionTypes.contains('String'),
          ),
          isTrue,
          reason: entry.key,
        );
      }
      for (final node in nodes.accesses.where(
        (node) => [
          'tearoffOnly',
          'parenthesizedTearoff',
        ].contains(nodes.enclosingFunction(node)),
      )) {
        final element = switch (node) {
          PropertyAccess() => node.propertyName.element,
          PrefixedIdentifier() => node.identifier.element,
          _ => null,
        };
        expect(
          analyzer.analyzeResolvedCall(
            node,
            element: element,
            treatUnknownAsReportable: true,
            requireObservedAsyncError: false,
          ),
          isNull,
          reason: 'Tearoff creation is not invocation',
        );
      }
      final incompleteAnalyzer = InferredThrowAnalyzer(
        manifest: ThrowingApiManifest.empty(),
        options: const ExceptionAnalysisOptions(maxDispatchCandidates: 0),
        featureSet: result.libraryElement.featureSet,
        packageRootPath: directory.path,
        knownUnits: {file.path: result.unit},
      );
      final incompleteWrapper = result.unit.declarations
          .whereType<FunctionDeclaration>()
          .singleWhere(
            (declaration) =>
                declaration.name.lexeme == 'incompleteDispatchCatch',
          );
      expect(
        incompleteAnalyzer
            .summarizeExecutable(incompleteWrapper.declaredFragment!.element)
            .effects
            .any(
              (effect) =>
                  effect.certainty == ExceptionCertainty.unknown &&
                  effect.channel == ExceptionChannel.scheduled,
            ),
        isTrue,
        reason: 'Omitted async-void overrides escape the awaited Future catch',
      );
    } finally {
      await collection?.dispose();
      await directory.delete(recursive: true);
    }
  });
}

final class _CallbackNodes extends RecursiveAstVisitor<void> {
  final List<FunctionExpressionInvocation> invocations = [];
  final List<AstNode> accesses = [];

  String? enclosingFunction(AstNode node) {
    for (
      AstNode? parent = node.parent;
      parent != null;
      parent = parent.parent
    ) {
      if (parent is FunctionDeclaration) return parent.name.lexeme;
    }
    return null;
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    invocations.add(node);
    super.visitFunctionExpressionInvocation(node);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    accesses.add(node);
    super.visitPropertyAccess(node);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    accesses.add(node);
    super.visitPrefixedIdentifier(node);
  }
}
