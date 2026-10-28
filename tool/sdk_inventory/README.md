# SDK evolution gate

Generate a candidate inventory using the checked-out analyzer dependencies:

```bash
dart run tool/verification/sdk_inventory.dart --write
dart run tool/verification/sdk_inventory.dart --sdk-root /path/to/dart-sdk --write
```

Verify the current SDK without rewriting the reviewed baseline:

```bash
dart run tool/verification/sdk_inventory.dart
```

Review added/removed callable identities, signature and static/native changes,
explicit producer identity changes, and SDK source fingerprints. Source hashes
cover private implementations and native backend patches, including changes
that leave the public signature unchanged. Check the SDK source and exception
models and update differential fixtures before accepting a baseline diff.
`--write` records the installed SDK; it does not perform that semantic review.

The ten declaration libraries are core, async, collection, convert, math,
typed_data, io, isolate, ffi, and js_interop. These records identify declarations;
they do not claim exhaustive exception modeling or enumerate every possible
runtime implementation. Native machine-code changes without a Dart source or
signature change require separate runtime and platform validation.
