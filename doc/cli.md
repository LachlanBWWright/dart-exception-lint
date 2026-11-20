# Agent-facing CLI contract

The CLI analyzes callable exception effects with the same `InferredThrowAnalyzer`
and same-session dependency resolver used by the plugin. It does not require
the target to enable the plugin and does not modify target source, dependency
configuration, or Git state. Run `dart pub get` (or `flutter pub get`) in the
target beforehand so its dependencies resolve.

## Running

From this repository:

```bash
dart run bin/dart_exception_lint.dart --root /path/to/project lib bin > effects.json
```

For a locally installed executable:

```bash
dart pub global activate --source path /path/to/dart-exception-lint
dart pub global run dart_exception_lint --root /path/to/project lib
```

An application that already depends on this package can use
`dart run dart_exception_lint`. `--help` lists all flags. JSON is the default;
`--format text` provides concise human-readable output. File/directory arguments
are relative to `--root`, including when the CLI is launched from another
directory. Baseline paths are relative to the invocation's working directory.
Use `--` before paths starting with a dash.

## Scope and semantics

With no paths, reporting covers the root's analyzer contexts. Explicit paths
restrict reporting, while imports and dependency bodies remain available to
inference. Analyzer exclusions are respected. An explicitly requested missing
or analyzer-excluded Dart file produces an execution error. Exception-analysis
test/generated exclusions appear in `skippedFiles`.

Roots include named functions (including local functions), methods, declared
constructors, implicit default class constructors, and property accessors,
including implicit field/top-level accessors. Closures and initializer effects
are analyzed through their owning callables and supported callback models.
This remains bounded static inference with the limitations described in the
[release contract](release-contract.md).

Immediate Future arguments can retain their effects through proven
static/top-level forwarding helpers. The proof follows at most eight helper
declarations, also bounded by configured call depth. It requires a single-input,
single-return body, resolved identities, and compatible types. An async helper
may immediately return or await its input or a proven delegate as its sole
action; this transfers error ownership rather than Future object identity.
Helpers with earlier work or suspension, mutating, virtual, contracted and
otherwise unverified helpers retain uncertainty. The plugin's stored-value ownership adapter also follows these
identity proofs for named arguments and aliases. For tracked local inputs, the
plugin preserves error types through stored async adoption with a separate
obligation per output; handling the input cannot discharge these outputs. The
CLI's context-free summaries still retain uncertainty for stored Future inputs.
General heap/closure ownership and complete CLI/plugin diagnostic parity remain unfinished.

`tool/dart_exception_lint/exception_analysis.yaml` and `throwing_apis.yaml` are
loaded per package. Inference options, budgets, and test/generated exclusions
apply. The CLI intentionally retains all inferred effects; the plugin's
diagnostic enablement, `report`/`strictness` filters, per-rule test overrides,
and comment suppressions do not filter this effect inventory. CLI enforcement
uses `--fail-on` instead.

`@ExceptionBoundary()` effects remain visible as `intentionalBoundary: true`
and do not fail CLI policy. Those effects still propagate to callers.
Compatible typed containment removes effects from outward summaries.

This is not an exact copy of plugin diagnostics: it reports escaping effects
at callable declarations. For example, a contained manual throw may still
violate the plugin's independent `no_manual_throw` rule without appearing as
an escaping CLI effect. Continue using `dart analyze` for syntax policies,
contract validation, and other project lints.

## JSON schema version 2

Every non-help invocation emits one JSON object to stdout in JSON mode.
Ordinary findings do not contaminate stdout with log text.

- `schemaVersion`: output contract version, currently `2`. Version 1 baselines
  must be regenerated because evidence participates in finding identity.
- `status`: `completed`, `failed`, or `budget_exceeded`.
- `analysisComplete`: false for execution errors or incomplete/unknown callable
  summaries. True describes the selected, configured analysis; it does not
  establish exhaustive language coverage or whole-program safety.
- `files`: analyzed reporting paths, sorted and relative to the root.
- `skippedFiles`: files omitted by test/generated analysis policy, with reasons.
- `scope`: requested paths, the optional Git comparison ref, and its resolved
  commit identity.
- `configuration`: hashes of observed inference policy, manifests, context
  exclusions/options, and package manifests/lockfiles, for baseline validation.
- `sdkVersion`: the runtime SDK version used for analysis.
- `callables`: declaration location, stable symbol, inference element key,
  completeness/reason, intentional-boundary status, effect count, and dependency
  element keys. Internal element keys are explanation data, not stable IDs.
- `findings`: effect records described below.
- `errors`: configuration, resolution, Dart compiler, compatibility, execution,
  or budget errors. Failed reports may retain partial findings; they cannot be
  used as baselines. Budget failures discard partial results.
- `policy`, `exitCode`, `elapsedMs`: enforcement and execution information.

Each finding contains `fingerprint`, `code`, `file`, `symbol`, `line`, `column`,
`offset`, `length`, `channel`, `certainty`, `exceptionTypes`, `sourceKind`,
`message`, `reason`, `evidence`, `intentionalBoundary`, `origin`, and `trace`.

Codes are `escaping_exception_effect` and `unknown_exception_effect`. Channels
are `synchronous`, `future`, `stream`, `deferred`, and `scheduled`. Certainty is
`definite`, `possible`, or `unknown`; empty exception types mean unknown types.
`reason` explains uncertainty using the engine's available reason/source text.

`evidence` is a sorted list independent of certainty and delivery channel:

- `sourceAnalysis`: an explicit source throw/rethrow followed through inference.
- `languageSemantics`: a modeled language check, such as a cast or null assertion.
- `sdkModel`: a hand-maintained SDK effect or callback-execution model, matched
  to a resolved SDK declaration. It is a model, not a proof from that API's body
  or a certification of complete SDK coverage.
- `annotationContract`: behavior supplied by a resolved public annotation.
- `manifestContract`: behavior supplied by the project's API manifest.
- `unresolved`: incomplete or unknown behavior, including budget sentinels.
- `unclassified`: an existing effect whose evidence has not been classified.
  This records missing provenance; it does not claim a stronger proof.

Evidence survives caller propagation and channel transformations. More than
one category can contribute: a source callback executed by a modeled SDK
scheduler retains both `sourceAnalysis` and `sdkModel`. Unknown modeled effects
retain `unresolved` alongside their other evidence. SDK-like spellings on
unresolved/dynamic calls do not establish SDK identity or known SDK exceptions.
Class, member, and library identities come from resolved elements rather than
reconstructing targets from receiver spelling.

Finding locations identify the containing declaration. `origin` identifies
the causal source when available, including its enclosing symbol. `trace` is
one bounded supporting path through cached summaries, ending at that source.
It is not a runtime stack, an exhaustive path listing, or a promise that every
intermediate callback context is available. Frames carry names, paths and
offsets; paths to dependencies outside the root can contain `..`.

Lines/columns are one-based; offsets/lengths use Dart UTF-16 code units. Null
origin fields mean the engine has no concrete source location.

## Baselines and policy

```bash
dart run bin/dart_exception_lint.dart --root /path/to/project lib --write-baseline baseline.json
# Apply a proposed change, then compare using the same scope.
dart run bin/dart_exception_lint.dart --root /path/to/project lib --baseline baseline.json > comparison.json
```

`--write-baseline` writes a completed analysis report atomically. Findings can
fail policy while still being saved as a baseline. Execution/budget failures
never overwrite it. A malformed or incompatible baseline fails execution.
SDK version, schema, scope and recorded configuration must match; re-establish
the baseline deliberately when those change. Referenced analyzer option
includes are not recursively fingerprinted; keep their versions/configuration
fixed when comparing runs.

Fingerprints use relative paths, callable symbols, source identity, types,
certainty and channels, excluding offsets. Inserting blank lines preserves
identity. Moving/renaming a callable or changing its effect creates new and
resolved identities. Equivalent sources within the same originating callable
are grouped rather than assigned unstable occurrence numbers.

Comparison adds `baselineState: new|existing` to findings and a `baseline`
object containing `new`/`existing` counts and complete `resolved` records.
Only new, non-boundary findings participate in policy. Without a baseline,
all non-boundary findings participate.

`--fail-on all` is the default; `known`, `unknown`, and `none` select which
effects fail enforcement. This flag never hides findings or execution errors.

Exit codes:

- `0`: policy passed.
- `1`: policy found new effects.
- `2`: analysis/configuration/baseline/Git failure or exceeded budget.
- `64`: invalid arguments (reported as JSON even if text was requested).

## Changed files and budgets

`--changed-since REF` compares tracked files against a verified Git commit and
includes untracked, non-ignored files. It includes staged, unstaged and committed
changes relative to that ref; deleted files are not reporting inputs. Optional
paths intersect this selection. An empty selection is a completed empty report.
Git is required only for this mode. It does not expand the selection to every
reverse-dependent caller. Use a full scope before accepting a project-wide fix.

Default budgets are 120 seconds and 2,048 MiB RSS. A watchdog in a separate
isolate remains responsive during synchronous inference and stops the analysis
worker when time or process RSS exceeds the budget. RSS includes the whole CLI
process and is sampled every 100 ms; it is not an operating-system memory cap.
SDK startup/compilation before the executable begins and output serialization
are outside the analysis budget. Existing inference source/depth/context bounds
continue to produce explicit uncertainty instead of pretending analysis is
complete.

For an agent, retain the JSON and exit code, inspect unknown reasons before
assuming safety, follow origins/traces to choose fixes, rerun with the same
scope, and check the baseline's new/resolved effects. Use `--fail-on none` for
exploration while still treating exit `2` as a failed analysis.
