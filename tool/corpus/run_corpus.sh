#!/usr/bin/env bash
set -u

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
manifest="$repo_root/tool/corpus/projects.tsv"
corpus_root="${CORPUS_ROOT:-${TMPDIR:-/tmp}/dart-exception-lint-corpus}"
limit="${CORPUS_LIMIT:-50}"
timeout_seconds="${CORPUS_TIMEOUT:-300}"
refresh="${CORPUS_REFRESH:-0}"
packages_per_repo="${CORPUS_PACKAGES_PER_REPO:-1}"
results="$repo_root/tool/corpus/results.tsv"
plugin_root="$(mktemp -d "$corpus_root/plugin.XXXXXX")"

cleanup() {
  rm -rf "$plugin_root"
}
trap cleanup EXIT

mkdir -p "$corpus_root"
cp -R "$repo_root"/. "$plugin_root"/
printf 'id\turl\tstatus\tpackages\tdiagnostics\tdependency_failures\tplugin_failures\trule_counts\tcommand\n' > "$results"

count=0
while IFS=$'\t' read -r id url manager; do
  [[ -z "$id" || "$id" == \#* ]] && continue
  ((count += 1))
  ((count > limit)) && break

  checkout="$corpus_root/$id"
  if [[ "$refresh" == 1 && -d "$checkout" ]]; then
    rm -rf "$checkout"
  fi
  if [[ ! -d "$checkout/.git" ]]; then
    git clone --depth 1 --filter=blob:none --quiet "$url" "$checkout" \
      2>"$corpus_root/$id.clone.log" || {
      printf '%s\t%s\tclone_failed\t0\t0\t0\t0\t%s\n' "$id" "$url" "git clone" >> "$results"
      continue
    }
  fi

  package_count=0
  diagnostic_count=0
  rule_counts=''
  dependency_failures=0
  plugin_failures=0
  package_status=ok
  while IFS= read -r pubspec; do
    package_dir="$(dirname "$pubspec")"
    [[ "$package_dir" == "$checkout/.dart_tool"* ]] && continue
    ((package_count += 1))
    options="$package_dir/analysis_options.yaml"
    backup="$options.dart_exception_lint.backup"
    had_options=0
    if [[ -f "$options" ]]; then
      cp "$options" "$backup"
      had_options=1
    fi
    cat > "$options" <<EOF
plugins:
  dart_exception_lint:
    path: $plugin_root
    diagnostics:
      no_null_assertion: true
      no_manual_throw: true
      catch_throwing_third_party_calls: true
      catch_runtime_throw_sources: true
      catch_async_error_sources: true
      catch_inferred_throwing_calls: true
      catch_unknown_dynamic_calls: true
      invalid_exception_analysis_config: true
      invalid_exception_contract: true
EOF

    if [[ "$manager" == flutter ]] && command -v flutter >/dev/null 2>&1; then
      resolver=(flutter pub get)
    else
      resolver=(dart pub get)
    fi
    if "${resolver[@]}" --directory "$package_dir" >"$corpus_root/$id.$package_count.pubget.log" 2>&1; then
      resolver_status=0
    else
      resolver_status=$?
      ((dependency_failures += 1))
    fi
    output_file="$corpus_root/$id.$package_count.analyze.log"
    if timeout "$timeout_seconds" dart analyze "$package_dir" >"$output_file" 2>&1; then
      status_code=0
    else
      status_code=$?
      if [[ "$status_code" == 124 ]]; then
        package_status=timeout
      else
        package_status=analyzer_failed
      fi
    fi
    if rg -q 'Failed to compile|executing an analyzer plugin|Plugin execution failed' "$output_file"; then
      ((plugin_failures += 1))
      package_status=plugin_failed
    elif [[ "$resolver_status" != 0 && "$package_status" == ok ]]; then
      package_status=dependency_failed
    fi
    found="$(rg -c 'catch_(runtime|async|inferred|unknown)_|no_null_assertion|no_manual_throw' "$output_file" 2>/dev/null || true)"
    [[ "$found" =~ ^[0-9]+$ ]] && ((diagnostic_count += found)) || true
    package_rule_counts="$(rg -o 'catch_runtime_throw_sources|catch_async_error_sources|catch_inferred_throwing_calls|catch_unknown_dynamic_calls|no_null_assertion|no_manual_throw' "$output_file" 2>/dev/null | sort | uniq -c | awk '{print $2 ":" $1}' | paste -sd, - || true)"
    if [[ -n "$package_rule_counts" ]]; then
      rule_counts="${rule_counts:+$rule_counts;}${package_count}:$package_rule_counts"
    fi
    if [[ "$had_options" == 1 ]]; then
      mv "$backup" "$options"
    else
      rm -f "$options"
    fi
  done < <(
    if [[ -f "$checkout/pubspec.yaml" ]]; then
      printf '%s\n' "$checkout/pubspec.yaml"
    else
      find "$checkout" -name pubspec.yaml -not -path '*/.dart_tool/*' -print \
        | sort | head -n "$packages_per_repo"
    fi
  )

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\tdart analyze\n' \
    "$id" "$url" "$package_status" "$package_count" "$diagnostic_count" \
    "$dependency_failures" "$plugin_failures" "$rule_counts" >> "$results"
done < "$manifest"

printf 'Wrote %s\n' "$results"
