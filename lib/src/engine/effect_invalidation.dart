// ignore_for_file: implementation_imports

import 'dart:async';

import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/src/dart/analysis/driver_based_analysis_context.dart';

/// Analyzer API signatures do not describe exception effects. A body-only
/// dependency edit must also invalidate callers' diagnostics, even when their
/// ordinary type-checking result would otherwise remain reusable.
final class EffectInvalidation {
  static final _contexts = Expando<_ContextEffects>();

  static void observe(RuleContext context) {
    final analysisContext = context.libraryElement?.session.analysisContext;
    if (analysisContext is! DriverBasedAnalysisContext) return;
    final effects = _contexts[analysisContext] ??= _ContextEffects(
      analysisContext,
    );
    final path = context.definingUnit.file.path;
    final contents = {
      for (final unit in context.allUnits) unit.file.path: unit.content,
    };
    final previous = effects.contents[path];
    effects.contents[path] = contents;
    if (previous != null &&
        (previous.length != contents.length ||
            contents.entries.any(
              (entry) => previous[entry.key] != entry.value,
            ))) {
      effects.invalidateCallers(path);
    }
  }

  static void dependsOn(LibraryElement caller, LibraryElement dependency) {
    final context = caller.session.analysisContext;
    if (context is! DriverBasedAnalysisContext || dependency.isInSdk) return;
    final effects = _contexts[context] ??= _ContextEffects(context);
    final callerPath = caller.firstFragment.source.fullName;
    final dependencyPath = dependency.firstFragment.source.fullName;
    if (callerPath == dependencyPath) return;
    (effects.callers[dependencyPath] ??= {}).add(callerPath);
  }
}

final class _ContextEffects {
  _ContextEffects(this.context);

  final DriverBasedAnalysisContext context;
  final contents = <String, Map<String, String>>{};
  final callers = <String, Set<String>>{};
  final pending = <String>{};
  bool scheduled = false;

  void invalidateCallers(String changed) {
    final visited = <String>{changed};
    final queue = <String>[changed];
    while (queue.isNotEmpty) {
      for (final caller in callers[queue.removeLast()] ?? const <String>{}) {
        if (!visited.add(caller)) {
          continue;
        }
        pending.add(caller);
        queue.add(caller);
      }
    }
    if (scheduled || pending.isEmpty) return;
    scheduled = true;
    // Never change the analyzer's session while synchronous lint callbacks are
    // resolving dependencies. Batch all affected callers in the next event.
    Timer.run(() {
      scheduled = false;
      final paths = pending.toList();
      pending.clear();
      for (final path in paths) {
        if (context.contextRoot.isAnalyzed(path)) {
          context.driver.changeFile(path);
        }
      }
    });
  }
}
