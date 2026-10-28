// ignore_for_file: implementation_imports

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/src/analysis_options/analysis_options.dart';
import 'package:analyzer/src/dart/analysis/driver_based_analysis_context.dart';
import 'package:analyzer/src/dart/analysis/file_state.dart';
import 'package:analyzer/src/dart/analysis/library_analyzer.dart';
import 'package:analyzer/src/dart/analysis/session.dart';
import 'package:analyzer/src/dart/element/element.dart';
import 'package:analyzer/src/dart/resolver/flow_analysis_visitor.dart';
import 'package:analyzer/src/util/performance/operation_performance.dart';

import 'effect_invalidation.dart';

/// Resolves dependency bodies synchronously within the caller's session.
///
/// Rule callbacks cannot await the public resolution API. This adapter uses
/// the pinned analyzer's library resolver, with lints disabled to prevent
/// recursive rule execution. It preserves element identity, selected imports,
/// language versions, parts and the driver's editor-overlay contents.
/// Failed or inconsistent resolution returns null and must retain uncertainty.
final class ResolvedDependencies {
  ResolvedDependencies(this._caller) : _session = _caller.session;

  final LibraryElement _caller;
  final Object _session;
  final Map<LibraryElement, Map<String, CompilationUnit>?> _libraries = {};
  static const maxLibraries = 128;

  bool get isCurrent {
    final session = _session;
    if (session is! AnalysisSessionImpl) return false;
    try {
      session.checkConsistency();
      return true;
    } catch (_) {
      return false;
    }
  }

  Map<String, CompilationUnit>? resolve(LibraryElement library) {
    EffectInvalidation.dependsOn(_caller, library);
    if (library.isInSdk ||
        !identical(library.session, _session) ||
        !isCurrent) {
      return null;
    }
    if (_libraries.containsKey(library)) return _libraries[library];
    if (_libraries.length >= maxLibraries) return null;
    // Reserve before resolving, so reentry cannot recursively resolve a body.
    _libraries[library] = null;
    try {
      final session = _session as AnalysisSessionImpl;
      final context = session.analysisContext;
      if (context is! DriverBasedAnalysisContext ||
          library is! LibraryElementImpl) {
        return null;
      }
      final file = context.driver.fsState.getFileForPath(
        library.firstFragment.source.fullName,
      );
      final kind = file.kind;
      if (kind is! LibraryFileKind || !file.exists) return null;
      final options =
          (AnalysisOptionsBuilder.from(file.analysisOptions)
                ..lint = false
                ..lintRules = [])
              .build();
      final results = LibraryAnalyzer(
        options,
        session.declaredVariables,
        library,
        session.inheritanceManager,
        kind,
        performance: OperationPerformanceImpl('exception_dependency'),
        typeSystemOperations: TypeSystemOperations(
          library.typeSystem,
          strictCasts: options.strictCasts,
        ),
      ).analyze();
      if (!isCurrent || results.any((result) => !result.file.exists)) {
        return null;
      }
      return _libraries[library] = {
        for (final result in results) result.file.path: result.unit,
      };
    } catch (_) {
      // Edits, unsupported implementations and resolver failures widen the
      // caller to unknown; they must never become a no-throw proof.
      return null;
    }
  }
}
