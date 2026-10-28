import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/dart/ast/ast.dart';

import '../analysis/inferred_throw_analyzer.dart';
import '../config/exception_analysis_options.dart';
import '../config/throwing_api_manifest.dart';
import 'resolved_dependencies.dart';
import 'effect_invalidation.dart';

/// Shares summaries across diagnostic adapters for the same resolved unit.
/// Weak keys release old analysis results when an editor replaces the AST.
/// Configuration is reloaded before reuse, so an options/manifest edit cannot
/// reuse summaries produced under another policy.
final class ExceptionAnalysisService {
  factory ExceptionAnalysisService._(
    RuleContext context,
    ExceptionAnalysisOptions options,
    ThrowingApiManifest manifest,
  ) => ExceptionAnalysisService._withDependencies(
    context,
    options,
    manifest,
    ResolvedDependencies(context.libraryElement!),
  );

  ExceptionAnalysisService._withDependencies(
    RuleContext context,
    this.options,
    this.manifest,
    ResolvedDependencies dependencies,
  ) : _library = context.libraryElement,
      _knownUnits = {
        for (final unit in context.allUnits) unit.file.path: unit.unit,
      },
      analyzer = InferredThrowAnalyzer(
        manifest: manifest,
        options: options,
        featureSet: context.libraryElement!.featureSet,
        packageRootPath: context.package?.root.path,
        knownUnits: {
          for (final unit in context.allUnits) unit.file.path: unit.unit,
        },
        resolveDependency: dependencies.resolve,
        resolutionIsCurrent: () => dependencies.isCurrent,
      );

  final ExceptionAnalysisOptions options;
  final ThrowingApiManifest manifest;
  final InferredThrowAnalyzer analyzer;
  final Object? _library;
  final Map<String, CompilationUnit> _knownUnits;

  bool _matchesResolution(RuleContext context) {
    if (!identical(_library, context.libraryElement)) return false;
    final units = context.allUnits.toList();
    return units.length == _knownUnits.length &&
        units.every(
          (unit) => identical(_knownUnits[unit.file.path], unit.unit),
        );
  }

  static final _units = Expando<ExceptionAnalysisService>();

  static ExceptionAnalysisService forContext(RuleContext context) {
    EffectInvalidation.observe(context);
    final options = ExceptionAnalysisOptions.load(
      packageRoot: context.package?.root.path,
      currentFilePath: context.definingUnit.file.path,
    );
    final manifest = ThrowingApiManifest.loadResult(
      packageRoot: context.package?.root.path,
      currentFilePath: context.definingUnit.file.path,
    ).unwrapOr(ThrowingApiManifest.empty());
    // Node processors register before currentUnit is set. Key by the defining
    // unit, which exists throughout registration and covers parts as well.
    final unit = context.definingUnit.unit;
    final previous = _units[unit];
    // These configuration objects are immutable. Comparing their normalized
    // content is independent of YAML formatting and file timestamps.
    if (previous != null &&
        previous._matchesResolution(context) &&
        previous.analyzer.dependenciesAreCurrent &&
        previous.options.cacheKey == options.cacheKey &&
        previous.manifest.cacheKey == manifest.cacheKey) {
      return previous;
    }
    final service = ExceptionAnalysisService._(context, options, manifest);
    _units[unit] = service;
    return service;
  }
}
