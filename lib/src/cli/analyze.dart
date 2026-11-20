import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/session.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../analysis/exception_annotations.dart';
import '../analysis/inferred_throw_analyzer.dart';
import '../config/exception_analysis_options.dart';
import '../config/throwing_api_manifest.dart';
import '../engine/analysis_compatibility.dart';
import '../engine/resolved_dependencies.dart';
import '../utils/source_utils.dart';
import 'report.dart';

/// File scope controls reporting, not dependency inference. Each library uses
/// the same resolver and inference implementation as the plugin adapters.
Future<Map<String, dynamic>> analyzeProject(
  Map<String, dynamic> request,
) async {
  final root = request['root'] as String;
  final paths = (request['paths'] as List).cast<String>();
  final explicitFiles = (request['explicitFiles'] as List).cast<String>();
  final changed = (request['changedFiles'] as List?)?.cast<String>().toSet();
  final errors = <Map<String, dynamic>>[];
  final findings = <String, Map<String, dynamic>>{};
  final callables = <Map<String, dynamic>>[];
  final configuration = <String, String>{};
  final files = <String>[];
  final skippedFiles = <Map<String, String>>[];
  final dependencySessions = <String, AnalysisSession>{};
  final declarationsByPath = <String, _Declarations>{};
  _Declarations declarationsFor(String path, CompilationUnit unit) =>
      declarationsByPath.putIfAbsent(path, () {
        final declarations = _Declarations();
        unit.accept(declarations);
        declarations.assignSymbols();
        return declarations;
      });
  final collection = AnalysisContextCollection(includedPaths: [root]);
  String relative(String file) => reportPath(file, root: root);
  try {
    await AnalysisCompatibility.initialize();
    if (AnalysisCompatibility.warning case final warning?) {
      errors.add({'code': 'unsupported_environment', 'message': warning});
    }
    final candidates =
        {
            for (final context in collection.contexts)
              ...context.contextRoot.analyzedFiles().where(
                (file) => file.endsWith('.dart'),
              ),
          }.where((file) {
            final rel = relative(file);
            return paths.any(
                  (scope) =>
                      scope == '.' || rel == scope || rel.startsWith('$scope/'),
                ) &&
                (changed == null || changed.contains(rel));
          }).toList()
          ..sort();
    if (changed == null) {
      final candidatePaths = candidates.map(relative).toSet();
      for (final file in explicitFiles) {
        if (candidatePaths.contains(file)) continue;
        errors.add({
          'code': 'unavailable_input',
          'file': file,
          'message':
              'Requested file is missing or excluded by analyzer configuration.',
        });
      }
    }
    final policies =
        <String, (ExceptionAnalysisOptions, ThrowingApiManifest)?>{};
    final libraries =
        <String, (ResolvedLibraryResult, InferredThrowAnalyzer)>{};
    void loadPolicy(String packageRoot) {
      if (!policies.containsKey(packageRoot)) {
        final options = ExceptionAnalysisOptions.loadResult(
          packageRoot: packageRoot,
        );
        final manifest = ThrowingApiManifest.loadResult(
          packageRoot: packageRoot,
        );
        if (options.errorOrNull case final failure?) {
          errors.add({
            'code': 'invalid_configuration',
            'file': relative(failure.sourcePath ?? packageRoot),
            'message': failure.message,
          });
        }
        if (manifest.errorOrNull case final failure?) {
          errors.add({
            'code': 'invalid_manifest',
            'file': relative(failure.sourcePath ?? packageRoot),
            'message': failure.message,
          });
        }
        final optionValue = options.valueOrNull;
        final manifestValue = manifest.valueOrNull;
        policies[packageRoot] = optionValue == null || manifestValue == null
            ? null
            : (optionValue, manifestValue);
        if (optionValue != null && manifestValue != null) {
          configuration[relative(packageRoot)] = fingerprint([
            optionValue.cacheKey,
            manifestValue.cacheKey,
          ]);
        }
      }
    }

    // Record contexts even when changed-file selection is empty, so an empty
    // rerun can be compared with its baseline. Exclusion/config edits must not
    // masquerade as resolved effects.
    for (final context in collection.contexts) {
      final contextRoot = context.contextRoot;
      final packageRoot = _packageRoot(
        p.join(contextRoot.root.path, '_scope.dart'),
        root,
      );
      loadPolicy(packageRoot);
      final excluded = contextRoot.excludedPaths.map(relative).toList()..sort();
      configuration['context:${relative(contextRoot.root.path)}'] = fingerprint(
        [
          excluded,
          switch (contextRoot.optionsFile) {
            final optionsFile? => _analysisOptionsContents(
              optionsFile.path,
              context.currentSession,
              root,
            ),
            null => null,
          },
          for (final name in ['pubspec.yaml', 'pubspec.lock'])
            if (File(p.join(packageRoot, name)).existsSync())
              File(p.join(packageRoot, name)).readAsStringSync(),
        ],
      );
    }
    for (final file in candidates) {
      final packageRoot = _packageRoot(file, root);
      loadPolicy(packageRoot);
      final policy = policies[packageRoot];
      if (policy == null) continue;
      final (options, manifest) = policy;
      if ((!options.analyzeTestFiles &&
              isTestDartFile(file, packageRoot: packageRoot)) ||
          (!options.analyzeGeneratedFiles && isGeneratedDartFile(file))) {
        skippedFiles.add({
          'file': relative(file),
          'reason': 'excluded_by_exception_analysis_configuration',
        });
        continue;
      }
      files.add(relative(file));
      final session = collection.contextFor(file).currentSession;
      final result = await session.getResolvedLibraryContaining(file);
      if (result is! ResolvedLibraryResult) {
        errors.add({
          'code': 'resolution_failed',
          'file': relative(file),
          'message': 'Cannot resolve library: ${result.runtimeType}',
        });
        continue;
      }
      final unit = result.unitWithPath(file);
      if (unit == null) {
        errors.add({
          'code': 'resolution_failed',
          'file': relative(file),
          'message': 'Resolved library does not contain requested unit.',
        });
        continue;
      }
      // A broken dependency must not yield a clean report for an untouched caller.
      for (final resolved in result.units) {
        for (final diagnostic in resolved.diagnostics.where(
          (d) => d.severity.name == 'error',
        )) {
          errors.add({
            'code': 'dart_analysis_error',
            'file': relative(resolved.path),
            'offset': diagnostic.offset,
            'message': diagnostic.message,
          });
        }
      }
      final key = '${result.element.uri}|$packageRoot';
      var entry = libraries[key];
      if (entry == null || !identical(entry.$1.element, result.element)) {
        for (final unit in result.units) {
          declarationsFor(unit.path, unit.unit);
        }
        final dependencies = ResolvedDependencies(result.element);
        entry = (
          result,
          InferredThrowAnalyzer(
            manifest: manifest,
            options: options,
            featureSet: result.element.featureSet,
            packageRootPath: packageRoot,
            knownUnits: {for (final unit in result.units) unit.path: unit.unit},
            resolveDependency: (library) {
              final units = dependencies.resolve(library);
              if (units != null) {
                for (final path in units.keys) {
                  dependencySessions[path] = session;
                  declarationsFor(path, units[path]!);
                }
              }
              return units;
            },
            resolutionIsCurrent: () => dependencies.isCurrent,
          ),
        );
        libraries[key] = entry;
      }
      final declarations = declarationsFor(file, unit.unit);
      for (final (node, element) in declarations.items) {
        final summary = entry.$2.summarizeExecutable(element);
        final symbol = declarations.symbols[element]!;
        final location = unit.lineInfo.getLocation(node.offset);
        final boundary = hasExceptionBoundaryAnnotation(element);
        callables.add({
          'file': relative(file),
          'symbol': symbol,
          'line': location.lineNumber,
          'column': location.columnNumber,
          'offset': node.offset,
          'length': node.length,
          'elementKey': summary.elementKey,
          'complete': summary.complete && !summary.hasUnknownEffects,
          'reason': summary.truncationReason,
          'intentionalBoundary': boundary,
          'dependencies': summary.dependencyElementKeys,
          'effectCount': summary.effects.length,
        });
        for (final effect in summary.effects) {
          final source = effect.source;
          final types = source.exceptionTypes.toSet().toList()..sort();
          final evidence =
              source.evidenceKinds.map((item) => item.name).toList()..sort();
          final origin = source.origin;
          final originFile = origin?.filePath == null
              ? null
              : relative(origin!.filePath!);
          final originUnit = declarationsByPath[origin?.filePath];
          final originDeclarations =
              originUnit?.items
                  .where(
                    (item) =>
                        origin?.offset != null &&
                        item.$1.offset <= origin!.offset! &&
                        item.$1.end > origin.offset!,
                  )
                  .toList()
                ?..sort((a, b) => a.$1.length.compareTo(b.$1.length));
          final originSymbol =
              originDeclarations == null || originDeclarations.isEmpty
              ? null
              : originUnit!.symbols[originDeclarations.first.$2];
          final code = effect.certainty.name == 'unknown'
              ? 'unknown_exception_effect'
              : 'escaping_exception_effect';
          final id = fingerprint([
            relative(file),
            symbol,
            code,
            source.kind.name,
            effect.channel.name,
            effect.certainty.name,
            types,
            evidence,
            source.displayName,
            originFile,
            originSymbol,
            origin?.displayName,
          ]);
          findings[id] = {
            'fingerprint': id,
            'code': code,
            'file': relative(file),
            'symbol': symbol,
            'line': location.lineNumber,
            'column': location.columnNumber,
            'offset': node.offset,
            'length': node.length,
            'channel': effect.channel.name,
            'certainty': effect.certainty.name,
            'exceptionTypes': types,
            'sourceKind': source.kind.name,
            'evidence': evidence,
            'message': source.displayName,
            'reason': effect.certainty.name == 'unknown'
                ? summary.truncationReason ?? source.displayName
                : null,
            'intentionalBoundary': boundary,
            'origin': origin == null
                ? null
                : {
                    'name': origin.displayName,
                    'file': originFile,
                    'symbol': originSymbol,
                    'offset': origin.offset,
                    'length': origin.length,
                  },
            'trace': entry.$2
                .explainSource(summary.elementKey, source)
                .map(
                  (frame) => {
                    'name': frame.displayName,
                    'file': frame.filePath == null
                        ? null
                        : relative(frame.filePath!),
                    'offset': frame.offset,
                    'length': frame.length,
                  },
                )
                .toList(),
          };
        }
      }
    }
    for (final dependency in dependencySessions.entries) {
      final result = await dependency.value.getErrors(dependency.key);
      if (result is! ErrorsResult) {
        errors.add({
          'code': 'resolution_failed',
          'file': relative(dependency.key),
          'message': 'Cannot validate resolved dependency.',
        });
        continue;
      }
      for (final diagnostic in result.diagnostics.where(
        (d) => d.severity.name == 'error',
      )) {
        errors.add({
          'code': 'dart_analysis_error',
          'file': relative(dependency.key),
          'offset': diagnostic.offset,
          'message': diagnostic.message,
        });
      }
    }
    final sortedConfiguration = {
      for (final key in configuration.keys.toList()..sort())
        key: configuration[key],
    };
    final sortedFindings = findings.values.toList()
      ..sort(
        (a, b) =>
            (a['fingerprint'] as String).compareTo(b['fingerprint'] as String),
      );
    return {
      'schemaVersion': reportSchemaVersion,
      'status': errors.isEmpty ? 'completed' : 'failed',
      'analysisComplete':
          errors.isEmpty && callables.every((c) => c['complete'] == true),
      'sdkVersion': Platform.version.split(' ').first,
      'scope': {
        'paths': paths,
        'changedSince': request['changedSince'],
        'changedRevision': request['changedRevision'],
      },
      'configuration': sortedConfiguration,
      'files': files,
      'skippedFiles': skippedFiles,
      'callables': callables,
      'findings': sortedFindings,
      'errors': {
        for (final error in errors) fingerprint(error): error,
      }.values.toList(),
    };
  } finally {
    await collection.dispose();
  }
}

String _packageRoot(String file, String root) {
  var directory = p.dirname(file);
  while (p.isWithin(root, directory) || directory == root) {
    if (File(p.join(directory, 'pubspec.yaml')).existsSync()) return directory;
    if (directory == root) break;
    directory = p.dirname(directory);
  }
  return root;
}

Map<String, String?> _analysisOptionsContents(
  String entryPath,
  AnalysisSession session,
  String root,
) {
  final visited = <String>{};
  final pending = [entryPath];
  final contents = <String, String?>{};
  while (pending.isNotEmpty) {
    final path = pending.removeLast();
    if (!visited.add(path)) continue;
    final file = session.resourceProvider.getFile(path);
    final text = file.exists ? file.readAsStringSync() : null;
    contents[reportPath(path, root: root)] = text;
    if (text == null) continue;

    final Object? yaml;
    try {
      yaml = loadYaml(text);
    } on YamlException {
      // The analyzer ignores invalid YAML. Its contents still affect identity.
      continue;
    }
    if (yaml is! YamlMap) continue;
    final includes = switch (yaml['include']) {
      final String include => [include],
      final YamlList list => list.whereType<String>(),
      _ => const <String>[],
    };
    final baseUri = Uri.file(path);
    for (final include in includes) {
      final uri = Uri.tryParse(include);
      if (uri == null) continue;
      if (session.uriConverter.uriToPath(baseUri.resolveUri(uri))
          case final includedPath?) {
        pending.add(includedPath);
      }
    }
  }
  return contents;
}

String _symbol(ExecutableElement element) {
  final names = <String>[];
  if (element is LocalFunctionElement) {
    // Local functions expose their lexical ancestry through fragments.
    Fragment? current = element.firstFragment;
    while (current != null && current is! LibraryFragment) {
      names.add(current.name ?? '<unnamed>');
      current = current.enclosingFragment;
    }
  } else {
    Element? current = element;
    while (current != null && current is! LibraryElement) {
      names.add(current.name ?? '<unnamed>');
      current = current.enclosingElement;
    }
  }
  final kind = switch (element) {
    ConstructorElement() => 'constructor',
    GetterElement() => 'getter',
    SetterElement() => 'setter',
    _ => 'function',
  };
  return '$kind:${names.reversed.join('.')}';
}

final class _Declarations extends RecursiveAstVisitor<void> {
  final items = <(AstNode, ExecutableElement)>[];
  final symbols = <ExecutableElement, String>{};

  void assignSymbols() {
    final declarationsByName = <String, List<ExecutableElement>>{};
    for (final (_, element) in items) {
      (declarationsByName[_symbol(element)] ??= []).add(element);
    }
    for (final MapEntry(key: name, value: elements)
        in declarationsByName.entries) {
      if (elements.length == 1) {
        symbols[elements.single] = name;
      } else {
        // Declaration order distinguishes shadowed local names without tying
        // finding identity to source offsets.
        for (var index = 0; index < elements.length; index++) {
          symbols[elements[index]] = '$name#${index + 1}';
        }
      }
    }
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    if (node.declaredFragment?.element case PropertyInducingElement variable) {
      if (variable.getter case final getter?) items.add((node, getter));
      if (variable.setter case final setter?) items.add((node, setter));
    }
    super.visitVariableDeclaration(node);
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    for (final constructor
        in node.declaredFragment?.element.constructors ??
            <ConstructorElement>[]) {
      if (constructor.isOriginImplicitDefault) items.add((node, constructor));
    }
    super.visitClassDeclaration(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    if (node.declaredFragment?.element case final element?) {
      items.add((node, element));
    }
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (node.declaredFragment?.element case final element?) {
      items.add((node, element));
    }
    super.visitMethodDeclaration(node);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    if (node.declaredFragment?.element case final element?) {
      items.add((node, element));
    }
    super.visitConstructorDeclaration(node);
  }
}
