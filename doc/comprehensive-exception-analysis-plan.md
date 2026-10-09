# Comprehensive Exception Analysis Plan

> Historical planning/baseline document. Current implementation status and
> acceptance evidence are maintained in [production-implementation.md](production-implementation.md).


## Purpose

`dart_exception_lint` should identify statically discoverable exception paths
and make unknown boundaries explicit. It cannot guarantee that every runtime
exception is caught: Dart exceptions are unchecked, and arbitrary user code,
dynamic dispatch, native code, FFI, resource exhaustion, and third-party code
can fail without a statically knowable exception contract.

The target is therefore:

> Detect known synchronous, deferred, and asynchronous exception effects for
> all resolved source available to the analyzer, while clearly reporting or
> classifying incomplete and unknown boundaries.

## Current baseline

The project already provides:

- direct syntax rules for null assertions and manual throws;
- runtime detection for parsing, decoding, bounds/state operations, late reads,
  casts, and integer division;
- inferred synchronous and asynchronous throw summaries;
- exception provenance and exception-type propagation;
- bounded call-depth and source parsing caches;
- Future and Stream handling for common await and error-handler patterns;
- local Future storage and function tear-off tracking;
- bounded dispatch expansion for current and directly imported libraries;
- manifest-backed third-party and SDK API declarations;
- callable and class-level `@ExceptionBoundary()` annotations;
- configuration validation and regression/integration tests.

The implementation is intentionally conservative and is not yet a complete
whole-program effect engine.

## Goals

1. Model exception effects precisely enough to distinguish synchronous throws,
   deferred generator failures, Future errors, Stream errors, and unknown
   boundaries.
2. Analyze control flow and local data flow without introducing unsound claims
   about paths that cannot be proven.
3. Resolve as many dynamic, extension, tear-off, callable-class, and subtype
   targets as the analyzer makes available.
4. Provide versioned, generated SDK metadata with a stable manifest override
   mechanism.
5. Make async error ownership explicit: creation, propagation, transformation,
   consumption, and abandonment should be separate concepts.
6. Keep diagnostics actionable, explain their source, and avoid duplicate
   reports from overlapping rules.
7. Remain incremental, bounded, and compatible with the Dart analyzer plugin
   lifecycle.

## Non-goals

- Proving that arbitrary Dart programs never throw.
- Treating every call as throwing by default.
- Replacing Dart's type system or analyzer control-flow engine.
- Requiring projects to annotate every ordinary function.
- Silently assuming that unavailable source is safe.

## Target architecture

### 1. Effect model

Replace the current pair of synchronous/asynchronous booleans with an explicit
effect representation. The exact class names can change, but the model should
contain:

```text
EffectSummary
  normalCompletion: yes | no | unknown
  synchronous: EffectSet
  deferred: EffectSet
  asynchronous: EffectSet
  dependencies: element keys
  complete: bool
  truncationReason: optional string

Effect
  kind: explicit | runtime | inferred | Future | Stream | generator | unknown
  confidence: definite | possible | unknown
  intent: deliberate | probable | possible | unknown
  exceptionTypes: normalized type identities
  origin: source location and causal chain
```

Important invariants:

- an effect must state whether it can happen before a call returns;
- an async effect must not be considered handled by a synchronous catch around
  future/stream creation;
- a caught effect must be removed only from the path protected by that catch;
- a rethrow must preserve its causal origin and type set;
- truncation and unresolved dispatch must remain visible as unknown effects;
- merging effects must preserve all distinct causal sources, subject to a
  configurable bounded limit.

### 2. Control-flow and local data-flow engine

Introduce a small abstract interpreter over resolved AST bodies rather than
using a flat recursive visitor as the primary summary mechanism.

The first implementation should support:

- statement sequencing and reachability;
- `return`, `throw`, `rethrow`, `break`, and `continue`;
- constant boolean branches and conditional expressions;
- `if`, `switch`, loops, and conservative loop widening;
- `try`, `catch`, and `finally` with typed catch filtering;
- local variable definitions and assignments;
- Future/Stream values stored in locals;
- callable aliases and tear-offs;
- closure capture with conservative invalidation;
- branch joins that union effects and widen uncertain state.

Do not attempt arbitrary symbolic execution. When a condition or alias cannot
be proven, analyze both possibilities and mark the result as possible or
unknown rather than guessing.

### 3. Incremental call and dispatch index

Create a package-scoped, revision-aware index containing:

- executable elements and source locations;
- class, mixin, interface, extension, and extension-type members;
- override relationships;
- subtype relationships;
- callable `call` methods;
- top-level function and getter references;
- imported/exported library relationships;
- whether a target set is complete.

Use resolved analyzer elements whenever available. For targets outside the
available resolved set, retain an explicit incomplete-target marker and route
the call through the unknown-boundary policy.

The index must be bounded and invalidated by source revision. It must not cause
each diagnostic visitor to reparse the same library independently.

### 4. SDK metadata pipeline

Add a generated metadata pipeline rather than expanding a hand-maintained name
list indefinitely.

The pipeline should:

1. identify the Dart SDK version used for generation;
2. inspect resolved SDK declarations and available source;
3. combine source-derived effects with curated contract metadata;
4. emit a versioned data file for known throwing APIs;
5. include exception types, async/deferred behavior, and confidence;
6. support additions and corrections without code changes;
7. expose a validation command that detects stale metadata.

The runtime should merge three sources in order:

1. built-in generated SDK metadata;
2. project manifest overrides, including `package: dart` entries;
3. implementation inference where source is available.

Native, external, and undocumented behavior must remain unknown unless
explicitly classified.

### 5. Async and generator semantics

Represent deferred work separately from synchronous and Future errors. Add
specific handling for:

- `async` and `async*` functions;
- `sync*` functions and errors during iteration;
- `yield` and `yield*`;
- `Future` creation, chaining, waiting, timeout, and completion;
- `catchError`, `then(onError:)`, `whenComplete`, `ignore`, and `unawaited`;
- `Stream.listen(onError:)`, `handleError`, transforms, cancellation, and
  subscription ownership;
- `Completer` and `StreamController` producer/consumer relationships;
- futures and streams stored in locals, fields, collections, and records.

Creation of a Future or Stream should not automatically be treated as an
unhandled error. The analyzer should report at the point where an error effect
is abandoned or consumed without a compatible handler.

### 6. Exception contracts and annotations

Keep `@ExceptionBoundary()` for intentional propagation endpoints. Add
optional contracts for APIs whose behavior cannot be inferred:

```dart
@MayThrow([FormatException])
String decode(String input) { ... }

@ReturnsFailingFuture([NetworkException])
Future<Response> fetch() { ... }

@DoesNotThrow
Result<T> safeOperation<T>() { ... }
```

The annotation design must define:

- legal declaration targets;
- type identity and inheritance behavior;
- sync versus async/deferred effects;
- override compatibility;
- whether annotations are inherited;
- conflict behavior with manifests and inferred summaries;
- diagnostics for malformed or contradictory contracts.

Manifests remain necessary for external packages and SDK/native APIs.

### 7. Diagnostic policy

Separate analysis from reporting. The analysis layer should produce effects;
the reporting layer should decide whether to report them based on:

- confidence and intent thresholds;
- sync/async observation;
- compatible catch handlers;
- boundary annotations;
- generated-file and test-file policy;
- duplicate suppression;
- source/provenance display.

Unknown effects should be configurable independently from known possible
effects. A diagnostic should explain whether the source is definite, possible,
async, deferred, external, dynamic, or truncated.

## Implementation phases

### Phase 1: Stabilize the effect API

- Introduce the explicit effect representation behind the existing rules.
- Preserve compatibility adapters for current `ThrowSummary` consumers.
- Normalize exception type identities and origins.
- Add merge, filter, catch, and observation unit tests.
- Define a maximum number of retained effects and a widening policy.

Acceptance criteria:

- all current tests pass;
- sync, async, deferred, and unknown effects cannot be confused;
- diagnostics remain unchanged for existing fixtures.

### Phase 2: Replace flat body scanning with abstract interpretation

- Add statement sequencing and reachability.
- Add branch joins and conservative loop handling.
- Model typed catches, `finally`, rethrows, and normal completion.
- Move existing local Future and callable-alias tracking into the shared engine.
- Add fixtures for unreachable code, conditional throws, nested catches, and
  rethrows.

Acceptance criteria:

- no effects are reported from proven unreachable statements;
- effects in one branch do not incorrectly become definite on every branch;
- `finally` effects remain visible;
- all behavior is covered by resolved analyzer tests.

### Phase 3: Build the incremental dispatch index

- Index all resolved units supplied by the analyzer context.
- Add imported/exported library target discovery.
- Add overrides, mixins, extensions, extension types, callable classes, and
  tear-offs.
- Track incomplete target sets and apply the unknown policy.
- Add cache invalidation and performance benchmarks.

Acceptance criteria:

- interface calls include all known concrete implementations;
- extension and callable-class effects are followed when resolved;
- unknown dispatch is reported only when the target set is incomplete;
- repeated analysis does not reparse unchanged libraries.

### Phase 4: Generate and consume SDK metadata

- Add the metadata schema and generator command.
- Generate metadata for every supported Dart SDK version.
- Add curated contracts for external/native SDK methods.
- Add SDK manifest override tests.
- Document metadata update and compatibility procedures.

Acceptance criteria:

- supported SDK APIs are classified without name-only heuristics;
- metadata generation is reproducible;
- stale SDK metadata is detectable in CI;
- user overrides take precedence predictably.

### Phase 5: Complete async, stream, and generator analysis

- Add separate deferred-generator effects.
- Model Future and Stream ownership through the abstract interpreter.
- Add handler/transformer contracts.
- Analyze `await for`, `yield*`, subscriptions, cancellation, and producer
  consumers.
- Add golden fixtures for common async patterns and false positives.

Acceptance criteria:

- Future creation is not reported when it is later awaited or intentionally
  consumed;
- synchronous catches do not hide later async errors;
- generator errors are reported at iteration/consumption sites;
- stream handlers and transformations are recognized correctly.

### Phase 6: Public contracts, reporting, and release hardening

- Finalize annotations and manifest schema.
- Add quick documentation for every effect category.
- Add provenance formatting with causal chains and source links.
- Add package-size, memory, and latency benchmarks.
- Test IDE and `dart analyze` behavior across supported SDK versions.
- Add migration notes and a stable release checklist.

Acceptance criteria:

- every diagnostic has actionable correction text;
- unknown boundaries are visible rather than silently ignored;
- performance remains bounded on large packages;
- the example package and full test matrix pass for every supported SDK.

## Testing strategy

Maintain several complementary test layers:

### Unit tests

- effect merging and widening;
- exception type compatibility;
- provenance and causal-chain formatting;
- manifest and annotation parsing;
- SDK metadata records;
- cache invalidation.

### Analyzer rule tests

- resolved getters, operators, extensions, tear-offs, and callable classes;
- branch and loop behavior;
- typed catches and rethrows;
- Future/Stream/generator ownership;
- boundary and unknown policies.

### Integration tests

- multiple libraries and parts;
- imported package source;
- interface implementations in separate libraries;
- generated/native/external boundaries;
- `dart analyze` and IDE-compatible plugin loading;
- SDK version compatibility.

### Golden tests

Keep representative source fixtures with expected diagnostics, confidence,
source locations, and provenance. Golden tests are especially important for
preventing false-positive growth as the effect engine becomes more capable.

## Performance and safety constraints

- Never perform unbounded recursive call-graph traversal.
- Cap call depth, target-set size, retained effects, and source-cache size.
- Key caches by stable element identity and source revision.
- Avoid filesystem parsing when a resolved unit is already available.
- Mark incomplete analysis explicitly rather than treating it as safe.
- Ensure plugin registration and analysis remain cancellation-friendly.
- Add benchmarks before enabling expensive whole-package behavior by default.

## Definition of done

The project can claim this plan is complete when:

1. every effect category has a documented representation and test coverage;
2. the abstract interpreter handles the supported control/data-flow constructs;
3. known dispatch targets are indexed incrementally;
4. SDK metadata is generated, versioned, and validated;
5. Future, Stream, and generator ownership rules are tested;
6. external and incomplete boundaries are reported according to policy;
7. annotations and manifests provide explicit contracts;
8. full tests, example analysis, compatibility checks, and benchmarks pass;
9. documentation clearly distinguishes proven, possible, deferred, and unknown
   exception paths.

This definition deliberately does not include proving that arbitrary Dart code
cannot throw. That is not a property a Dart lint rule can establish.
