# dart_exception_lint

`dart_exception_lint` is a Dart analyzer plugin that reports exception-prone code:

- `no_null_assertion`: bans postfix `!`.
- `no_manual_throw`: bans manual `throw` and `rethrow`.
- `catch_throwing_third_party_calls`: flags manifest-configured third-party APIs outside `try`/`catch`.
- `catch_runtime_throw_sources`: flags direct runtime throw sources such as parse/decode calls.
- `catch_async_error_sources`: flags async error producers and awaited failing futures without handling.
- `catch_inferred_throwing_calls`: follows available source and reports calls whose implementation is inferred as throwing.
- `catch_unknown_dynamic_calls`: flags dynamic, unresolved, and otherwise unknown call boundaries.

## Installation

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
```

Put exception-analysis settings in
`tool/dart_exception_lint/exception_analysis.yaml`:

```yaml
exception_analysis:
  strictness:
    internal: possible
    third_party: deliberate
  max_call_depth: 4
  analyze_test_files: false
```

For local development, replace the `version` entry with
`path: /path/to/dart-exception-lint`. Restart the Dart Analysis Server after
changing plugin configuration.

Configuration and manifest errors are reported as
`invalid_exception_analysis_config` warnings. Exception analysis is not
silently disabled when either file contains invalid YAML or unsupported
values.

By default, diagnostics are skipped for files under `test/` and files named
`*_test.dart`. Set `exception_analysis.analyze_test_files: true` in the
dedicated configuration file to analyze
test files for all rules, or set
`exception_analysis.rules.<rule>.analyze_test_files` to override the default
for a single rule.

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
    internal: possible
    third_party: deliberate
```

Use a stricter third-party threshold to avoid noisy reports from package internals while still catching deliberate exception-based APIs. Use `unknown` when you want unresolved boundaries reported:

```yaml
exception_analysis:
  strictness:
    internal: unknown
    third_party: possible
```

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

Source-unavailable or externally implemented APIs can declare their exception
behavior with the public annotations exported by
`package:dart_exception_lint/dart_exception_lint.dart`:

```dart
@MayThrow([FormatException])
String decode(String input) => externalDecode(input);

@ReturnsFailingFuture([NetworkException])
Future<Response> fetch() => client.fetch();

@DoesNotThrow()
Result<T> safeOperation<T>(T value) => Result.success(value);
```

Contracts are authoritative for inferred analysis. They do not disable direct
syntax rules such as `no_manual_throw` or `no_null_assertion`, and they should
only be used when the declared API contract is maintained by the owner.

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

## Known limitations

Throw inference is intentionally conservative and bounded. It depends on
source being available to the analyzer, stops at `max_call_depth`, and cannot
prove the behavior of dynamic, external, native, or otherwise unresolved
calls. Resolved thrown types carry their known analyzer supertypes through
local summaries, while custom exception hierarchies in manifest strings still
require explicit `exception_types` metadata.

The analyzer tracks local Future ownership: creation, awaiting, compatible
handling, and abandonment. It also follows resolved function tear-offs,
constructor initializers, and user-defined index operators. It does not yet
perform whole-program symbolic data flow, enumerate all possible runtime
subtypes at a dynamic dispatch site, or derive a complete SDK exception catalog
automatically.

Use `@ExceptionBoundary()` from `package:dart_exception_lint/dart_exception_lint.dart`
on a function, method, or class for an intentional propagation endpoint.
Effect-based diagnostics treat code inside that callable (or class members) as
handled; direct syntax rules remain active.

The inferred and manifest-backed diagnostics are separate policy controls. A
call may intentionally receive both reports when both diagnostics are enabled:
the manifest report reflects explicit project policy, while the inferred report
reflects implementation behavior.

This package reports all statically discoverable exception effects within the
configured analysis boundary. It cannot guarantee detection of failures from
unresolved dynamic calls, native/FFI code, resource exhaustion, platform
services, or unavailable third-party implementations. Enable
`catch_unknown_dynamic_calls` and use `strictness: unknown` when those
boundaries should be surfaced instead of treated as tolerated uncertainty.

## Diagnostics

Detailed rule documentation and examples live in [`doc/diagnostics.md`](doc/diagnostics.md).
