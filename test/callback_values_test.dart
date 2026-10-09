import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:dart_exception_lint/src/engine/callback_values.dart';
import 'package:test/test.dart';

void main() {
  test('Native callback aliases and joins preserve all alternatives', () async {
    await _withFixture((unit) {
      final index = _Declarations();
      unit.accept(index);
      final resolver = CallbackValueResolver(
        resolvedUnits: {'main.dart': unit},
      );
      Set<String?> names(String variable) => resolver
          .forElement(index.variables[variable]!.declaredFragment!.element)
          .targets
          .map((element) => element.name)
          .toSet();
      expect(names('alias'), {'safe'});
      expect(names('chain'), {'safe'});
      expect(names('joined'), {'safe', 'fail'});
      expect(names('switched'), {'safe', 'fail'});
      expect(names('method'), {'execute'});
      expect(names('propertyMethod'), {'execute'});
      expect(names('inline'), {null});
      expect(names('partlyUnknown'), {'safe'});
      expect(
        resolver
            .forElement(
              index.variables['partlyUnknown']!.declaredFragment!.element,
            )
            .hasUnknown,
        isTrue,
      );
      for (final variable in [
        'alias',
        'chain',
        'joined',
        'switched',
        'method',
        'propertyMethod',
        'inline',
      ]) {
        expect(
          resolver
              .forElement(index.variables[variable]!.declaredFragment!.element)
              .hasUnknown,
          isFalse,
          reason: variable,
        );
      }
      expect(
        resolver
            .forElement(
              index.variables['getterValue']!.declaredFragment!.element,
            )
            .hasUnknown,
        isTrue,
      );
      final safe = index.functions['safe']!.declaredFragment!.element;
      final fail = index.functions['fail']!.declaredFragment!.element;
      final a = CallbackValue(targets: [safe, fail]);
      final b = CallbackValue(targets: [fail, safe, safe]);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(CallbackValue(targets: [safe, fail], hasUnknown: true)));
    });
  });

  test(
    'Constructor and instantiated function references preserve native targets',
    () async {
      await _withFixture((unit) {
        final index = _Declarations();
        unit.accept(index);
        final resolver = CallbackValueResolver(
          resolvedUnits: {'main.dart': unit},
        );
        for (final variable in [
          'constructor',
          'namedConstructor',
          'sdkFactory',
          'genericFunction',
          'genericMethod',
        ]) {
          final expression = index.variables[variable]!.initializer!;
          expect(
            expression,
            anyOf(isA<ConstructorReference>(), isA<FunctionReference>()),
          );
          final nativeTarget = switch (expression) {
            ConstructorReference() => expression.constructorName.element!,
            FunctionReference(:final function) => switch (function) {
              SimpleIdentifier() => function.element!,
              PrefixedIdentifier() => function.identifier.element!,
              PropertyAccess() => function.propertyName.element!,
              _ => throw StateError('Unexpected function reference shape'),
            },
            _ => throw StateError('Unexpected reference shape'),
          };
          final value = resolver.forElement(
            index.variables[variable]!.declaredFragment!.element,
          );
          expect(value.hasUnknown, isFalse, reason: variable);
          expect(value.targets, {nativeTarget.baseElement}, reason: variable);
        }
        expect(
          resolver
              .forElement(
                index.variables['sdkFactory']!.declaredFragment!.element,
              )
              .targets
              .single
              .library
              .uri
              .toString(),
          'dart:async',
        );
        expect(
          resolver
              .forElement(
                index.variables['genericFunction']!.declaredFragment!.element,
              )
              .targets
              .single
              .name,
          'identity',
        );
      });
    },
  );

  test(
    'Writes, captures, cycles and budgets cannot prove callback safety',
    () async {
      await _withFixture((unit) {
        final index = _Declarations();
        unit.accept(index);
        final resolver = CallbackValueResolver(
          resolvedUnits: {'main.dart': unit},
        );
        for (final variable in [
          'changed',
          'capturedWrite',
          'patternWrite',
          'loopWrite',
          'stored',
          'uninitialized',
        ]) {
          final value = resolver.forElement(
            index.variables[variable]!.declaredFragment!.element,
          );
          expect(value.hasUnknown, isTrue, reason: variable);
          expect(value.targets, isEmpty, reason: variable);
        }
        final small = CallbackValueResolver(
          resolvedUnits: {'main.dart': unit},
          maxAliasDepth: 1,
        );
        expect(
          small
              .forElement(index.variables['chain']!.declaredFragment!.element)
              .hasUnknown,
          isTrue,
        );
        final narrow = CallbackValueResolver(
          resolvedUnits: {'main.dart': unit},
          maxTargets: 1,
        );
        final joined = narrow.forElement(
          index.variables['joined']!.declaredFragment!.element,
        );
        expect(joined.targets.length, 1);
        expect(joined.hasUnknown, isTrue);
        final exhausted = CallbackValueResolver(
          resolvedUnits: {'main.dart': unit},
          maxResolutionSteps: 0,
        );
        expect(
          exhausted
              .forElement(index.variables['alias']!.declaredFragment!.element)
              .hasUnknown,
          isTrue,
        );
        final safe = index.functions['safe']!.declaredFragment!.element;
        final bind = index
            .functions['forward']!
            .declaredFragment!
            .element
            .formalParameters
            .first;
        final changed = index
            .functions['changedParameter']!
            .declaredFragment!
            .element
            .formalParameters
            .first;
        final bindings = CallbackValueResolver(
          resolvedUnits: {'main.dart': unit},
          parameterBindings: {
            bind: CallbackValue(targets: [safe]),
            changed: CallbackValue(targets: [safe]),
          },
        );
        expect(bindings.forElement(bind).targets, {safe});
        expect(bindings.forElement(bind).hasUnknown, isFalse);
        expect(bindings.forElement(changed).hasUnknown, isTrue);
        expect(resolver.forElement(null).hasUnknown, isTrue);
      });
    },
  );

  test(
    'Malformed initializer cycles remain unknown without recursion',
    () async {
      await _withFixture((unit) {
        final index = _Declarations();
        unit.accept(index);
        final resolver = CallbackValueResolver(
          resolvedUnits: {'main.dart': unit},
        );
        for (final variable in ['cycleA', 'cycleB']) {
          expect(
            resolver
                .forElement(
                  index.variables[variable]!.declaredFragment!.element,
                )
                .hasUnknown,
            isTrue,
          );
        }
      }, includeCycle: true);
    },
  );

  test('Resolved units added after construction are indexed lazily', () async {
    final units = <String, CompilationUnit>{};
    final resolver = CallbackValueResolver(resolvedUnits: units);
    await _withFixture((unit) {
      final index = _Declarations();
      unit.accept(index);
      final alias = index.variables['alias']!.declaredFragment!.element;
      expect(resolver.forElement(alias).hasUnknown, isTrue);
      units['main.dart'] = unit;
      expect(resolver.forElement(alias).hasUnknown, isFalse);
      expect(
        resolver.forElement(alias).targets.map((element) => element.name),
        ['safe'],
      );
    });
  });

  test('Unresolved syntax does not establish callback values', () {
    final unit = parseString(
      content: 'void safe() {} void main() { final alias = safe; }',
    ).unit;
    final index = _Declarations();
    unit.accept(index);
    final resolver = CallbackValueResolver(resolvedUnits: {'main.dart': unit});
    expect(
      resolver.resolve(index.variables['alias']!.initializer!).hasUnknown,
      isTrue,
    );
  });

  test(
    'Native factory hooks retain returned targets without captured environments',
    () async {
      await _withFixture((unit) {
        final index = _Declarations();
        unit.accept(index);
        final safe = index.functions['safe']!.declaredFragment!.element;
        final parameter = index
            .functions['parameterFactory']!
            .declaredFragment!
            .element
            .formalParameters
            .first;
        final resolver = CallbackValueResolver(
          resolvedUnits: {'main.dart': unit},
          parameterBindings: {
            parameter: CallbackValue(targets: [safe]),
          },
          returnedExpressions: (factory) {
            final body =
                index.functions[factory.name]?.functionExpression.body ??
                index.methods[factory.name]?.body;
            if (body is ExpressionFunctionBody) {
              return [body.expression];
            }
            if (body is BlockFunctionBody) {
              return body.block.statements
                  .whereType<ReturnStatement>()
                  .map((statement) => statement.expression!)
                  .toList();
            }
            return null;
          },
        );
        for (final entry in {
          'returnedSafe': 'safe',
          'returnedFail': 'fail',
          'returnedAlias': 'fail',
          'returnedStatic': 'fail',
        }.entries) {
          final value = resolver.forElement(
            index.variables[entry.key]!.declaredFragment!.element,
          );
          expect(value.hasUnknown, isFalse, reason: entry.key);
          expect(value.targets.map((target) => target.name), [
            entry.value,
          ], reason: entry.key);
        }
        final joined = resolver.forElement(
          index.variables['returnedChoice']!.declaredFragment!.element,
        );
        expect(joined.hasUnknown, isFalse);
        expect(joined.targets.map((target) => target.name).toSet(), {
          'safe',
          'fail',
        });
        for (final variable in [
          'returnedParameter',
          'returnedCapture',
          'returnedLocal',
          'returnedRecursive',
          'returnedVirtual',
        ]) {
          final value = resolver.forElement(
            index.variables[variable]!.declaredFragment!.element,
          );
          expect(value.hasUnknown, isTrue, reason: variable);
          expect(value.targets, isEmpty, reason: variable);
        }
        expect(
          CallbackValueResolver(resolvedUnits: {'main.dart': unit})
              .forElement(
                index.variables['returnedSafe']!.declaredFragment!.element,
              )
              .hasUnknown,
          isTrue,
        );
      });
    },
  );

  test(
    'Immutable aggregate selections retain native callback targets',
    () async {
      await _withFixture((unit) {
        final index = _Declarations();
        unit.accept(index);
        final resolver = CallbackValueResolver(
          resolvedUnits: {'main.dart': unit},
        );
        for (final variable in [
          'recordPositional',
          'recordNamed',
          'recordAliasSelection',
          'listSelection',
          'listAliasSelection',
          'constIndexSelection',
          'mapSelection',
          'mapAliasSelection',
          'freshListSelection',
          'freshMapSelection',
          'freshDuplicateMapSelection',
        ]) {
          final value = resolver.forElement(
            index.variables[variable]!.declaredFragment!.element,
          );
          expect(value.hasUnknown, isFalse, reason: variable);
          expect(value.targets.map((target) => target.name), [
            'fail',
          ], reason: variable);
        }
        final safe = resolver.forElement(
          index.variables['recordSafe']!.declaredFragment!.element,
        );
        expect(safe.hasUnknown, isFalse);
        expect(safe.targets.map((target) => target.name), ['safe']);
      });
    },
  );

  test(
    'Mutable, escaped and unsupported aggregates retain uncertainty',
    () async {
      await _withFixture((unit) {
        final index = _Declarations();
        unit.accept(index);
        final resolver = CallbackValueResolver(
          resolvedUnits: {'main.dart': unit},
        );
        for (final variable in [
          'mutableListSelection',
          'mutatedListSelection',
          'escapedListSelection',
          'mutableMapSelection',
          'mutatedMapSelection',
          'escapedMapSelection',
          'dynamicIndexSelection',
          'dynamicKeySelection',
          'spreadSelection',
          'mapSpreadSelection',
          'missingMapSelection',
          'outOfRangeSelection',
          'reassignedRecordSelection',
          'capturedRecordSelection',
          'mutableAliasSelection',
          'computedKeySelection',
        ]) {
          final value = resolver.forElement(
            index.variables[variable]!.declaredFragment!.element,
          );
          expect(value.hasUnknown, isTrue, reason: variable);
        }
        final exhausted = CallbackValueResolver(
          resolvedUnits: {'main.dart': unit},
          maxResolutionSteps: 1,
        );
        expect(
          exhausted
              .forElement(
                index.variables['recordPositional']!.declaredFragment!.element,
              )
              .hasUnknown,
          isTrue,
        );
        final shallow = CallbackValueResolver(
          resolvedUnits: {'main.dart': unit},
          maxAliasDepth: 1,
        );
        expect(
          shallow
              .forElement(
                index
                    .variables['listAliasSelection']!
                    .declaredFragment!
                    .element,
              )
              .hasUnknown,
          isTrue,
        );
      });
    },
  );
}

Future<void> _withFixture(
  void Function(CompilationUnit) check, {
  bool includeCycle = false,
}) async {
  final directory = await Directory.systemTemp.createTemp('callback-values-');
  AnalysisContextCollection? collection;
  try {
    final file = File('${directory.path}/main.dart');
    await file.writeAsString('''
void safe() {}
void fail() { throw 'failure'; }
void Function() safeFactory() => safe;
void Function() failFactory() => fail;
void Function() choiceFactory(bool flag) => flag ? safe : fail;
void Function() parameterFactory(void Function() action) => action;
void Function() capturedFactory(void Function() action) => () { action(); };
void Function() localFactory() { void action() {} return action; }
void Function() recursiveFactory() => recursiveFactory();
void escape(Object aggregate) {}
T identity<T>(T value) => value;
void forward(void Function() action) { action(); }
void changedParameter(void Function() action) { void mutate() { action = fail; } mutate(); action(); }
class Worker {
  Worker();
  Worker.named();
  static T generic<T>(T value) => value;
  static void Function() staticFactory() => fail;
  void Function() virtualFactory() => safe;
  void execute() {}
  void Function() get callback => fail;
}
void fixture(bool choose, void Function() Function() factory) {
  final alias = (safe);
  final chain = alias;
  final joined = choose ? safe : fail;
  final switched = switch (choose) { true => safe, false => fail };
  final worker = Worker();
  final method = worker.execute;
  final propertyMethod = (worker).execute;
  final getterValue = worker.callback;
  final inline = () {};
  final partlyUnknown = choose ? safe : factory();
  final constructor = Worker.new;
  final namedConstructor = Worker.named;
  final sdkFactory = Future<void>.sync;
  final genericFunction = identity<int>;
  final genericMethod = Worker.generic<int>;
  final returnedSafe = safeFactory();
  final returnedFail = failFactory();
  final returnedChoice = choiceFactory(choose);
  final factoryAlias = failFactory;
  final returnedAlias = factoryAlias();
  final returnedStatic = Worker.staticFactory();
  final returnedParameter = parameterFactory(fail);
  final returnedCapture = capturedFactory(fail);
  final returnedLocal = localFactory();
  final returnedRecursive = recursiveFactory();
  final returnedVirtual = worker.virtualFactory();
  final callbacksRecord = (safe, fail, named: fail);
  final recordAlias = callbacksRecord;
  final recordSafe = callbacksRecord.\$1;
  final recordPositional = callbacksRecord.\$2;
  final recordNamed = callbacksRecord.named;
  final recordAliasSelection = (recordAlias).named;
  const callbacksList = [safe, fail];
  final listAlias = callbacksList;
  final listSelection = callbacksList[1];
  final listAliasSelection = listAlias[1];
  const callbackIndex = 1;
  final constIndexSelection = callbacksList[callbackIndex];
  const callbacksMap = {'safe': safe, 'failure': fail};
  final mapAlias = callbacksMap;
  final mapSelection = callbacksMap['failure']!;
  final mapAliasSelection = mapAlias['failure']!;
  final freshListSelection = [safe, fail][1];
  final freshMapSelection = {'failure': fail}['failure']!;
  final freshDuplicateMapSelection = {'failure': safe, 'failure': fail}['failure']!;
  final mutableList = [safe];
  final mutableListSelection = mutableList[0];
  final mutatedList = [safe];
  mutatedList[0] = fail;
  final mutatedListSelection = mutatedList[0];
  final escapedList = [safe];
  escape(escapedList);
  final escapedListSelection = escapedList[0];
  final mutableMap = {'failure': safe};
  final mutableMapSelection = mutableMap['failure'];
  final mutatedMap = {'failure': safe};
  mutatedMap['failure'] = fail;
  final mutatedMapSelection = mutatedMap['failure'];
  final escapedMap = {'failure': safe};
  escape(escapedMap);
  final escapedMapSelection = escapedMap['failure'];
  final dynamicIndexSelection = callbacksList[choose ? 0 : 1];
  final dynamicKeySelection = callbacksMap[choose ? 'safe' : 'failure'];
  final spreadSelection = [...callbacksList][1];
  final mapSpreadSelection = {...callbacksMap}['failure'];
  final missingMapSelection = callbacksMap['missing'];
  final outOfRangeSelection = callbacksList[5];
  var reassignedRecord = (safe,);
  reassignedRecord = (fail,);
  final reassignedRecordSelection = reassignedRecord.\$1;
  var capturedRecord = (safe,);
  void rewriteRecord() { capturedRecord = (fail,); }
  rewriteRecord();
  final capturedRecordSelection = capturedRecord.\$1;
  final mutableAlias = mutableList;
  final mutableAliasSelection = mutableAlias[0];
  final computedKeySelection = {'safe': safe, (choose ? 'other' : 'safe'): fail}['safe'];
  var changed = safe;
  changed = fail;
  var capturedWrite = safe;
  void mutate() { capturedWrite = fail; }
  mutate();
  var patternWrite = safe;
  (patternWrite,) = (fail,);
  var loopWrite = safe;
  for (loopWrite in [fail]) {}
  ${includeCycle ? 'late final void Function() cycleA = cycleB; late final void Function() cycleB = cycleA;' : ''}
  final stored = [safe].first;
  late void Function() uninitialized;
}
''');
    collection = AnalysisContextCollection(includedPaths: [directory.path]);
    final result =
        await collection
                .contextFor(file.path)
                .currentSession
                .getResolvedUnit(file.path)
            as ResolvedUnitResult;
    final errors = result.diagnostics
        .where(
          (diagnostic) => diagnostic.diagnosticCode.severity.name == 'ERROR',
        )
        .toList();
    if (includeCycle) {
      expect(errors, hasLength(2));
      expect(
        errors.every((diagnostic) => diagnostic.message.contains('cycleB')),
        isTrue,
      );
    } else {
      expect(errors, isEmpty);
    }
    check(result.unit);
  } finally {
    await collection?.dispose();
    await directory.delete(recursive: true);
  }
}

final class _Declarations extends RecursiveAstVisitor<void> {
  final variables = <String, VariableDeclaration>{};
  final functions = <String, FunctionDeclaration>{};
  final methods = <String, MethodDeclaration>{};
  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    methods[node.name.lexeme] = node;
    super.visitMethodDeclaration(node);
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    variables[node.name.lexeme] = node;
    super.visitVariableDeclaration(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    functions[node.name.lexeme] = node;
    super.visitFunctionDeclaration(node);
  }
}
