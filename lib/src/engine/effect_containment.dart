import 'package:analyzer/dart/ast/ast.dart';

import '../analysis/throw_protection.dart';
import '../analysis/throw_summary.dart';
import 'exception_effect.dart';

/// Projects only effects that escape at this execution/observation site.
/// Inference ignores propagation exemptions so callers still see outward
/// effects; diagnostic adapters honor those exemptions by default.
Iterable<ThrowSource> residualEffects(
  AstNode node,
  Iterable<ThrowSource> sources, {
  bool respectExceptionBoundary = true,
}) => sources.where(
  (source) => !isEffectContained(
    node,
    source,
    respectExceptionBoundary: respectExceptionBoundary,
  ),
);

bool isEffectContained(
  AstNode node,
  ThrowSource source, {
  bool respectExceptionBoundary = true,
}) {
  final channel = ExceptionEffect.fromSource(source).channel;
  return isProtectedByCatch(
    node,
    channel: channel,
    requireAsyncProtection:
        channel == ExceptionChannel.future ||
        channel == ExceptionChannel.stream,
    exceptionTypes: source.exceptionTypes,
    resolvedExceptionTypes: source.resolvedExceptionTypes,
    exceptionSupertypes: source.exceptionSupertypes,
    respectExceptionBoundary: respectExceptionBoundary,
  );
}
