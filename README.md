# dart_exception_lint

`dart_exception_lint` is a Dart analyzer plugin that reports exception-prone code:

- `no_null_assertion`: bans expression and pattern null assertions.
- `no_manual_throw`: bans manual `throw`, `rethrow`, and explicit SDK error producers, including known callable aliases, `.call`, and `Function.apply` forwarding.
- `catch_throwing_third_party_calls`: flags manifest-configured third-party APIs outside `try`/`catch`.
- `catch_runtime_throw_sources`: flags direct runtime throw sources such as parse/decode calls, assertions, range checks, serialization, typed-data bounds checks, numeric operations, and collection-state APIs.
- `catch_async_error_sources`: flags async error producers and awaited failing futures without handling.
- `catch_inferred_throwing_calls`: follows available source and reports calls whose implementation is inferred as throwing.
- `catch_unknown_dynamic_calls`: flags dynamic, unresolved, and otherwise unknown call boundaries.


## Installation

The current model inventory supports Dart 3.11–3.13 and analyzer 14.1.0.
Unreviewed environments emit `unsupported_exception_analysis_environment`
warnings; source coverage and native models must be audited before widening
support. All diagnostics are enabled when the plugin is enabled. Individual
`diagnostics` entries can explicitly disable a rule.

For a published release, enable the plugin in your consuming package's
`analysis_options.yaml`. The plugin is resolved from the top-level `plugins`
section and does not need to be added as an ordinary application dependency:

```yaml
plugins:
  dart_exception_lint: ^0.1.0-dev.1

  # To configure individual diagnostics, use the expanded form:
  # dart_exception_lint:
  #   version: ^0.1.0-dev.1
  #   diagnostics:
  #     no_null_assertion: true
```

The expanded form with diagnostics enabled is:

```yaml
plugins:
  dart_exception_lint:
    version: ^0.1.0-dev.1
    diagnostics:
      no_null_assertion: true
      no_manual_throw: true
      catch_throwing_third_party_calls: true
      catch_runtime_throw_sources: true
      catch_async_error_sources: true
      catch_inferred_throwing_calls: true
      catch_unknown_dynamic_calls: true
      # All of these are on by default; false explicitly disables a rule.
```

Put exception-analysis settings in
`tool/dart_exception_lint/exception_analysis.yaml`:

```yaml
exception_analysis:
  strictness:
    internal: unknown
    third_party: unknown
  max_call_depth: 4
  max_sources_per_summary: 64
  max_dispatch_candidates: 64
  analyze_test_files: true
  analyze_generated_files: true
  treat_io_operations_as_throwing: true
  treat_index_access_as_throwing: true
  treat_as_casts_as_throwing: true
```

For CI enforcement, run `dart analyze --fatal-infos`; exception-effect lints
use informational severity by default. Configuration and contract failures
are warnings and fail ordinary analysis.

For local development, replace the `version` entry with
`path: /path/to/dart-exception-lint`. Restart the Dart Analysis Server after
changing plugin configuration.

Configuration and manifest errors are reported as
`invalid_exception_analysis_config` warnings. Exception analysis is not
silently disabled when either file contains invalid YAML or unsupported
values.

The defaults analyze application, test, and generated files and report known
and unknown exception behavior in both local and dependency code. Reducing a
strictness threshold or excluding files deliberately reduces reporting. These
settings do not establish that the excluded behavior is safe.

Set `exception_analysis.analyze_test_files: false` to exclude test diagnostics,
or `exception_analysis.rules.<rule>.analyze_test_files` for a single rule.
Set `analyze_generated_files: false` to exclude generated-file diagnostics.

### Exception analysis strictness

`exception_analysis.strictness` controls which inferred exception sources are reported based on the source's intent:

| Value | Reports |
| --- | --- |
| `deliberate` | Explicit exception-oriented code such as `throw`, `rethrow`, `Future.error`, stream errors, and manifest overrides. |
| `probable` | `deliberate` sources plus high-risk runtime operations such as null assertions and casts. |
| `possible` | `probable` sources plus known input- or state-dependent throwing APIs such as parse/decode and collection-state calls. |
| `unknown` | `possible` sources plus unresolved, dynamic, external, abstract, and truncated analysis boundaries. |

Defaults:

```yaml
exception_analysis:
  strictness:
    internal: unknown
    third_party: unknown
```

Use a narrower threshold only when you intend to tolerate uncertainty. For
example, `third_party: deliberate` reports explicit dependency error producers
while omitting possible runtime failures and unknown dependency boundaries.

Migration: earlier development defaults used `internal: possible`,
`third_party: deliberate`, and excluded tests and generated files. Put those
values explicitly in the configuration to retain that reporting policy.

## Throwing API manifest

The manifest is still read from the analyzed package root at:

```text
tool/dart_exception_lint/throwing_apis.yaml
```

Example:

```yaml
apis:
  - package: http
    library: package:http/http.dart
    function: get
  - package: dio
    library: package:dio/dio.dart
    class: Dio
    method: get
  - package: some_package
    library: package:some_package/client.dart
    class: Client
    constructor: named
  # SDK APIs use package: dart and retain their dart: library URI.
  - package: dart
    library: dart:core
    class: RegExp
    constructor: ''
```

Supported manifest fields:

| Field | Meaning |
| --- | --- |
| `package` | Required package name from the `package:` URI. |
| `library` | Required full library URI. |
| `function` | Top-level function name. |
| `class` | Enclosing class for methods and constructors. |
| `method` | Method name. |
| `constructor` | Constructor name, using an empty string for unnamed constructors. |
| `static` | Optional static/instance discriminator for methods. |
| `subtypes` | Optional subtype matching for methods and constructors. |
| `confidence` | Optional override classification: `definite_throw`, `possible_throw`, `async_error`, `unknown`, or `no_obvious_throw`. |
| `async` | Optional async override for APIs that surface errors through `Future` or `Stream`. |
| `exception_types` | Optional future-facing metadata for thrown exception types. |

## Public exception contracts

Annotations are optional. The linter does not require users to annotate
ordinary functions or call sites: it analyzes source, known SDK/runtime
operations, async producers, and unknown boundaries automatically. Contracts
are only an optional way to describe source-unavailable or externally
implemented APIs with the public annotations exported by
`package:dart_exception_lint/dart_exception_lint.dart`:

```dart
@MayThrow([FormatException])
String decode(String input) => externalDecode(input);

@ReturnsFailingFuture([NetworkException])
Future<Response> fetch() => client.fetch();

@DoesNotThrow()
String safeOperation(String value) => value;
```

Contracts contribute effects to inference. A `DoesNotThrow` annotation does
not erase escaping or unverified body effects; validation also checks inherited
exception-free promises. Contracts do not disable direct syntax rules such as
`no_manual_throw` or `no_null_assertion`. `catch_unknown_dynamic_calls` remains the mechanism for warning
about unresolved behavior without requiring any annotation.

## Local development

```bash
dart pub get
dart format .
dart analyze
dart test
cd example && dart pub get && dart analyze
```

## Example

See [`example/`](example) for a local consumer package that enables the plugin by path and includes manifest-backed and source-inferred sample violations.

## Analysis scope

The plugin does not require any particular return or Result type. Its intended
policy is that exceptions must be contained within each local callable, with
explicit propagation endpoints declared by `@ExceptionBoundary()`.

The production checklist is **still in progress**. See
[`doc/production-implementation.md`](doc/production-implementation.md) for
implemented foundations, remaining acceptance criteria, and verification.
Strict defaults surface uncertainty; they do not make an unfinished semantic
model exhaustive.

Throw inference is intentionally conservative and bounded. It depends on
source being available to the analyzer, stops at `max_call_depth`, and cannot
prove the behavior of dynamic, external, native, or otherwise unresolved
calls. Resolved thrown types carry their known analyzer supertypes through
local summaries, while custom exception hierarchies in manifest strings still
require explicit `exception_types` metadata.

The analyzer tracks local Future ownership: creation, awaiting, compatible
handling, and abandonment. Returning a known failing Future does not discharge
its error effect. Unconsumed effects stored in fields are reported after the
unit is analyzed; tracking across units and runtime control flow remains
bounded. It also follows resolved function tear-offs,
constructor initializers, and user-defined index operators. It does not yet
perform whole-program symbolic data flow, enumerate all possible runtime
subtypes at a dynamic dispatch site, or derive a complete SDK exception catalog
automatically.

Use `@ExceptionBoundary()` from `package:dart_exception_lint/dart_exception_lint.dart`
on a function, method, or class for an intentional propagation endpoint.
Effect-based diagnostics allow intentional propagation inside that callable
(or class members); callers still see its outward exception effects. Direct
syntax and explicit error-production rules remain active.

The manifest adapter owns direct manifest-backed call diagnostics. Inference
still carries those effects through local wrappers, and async analysis follows
their returned error obligations.

Dependency bodies are resolved on demand in the caller's analyzer session,
including selected imports, exported declarations, parts and unsaved editor
contents. Resolution is bounded to 128 dependency libraries per analysis;
unavailable bodies, stale sessions and exhausted budgets retain unknown effects.

Source calls can specialize positional, named and default callback parameters,
including forwarding wrappers, captured reads, unwritten local aliases, and
conditional/switch callback alternatives. Unknown alternatives remain visible
beside known effects. Local or parameter writes invalidate that proof. Callback
specialization is bounded to 64 contexts per analyzer and
uses the configured call depth; exhausted budgets remain unknown. Native value
resolution also has limits of 64 alias levels, 64 target alternatives and 4,096
resolution steps. Incomplete callback bodies and dispatch sets retain scheduling
uncertainty. Native record fields and const list/map entries selected by literal
or const local keys can preserve callable targets through unwritten local
storage. Simple synchronous
top-level and static factories also preserve their returned targets; creation
effects and later callback execution remain separate. Mutable collections,
instance factory dispatch, returned closures and factory parameter captures
retain uncertainty. General heap storage, escaping captures, path-sensitive
conditional execution and generic callback bounds still need work.

A synchronous catch around `Iterable.forEach` cannot contain a Future error
from an async callback: that API discards the callback result. Selected SDK
models preserve these scheduled errors, while APIs such as `Future.sync`
adopt a returned Future. Async-void failures and unresolved callback scheduling
also remain separate from synchronous catch coverage. Even a Future-returning
opaque callback can start a Timer before returning, so awaiting its result does
not prove that all its errors are contained. Returned lazy callback values also
retain uncertainty until their later execution is proven contained.

Known models report exception effects and incomplete analysis is reported as
unknown by default. Full control-flow interpretation, higher-order execution,
and async ownership are still incomplete.
Native termination and resource exhaustion fall outside the Dart-exception
contract. Keep `catch_unknown_dynamic_calls` enabled to surface unverified
boundaries.

## Diagnostics

Detailed rule documentation and examples live in [`doc/diagnostics.md`](doc/diagnostics.md).
