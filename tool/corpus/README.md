# External corpus evaluation

`projects.tsv` is a reproducible evaluation corpus of 50 widely used Dart and
Flutter repositories. The list is intentionally a mixture of SDK/tooling
packages, foundational packages, application infrastructure, and Flutter
plugins. Some rows point at a monorepo; the runner discovers analyzable package
roots rather than assuming that the repository root is a package.

Run the evaluator from the repository root:

```bash
tool/corpus/run_corpus.sh
```

Useful options:

```bash
CORPUS_LIMIT=10 CORPUS_REFRESH=1 tool/corpus/run_corpus.sh
CORPUS_ROOT=/tmp/dart-exception-corpus CORPUS_TIMEOUT=180 tool/corpus/run_corpus.sh
```

The runner clones shallow copies, injects a temporary local plugin configuration
into each package, runs dependency resolution, runs the analyzer, restores the
package files, and writes machine-readable results to
`tool/corpus/results.tsv`. Clones and generated results are ignored by git.

The corpus is an evaluation harness, not a claim that every repository has a
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
