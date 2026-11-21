# Release contract

The plugin reports escaping Dart exception effects and unresolved behavior.
It does not prove that arbitrary Dart programs cannot fail. Resource exhaustion
and native process termination remain outside the contract. No particular Result
type or annotation scheme is required of consuming applications.

## Supported environment

The current analysis interface is pinned to analyzer 14.3.0 and Dart 3.11–3.14.
CI exercises 3.11.0, 3.12.0, 3.13.5 and stable. Declaration inventories record
SDK 3.11.0, 3.12.0, 3.13.5 and 3.14.1. Each inventory covers public callable
identities, signatures, native declarations and explicit error-producer
identities in ten SDK libraries. SHA-256 source fingerprints include SDK private implementations
and VM/JavaScript patches, so a body-only SDK change also requires review.
An inventory is change detection, not an assertion that every declaration has
a complete exception model. Future stable SDK drift deliberately fails this
gate until reviewed; an unsupported environment also warns in the plugin.

## Behavioral acceptance

Every supported semantic family needs an escaping example, compatible typed
containment, incompatible containment, and an unresolved or budget-limited
example. A known source must survive beside unresolved alternatives. Each
source retains its types, origin, certainty and synchronous, Future, Stream,
deferred or scheduled channel independently. When a summary exceeds its source
budget, known effects get priority and omitted effects retain uncertainty in
their original channels.

Containment uses a shared residual-effect projection. Inference ignores
`ExceptionBoundary` exemptions when computing outward effects; diagnostic
adapters honor them locally. Explicit throws, error production and null
assertions remain independently prohibited by their syntax policies.

Expression reachability covers short circuits, conditional selection, and
evaluation order within arguments, records, collections, and cascades.
Invocation effects require the receiver and arguments to finish evaluating.
Null-aware selectors can skip the rest of a chain up to its expression
boundary. Loop initialization, conditions, and updates respect evaluation
order, including labeled `continue`. Assignment summaries distinguish getter,
operator, and setter effects, including indexed writes. Proven switch case
selection honors guards and grouped labels. Structural proofs retain possible
normal completion for opaque expressions and conservative selection for
switches with labeled case targets.

Resolved constant booleans use the same branch facts in completion, inference
and async ownership. Ordinary final/mutable initializers do not establish these
facts. Exact generative allocations, `super`, extensions and extension types
retain static dispatch; hierarchy inventories include classes without declared
overrides, so an open leaf cannot disappear from completeness checks.

Future error ownership can cross a source helper after proving a single-input
static/top-level body immediately returns that input or a proven delegate. An
async helper may return or await that value as its sole action. Async adoption
creates a new Future; the proof preserves its error channel, not object identity.
Proofs respect the configured call depth and a hard cap of eight
helper declarations. Named and stored aliases retain the original obligation
and catch types only for proven identity forwarding. Async adoption does not
join the input and output alias locations. For tracked local inputs, the plugin
retains their error-type facts after adoption and creates an independent
obligation for each adopted output. Scheduled effects and ambiguous mixed
channels cannot establish this transfer. Unknown inputs and general heap ownership
remain conservative. Dependency edits, invalid configuration, annotation
contracts, manifest overrides, dynamic type boundaries, and proof budgets cannot establish
ownership through an unverified helper. Helpers with earlier work or suspension,
general consumers, heap storage and captures remain conservative.

Local async ownership distinguishes positional/named record fields and literal
list/map slots, including aggregate aliases. Awaiting a slot checks every
joined alternative. A consumer cannot discharge a sibling slot. Mutating or
escaping tracked collections abandons the old slot proofs; dynamic selection
does not consume an arbitrary known slot. Cross-function heap ownership,
arbitrary captures, runtime mutation and scheduling remain conservative.

Discarding a known failing Future preserves a scheduled effect in the caller's
summary. A synchronous catch around its creation cannot discharge that effect.

Sync generator effects remain deferred when code obtains the SDK iterator.
Direct calls to `Iterator.moveNext()` execute those effects synchronously, so a
compatible catch around iteration can contain them. Initialized final locals
and final aliases can carry the same effect to a reachable consumer in the
declaring body. Returning or capturing the value, passing it to an unmodeled
operation, or reaching the local read limit retains a possible deferred
escape alongside proven consumption.

## Required release evidence

- Formatting, static analysis and the entire test suite pass on each CI SDK.
- Analyzer syntax and SDK declaration/source inventories match their baselines.
- The labeled semantic corpus has no unexpected or missing effect labels.
  Its labels distinguish known effects from uncertainty and failure channels.
  Its small size precludes any external-project accuracy claim.
- VM/JavaScript differential probes and generated cold/warm/RSS benchmarks pass.
- Example analysis, clean-snapshot publish dry run, and installed enable-only
  consumer enforcement pass.
- The clean snapshot's standalone CLI reports effects in a target that has not
  enabled the plugin, then passes an unchanged baseline comparison. The
  [CLI contract](cli.md) defines its separate callable-level reporting scope.
- A real Analysis Server LSP consumer sees caller diagnostics appear and clear
  after unsaved body-only dependency edits through a source wrapper. Reverse
  effect dependencies schedule fresh caller analysis after the active lint
  pass, independently of unchanged analyzer type signatures.
- A Flutter 3.50.1 consumer installs the plugin through its analysis options.
  Flutter analysis verifies a typed catch, and a headless Chromium widget test
  exercises valid input and the handled failure.
- External corpus results separate dependency/plugin failures from diagnostics;
  reviewed external labels, real Dart and Flutter workloads, IDE latency and
  broader browser and platform coverage remain part of the production checklist.

The detailed outstanding acceptance criteria remain authoritative in
[production-implementation.md](production-implementation.md). Passing these
automated gates does not automatically complete its open semantic models.
