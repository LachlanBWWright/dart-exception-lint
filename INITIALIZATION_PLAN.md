# Dart Exception Lint Initialization Plan

## Goal

Initialize this repository as a Dart analyzer plugin that reports diagnostics for exception-prone code paths:

- Null assertions with `!`.
- Manual exception throws.
- Calls into known throwing third-party APIs when the call is not protected by an appropriate `try`/`catch`.

The initial implementation should prioritize accurate, explainable lint diagnostics over broad inference. Third-party throwing behavior should start from an explicit manifest of known APIs rather than trying to prove arbitrary package behavior.

## Reference Points From The Dart Analyzer Plugin Guide

The Dart analyzer plugin guide describes analyzer plugins as standard Dart packages that extend `dart analyze`, `flutter analyze`, and IDE analysis. Support was added in Dart 3.10.

Key setup constraints:

- The plugin package needs `analysis_server_plugin`, `analyzer_plugin`, and `analyzer` dependencies.
- The analysis server loads the plugin from `lib/main.dart`.
- `lib/main.dart` must expose a top-level variable named `plugin`.
- The plugin class must extend `Plugin` from `package:analysis_server_plugin/plugin.dart`.
- Plugin diagnostics can be warnings or lints. Warnings are enabled by default; lints are explicitly enabled under the plugin's `diagnostics` section.
- Local development consumers enable the plugin from `analysis_options.yaml` with a `plugins:` entry pointing at this package path.
- Plugin changes require restarting the Dart Analysis Server.
- Plugin debugging should use analyzer diagnostics pages and plugin-owned log files, because `print` output is not connected to the console.

Guide: https://dart.dev/tools/analyzer-plugins

## Package Bootstrap

1. Create `pubspec.yaml`.
   - Package name: `dart_exception_lint`.
   - SDK constraint: `^3.10.0` or newer, matching the analyzer plugin feature floor.
   - Runtime dependencies:
     - `analysis_server_plugin`
     - `analyzer_plugin`
     - `analyzer`
   - Dev dependencies:
     - `test`
     - `lints` or a local `analysis_options.yaml`.

2. Add standard package layout.
   - `lib/main.dart`: plugin entry point with top-level `plugin`.
   - `lib/src/plugin.dart`: plugin class and registration.
   - `lib/src/rules/`: one file per rule.
   - `lib/src/diagnostics.dart`: diagnostic code definitions and shared metadata.
   - `lib/src/config/`: third-party throwing API manifest parsing.
   - `test/`: focused analyzer plugin rule tests.
   - `example/`: a tiny consumer package that enables the plugin by local path.

3. Add repository hygiene.
   - `.gitignore` for Dart build artifacts, `.dart_tool/`, `.packages`, coverage, and editor noise.
   - Root `analysis_options.yaml` for developing this plugin package itself.
   - CI later: `dart pub get`, `dart format --set-exit-if-changed .`, `dart analyze`, `dart test`.

## Plugin Skeleton

1. Implement `lib/main.dart`.
   - Import `package:analysis_server_plugin/plugin.dart`.
   - Import local plugin implementation.
   - Define `final plugin = DartExceptionLintPlugin();`.

2. Implement `DartExceptionLintPlugin`.
   - Extend `Plugin`.
   - Set `name` to `Dart Exception Lint`.
   - Register all lint rules in `register(PluginRegistry registry)`.
   - Keep rule registration simple and static at first.

3. Add a minimal smoke test.
   - Verify the plugin loads and exposes the expected diagnostics.
   - Add one fixture file containing a null assertion and assert a diagnostic is produced.

## Diagnostic Model

Start with lints, not warnings, so users opt into each rule explicitly:

- `no_null_assertion`: reports postfix `!` expressions.
- `no_manual_throw`: reports `throw` expressions and statements.
- `catch_throwing_third_party_calls`: reports configured throwing package API calls outside a protective `try`/`catch`.

Each diagnostic should include:

- Stable diagnostic code.
- Human-readable message.
- Specific correction message.
- Precise source range.
- Rule documentation in `doc/diagnostics.md`.

Suggested enablement shape for a consuming package:

```yaml
plugins:
  dart_exception_lint:
    path: /path/to/dart-exception-lint
    diagnostics:
      no_null_assertion: true
      no_manual_throw: true
      catch_throwing_third_party_calls: true
```

## Rule 1: No Null Assertions

Implementation approach:

1. Visit resolved AST nodes with a recursive AST visitor.
2. Inspect `PostfixExpression` nodes.
3. Report when `node.operator.type` is the bang token and the expression is not part of analyzer-generated synthetic code.
4. Report the operator token range instead of the whole expression so the editor highlights the risky assertion precisely.
5. Do not attempt to infer whether the value is "probably non-null"; the point of the rule is to ban the escape hatch itself.
6. Add tests for:
   - Local variable null assertion.
   - Property access after null assertion.
   - Generic/cascade/chain cases.
   - Function call result null assertion.
   - Null assertion in collection literals and argument lists.
   - No false positive for logical not `!condition`.
   - No false positive for nullable type syntax or null-aware operators.

This rule is syntactic and should be the first implemented because it is low risk and proves the rule/test pipeline.

## Rule 2: No Manual Throws

Implementation approach:

1. Visit `ThrowExpression` nodes.
2. Report every manually written `throw`, including expression-bodied members and closures.
3. Report the `throw` keyword range, with the thrown expression included in secondary context only if the analyzer plugin API supports related locations.
4. Classify the thrown value from the resolved expression type for the diagnostic message:
   - `Exception` subtype.
   - `Error` subtype.
   - `Object` or arbitrary value.
   - Unresolved.
5. Keep classification informational in the first version; all manual throws are violations.
6. Consider an allowlist later for test files, generated code, or deliberately unreachable branches.
7. Add tests for:
   - Throwing `Exception`.
   - Throwing `Error`.
   - Throwing arbitrary objects.
   - Throw expressions inside arrow functions.
   - Throw expressions inside async functions and closures.
   - Throw expressions inside switch expressions or conditional expressions if supported by the parser shape.
   - No false positive for rethrow, unless a separate `no_rethrow` rule is added.

This rule is also syntactic and should be implemented before call-path analysis.

## Rule 3: Catch Throwing Third-Party Calls

This rule needs a conservative first version. Dart code generally does not declare thrown exceptions in function signatures, so the linter needs a source of truth for APIs considered throwing.

Implementation approach:

1. Define a manifest format for known throwing APIs.
   - Start with a checked-in YAML or JSON file.
   - Match package URI, library URI, class name, constructor name, method name, top-level function name, and optional static/instance flag.
   - Optionally record thrown exception type names for future catch-type validation.
   - Record whether a match should apply to subtypes, overridden interface methods, or only the exact declaring element.

2. Resolve invocation targets.
   - Inspect `MethodInvocation`, `FunctionExpressionInvocation`, `InstanceCreationExpression`, `FunctionReference`, and `PrefixedIdentifier` or `PropertyAccess` nodes when they are callable.
   - Use analyzer element metadata to identify package, library, enclosing class or extension, callable name, constructor name, and whether the call is static, instance, extension, or top-level.
   - Canonicalize elements through declarations where the analyzer exposes wrappers such as import prefixes, synthetic properties, or property accessors.

3. Determine whether the call is protected.
   - Walk ancestors from the invocation to the nearest enclosing function body.
   - Treat the call as protected if it is inside a `TryStatement` with at least one `catch` clause.
   - Ensure the invocation is inside the try body, not inside a catch clause or finally block.
   - Do not initially attempt to prove the catch type is exhaustive; later versions can require matching exception types if the manifest records them.

4. Report only when all are true:
   - The target resolves to a configured third-party throwing API.
   - The invocation is not inside a protective `try`/`catch`.
   - The source is not generated or explicitly ignored.

5. Add tests for:
   - Uncaught configured package function call.
   - Caught configured package function call.
   - Constructor calls.
   - Static methods.
   - Instance methods.
   - Same method name from a different package should not report.
   - Unresolved calls should not report.

Initial limitation:

- This rule will not detect transitive calls through project functions in the first version. A later phase can build an intra-package call graph and propagate "may throw" summaries.

## How Exception-Related Violations Are Found

The plugin should separate detection into three layers: local syntax, resolved call matching, and optional function-level propagation. This keeps the first version useful while making the more ambitious exception-flow work incremental.

### Layer 1: Local Syntax Scan

This layer catches direct exception-related constructs in the current compilation unit without needing a cross-file model.

Inputs:

- Resolved Dart AST for each analyzed file.
- Token offsets for precise highlighting.
- Analyzer element and static type information when available.

Detection:

1. Traverse every user-authored AST node in a compilation unit.
2. Emit `no_null_assertion` for each `PostfixExpression` whose operator token is `!`.
3. Emit `no_manual_throw` for each `ThrowExpression`.
4. Optionally record local "may throw" facts for the enclosing function when a throw is found. These facts are not needed to report the direct violation, but they become useful for propagation.

Skipped sources:

- Generated files by convention, such as `.g.dart`, `.freezed.dart`, and `.gen.dart`, if configured.
- Code ranges explicitly suppressed with analyzer ignore comments.
- Synthetic analyzer nodes with no real source offset.

Why this works:

- Null assertions and manual throws are explicit syntax. No inference is needed.
- The visitor can report violations with stable offsets even when type resolution is partial.

### Layer 2: Resolved Throwing API Call Matching

This layer detects direct calls into APIs that the project has declared as throwing.

Inputs:

- Resolved invocation AST nodes.
- Analyzer `Element` metadata for the invoked target.
- A normalized throwing API manifest.
- Ancestor AST context for try/catch detection.

Candidate invocation nodes:

- `MethodInvocation`: `client.get()`, `dio.get()`, `PackageApi.staticCall()`.
- `InstanceCreationExpression`: `ThrowingClient()`, `ThrowingClient.named()`.
- `FunctionExpressionInvocation`: `callback()` or a value known to reference a configured function.
- `FunctionReference`: tear-offs such as `http.get` when passed to another function.
- `PropertyAccess` and `PrefixedIdentifier`: needed for some static, prefixed, or tear-off shapes before invocation is obvious.

Element normalization:

1. Resolve the invoked element from the node.
2. Follow synthetic accessors back to the underlying getter, setter, method, or variable when necessary.
3. Derive a stable identity:
   - Package name from the library source URI.
   - Library URI, such as `package:dio/dio.dart`.
   - Enclosing class, mixin, enum, extension, or extension type if present.
   - Callable name.
   - Constructor name for constructors, using unnamed constructor as a distinct value.
   - Static, instance, top-level, constructor, or extension-call kind.
4. Compare this identity to normalized manifest entries.

Matching rules:

- Exact library URI and callable name should be required for the first version.
- Class/member matches should require the resolved declaring class unless the manifest opts into subtype matching.
- Extension methods should match by extension declaration identity, not just method name.
- If the element is unresolved, do not report. A false negative is better than reporting on an unknown call.
- If multiple manifest entries match, choose the most specific one for the diagnostic.

Try/catch protection detection:

1. Starting at the invocation node, walk ancestors until reaching the enclosing function, method, constructor, field initializer, or top-level declaration.
2. If a `TryStatement` ancestor is found, check which part contains the invocation.
3. Count it as protected only when the invocation is inside the try body and the try statement has at least one catch clause.
4. Do not count invocations inside `finally` as protected by that same try statement.
5. Do not count invocations inside a catch handler as protected unless there is an inner try/catch around that invocation.
6. For the first version, any catch clause is enough.
7. In a later version, compare manifest exception types against catch clause types and flag overly narrow catches.

Diagnostic placement:

- For function and method calls, highlight the method/function name token.
- For constructors, highlight the constructor type/name.
- For tear-offs, highlight the referenced callable.
- Include manifest metadata in the message when useful, for example: `dio/Dio.get is configured as throwing and must be called inside try/catch`.

### Layer 3: Project Function May-Throw Propagation

This layer is a later milestone. It detects project-local functions that indirectly throw because they contain a manual throw, null assertion, or uncaught throwing third-party call.

Function summary model:

```text
FunctionSummary
  elementIdentity
  sourcePath
  mayThrowReasons:
    - manualThrow
    - nullAssertion
    - uncaughtConfiguredApi
    - callsMayThrowProjectFunction
  declaredSafeOverride
  lastComputedContentHash
```

Propagation algorithm:

1. Build summaries for every function-like declaration in the analyzed package.
   - Top-level functions.
   - Methods.
   - Constructors.
   - Getters and setters.
   - Function-typed field initializers if practical.
   - Local functions and closures only within their enclosing file in the first propagation pass.
2. For each function body, record direct may-throw reasons from Layer 1 and Layer 2.
3. Record calls to other project functions by resolved element identity.
4. Iterate until summaries stop changing:
   - If function `A` calls function `B`, and `B` may throw, mark `A` as may throw unless the call is protected by try/catch.
5. Report call sites to project-local may-throw functions when the call is not protected.

Initial boundaries:

- Keep propagation intra-package only.
- Avoid whole-world analysis of dependencies.
- Do not attempt path-sensitive proof in the first propagation version. If any reachable statement in a function may throw, the function summary may throw.
- Treat dynamic calls, unresolved calls, reflection-like behavior, and function values conservatively as unknown rather than violations.

Why propagation is a later milestone:

- Analyzer plugins run repeatedly and need to stay fast.
- Cross-file summaries require cache invalidation.
- False positives increase quickly if the first version cannot explain why a function is considered throwing.

### Async And Future Error Handling

The first version should treat `try`/`catch` around `await` as protection:

```dart
try {
  await dio.get('/users');
} catch (_) {}
```

Cases to defer:

- `.catchError(...)` chains.
- `Future.sync`, `runZonedGuarded`, and framework-level error handlers.
- Streams whose errors are handled by `handleError` or listeners.

These should become separate explicit configurations because projects disagree about whether they are acceptable substitutes for local `try`/`catch`.

### Severity And Confidence

Diagnostics should carry a confidence model internally, even if the analyzer only displays the diagnostic:

- High confidence:
  - Direct null assertion.
  - Direct manual throw.
  - Exact manifest API call outside try/catch.
- Medium confidence:
  - Project-local may-throw propagation.
  - Manifest subtype matches.
- Low confidence:
  - Dynamic calls or unresolved elements.

Only high-confidence findings should report in the first release. Medium-confidence findings can be added after diagnostics include clear reason chains.

### Reason Chains

For propagated or manifest-based diagnostics, store a short reason chain for messages and tests:

```text
uncaught call to UserRepository.load
  -> calls Dio.get
  -> Dio.get is configured as throwing in tool/dart_exception_lint/throwing_apis.yaml
```

The first version can keep this internal to tests and logs. A later version can expose it in diagnostics documentation or quick-fix detail.

## Configuration Plan

Start with plugin-level defaults plus an optional manifest file:

```yaml
plugins:
  dart_exception_lint:
    path: /path/to/dart-exception-lint
    diagnostics:
      no_null_assertion: true
      no_manual_throw: true
      catch_throwing_third_party_calls: true
    throwing_api_manifest: tool/throwing_apis.yaml
```

Manifest example:

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

If plugin options are not straightforward through the current plugin APIs, keep the first version simple by reading `tool/dart_exception_lint/throwing_apis.yaml` from the analyzed package root and document that convention.

## Testing Strategy

1. Rule unit tests:
   - Use the analyzer plugin testing guidance linked from the Dart guide.
   - Keep fixtures small and single-purpose.
   - Assert diagnostic code, offset/range, and message.

2. Integration fixture:
   - Add `example/analysis_options.yaml` enabling this plugin by local path.
   - Add sample Dart files with expected violations.
   - Run `dart analyze example` manually during development.

3. Regression test groups:
   - `no_null_assertion`.
   - `no_manual_throw`.
   - `catch_throwing_third_party_calls`.
   - Configuration/manifest parsing.

## Documentation

Add these docs during initialization:

- `README.md`: short purpose, installation, enablement, and rule list.
- `doc/diagnostics.md`: one section per diagnostic with examples.
- `example/README.md`: local plugin enablement and sample analysis command.

The README should make the main limitation explicit: third-party exception detection depends on a maintained manifest, because Dart does not expose checked exceptions in API signatures.

## Implementation Order

1. Bootstrap package files and dependencies.
2. Create plugin entry point and registration skeleton.
3. Add diagnostic definitions.
4. Implement `no_null_assertion`.
5. Add first rule tests and confirm the test harness.
6. Implement `no_manual_throw`.
7. Add third-party throwing API manifest parser.
8. Implement resolved invocation matching.
9. Implement try/catch protection detection.
10. Add example consumer package.
11. Expand README and diagnostic docs.
12. Add CI once local commands are stable.

## Open Decisions

- Whether `rethrow` should be banned by `no_manual_throw` or covered by a separate rule.
- Whether test files should be exempt by default.
- Whether generated files should be skipped by filename convention, analyzer metadata, or configuration.
- Whether caught third-party calls require any catch clause or a catch clause compatible with a manifest-listed exception type.
- Whether project-local functions that call throwing third-party APIs should become "may throw" and require callers to catch them.

## First Milestone Definition Of Done

- `dart pub get` succeeds.
- `dart analyze` succeeds for the plugin package.
- `dart test` runs at least one passing test for `no_null_assertion`.
- `example/analysis_options.yaml` enables the local plugin.
- `example/lib/main.dart` demonstrates at least one reported null assertion.
- README explains how to enable the plugin locally.
