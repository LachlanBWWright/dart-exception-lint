# Diagnostics

Effect and syntax diagnostics analyze test and generated files by default.
Generated-file suffixes include `*.g.dart`, `*.freezed.dart`, `*.gen.dart`,
`*.mocks.dart`, `*.graphql.dart`, `*.chopper.dart`, `*.config.dart`,
`*.mapper.dart`, `*.routes.dart`, and `*.json.dart`. To exclude their diagnostics,
set `analyze_generated_files: false`. To exclude tests, set
`analyze_test_files: false`, optionally overriding individual rules:

```yaml
exception_analysis:
  analyze_test_files: false
  rules:
    catch_async_error_sources:
      analyze_test_files: true
```

Save this as `tool/dart_exception_lint/exception_analysis.yaml`. The analyzer
plugin configuration only supports its standard keys, so exception-analysis
settings live in this plugin-owned file to avoid unsupported-option warnings.

Invalid YAML, unsupported values, and malformed manifest entries produce an
`invalid_exception_analysis_config` warning on the package's defining library.

## Exception boundaries

Import `package:dart_exception_lint/dart_exception_lint.dart` and annotate an
intentional propagation endpoint or class with `@ExceptionBoundary()`. Inferred,
manifest, runtime, and async source diagnostics treat effects inside that
callable as intentional propagation. The annotation does not make the API
safe for callers: inferred and async effects remain visible at calls outside
the boundary. Explicit error-production rules such as `no_manual_throw` and
`no_null_assertion` still report their own constructs.

`exception_analysis.analyze_test_files` controls the package-wide default.
`exception_analysis.rules.<rule>.analyze_test_files` overrides that setting for
one diagnostic.

## `no_null_assertion`

Reports expression and pattern null assertions.

```dart
String? name = loadName();
print(name!);
```

Use local null handling instead:

```dart
String? name = loadName();
if (name != null) {
  print(name);
}
```

This rule is useful when the project treats null assertions as runtime failure
sources. It reports every non-synthetic postfix null assertion and does not try
to prove whether the value is actually null at runtime.

## `no_manual_throw`

Reports manually written `throw` and `rethrow` expressions, including arrow
functions and closures. Also reports resolved SDK error producers, including
`Error.throwWithStackTrace`, `Future.error`, `Stream.error`,
`Completer.completeError`, stream/I/O sink `addError`,
`MultiStreamController.addErrorSync`, and zone `handleUncaughtError`, even when
the produced error is subsequently caught or ignored.

Native callable targets are followed through unwritten local aliases,
conditional/switch alternatives, immutable records, const collections and
supported factory returns. Explicit `.call` and native `Function.apply`
forwarding also preserve the prohibition. A known producer remains prohibited
beside an unknown alternative. Merely creating a tearoff or an error object does
not produce an error. Mutable aliases and unverified capture/heap paths remain
uncertainty for the effect rules instead of stale explicit-producer claims.
The [SDK inventory](sdk-error-producers.md) records audited identities and
remaining scope; this classifier does not prove exception delivery timing.

```dart
void fail() {
  throw Exception('boom');
}
```

Handle failures locally or represent them as application-defined values.
The linter does not require a particular Result type.
The diagnostic message distinguishes thrown `Exception`, `Error`, and
non-`Exception` values when static type information is available.

## `catch_throwing_third_party_calls`

Reports configured third-party API calls when they appear outside a local `try`/`catch`.

Manifest:

```yaml
apis:
  - package: dio
    library: package:dio/dio.dart
    class: Dio
    method: get
```

Violation:

```dart
await dio.get('/users');
```

Accepted:

```dart
try {
  await dio.get('/users');
} catch (_) {
  // handle error
}
```

Manifest entries still act as an explicit override layer even when inferred source analysis is enabled.
Use this rule for package APIs whose failure behavior is known but cannot be
inferred reliably from source. Manifest matches support top-level functions,
methods, constructors, static/instance discrimination, subtype matching,
confidence overrides, async metadata, and exception type metadata.
SDK entries are supported with `package: dart`, for example
`library: dart:core`; this provides an extensible escape hatch for SDK APIs
whose throwing behavior is not available from analyzer source metadata.

## Exception Analysis Strictness

Inferred exception analysis can filter sources by intent:

```yaml
exception_analysis:
  strictness:
    internal: possible
    third_party: deliberate
```

The threshold values are:

| Value | Meaning |
| --- | --- |
| `deliberate` | Explicit exception-oriented code such as `throw`, `rethrow`, async error producers, and manifest overrides. |
| `probable` | `deliberate` plus high-risk runtime operations such as null assertions and casts. |
| `possible` | `probable` plus known input- or state-dependent throwing APIs. |
| `unknown` | `possible` plus unresolved, dynamic, external, abstract, and truncated analysis boundaries. |

For example, this reports unresolved internal boundaries but only deliberate and input-dependent third-party sources:

```yaml
exception_analysis:
  strictness:
    internal: unknown
    third_party: possible
```

## `catch_runtime_throw_sources`

Reports direct runtime throw sources outside local `try`/`catch`, including known
parse/decode APIs, assertions, argument/range validation helpers,
serialization failures, typed-data bounds checks, collection-state APIs, and
async terminal operations on `Future`, `Stream`, and isolate spawning APIs.

```dart
void f(String value) {
  int.parse(value);
}
```

Accepted:

```dart
void f(String value) {
  try {
    int.parse(value);
  } catch (_) {}
}
```

The reported source set is controlled by `exception_analysis` booleans such as
`treat_parse_methods_as_throwing`, `treat_index_access_as_throwing`,
`treat_as_casts_as_throwing`, `treat_late_initialization_as_throwing`, and
`treat_arithmetic_as_throwing`, and `treat_collection_state_as_throwing`.
Collection-state detection covers bounds-sensitive operations such as
`firstWhere`, `lastWhere`, `singleWhere`, `elementAt`, `substring`, and
`codeUnitAt`. It also covers reads of uninitialized `late`
variables. Native numeric and BigInt division, remainder, modulo, shifts, compounds,
modular/width operations, clamp, formatting and integer conversions retain
their specific exception types, including VM/JavaScript differences. Direct
SDK `Random()` and `Random.secure()` calls also retain `RangeError` when
`nextInt` receives a maximum outside `1..2^32`; `Random.secure()` retains
`UnsupportedError` for platforms without secure randomness. Literal and const
proofs also suppress numeric parse failures when the source text and radix are
proven valid. `tryParse` retains only invalid-radix and incompatible dynamic
argument effects because malformed text returns `null`. Ordinary variable
initializers do not establish those proofs. See the
[numeric inventory](sdk-numeric-exceptions.md) for covered and remaining families.
This rule only reports direct
sources in the current file; use `catch_inferred_throwing_calls` to follow
helper calls.

## `catch_async_error_sources`

Reports awaited futures and direct async error producers without handling.

```dart
Future<void> f() async {
  await Future.error(Exception('boom'));
}
```

Accepted:

```dart
Future<void> f() async {
  try {
    await Future.error(Exception('boom'));
  } catch (_) {}
}
```

The rule reports async error sources only when `require_async_error_handling` is
enabled. Awaited calls are considered handled only when surrounding catches
cover every known thrown type; `on Exception` does not catch `Error` values.
Separate or nested catches can collectively cover the effects. Unknown thrown
types require a universal catch. Direct stream listens require a non-null
`onError` callback or an unconditional SDK `handleError` transformer.
`catchError` and `handleError` filters preserve the incoming error effect unless
they are absent, null, or visibly return `true` for every input. Callback bodies
are analyzed independently, so a handler can itself introduce a new failure.
Errors stored in a local future are reported at the later `await`, or at the
creation site when the future is abandoned without an observation. An
unawaited future inside a synchronous `try`/`catch` is still reported because
that catch cannot handle the future's later error. `unawaited(...)` documents
intentional abandonment but is not treated as an error handler. Returning a
known failing Future is also reported, because the local function still exposes
an error effect. Field storage does not prove handling: known effects without
a consumer in the analyzed unit are reported at creation. Resolved field
identity is used, so unrelated fields with the same name do not share effects.
Consumption tracking is bounded and does not prove that a later method will
run or that an error handler is attached before the Future completes.
Native callable values are followed through unwritten local initializer aliases
and conditional/switch alternatives. Reassignment or a captured write preserves
unknown behavior instead of reusing the initial callback proof. Creating a
method tearoff does not execute its body; effects follow the eventual call.
Immutable record fields, const list/map entries selected by literal or const local keys, and
simple synchronous top-level/static factory returns also preserve targets.
A catch around factory creation does not contain later callback execution.
Mutable collections, virtual factory returns and escaping closure environments
remain unknown until their value flow can be proven.

## `catch_inferred_throwing_calls`

Reports calls whose implementation can be inspected and inferred as throwing, including third-party package source when it is available.

```dart
void helper() {
  throw Exception('boom');
}

void f() {
  helper();
}
```

This diagnostic honors `exception_analysis.strictness`. The default is
`unknown` for both local and dependency code. Setting
`third_party: deliberate` deliberately filters input-dependent APIs such as
`int.parse` and unknown dependency boundaries.
It inspects available package, SDK, and in-workspace source according to
`analyze_third_party_source`, `analyze_sdk_source`, and `max_call_depth`.
Manifest entries are intentionally excluded here so this rule reports only
implementation-inferred sources. An explicit `super.noSuchMethod(invocation)` call
is modeled as throwing `NoSuchMethodError`, so wrappers that delegate a missing
member to `Object.noSuchMethod` carry that effect through their callers.

## `catch_unknown_dynamic_calls`

Reports dynamic or unresolved call boundaries when the plugin cannot prove what is being invoked.

```dart
void f(dynamic client) {
  client.fetch();
}
```

Unknown sources inferred from implementation bodies honor `exception_analysis.strictness` and require an `unknown` threshold. Direct dynamic calls in the analyzed file are still reported when this diagnostic and `report.unknown` are enabled. This includes dynamic method calls, dynamic and `Function`-typed function calls, and awaiting a value whose type is `dynamic`.
Use this rule when unknown exception boundaries should be made explicit through
typing, safer wrappers, or local protection. An opaque callback may also schedule
work independently of its returned Future; awaiting and catching that Future
does not discharge scheduling uncertainty. Callback value/context budgets and
source-budget truncation preserve the unresolved channels. Disable `report.unknown` to turn off
unknown-boundary reports while keeping the other exception diagnostics active.
Diagnostics include a reason such as `dynamic_or_unresolved_call`,
`external_or_abstract`, `max_call_depth`, or `abstract_dispatch_incomplete` so
the warning identifies which analysis boundary needs attention. Incomplete
dispatch through an abstract receiver is retained as an unknown effect even
when the known base implementation appears safe; configured strictness still
controls whether that effect is reported.

## `invalid_exception_analysis_config`

Reports malformed `exception_analysis.yaml` and `throwing_apis.yaml` files.
The warning is emitted once on the defining library rather than once per
analyzed file. Fix the referenced configuration before relying on exception
coverage from the other diagnostics.
