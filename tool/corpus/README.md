# External corpus evaluation

`projects.tsv` is a revision-pinned inventory of 52 widely used Dart and
Flutter repositories. The list is intentionally a mixture of SDK/tooling
packages, foundational packages, application infrastructure, and Flutter
plugins. A manifest row can pin a package path within a monorepo. For other
rows, the runner uses the repository root package when available and discovers
package roots when needed.

Run the evaluator from the repository root:

```bash
tool/corpus/run_corpus.sh
```

Useful options:

```bash
CORPUS_LIMIT=10 CORPUS_REFRESH=1 tool/corpus/run_corpus.sh
CORPUS_ROOT=/tmp/dart-exception-corpus CORPUS_TIMEOUT=180 tool/corpus/run_corpus.sh
CORPUS_FILTER='^(dart_path|dart_yaml|dart_http)$' tool/corpus/run_corpus.sh
CORPUS_RESULTS=/tmp/dart-exception-results.tsv tool/corpus/run_corpus.sh
```

The runner first verifies that a disposable consumer emits a plugin diagnostic.
If startup fails, it leaves the previous results in place and records the
startup output in `plugin-probe.log` under the corpus root.

The runner creates a disposable worktree at each pinned commit, injects a
temporary local plugin configuration, resolves dependencies, and runs the
analyzer. It removes the worktrees after analysis and atomically replaces
`tool/corpus/results.tsv` or the path set by `CORPUS_RESULTS`. Cached clones
retain their current revisions and can supply available pins without a fetch.
Flutter analyzer protocol logs are kept with analyzer output under
`CORPUS_ROOT` and are checked for plugin errors and results from the selected
package. A Flutter run also needs a final idle status for every observed
plugin process. Partial plugin output is recorded as `plugin_incomplete`.
Flutter analysis runs each package source or test directory in its own process.
The runner keeps numbered scope logs alongside the combined package logs.
Separately configured examples are outside those scopes.
The injected analyzer options exclude nested packages that have their own
`pubspec.yaml`. These packages can have separate dependencies and can be
selected explicitly by a manifest entry. Dependency resolution also skips
separately configured examples.
Ancestor analyzer options in the disposable worktree retain their settings and
includes after plugin activation is removed. This keeps workspace-level lints
from interrupting the selected plugin's evaluation.
Warnings remain visible in analyzer logs. A failed dependency resolution skips
analysis for that package. Diagnostic counts use the rule code at the end of
analyzer output lines. The project row reports the first failed package and
counts dependency and plugin failures across all its packages.

This repository inventory measures diagnostic volume and execution failures. It does not measure precision or recall; it has no reviewed expected-diagnostic labels. It is not a claim that every repository has a
single canonical package root. Failures caused by unavailable platform SDKs,
private dependencies, repository-specific tooling, or analyzer-plugin
compilation are recorded separately from linter diagnostics. The TSV has
explicit `dependency_failures`, `plugin_failures`, and per-package
`rule_counts` columns so a zero-result run is not mistaken for a clean package
and corpus findings can be triaged by diagnostic family.

For a report suitable for a review artifact:

```bash
dart run tool/corpus/summarize_results.dart
```

The default limit includes all 52 manifest entries. `CORPUS_FILTER` selects
project IDs with a Bash regular expression before applying `CORPUS_LIMIT`.
Dependency resolution and analysis both use `CORPUS_TIMEOUT`.
Flutter rows use `flutter pub get` and `flutter analyze`. A missing Flutter
executable appears as `flutter_unavailable` in the results.

`semantic_cases.json` labels known and unknown effect channels in local
fixtures. Cases with `exceptionTypes` also check the exact known types by
channel. A `*` type indicates a source with no established exception type.

Run the semantic gate with this command.

```bash
dart run tool/verification/semantic_corpus.dart
```

Unexpected and missing labels fail the gate. Its reported counts describe only
these fixtures; the external repository inventory still has no reviewed
diagnostic labels and does not measure external precision or recall.
