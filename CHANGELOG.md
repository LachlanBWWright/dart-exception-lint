# Changelog

## Unreleased

- Share residual-effect containment across inference, runtime and manifest
  reporting; preserve discarded failing Futures as scheduled caller effects.
- Track argument/record evaluation order, short-circuit branches and
  noncompleting expressions in structural reachability.
- Distinguish async obligations in record fields and literal collection slots,
  preserve aggregate aliases, check all branch alternatives at await sites,
  and invalidate collection proofs on mutation or escape.
- Add SDK declaration/source drift inventories for Dart 3.11–3.13, a labeled
  semantic corpus, a Dart 3.12 CI job and a concrete release contract.
- Invalidate caller diagnostics after body-only dependency edits; exercise
  unsaved safe/throwing/safe overlays through a real Analysis Server LSP session.
- Make external corpus subsets selectable, include all 52 repositories by
  default, bound dependency resolution time, and count manifest diagnostics.

- Model native numeric and BigInt division, modulo, shifts, compounds,
  modular and width constraints, clamp/format/radix ranges, and conversions
  with VM/JavaScript exception types; preserve operand and arity failures and
  suppress proven-safe SDK fallbacks.
- Model `Random.secure()` platform availability and `Random.nextInt` bounds for
  direct SDK factory results, retaining `UnsupportedError` and `RangeError`.
- Include `FormatException`, invalid-radix `RangeError`, and dynamic argument
  `TypeError` for native numeric parse methods while preserving `tryParse` null
  behavior and proven-valid literal inputs.

- Raise the minimum Dart SDK to 3.11.0 to match analyzer dependencies.
- Enable all diagnostics when the plugin is enabled, honor explicit opt-outs,
  and warn on unreviewed SDK/analyzer environments.
- Default to reporting unknown local and dependency boundaries, including test
  and generated files; validate configuration shapes and conflicting layouts.
- Share inference summaries and retain separate channel, certainty, type, and
  completeness information, including unknown effects beside known failures.
- Keep synchronous and returned-Future uncertainty separate for opaque calls;
  require verified forwarding when proving observation through awaits/handlers.
- Distinguish awaiting a Stream object from consuming it with `await for`,
  and route Stream contracts through their stream channel.
- Preserve projected sources on stored async obligations and check each effect
  independently at consumers.
- Track structural completion and lexical reachability; honor finally overrides
  while retaining the independent prohibition on explicit error production.
- Resolve dependency bodies in the caller's analyzer session, including parts,
  selected imports and editor overlays; reject stale resolution proofs and
  retain uncertainty when bodies cannot be resolved within the library budget.
- Follow lazy iterable effects through parentheses, SDK transformations and
  collecting constructors, and check containment at execution consumers.
- Specialize callback effects at source calls, including forwarded/default
  callbacks and captured reads; invalidate reassigned parameters and retain
  uncertainty on context budgets. Preserve discarded callback Future and
  async-void failures beyond synchronous catches.
- Follow unwritten callback aliases, conditional/switch target unions, constructor
  and generic tearoff targets; preserve unresolved alternatives beside known effects.
  Separate method tearoff creation from dispatch through SDK callback APIs.
- Preserve every omitted channel when source budgets truncate summaries; keep
  returned lazy callback ownership uncertain until consumption is proven.
- Follow immutable record fields, const collection selections and simple
  synchronous factory returns without conflating creation and invocation;
  preserve uncertainty for mutable storage and escaping closure environments.
- Identify explicit SDK error producers independently of effect-model options;
  follow native aliases, stored targets, `.call` and `Function.apply` forwarding.
  Include stream constructors, zone delivery and I/O sink error APIs in the
  prohibition without treating the identity audit as a delivery-timing model.
- Add callback VM/JavaScript differential and shared/context-limit performance
  gates to the minimum/stable CI matrix.
- Resolve public annotation identity and native exception type relationships;
  validate body contradictions and inherited exception-free contracts.
- Model implicit dynamic casts, cast/null-assert patterns, accessor/operator
  calls, constructor initialization, open dispatch, and scheduled effects.
- Retain Future obligations across branches, overwrites, aliases, and distinct
  field receivers; invalidate summaries after dependency and resolution edits.
- Add analyzer syntax coverage checks, bounded inference benchmarks, and a
  revision-pinned 52-repository diagnostic-volume corpus inventory.
- Track remaining production acceptance criteria explicitly; these changes do
  not complete the whole-program exception analysis checklist.

- Require catches to cover every thrown type and correct SDK Error inheritance.
- Preserve exception effects at calls to annotated propagation boundaries.
- Retain async effects rejected by error-handler filters and resolve SDK handlers.
- Report unconsumed field futures and returned failing futures; preserve field identity.
- Ban explicit async error producers with `no_manual_throw`, regardless of handling.
- Preserve resolved exception ancestry separately from alternative thrown types.

## 0.1.0-dev.1

- Added production-readiness documentation, published-package installation
  guidance, and CI validation including example analysis and publish dry-run.
- Added intent-aware inference for synchronous and asynchronous throw sources.
- Added manifest-backed third-party API matching.
- Added visible `invalid_exception_analysis_config` warnings for malformed
  plugin configuration and throwing API manifests.
- Deduplicated inferred reports when a call is already covered by the
  manifest-backed diagnostic.
- Added typed async-producer effects, stored-future tracking, correct
  awaited-versus-unawaited protection, and local function tear-off inference.
- Added class-level exception boundaries and conservative block reachability
  for inferred summaries.
