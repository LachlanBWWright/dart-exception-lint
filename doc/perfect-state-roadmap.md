# Path to a production-comprehensive exception linter

> Historical planning/baseline document. Current implementation status and
> acceptance evidence are maintained in [production-implementation.md](production-implementation.md).


## Scope and guarantee

`dart_exception_lint` cannot prove that arbitrary Dart code never throws.
Dart exceptions are unchecked, and behavior can originate in dynamic calls,
native code, FFI, operating-system APIs, resource exhaustion, reflection-like
mechanisms, or package source that is unavailable to the analyzer.

The attainable guarantee is:

> Report every exception effect that can be established from the resolved
> source and configured contracts, and report every incomplete boundary as
> unknown according to policy.

An unknown boundary must never be silently interpreted as safe.

## Implemented baseline

The current implementation already provides:

- direct rules for null assertions and manual throws;
- runtime sources for parsing, decoding, casts, bounds/state operations, late
  reads, and integer division;
- inferred synchronous, deferred, asynchronous, and unknown effects;
- exception origin and exception-type propagation;
- typed catch compatibility for common broad and exact catches;
- bounded call-depth and revision-aware source parsing caches;
- local Future ownership, collection access, async generators, sync generators,
  `Completer`, `StreamController`, and common Future handlers;
- local callable aliases, tear-offs, constructors, getters, operators, and
  known subtype dispatch;
- manifest-backed contracts for third-party and SDK APIs;
- `@ExceptionBoundary()` propagation endpoints;
- invalid configuration diagnostics;
- integration, regression, and plugin smoke tests.

This pass additionally implements:

- public `@MayThrow`, `@ReturnsFailingFuture`, and `@DoesNotThrow` contracts;
- analyzer constant-value extraction of contract exception types;
- bounded transitive import/export dispatch indexing with element
  deduplication;
- content-aware source cache invalidation and filesystem-race protection;
- published plugin installation documentation and CI publish verification.

## Work required for the next production-comprehensive release

### 1. Shared abstract interpretation

Replace rule-specific flat visitors with one bounded abstract interpreter that
models statement sequencing, branch joins, loops, `switch`, patterns,
`try/catch/finally`, rethrows, assignment, promotion, closure capture, and
normal completion. All rules should consume the same effect graph.

The interpreter must widen uncertain paths to `possible` or `unknown` and must
retain a configurable maximum number of causal effects.

### 2. Complete dispatch and reference indexing

The bounded recursive import/export walk is implemented. The remaining work is
to add complete support for every resolved extension, extension-type, mixin,
callable-class, `noSuchMethod`, generic-instantiation, and unavailable-target
case, with completeness markers for each target set.

Index resolved declarations across imports, exports, mixins, extension methods,
extension types, callable classes, `noSuchMethod`, getters/setters, generic
instantiations, and all available subtypes. Mark the index incomplete when the
analyzer cannot establish that the target set is exhaustive.

### 3. Generated SDK metadata

Generate versioned metadata from the selected Dart SDK and curated contracts.
It should describe throwing APIs, exception types, sync/async/deferred timing,
and confidence. CI should regenerate and validate metadata for every supported
SDK version. Native and external APIs remain unknown unless contracted.

### 4. Cross-function async ownership

Extend Future and Stream ownership through parameters, returns, fields,
records, maps, callbacks, timers, subscriptions, cancellation, and producer /
consumer pairs. Distinguish created, propagated, transformed, consumed,
ignored, abandoned, escaped, and unknown states.

### 5. Analyzer-native catch typing

Replace name-based catch matching with analyzer type-system relationships,
including custom inheritance, aliases, generic types, promoted variables, and
callback signature compatibility.

### 6. Optional contract annotations

The initial optional contract API is implemented and consumed by inference:
`@MayThrow`, `@ReturnsFailingFuture`, and `@DoesNotThrow`. Validation for
override compatibility, inheritance, contradictory contracts, and richer
timing/contract diagnostics remains.

Contracts are not a prerequisite for diagnostics. They supplement inference
only where source or behavior is unavailable; unknown-boundary diagnostics must
remain active without them.

Add validated contracts for source-unavailable APIs, for example:

```dart
@MayThrow([FormatException])
String decode(String value) => ...;

@ReturnsFailingFuture([NetworkException])
Future<Response> fetch() => ...;
```

Define override compatibility, inheritance, sync/async timing, precedence with
manifests, and diagnostics for contradictory contracts.

### 7. Central reporting and diagnostics

Separate effect production from reporting. Centralize suppression and
deduplication across inferred, runtime, manifest, async, and unknown rules.
Diagnostics should identify the source category, timing, confidence, origin,
and reason an operation is unknown.

### 8. Compatibility and performance matrix

Test supported Dart SDK/analyzer combinations, Flutter projects, generated
files, build-runner workflows, large monorepos, malformed intermediate files,
FFI, and native plugins. Add fuzz, golden, memory, and large-project runtime
tests.

## Definition of done

The project is ready to claim production-comprehensive analysis when:

1. every resolved body is analyzed by the shared interpreter;
2. every incomplete call boundary is either reported or explicitly configured;
3. SDK metadata is generated and versioned;
4. async effects are tracked across function and object boundaries;
5. catch compatibility uses analyzer types;
6. duplicate causes are merged into stable diagnostics;
7. caches are package/revision/SDK aware and context-safe;
8. `dart analyze` and IDE analysis-server loading are tested;
9. supported SDK versions pass the compatibility and performance matrix; and
10. the documentation states the precise static-analysis guarantee.

The project must not advertise that it finds literally every runtime
exception. It should advertise complete coverage of statically discoverable
effects plus explicit unknown-boundary reporting.
