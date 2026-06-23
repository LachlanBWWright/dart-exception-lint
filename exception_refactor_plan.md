Goal
Make expected failures explicit in return types, especially config/YAML parsing and linter setup. Keep exceptions only at external
boundaries where Dart/analyzer/IO APIs already throw and convert them immediately into Result.

Phase 1: Add A Small Result Core
Create something like lib/src/result.dart:

sealed class Result<T, E> {
const Result();

    bool get isOk => this is Ok<T, E>;
    bool get isErr => this is Err<T, E>;

    R match<R>({
      required R Function(T value) ok,
      required R Function(E error) err,
    });

}

final class Ok<T, E> extends Result<T, E> {
const Ok(this.value);
final T value;
}

final class Err<T, E> extends Result<T, E> {
const Err(this.error);
final E error;
}

Add focused helpers only when needed: map, flatMap, unwrapOr, maybe tryCatch for boundary conversion.

Phase 2: Define Domain Error Types
Avoid String errors as the main model. Add typed failures, likely:

sealed class ConfigReadFailure {}

final class ConfigFileReadFailure extends ConfigReadFailure {
const ConfigFileReadFailure(this.path, this.message);
final String path;
final String message;
}

final class ConfigParseFailure extends ConfigReadFailure {
const ConfigParseFailure(this.message, {this.sourcePath});
final String message;
final String? sourcePath;
}

Likely split into:

- ManifestFailure for ThrowingApiManifest
- ExceptionAnalysisOptionsFailure for ExceptionAnalysisOptions
- maybe WireParseFailure for enum/wire-name parsing

Phase 3: Refactor Pure Parsers First
Start with the places that currently throw intentionally:

- lib/src/analysis/throw_summary.dart
  - ThrowConfidenceExtension.parse
  - ThrowIntentExtension.parse

Change to non-throwing APIs:

static Result<ThrowConfidence, WireParseFailure> tryParse(String value)

Then either remove throwing parse, or keep it temporarily deprecated during migration.

- lib/src/config/throwing_api_manifest.dart
  - ThrowingApiManifest.parse
  - ThrowingApiSpecification.fromYaml
  - \_readRequiredString
  - \_readOptionalString
  - \_readOptionalBool
  - \_readOptionalStringList
  - \_readOptionalConfidence

These should return Result<..., ManifestFailure> instead of throwing FormatException.

This is the highest-value area because manifest validation is expected user input failure, not exceptional control flow.

Phase 4: Refactor Config Loading Boundaries
Update file-loading methods to convert IO/YAML exceptions immediately:

- ThrowingApiManifest.load(...)
- ExceptionAnalysisOptions.load(...)
- ExceptionAnalysisOptions.parse(...)

Recommended shape:

static Result<ThrowingApiManifest, ManifestFailure> loadResult(...)
static Result<ThrowingApiManifest, ManifestFailure> parseResult(...)

For compatibility during transition, existing load can become:

static ThrowingApiManifest load(...) {
return loadResult(...).unwrapOr(empty());
}

But longer term, callers should decide whether to ignore config failures, report diagnostics, or fall back.

Phase 5: Decide Plugin Behavior On Config Errors
The analyzer plugin cannot freely return errors from registerNodeProcessors, so this is a boundary decision.

For rule files like:

- lib/src/rules/catch_throwing_third_party_calls_rule.dart
- lib/src/rules/catch_inferred_throwing_calls_rule.dart
- lib/src/rules/catch_runtime_throw_sources_rule.dart

Change config loading from implicit fallback/throwing behavior to explicit matching:

switch (ThrowingApiManifest.loadResult(...)) {
case Ok(value: final manifest):
...
case Err(error: final failure):
// Either report a config diagnostic or use empty manifest.
}

Best long-term behavior: add a config diagnostic such as invalid_throwing_api_manifest instead of silently disabling analysis.

Phase 6: Refactor Analyzer Internals Where Feasible
Most analyzer logic already uses nullable returns for absence, like ResolvedCallable.tryCreate(...) and source matching returning
null. Do not blindly replace every nullable with Result.

Use Result when failure has information the caller should act on.

Keep nullable for simple “not matched” outcomes:

- no manifest match
- no runtime source match
- no resolved callable
- no reportable analysis

Use Result for:

- invalid config
- malformed manifest entry
- invalid wire value
- failed file read
- analysis aborted due to incomplete/invalid state if that distinction matters

Phase 7: Tests
Update current throw-expecting tests first:

- test/throwing_api_manifest_test.dart
  - replace throwsFormatException with isA<Err<...>>()
- test/throw_summary_intent_test.dart
  - assert invalid wire names return Err

Add new tests for:

- invalid YAML root
- non-list apis
- invalid confidence
- bad string list entry
- missing required field
- file read failure converted to Err

Phase 8: Cleanup
Once callers use Result directly:

1. Remove throwing parser APIs.
2. Remove try/on FormatException blocks around internal parsing.
3. Search with:

rg -n "throw |throws|FormatException|try \\{|catch \\(|rethrow" lib test

4. Classify remaining hits:
   - intentional fixture code for lint tests: keep
   - fake analyzer interfaces throwing UnimplementedError: replace with minimal implementations if practical
   - external-boundary conversion: acceptable if immediately converted to Err
   - internal expected failure: refactor

Recommended Order

1. Add Result.
2. Add typed parse/config failures.
3. Convert enum wire parsers.
4. Convert ThrowingApiManifest.parse.
5. Convert ThrowingApiManifest.load.
6. Convert ExceptionAnalysisOptions.parse/load.
7. Update rule callers.
8. Add config diagnostics or explicit fallback policy.
9. Sweep remaining exception usage.

The biggest design choice is how strict the plugin should be when config parsing fails: silently fall back to defaults, or emit a
diagnostic. For a linter about exception safety, I’d make config failures visible with a diagnostic; silent fallback can hide broken
lint coverage.
