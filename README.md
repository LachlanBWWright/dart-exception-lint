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

Add the plugin to your consuming package's `analysis_options.yaml`:

```yaml
plugins:
  dart_exception_lint:
    path: /path/to/dart-exception-lint
    diagnostics:
      no_null_assertion: true
      no_manual_throw: true
      catch_throwing_third_party_calls: true
      catch_runtime_throw_sources: true
      catch_async_error_sources: true
      catch_inferred_throwing_calls: true
      catch_unknown_dynamic_calls: true
    exception_analysis:
      report:
        definite_throw: true
        possible_throw: true
        async_error: true
        unknown: true
      max_call_depth: 4
      analyze_third_party_source: true
      analyze_sdk_source: true
      treat_dynamic_invocation_as_throwing: true
      treat_external_calls_as_throwing: true
      treat_index_access_as_throwing: false
      treat_parse_methods_as_throwing: true
      treat_as_casts_as_throwing: false
      require_async_error_handling: true
```

Restart the Dart Analysis Server after changing plugin configuration.

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

## Diagnostics

Detailed rule documentation and examples live in [`doc/diagnostics.md`](doc/diagnostics.md).