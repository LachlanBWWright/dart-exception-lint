# Diagnostics

All diagnostics skip generated Dart files (`*.g.dart`, `*.freezed.dart`, and
`*.gen.dart`). Test files are also skipped by default: files under `test/` and
files named `*_test.dart` are not analyzed unless configuration opts them in.

```yaml
plugins:
  dart_exception_lint:
    exception_analysis:
      analyze_test_files: false
      rules:
        catch_async_error_sources:
          analyze_test_files: true
```

`exception_analysis.analyze_test_files` controls the package-wide default.
`exception_analysis.rules.<rule>.analyze_test_files` overrides that setting for
one diagnostic.

## `no_null_assertion`

Reports postfix `!` operators.

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

Reports manually written `throw` and `rethrow` expressions, including arrow functions and closures.

```dart
void fail() {
  throw Exception('boom');
}
```

Prefer returning an error result or moving exception handling to a safer boundary.
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

## Exception Analysis Strictness

Inferred exception analysis can filter sources by intent:

```yaml
plugins:
  dart_exception_lint:
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
plugins:
  dart_exception_lint:
    exception_analysis:
      strictness:
        internal: unknown
        third_party: possible
```

## `catch_runtime_throw_sources`

Reports direct runtime throw sources outside local `try`/`catch`, including known parse/decode and collection-state APIs.

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
`treat_parse_methods_as_throwing`, `treat_index_access_as_throwing`, and
`treat_as_casts_as_throwing`. This rule only reports direct sources in the
current file; use `catch_inferred_throwing_calls` to follow helper calls.

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
enabled. Awaited calls are considered handled inside `try`/`catch`; direct stream
listens are considered handled when an `onError` callback is supplied.

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

This diagnostic honors `exception_analysis.strictness`. With the default `third_party: deliberate`, a third-party helper that explicitly throws is reported, while one that only calls `int.parse` is filtered out unless `third_party` is set to `possible` or `unknown`.
It inspects available package, SDK, and in-workspace source according to
`analyze_third_party_source`, `analyze_sdk_source`, and `max_call_depth`.
Manifest entries are intentionally excluded here so this rule reports only
implementation-inferred sources.

## `catch_unknown_dynamic_calls`

Reports dynamic or unresolved call boundaries when the plugin cannot prove what is being invoked.

```dart
void f(dynamic client) {
  client.fetch();
}
```

Unknown sources inferred from implementation bodies honor `exception_analysis.strictness` and require an `unknown` threshold. Direct dynamic calls in the analyzed file are still reported when this diagnostic and `report.unknown` are enabled.
Use this rule when unknown exception boundaries should be made explicit through
typing, safer wrappers, or local protection. Disable `report.unknown` to turn off
unknown-boundary reports while keeping the other exception diagnostics active.
