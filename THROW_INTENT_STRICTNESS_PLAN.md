# Throw Intent Strictness Plan

## Goal

Add configurable strictness levels that decide whether exception sources should be reported based on how deliberate the exception behavior is.

The strictness should be independently configurable for:

- Internal package code.
- Third-party package code.

This should reduce noisy third-party reports from dynamic, unresolved, external, or otherwise unknowable calls while still allowing the plugin to report third-party APIs that deliberately use exception-based error handling.

## Proposed User Configuration

Add an `exception_analysis.strictness` section:

```yaml
plugins:
  dart_exception_lint:
    exception_analysis:
      strictness:
        internal: possible
        third_party: deliberate
```

Supported values:

| Value | Meaning |
| --- | --- |
| `deliberate` | Report explicitly exception-oriented code only. |
| `probable` | Report deliberate sources plus high-risk language/runtime operations such as null assertions and casts. |
| `possible` | Report probable sources plus known APIs that commonly throw depending on input or state. |
| `unknown` | Report possible sources plus unresolved, dynamic, external, abstract, and truncated analysis boundaries. |

Suggested defaults:

```yaml
strictness:
  internal: possible
  third_party: deliberate
```

These defaults keep local code reasonably strict while avoiding third-party warnings unless the plugin can trace the behavior to deliberate exception usage.

## Throw Intent Model

Add a new enum, likely in `lib/src/analysis/throw_summary.dart`:

```dart
enum ThrowIntent {
  deliberate,
  probable,
  possible,
  unknown,
}
```

Add ordering helpers:

```dart
extension ThrowIntentExtension on ThrowIntent {
  String get wireName;

  bool meets(ThrowIntent minimum);

  static ThrowIntent parse(String value);
}
```

Ordering should be:

```text
deliberate < probable < possible < unknown
```

For reporting, a source is included when its intent is at least as strict as the configured minimum. For example:

- Minimum `deliberate` reports only deliberate sources.
- Minimum `possible` reports deliberate, probable, and possible sources.
- Minimum `unknown` reports everything, including unresolved boundaries.

## Source Kind Mapping

Map existing `ThrowSourceKind` values to intent:

| Source kind | Intent | Rationale |
| --- | --- | --- |
| `explicitThrow` | `deliberate` | The implementation explicitly throws. |
| `rethrowExpression` | `deliberate` | The implementation explicitly propagates an exception. |
| `futureError` | `deliberate` | Explicit async error creation. |
| `completerCompleteError` | `deliberate` | Explicit async error completion. |
| `streamAddError` | `deliberate` | Explicit stream error emission. |
| `nullAssertion` | `probable` | The code intentionally accepts a runtime null failure path. |
| `asCast` | `probable` | The code intentionally accepts a runtime type failure path. |
| `parseCall` | `possible` | Known throwing API, usually input-dependent. |
| `decodeCall` | `possible` | Known throwing API, usually input-dependent. |
| `collectionStateCall` | `possible` | Known throwing API, usually state-dependent. |
| `indexAccess` | `possible` | Known throwing operation, state-dependent. |
| `externalCall` | `unknown` | Throw behavior cannot be inspected. |
| `dynamicInvocation` | `unknown` | Target cannot be resolved. |
| `unresolvedCall` | `unknown` | Target cannot be resolved. |
| `truncation` | `unknown` | Analysis did not complete. |
| `inferredCall` | Inherited | Preserve strongest underlying source intent. |
| `awaitedAsyncDependency` | Inherited | Preserve strongest underlying source intent. |
| `manifestOverride` | Configured or `deliberate` | Manifest is explicit user knowledge; default to deliberate unless manifest intent is added. |

## Preserve Intent Through Inference

Currently, inferred dependency reports collapse underlying causes into generic `inferredCall` or `awaitedAsyncDependency` sources. That loses the reason a call was considered throwing.

Update `ThrowSource` to carry an optional explicit intent:

```dart
final class ThrowSource {
  const ThrowSource({
    required this.kind,
    required this.confidence,
    required this.displayName,
    this.intent,
    this.isAsync = false,
    this.exceptionTypes = const [],
  });

  final ThrowIntent? intent;

  ThrowIntent get effectiveIntent => intent ?? kind.defaultIntent;
}
```

When `InferredThrowAnalyzer.inferCallFromBody` creates propagated sources from a dependency summary:

- Compute the strongest reportable underlying intent from `summary.sources`.
- Assign that intent to the propagated `inferredCall` or `awaitedAsyncDependency`.
- Preserve exception types as today.

This allows a third-party method containing `throw Exception()` to remain `deliberate`, while a third-party method that only reaches an unresolved call remains `unknown`.

## Origin Detection

Reuse the existing package-root logic:

- Internal: executable source path is inside `packageRootPath`.
- Third-party: executable source path is outside `packageRootPath`.

Centralize this as a helper in `InferredThrowAnalyzer`:

```dart
CodeOrigin _originForExecutable(ExecutableElement executable)
```

Possible enum:

```dart
enum CodeOrigin {
  internal,
  thirdParty,
}
```

SDK code can initially be treated as third-party for strictness purposes unless a separate `sdk` strictness is added later.

## Reporting Filter

Add filtering after a summary is computed, before returning `InferredCallAnalysis`.

High-level flow:

1. Resolve the executable.
2. Summarize it as today.
3. Determine origin.
4. Determine minimum intent from options:
   - `strictness.internal`
   - `strictness.thirdParty`
5. Filter `summary.sources` to sources whose `effectiveIntent` meets the origin minimum.
6. If no sources remain, return `null`.
7. Build `InferredCallAnalysis` from the filtered sources.

This filter should apply to:

- `catch_inferred_throwing_calls`
- `catch_async_error_sources` when async errors are inferred from implementation source
- `catch_unknown_dynamic_calls` for third-party unknowns

Direct local syntax rules like `no_null_assertion` and `no_manual_throw` should not be weakened by inferred-call strictness. Those rules intentionally report direct syntax in the user's code.

## Config Parsing

Update `ExceptionAnalysisOptions`:

- Add `internalStrictness`.
- Add `thirdPartyStrictness`.
- Parse `exception_analysis.strictness.internal`.
- Parse `exception_analysis.strictness.third_party`.
- Keep current behavior when the section is omitted by using defaults.

Suggested defaults:

```dart
internalStrictness: ThrowIntent.possible,
thirdPartyStrictness: ThrowIntent.deliberate,
```

Consider whether existing booleans should remain:

- `report.unknown` can remain as a coarse global kill switch for unknown confidence.
- `treat_dynamic_invocation_as_throwing` can remain as the source creation switch.
- `treat_external_calls_as_throwing` can remain as the source creation switch.

The new strictness filter runs after those switches. That keeps backward compatibility for users who already disabled entire source categories.

## Manifest Behavior

Keep manifest matching as an explicit override layer.

Initial behavior:

- `manifestOverride` defaults to `deliberate`.
- Manifest-backed diagnostics continue to report at third-party `deliberate`.

Optional later extension:

```yaml
apis:
  - package: dio
    library: package:dio/dio.dart
    class: Dio
    method: get
    intent: possible
```

Do not add manifest intent in the first pass unless needed. It broadens the migration and documentation surface.

## Tests

Add focused unit tests for:

- `ThrowIntent.parse`.
- `ThrowSource.effectiveIntent`.
- Intent ordering and threshold checks.
- `ExceptionAnalysisOptions` parsing defaults and explicit strictness values.

Add analyzer tests or integration fixtures for:

- Internal call inferred from explicit `throw` reports at `internal: deliberate`.
- Internal call inferred from `int.parse` does not report at `internal: deliberate` but reports at `internal: possible`.
- Third-party call inferred from explicit `throw` reports at `third_party: deliberate`.
- Third-party call inferred from `int.parse` does not report at `third_party: deliberate` but reports at `third_party: possible`.
- Third-party unresolved or dynamic call does not report at `third_party: deliberate`.
- Third-party unresolved or dynamic call reports at `third_party: unknown` when existing unknown switches are enabled.
- Direct `no_null_assertion` and `no_manual_throw` still report in user code regardless of strictness.

## Documentation

Update:

- `README.md`
- `doc/diagnostics.md`
- `example/analysis_options.yaml`

Document the strictness values as intent thresholds, not package allowlists.

Include examples:

```yaml
strictness:
  internal: possible
  third_party: deliberate
```

and:

```yaml
strictness:
  internal: unknown
  third_party: possible
```

## Implementation Order

1. Add `ThrowIntent` and source-kind intent mapping.
2. Add optional `intent` to `ThrowSource`.
3. Preserve underlying intent when creating propagated inferred sources.
4. Add strictness fields and parsing to `ExceptionAnalysisOptions`.
5. Add origin-aware intent filtering in `InferredThrowAnalyzer`.
6. Adjust rule interactions only where needed after analyzer filtering.
7. Add tests for config, intent mapping, and origin-specific reporting.
8. Update docs and examples.

## Open Decisions

- Whether SDK code should share third-party strictness or get a separate `sdk` strictness.
- Whether `manifestOverride` should always mean `deliberate` or eventually support manifest-level `intent`.
- Whether `nullAssertion` should be `deliberate` instead of `probable`. It is explicit syntax, but it usually represents an accepted runtime risk rather than deliberate exception-based error handling.
- Whether the old `report` booleans should eventually be deprecated in favor of strictness thresholds.
