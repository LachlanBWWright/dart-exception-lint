# Production exception analysis implementation

This is the authoritative checklist for the 30-item implementation requested in this conversation. A task is complete only when its acceptance criteria and evidence are recorded; unknown classification is a conservative analysis result, not evidence that a promised semantic model is implemented. No Result type is required.

## Contract

Report known escaping Dart exception effects and unresolved exception behavior. Include thrown Dart objects, Future and Stream errors, deferred execution, and scheduled callbacks. Exclude ambient resource exhaustion and native process termination. Explicit exemptions are visible policy decisions.

## Work tracker

- [x] 1. Strict default policy
- [ ] 2. Exhaustive coverage inventory
- [ ] 3. Shared analysis engine
- [ ] 4. Independent effect channels and completeness
- [ ] 5. Analyzer-native type matching
- [x] 6. Resolved dependency analysis
- [ ] 7. Control-flow interpretation
- [ ] 8. Value and alias analysis
- [ ] 9. Implicit runtime checks
- [ ] 10. Explicit and implicit invocations
- [ ] 11. Pattern semantics
- [ ] 12. Construction and lazy initialization
- [ ] 13. Dispatch index
- [ ] 14. Recursive fixed points
- [ ] 15. Higher-order effects
- [ ] 16. Versioned SDK models
- [ ] 17. Async channels
- [ ] 18. Future ownership
- [ ] 19. Future transformations
- [ ] 20. Streams and lazy execution
- [ ] 21. Scheduling, zones, isolates
- [ ] 22. Native and platform boundaries
- [ ] 23. Validated contracts and manifests
- [ ] 24. Explicit error production
- [ ] 25. Configuration and exemptions
- [ ] 26. Unified diagnostics
- [ ] 27. Incremental analysis
- [ ] 28. Performance gates
- [ ] 29. Correctness and compatibility matrix
- [ ] 30. Installation and release verification

## Implemented foundations and remaining acceptance criteria

Items 1 and 6 are complete. All other items remain open until their full acceptance
criteria are demonstrated. The following records concrete progress and the work
still required; conservative unknown fallbacks do not complete semantic models.

| Item | Implemented | Remaining to complete |
| --- | --- | --- |
| 1 | Enable-only plugin activates all rules; unknown local/dependency strictness and test/generated reporting enabled by default; documented migration. | Complete; explicit opt-outs deliberately reduce reporting. |
| 2 | Explicit inventory of 183 analyzer 14.1.0 nodes; CI fails unreviewed new/removed nodes; conservative syntax emits unknown effects. | Audit every implicit operation, SDK and external boundary; add positive and containment fixtures for every semantic family. |
| 3 | Inferred, async, and unknown adapters share summaries and per-source containment; stored async obligations retain their projected source analysis. | Residual effect containment is now shared by runtime, manifest and inferred reporting, and runtime configuration uses the shared analysis service. Move the remaining runtime/manifest interpretation and ownership facts into one interpreter and reporting pipeline. |
| 4 | Independent source channels and certainty; mixed unknowns and truncation survive merges; propagation and inferred/unknown call containment preserve per-source types and channels; source-budget truncation retains unknown effects for every omitted channel. | Integrate structural completion facts into callable summaries and complete interprocedural path semantics; unify the remaining catalog/manifest projections. |
| 5 | Resolved thrown types and annotation types use analyzer identity/subtyping; unknown catch coverage requires universal catches. | Instantiated generic effects, complete aliases and cross-library identity matrix. |
| 6 | On-demand same-session library resolution with lints disabled; transitive imports, exports/parts, conditional/deferred imports and editor overlays; stale-session rejection, bounded library cache and unknown fallback. | Complete; regression and installed-consumer checks pass on minimum/stable SDKs. Broader incremental invalidation remains tracked under item 27. |
| 7 | Cached structural normal/return/throw/break/continue transfers across blocks, branches, labels, loops, switches, catches and finally; lexical dead-code filtering and finally overrides are shared with diagnostic containment. | Argument/record evaluation order, short-circuit/conditional/null-aware reachability, and structurally noncompleting expressions now have shared proofs and regression fixtures. Complete the remaining expression forms, path-sensitive loop/switch/catch reachability, exception-type-dependent catch selection, deferred consumer flow and interprocedural completion. Structural transfer facts conservatively retain possible implicit failures. |
| 8 | Literal bounds/cast proofs, native callback initializer aliases, conditional/switch callback value joins, immutable record fields, constant-index const collection selections, and some Future alias/receiver invalidation; assignment, captured writes, patterns and foreach writes invalidate callback proofs. | General value lattice, promotions, captures, mutation and branch joins. |
| 9 | Dynamic downcasts at typed boundaries (including dynamic-to-function-signature assignment), pattern casts and generic/covariant invocation checks; audited native numeric and BigInt division/remainder/modulo/shifts/compounds, modular and width constraints, clamp/format/radix ranges, numeric parse/tryParse errors, conversions, direct-SDK `Random.secure` availability and `Random.nextInt` bounds, finite constant proofs, dynamic operand and tearoff arity failures, and portable SDK inheritance. | Exhaustive covariant/generic/function-type boundaries and all language-inserted runtime checks. |
| 10 | Getter/setter, compound/update, index/operator and interpolation targets; method tearoff creation is separate from execution, including SDK alias calls; explicit `super.noSuchMethod` fallback is modeled as `NoSuchMethodError`. | Synthesized `noSuchMethod` forwarders and dynamic dispatch; complete callable/cascade/null-aware and equality/hash semantics; manual `Iterator.moveNext` consumption of deferred generator effects. |
| 11 | Cast/null-assert and relational operand casts, object getter and custom equality/operator effects; failed typed-variable matches remain normal. | List/map extraction, guards, destructuring and assignment effects, all pattern-flow states. |
| 12 | Eager instance initialization, implicit superclass calls, redirects and lazy accessor effects. | Full redirects/mixins, local late writes, initialization order and lazy initialization states. |
| 13 | Open concrete dispatch remains unknown; exact construction and bounded closed hierarchies expand known candidates. | Complete revision-aware dispatch for extensions, mixins, generics and noSuchMethod. |
| 14 | Dependency-first Tarjan components and monotone fixed points with unknown on budgets; local identity includes offsets. | Complete dependency invalidation, generic identities and context-independent cache proofs. |
| 15 | Resolved SDK callback models; call-specific positional/named/default callback bindings through source wrappers, constructors, methods and captured reads; native local aliases and conditional/switch callback alternatives retain known targets beside unknown values; parameter/local writes invalidate proofs; simple synchronous top-level/static factories preserve returned target unions while creation effects remain separate; depth/context/dispatch budgets retain unknown effects, including unverified scheduling from incomplete callback bodies. Transitive dependency substitution and child-proof invalidation have regression coverage. Discarded callback Futures and async-void failures retain scheduled routing. | General returned callable environments, mutable collection/field storage, escaping captures, path-sensitive conditional invocation, generic contexts and validated callback bounds; exhaustive dispatch substitution fixtures. |
| 16 | Curated SDK source catalog with conditional models; pinned numeric and BigInt VM/JavaScript inventory distinguishes exceptions from NaN/infinity results and lists unmodeled families. | Generated callable/source drift inventories now cover Dart 3.11.0, 3.12.0 and 3.13.5, including public signatures, explicit producer identities and native/backend source fingerprints. Complete generated exception-effect metadata, semantic provenance and exhaustive native/external audit; inventory drift checks do not certify model completeness. |
| 17 | FutureOr recognition, async-void scheduling, separate stream/deferred channels, Stream contract routing, mixed annotation projections, and independent synchronous/returned-Future uncertainty for opaque Future signatures. | Complete interprocedural timing and per-effect consumer projections. |
| 18 | If/conditional/switch branch joins, aliases, overwrite abandonment, distinct field receivers and unknown Future parameters; observation follows verified result forwarding instead of arbitrary enclosing awaits/handlers. | Local record fields and literal list/map slots now have distinct ownership, aggregate aliases preserve slot identity, and awaits check every branch alternative. Mutation, escape, duplicate map keys and spread uncertainty preserve abandonment. Complete parameters/returns/captures, mutable heap modeling, all-path ownership and order-independent cross-function consumers. |
| 19 | Existing common Future/error-handler models, filter checks and callback sources; selected SDK APIs distinguish Future assimilation from discarded callback results and nested lazy values, including Future-wrapped Stream/Iterable payloads; unverified returned lazy ownership remains unknown. | Every constructor/combinator/transformation, complete callback-return assimilation, timeout/whenComplete ordering, late handlers and completer state. |
| 20 | Existing stream sources and selected callback execution models; lazy creation catches do not discharge later execution, and parentheses, SDK iterable transformations and collecting constructors forward effects to terminal consumers. | Full generator/yield/iteration, transformations, subscriptions/controllers, cancellation and terminal consumers. |
| 21 | Timer and microtask effects retain scheduled routing; creation-site catch cannot discharge them. | Zones, isolates, framework event callbacks and callback result ownership. |
| 22 | Unavailable boundary implementations retain unknown. | Explicit FFI/native/platform/JS/deferred/Flutter inventory and fixtures. |
| 23 | Order-independent shared contract/external policy, public annotation identity, body contradictions, inherited DoesNotThrow validation, all annotation timing checks, native catch types and multichannel manifests. | Full override/type/channel bounds, inherited generic contracts and callback metadata/precedence. |
| 24 | Throw/rethrow and audited native SDK error producers remain prohibited independently of catches and effect-model options; native aliases, conditional/switch targets, immutable storage, supported factory returns, `.call` and `Function.apply` forwarding share value proofs. Stream constructors, synchronous stream delivery, zone delivery and I/O sink declarations have a pinned identity inventory. | General mutable/heap/captured/reflective alias flows, SDK evolution checks and complete producer forwarding/dispatch audit; identity classification is separate from delivery semantics. |
| 25 | Visible warning severity and registration-safe configuration validation; strict shape/key/value validation, explicit null rejection, conflicts, package-local lookup and content-based option reload. | Workspace scoping, every read-error/race fixture and exemption audit. |
| 26 | Direct SDK reporting and direct manifest reports have separate owners; source origins retained. | One stable residual-effect diagnostic pipeline, CLI/IDE parity and complete cross-rule deduplication. |
| 27 | Defining-unit cache sharing during registration, options/manifest comparison, resolved-library/unit identity checks and dependency content/deletion checks. | Reverse effect dependencies now schedule caller reanalysis after local body-only edits, including transitive unsaved overlays verified through Analysis Server LSP on minimum/stable SDKs. Complete package/SDK/feature graph invalidation, deletion/cancellation, cross-context overlays, graph bounds and race tests. |
| 28 | Generated 200/2,000-function, 2,000-statement-body, resolved-dependency, shared-callback, stored/returned-callback and context-limit cold/warm/RSS workloads with CI budgets. | Pinned real small/large Dart and Flutter reference workloads, IDE edit latency and reproducible baselines. |
| 29 | Regression/integration tests, minimum/stable Dart CI, syntax gate and 52 pinned external repositories. | A 20-case labeled known/unknown channel corpus now fails missing/unexpected effect labels, and CI includes Dart 3.12.0. Expand VM/JavaScript probes, fuzzing, reviewed external diagnostic labels and the Flutter/browser/IDE matrix. Unsupported-version warnings are implemented. The repository inventory alone is not a correctness corpus. |
| 30 | Minimum SDK corrected; strict defaults and migration documented; clean snapshot publish dry-run and enable-only consumer enforcement pass. | Every release gate across the full supported matrix, including platform and IDE cases. |

## Verification evidence

### Release-contract implementation batch

The stable Dart 3.13.5 suite passes 440 tests, including new structural flow,
record/list/map ownership, alias, mutation, duplicate-key, spread and labeled
effect regressions. A clean isolated Dart 3.11.0 snapshot passes its 437-test
suite; all 86 ownership tests, including the three subsequent aggregate edge
cases, also pass on minimum Dart. The installed Analysis Server LSP gate passes
on Dart 3.11.0, 3.12.0 and 3.13.5: a dependency's unsaved safe/throwing/safe body edits propagate
through a wrapper and update the untouched caller's diagnostics. The gate waits
for plugin readiness separately from native analyzer idle status.

Both SDKs pass the generated core/callback performance budgets and all six
VM/JavaScript differential gates (232 runtime observations on each backend).
The 20-case semantic corpus retains known and unknown channel labels with zero
unexpected or missing labels. SDK declaration/source inventory checks pass for
3.11.0, 3.12.0 and 3.13.5; their public callable counts are 3,354, 3,373 and 3,391.
These generated identities and source hashes do not certify exhaustive models.

The stable clean release snapshot has zero publish warnings and passes
enable-only installed consumer enforcement. Formatting and static analysis
pass. Three pinned external repositories completed dependency/plugin analysis
without failures; [the evaluation report](corpus-evaluation.md) records 1,619
diagnostics and the limits of that evidence. The remaining 49 repositories,
reviewed external diagnostic labels, Flutter/browser/IDE latency and full
platform release coverage are still outstanding. No package was published.

### Earlier implementation evidence

The pre-implementation tree passed 198 tests. Before the release-contract implementation batch, complete runs passed
397 tests on both Dart 3.11.0 and 3.13.0. The expanded 79-test
inferred/deferred group, including two subsequently added `super.noSuchMethod`
regressions, passes on both SDKs. Coverage includes dependencies and
overlays, callback forwarding/defaults/captured reads, native alias/value joins,
mutation, immutable record/const collection selections, returned factory values,
creation-versus-execution containment, native SDK producer identities, callable
producer forwarding, native numeric exceptions and safe proofs, adapter freshness and traversal budgets, rule-facing
projections, source/context/
dispatch budgets, method tearoff timing and returned lazy payloads. Imported
factory regressions cover safe-to-throwing overlay edits and session rejection.
Static analysis and formatting pass. Installed consumer tests distinguish safe
calls, typed containment and escaping effects.

On Dart 3.13.0 Linux x64, generated core benchmarks measured 63 ms cold /
2 ms for ten warm passes at 200 functions, and 354 ms cold /
17 ms warm at 2,000 functions. The 2,000-statement function measured
266 ms cold / 0 ms warm; its source-budget uncertainty is expected
and the known parse effect is retained. The 1,000-caller dependency workload
measured 274 ms cold / 8 ms warm, including dependency-body resolution
in the cold time. Peak RSS was 771 MB. All generated core performance gates
also pass on Dart 3.11.0 (dependency workload: 299 ms cold /
6 ms warm, peak RSS across core workloads: 693 MB).

The callback benchmark preserves known String effects for all 1,000 callers
sharing one aliased target: 295 ms cold / 13 ms for ten warm passes
on Dart 3.13.0, and 336 ms / 11 ms on Dart 3.11.0. A 256-target
workload retains 64 known callers and 192 conservative unknown callers, all
with scheduled uncertainty. The added 1,000-caller record/const selection and
returned-factory workload preserves all known effects without unknowns:
427 ms cold / 6 ms warm on stable, and 520 ms /
8 ms on minimum. Peak RSS across callback workloads is
707 MB / 679 MB respectively. Every performance gate passes
on both SDKs and runs in CI. These are generated workloads, not real-project
or IDE performance claims.

Six labeled differential gates check known effects, containment and unknown
channels, with 232 runtime observations (32 core, 20 callback-value, 27
stored/returned-callback, 20 explicit-producer, 124 numeric and 9 numeric-parser
cases) on the Dart VM and compiled JavaScript under
Node. They include lazy consumers, finally controls, abandoned Futures,
callback value joins and signature checks, discarded Futures, async-void
failures, opaque callbacks starting Timers, returned Stream/Iterable payloads,
record/const storage, factory timing, mutation, unverified capture/dispatch,
producer aliases, function call tearoffs, bounded nested Function.apply, numeric
backend differences, compound accessors, and converter alias arity checks.
All 232 observations match on both Dart 3.11.0 and 3.13.0 on both runtimes.
This small corpus does not establish exhaustive language or platform coverage.

The syntax gate verifies the audited analyzer version and 183 nodes, the corpus manifest validates 52 unique
pinned revisions, and the corpus shell script passes syntax validation. The
external corpus has not been executed or labeled during this implementation.

Package static analysis passes. Example analysis exits successfully with
expected informational diagnostics. The original worktree publish dry-run reports its uncommitted changes. A clean
temporary snapshot passes publish dry-run with zero warnings and verifies
enable-only consumer enforcement with `dart analyze --fatal-infos` on both Dart
3.11.0 and 3.13.0. No package
was published and the user worktree was not committed.
