# Release contract

The plugin reports escaping Dart exception effects and unresolved behavior.
It does not prove that arbitrary Dart programs cannot fail. Resource exhaustion
and native process termination remain outside the contract. No particular Result
type or annotation scheme is required of consuming applications.

## Supported environment

The current analysis interface is pinned to analyzer 14.1.0 and Dart 3.11–3.13.
CI exercises 3.11.0, 3.12.0 and stable. Declaration inventories record SDK
3.11.0, 3.12.0 and 3.13.5. Each inventory covers public callable identities,
signatures, native declarations and explicit error-producer identities in ten
SDK libraries. SHA-256 source fingerprints include SDK private implementations
and VM/JavaScript patches, so a body-only SDK change also requires review.
An inventory is change detection, not an assertion that every declaration has
a complete exception model. Future stable SDK drift deliberately fails this
gate until reviewed; an unsupported environment also warns in the plugin.

## Behavioral acceptance

Every supported semantic family needs an escaping example, compatible typed
containment, incompatible containment, and an unresolved or budget-limited
example. A known source must survive beside unresolved alternatives. Each
source retains its types, origin, certainty and synchronous, Future, Stream,
deferred or scheduled channel independently.

Containment uses a shared residual-effect projection. Inference ignores
`ExceptionBoundary` exemptions when computing outward effects; diagnostic
adapters honor them locally. Explicit throws, error production and null
assertions remain independently prohibited by their syntax policies.

Expression reachability includes short-circuit and conditional selection,
argument and record-field evaluation order, null-aware call arguments, and
noncompleting expressions. This is a structural proof; opaque expressions keep
possible normal completion. It is not a general symbolic value interpreter.

Local async ownership distinguishes positional/named record fields and literal
list/map slots, including aggregate aliases. Awaiting a slot checks every
joined alternative. A consumer cannot discharge a sibling slot. Mutating or
escaping tracked collections abandons the old slot proofs; dynamic selection
does not consume an arbitrary known slot. Cross-function heap ownership,
arbitrary captures, runtime mutation and scheduling remain conservative.

Discarding a known failing Future preserves a scheduled effect in the caller's
summary. A synchronous catch around its creation cannot discharge that effect.

## Required release evidence

- Formatting, static analysis and the entire test suite pass on each CI SDK.
- Analyzer syntax and SDK declaration/source inventories match their baselines.
- The labeled semantic corpus has no unexpected or missing effect labels.
  Its labels distinguish known effects from uncertainty and failure channels.
  Its small size precludes any external-project accuracy claim.
- VM/JavaScript differential probes and generated cold/warm/RSS benchmarks pass.
- Example analysis, clean-snapshot publish dry run, and installed enable-only
  consumer enforcement pass.
- A real Analysis Server LSP consumer sees caller diagnostics appear and clear
  after unsaved body-only dependency edits through a source wrapper. Reverse
  effect dependencies schedule fresh caller analysis after the active lint
  pass, independently of unchanged analyzer type signatures.
- External corpus results separate dependency/plugin failures from diagnostics;
  reviewed external labels, real Dart/Flutter workloads, IDE latency, browser
  behavior and platform installation evidence are still release blockers for a
  production-comprehensive claim.

The detailed outstanding acceptance criteria remain authoritative in
[production-implementation.md](production-implementation.md). Passing these
automated gates does not automatically complete its open semantic models.
