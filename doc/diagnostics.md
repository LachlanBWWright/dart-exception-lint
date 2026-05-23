# Diagnostics

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

## `no_manual_throw`

Reports manually written `throw` and `rethrow` expressions, including arrow functions and closures.

```dart
void fail() {
  throw Exception('boom');
}
```

Prefer returning an error result or moving exception handling to a safer boundary.

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

## `catch_unknown_dynamic_calls`

Reports dynamic or unresolved call boundaries when the plugin cannot prove what is being invoked.

```dart
void f(dynamic client) {
  client.fetch();
}
```
