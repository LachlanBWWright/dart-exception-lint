# Example

This package enables `dart_exception_lint` from the parent directory:

```yaml
plugins:
  dart_exception_lint:
    path: ..
    diagnostics:
      no_null_assertion: true
      no_manual_throw: true
      catch_throwing_third_party_calls: true
```

Run analysis from this directory after `dart pub get`:

```bash
dart analyze
```

Manual validation lives in both `lib/main.dart` and `lib/manual_validation.dart`. Together they exercise:

- null assertions
- manual throws
- top-level, static, instance, constructor, async, and prefixed third-party calls
- protected vs unprotected `try`/`catch` boundaries
