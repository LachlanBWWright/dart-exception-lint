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

### Scoped follow-up runs

Each counter below covers the selected package's own files. Dependency
resolution skipped nested examples, and existing analyzer warnings were kept
visible. All eight runs completed with zero dependency and plugin failures.

| Repository | Plugin diagnostics |
| --- | ---: |
| Equatable | 2,892 |
| Fpdart | 3,019 |
| GetIt | 10,541 |
| RxDart | 23,778 |
| `dart_path` | 11,465 |
| `dart_lints` | 0 |
| Mocktail | 5,855 |
| Very Good Analysis | 44 |

The earlier full-package RxDart analysis reached its 660-second timeout. An
Analysis Server CPU profile showed repeated dependency hashing and source-key
construction during rule execution. At `93e1bec`, the same pinned package
completed plugin analysis in about 183 seconds with a fresh analyzer state.
Its pinned package root contains 83 library files. The `dart_path`, Dart Lints,
Mocktail and Very Good Analysis rows were verified at `83997df`. The Mocktail
run used an existing bare clone with an unavailable upstream.

### Dart monorepo package selection

The run at `1087f0e` selected the maintained packages inside their pinned
repositories. Bloc, Dio, and Retrofit completed with zero dependency and
plugin failures.

| Package | Plugin diagnostics |
| --- | ---: |
| Bloc | 4,543 |
| Dio | 10,303 |
| Retrofit | 445 |

The pinned `json_serializable` package produced 11 compiler errors after Pub
resolved `source_helper` 1.4.0 under its `^1.3.10` constraint. The two packages
defined conflicting imports and extensions. A separate run with `source_helper`
1.3.10 in a disposable workspace override completed with analyzer exit code
zero. The regular corpus result records the original dependency resolution.

## Flutter 3.50.1 and bundled Dart 3.14.0

Three pinned Flutter packages completed dependency resolution and plugin
analysis on Linux x64 at `83fface`. The evaluator analyzed each package's own
source and test directories. The protocol logs reported no plugin errors,
and each cached checkout remained clean after its evaluation worktree was removed.

| Repository | Plugin diagnostics | Flutter analysis time |
| --- | ---: | ---: |
| flutter_hooks | 1,840 | 209.2 s |
| provider | 1,308 | 111.0 s |
| window_manager | 21 | 70.1 s |
| Total | 3,169 | |

The timings include plugin setup and reflect concurrent workloads on the same
host. They describe these specific runs. The evaluator now uses package source
and test directories for all Flutter rows so a separately configured example
cannot finish before the package under evaluation publishes its results.

## Reviewed source sites

- In `dart_path`, the nonempty check guards `path.codeUnitAt(0)` and `path[0]`
  on the same String. The focused rerun confirms that both bounds diagnostics
  disappear. The `InternalStyle.isSeparator` dispatch still reports
  uncertainty. [Pinned source](https://github.com/dart-lang/path/blob/7e3d5d87220133ad9cc99f82e85a826011a62859/lib/src/parsed_path.dart#L51-L57)
- In the same parser, `start` begins at zero or one and is updated to `i + 1`
  inside the bounded loop. The final `substring(start)` also checks
  `start < path.length`. The evaluator confirms that this final bounds
  diagnostic and the loop's code-unit, indexed-read and two-argument
  substring diagnostics disappear. The open `InternalStyle.isSeparator`
  dispatch still reports uncertainty. [Pinned source](https://github.com/dart-lang/path/blob/7e3d5d87220133ad9cc99f82e85a826011a62859/lib/src/parsed_path.dart#L60-L72)
- The `flutter_hooks` ticker assertion explicitly throws a `FlutterError`.
  The scoped run reports the expected `no_manual_throw` diagnostic on that
  statement. [Pinned source](https://github.com/rrousselGit/flutter_hooks/blob/6f7344fc09f3800c1a9944d06ae56d5324e084e3/packages/flutter_hooks/lib/src/animation.dart#L178-L187)
- The `provider` delegate initializer uses postfix `!` on `element` before
  starting its listener. The scoped run reports the expected
  `no_null_assertion` diagnostic at that operator. [Pinned source](https://github.com/rrousselGit/provider/blob/3ed4c6d6b1700c08256f25a034bb93f943bd7236/packages/provider/lib/src/deferred_inherited_provider.dart#L98-L107)

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
