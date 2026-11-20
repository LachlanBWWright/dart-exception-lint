# External smoke evaluation

## Dart 3.14.1 and analyzer 14.3.0

The evaluator completed one package at each of 10 pinned revisions on Linux
x64. Dependency resolution and plugin analysis succeeded for every package,
and the evaluator restored their tracked files afterward.

| Repository | Diagnostics |
| --- | ---: |
| dart_http | 135 |
| dart_path | 448 |
| dart_args | 1,597 |
| dart_collection | 2,377 |
| dart_crypto | 1,088 |
| dart_intl | 1,531 |
| dart_yaml | 201 |
| dart_source_span | 91 |
| dart_async | 1,412 |
| dart_ffi | 142 |
| Total | 9,022 |

The HTTP manifest entry selects `pkgs/http`. The startup probe confirmed
that the installed plugin emitted `no_manual_throw`. The table records
diagnostic volume. The separate semantic corpus carries expected effect labels.

## Earlier release-contract run

The release-contract implementation batch exercised three pinned repositories
from `tool/corpus/projects.tsv` on Dart 3.13.5/Linux x64:

```bash
CORPUS_FILTER='^(dart_path|dart_yaml|dart_http)$' CORPUS_TIMEOUT=180 tool/corpus/run_corpus.sh
dart run tool/corpus/summarize_results.dart
```

One package root per repository completed dependency resolution and plugin
analysis without dependency or plugin failures. The runner restored package
options and lockfiles afterward. The counts include the configured default
analysis of tests and generated files.

| Repository | Diagnostics | Unknown-boundary diagnostics |
| --- | ---: | ---: |
| dart_http | 10 | 0 |
| dart_path | 1,476 | 915 |
| dart_yaml | 133 | 89 |

These are diagnostic-volume and installation results. The source inventory pins
the revisions; the counts are not accuracy labels. In particular, `ok` means
the evaluation completed, not that a package is exception-free. High unknown
volume in `path` and `yaml` needs causal triage and reviewed diagnostic labels
before asserting that the strict defaults are useful on existing applications.
Only these three repositories were executed in this batch; the other manifest
entries and the full Dart/Flutter/platform/IDE matrix remain outstanding.

The separate 20-case semantic corpus passes with 17 expected positive channel
labels, zero unexpected/missing labels, and retained unknown effects. This
small local corpus guards channel behavior; it cannot establish precision or
recall for the external repositories.
