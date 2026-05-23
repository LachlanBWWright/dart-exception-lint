# Exception Origin Detection Plan

## Goal

Extend `dart_exception_lint` from a manifest-backed third-party call lint into a broader exception-origin analyzer that can report calls and expressions that may raise errors or exceptions.

The current implementation intentionally reports only:

- Explicit `throw` expressions.
- Null assertions.
- Configured third-party API calls outside `try`/`catch`.

This plan describes how to grow the linter so it can identify more possible exception sources, including exceptions raised indirectly inside third-party package implementations.

## Core Constraint

Dart does not have checked exceptions. A function signature does not declare the exceptions it can throw, and many failures are produced by runtime operations rather than explicit `throw` statements.

That means the analyzer should not model throwability as a simple boolean. It should classify findings by confidence:

| Classification | Meaning |
| --- | --- |
| `definite_throw` | The code contains an explicit `throw`, `rethrow`, or known throwing primitive on every observed path. |
| `possible_throw` | The code contains an operation or call that may throw depending on inputs, runtime state, platform behavior, or callback behavior. |
| `async_error` | The code can complete a `Future` or `Stream` with an error rather than throwing synchronously. |
| `unknown` | The target cannot be resolved, source is unavailable, or the implementation uses dynamic/native/external behavior. |
| `no_obvious_throw` | No configured throw source was found within the current analysis limits. This is not proof of safety. |

Diagnostics should be based on configurable policy. For example, a team may choose to report only `definite_throw` and selected `possible_throw` categories at first.

## Proposed Rules

Keep the existing rules, then add broader rules behind separate diagnostic codes so users can opt in gradually:

- `no_null_assertion`: existing direct syntax rule.
- `no_manual_throw`: existing direct syntax rule.
- `catch_throwing_third_party_calls`: existing manifest-backed API rule.
- `catch_runtime_throw_sources`: reports built-in Dart operations that commonly throw.
- `catch_async_error_sources`: reports `Future` and `Stream` error-producing operations that are not handled.
- `catch_inferred_throwing_calls`: reports calls whose implementation has been analyzed and classified as throwing.
- `catch_unknown_dynamic_calls`: optional strict rule for dynamic, external, native, or unresolved calls.

The current manifest should remain supported. It is still useful for APIs whose implementation is too complex, unavailable, or intentionally treated as throwing by policy.

## Analysis Architecture

### Phase 1: Throw Source Catalog

Create a structured catalog of exception origins the analyzer knows how to identify.

Suggested location:

```text
lib/src/analysis/throw_source_catalog.dart
```

Each catalog entry should define:

- Source kind.
- Confidence classification.
- Synchronous or asynchronous behavior.
- Optional exception type names.
- Matching logic against AST nodes or resolved elements.
- Suggested remediation text.

Example source kinds:

- `explicitThrow`
- `rethrow`
- `nullAssertion`
- `lateInitializationRead`
- `indexAccess`
- `integerParse`
- `jsonDecode`
- `futureError`
- `streamAddError`
- `awaitPossiblyFailingFuture`
- `externalCall`
- `dynamicInvocation`
- `platformChannelInvocation`
- `unknownResolvedCall`

### Phase 2: Function Throw Summaries

Add an internal summary model for functions, methods, constructors, getters, setters, and closures.

Suggested location:

```text
lib/src/analysis/throw_summary.dart
```

Each summary should include:

- The declaring element key.
- Source URI and source range.
- Whether the callable can throw synchronously.
- Whether the callable can complete asynchronously with an error.
- A list of direct throw sources.
- A list of callees that contributed to the summary.
- Whether the summary is complete or truncated.
- Analysis depth and reason for truncation.

Example:

```dart
class ThrowSummary {
  final String elementKey;
  final ThrowConfidence confidence;
  final bool canThrowSynchronously;
  final bool canCompleteWithAsyncError;
  final List<ThrowSource> sources;
  final List<String> dependencyElementKeys;
  final bool complete;
}
```

### Phase 3: Local Body Analysis

For each callable body available to the analyzer, scan the resolved AST and produce a local throw summary.

Direct syntax sources:

- `throw expression`
- `rethrow`
- postfix null assertion `!`
- explicit `as` casts when strict mode chooses to treat failed casts as throw sources
- forced nullable access patterns if represented distinctly in the AST

Runtime operation sources:

- Index reads and writes: `list[index]`, `map[key] = value` where relevant.
- Integer and double parsing: `int.parse`, `double.parse`.
- Date parsing: `DateTime.parse`.
- URI parsing: `Uri.parse` if policy treats invalid input as possible.
- JSON decoding: `jsonDecode`, `JsonDecoder.convert`.
- Enum lookup helpers if known to throw.
- `Iterable.single`, `first`, `last`, `singleWhere`, `firstWhere` without `orElse`.
- `List.single`, `Queue.first`, and similar core collection APIs.
- `RangeError.check*`, `ArgumentError.checkNotNull`, and other SDK check helpers.

Async error sources:

- `Future.error`.
- `Completer.completeError`.
- `StreamController.addError`.
- `Error.throwWithStackTrace`.
- Awaiting a `Future` whose producer summary is throwing or unknown under strict policy.
- Listening to a `Stream` without an error handler under strict policy.

Unknown or strict-mode sources:

- Calls through `dynamic`.
- `Function.apply`.
- Invocations of `Function`-typed values.
- `external` members.
- Native extensions.
- FFI calls.
- Platform channel calls, such as Flutter `MethodChannel.invokeMethod`.
- Generated plugin bindings.
- Reflection-like patterns where present.

### Phase 4: Resolved Call Traversal

Extend the current third-party call logic so it can inspect resolved target implementations when source is available.

Current behavior:

```text
call node -> resolved element -> manifest match -> report if not inside try/catch
```

Proposed behavior:

```text
call node
  -> resolved element
  -> explicit manifest match?
  -> cached throw summary for target available?
  -> source body available?
  -> analyze target body
  -> optionally recurse into callees
  -> classify call as definite, possible, async_error, unknown, or no_obvious_throw
  -> report according to configured policy
```

Traversal rules:

- Canonicalize elements through declarations.
- Handle top-level functions, methods, constructors, getters, setters, and extension methods.
- Include package source from `.pub-cache` and path dependencies when available.
- Respect package boundaries and generated-file filters.
- Cap recursion depth.
- Detect cycles in call graphs.
- Cache summaries by element key and package version.
- Treat unavailable source as `unknown`, not safe.

### Phase 5: Protection Analysis

The current `_isProtectedByTryCatch` check only accepts calls inside the body of a local `try` statement with a `catch` clause.

Broaden protection analysis carefully:

Synchronous protection:

- `try` body with `catch`.
- Catch type compatibility if the throw source has known exception types.
- `on Type catch` clauses that match known thrown types.
- Rethrow behavior inside catch blocks.

Asynchronous protection:

- `await` inside `try`/`catch`.
- `Future.catchError`.
- `Future.then(onError: ...)`.
- `unawaited` futures should be treated as unhandled unless configured otherwise.
- Stream subscriptions with `onError`.
- `await for` inside `try`/`catch`.

Limitations to document:

- A caller catching exceptions higher up the stack should not suppress a local lint unless interprocedural protection analysis is explicitly enabled.
- Generic `catch (_) {}` catches too broadly but should count as protection for this linter unless a stricter catch-quality rule is added.

### Phase 6: Configuration

Add config so teams can decide how aggressive the linter should be.

Example:

```yaml
plugins:
  dart_exception_lint:
    path: /path/to/dart-exception-lint
    diagnostics:
      catch_inferred_throwing_calls: true
    exception_analysis:
      report:
        definite_throw: true
        possible_throw: false
        async_error: true
        unknown: false
      max_call_depth: 4
      analyze_third_party_source: true
      analyze_sdk_source: true
      treat_dynamic_invocation_as_throwing: false
      treat_external_calls_as_throwing: true
      treat_index_access_as_throwing: false
      treat_parse_methods_as_throwing: true
      require_async_error_handling: true
```

Keep existing `throwing_apis.yaml` as an override layer:

```yaml
apis:
  - package: dio
    library: package:dio/dio.dart
    class: Dio
    method: get
    confidence: possible_throw
    async: true
    exception_types:
      - DioException
```

Manifest entries should be able to force a classification even when source analysis says `unknown` or `no_obvious_throw`.

## Exception Origin Coverage

### Explicit `throw`

Status: already covered by `no_manual_throw`.

Additional work:

- Record these in function throw summaries.
- Classify thrown expression type.
- Distinguish synchronous throw from async function returning a failed `Future`.

### `rethrow`

Status: not currently reported by `no_manual_throw` unless analyzer represents it as the same throw node shape.

Plan:

- Add explicit detection for `RethrowExpression` or the analyzer node shape used by the current SDK.
- Classify as `definite_throw`.
- Record that the source exception type is inherited from the enclosing catch clause.

### Null Assertions

Status: already covered by `no_null_assertion`.

Additional work:

- Record null assertions in throw summaries as `possible_throw`.
- Optionally suppress summary contribution when analyzer flow analysis proves the operand is non-null, if the project wants a less strict mode.

### Runtime Index And Range Errors

Examples:

```dart
items[index]
items.removeAt(index)
items.getRange(start, end)
```

Plan:

- Match index expressions and known SDK range-checking APIs.
- Classify as `possible_throw`.
- Optional future refinement: use constant values and simple range facts to suppress obvious safe cases.

### Parse And Decode Errors

Examples:

```dart
int.parse(value)
DateTime.parse(value)
jsonDecode(body)
```

Plan:

- Add SDK and `dart:convert` known API entries to the throw source catalog.
- Classify as `possible_throw`.
- Encourage `tryParse` alternatives where available.

### Failed Casts And Type Checks

Examples:

```dart
value as User
json as Map<String, Object?>
```

Plan:

- Add optional detection for `AsExpression`.
- Classify as `possible_throw`.
- Keep disabled by default if this is too noisy.

### Awaited Future Errors

Examples:

```dart
await client.get();
await Future.error(error);
```

Plan:

- Distinguish the call creating the future from the `await` that observes the error.
- If an awaited expression has an async-error summary, require protection around the `await`.
- Treat `await` in `try`/`catch` as protected.
- Treat unawaited futures as a separate possible diagnostic.

### Streams

Examples:

```dart
controller.addError(error);
stream.listen(onData);
await for (final event in stream) {}
```

Plan:

- Detect explicit `addError` and classify as `async_error`.
- Treat `await for` as requiring `try`/`catch` when the stream source is known to emit errors.
- Treat `listen` without `onError` as unhandled under strict async mode.

### External, Native, FFI, And Platform Calls

Examples:

```dart
external String read();
channel.invokeMethod('read');
ffiPointer.ref
```

Plan:

- Identify `external` elements through analyzer metadata.
- Add known Flutter platform channel APIs if Flutter dependencies are present.
- Classify as `unknown` or `possible_throw` depending on config.
- Do not attempt to inspect native implementations.

### Dynamic Calls And Function-Typed Values

Examples:

```dart
dynamic client = loadClient();
client.fetch();

Future<void> Function() callback;
await callback();
```

Plan:

- Detect `MethodInvocation` and `FunctionExpressionInvocation` where target or function type is `dynamic` or only `Function`.
- Classify as `unknown` by default.
- Provide strict mode to report these as requiring protection.
- Avoid pretending this is evidence of a real exception; the diagnostic should say the call target is unknown.

### Third-Party Package Source Traversal

Plan:

- For package dependencies with source available, analyze target bodies the same way local bodies are analyzed.
- Cache per package version and source URI.
- Recurse into package-private helper calls up to `max_call_depth`.
- Stop at public API boundaries, dynamic calls, external calls, or unavailable source and classify accordingly.
- Prefer explicit manifest entries over inferred summaries when both exist.

## Implementation Milestones

### Milestone 1: Internal Analysis Model

- Add `ThrowSource`, `ThrowSummary`, `ThrowConfidence`, and `ThrowSourceKind`.
- Add unit tests for summary construction.
- Keep diagnostics unchanged.

### Milestone 2: Local Summary Collection

- Record direct `throw`, `rethrow`, null assertions, parse/decode calls, and `Future.error`.
- Add tests using small in-repo Dart snippets.
- Do not recurse into callees yet.

### Milestone 3: Built-In Runtime Source Rule

- Add `catch_runtime_throw_sources`.
- Report configurable SDK/runtime sources outside protection.
- Start with low-noise APIs: `int.parse`, `double.parse`, `DateTime.parse`, `jsonDecode`, `Iterable.single`, `firstWhere` without `orElse`.

### Milestone 4: Async Error Rule

- Add `catch_async_error_sources`.
- Detect `Future.error`, `Completer.completeError`, `StreamController.addError`, and known async-error summaries.
- Require `await` protection for known failing futures.

### Milestone 5: Resolved Call Summary Cache

- Analyze resolved target bodies.
- Cache summaries by element key.
- Handle recursion depth and cycles.
- Add tests for local helper functions and path dependency calls.

### Milestone 6: Third-Party Source Analysis

- Enable package source traversal behind config.
- Add fixture packages with explicit throw, parse errors, async errors, external calls, and dynamic calls.
- Compare inferred results with manifest-backed results.

### Milestone 7: Policy And Documentation

- Document confidence classifications.
- Document known false positives and false negatives.
- Add examples for strict and conservative configs.
- Keep conservative defaults to avoid making normal Dart code unusably noisy.

## Testing Strategy

Use three layers of tests:

- Pure unit tests for manifest parsing, source catalog matching, and summary merging.
- Rule tests with inline Dart fixtures for direct syntax and runtime sources.
- Integration tests with temporary packages and path dependencies for third-party traversal.

Important test cases:

- Direct third-party method throws.
- Third-party public method calls private helper that throws.
- Third-party async method returns `Future.error`.
- Third-party method awaits another throwing async method.
- Third-party method calls `jsonDecode`.
- Third-party method calls external/native method.
- Dynamic invocation in third-party method.
- Cyclic call graph.
- Max-depth truncation.
- Protected sync call.
- Protected awaited async call.
- Unawaited async call.
- Catch clause with matching type.
- Catch clause with non-matching type.

## Risks

- Broad possible-throw detection can become too noisy.
- Interprocedural analysis may be expensive inside analyzer plugins.
- Package source can differ by dependency version and generated files.
- Analyzer APIs for element declarations and fragments may shift across SDK versions.
- Perfect proof of safety is not possible in Dart.

Mitigations:

- Keep aggressive checks opt-in.
- Cache summaries aggressively.
- Cap recursion depth.
- Use confidence classifications in messages.
- Preserve manifest overrides.
- Prefer precise diagnostics over broad speculation in default config.

## Recommended Direction

Do not replace `catch_throwing_third_party_calls` with inference. Instead:

1. Keep manifest-backed matching as the predictable baseline.
2. Add local throw summaries.
3. Add a conservative built-in runtime source catalog.
4. Add inferred third-party traversal behind explicit config.
5. Report findings with confidence labels so users know whether the linter found a direct throw, a known throwing API, an async error source, or an unknown call boundary.

This gives the project a path toward broad exception-origin detection without pretending Dart can provide checked-exception precision.
