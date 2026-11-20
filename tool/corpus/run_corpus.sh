#!/usr/bin/env bash
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
manifest="$repo_root/tool/corpus/projects.tsv"
corpus_root="${CORPUS_ROOT:-${TMPDIR:-/tmp}/dart-exception-lint-corpus}"
limit="${CORPUS_LIMIT:-52}"
project_filter="${CORPUS_FILTER:-.*}"
timeout_seconds="${CORPUS_TIMEOUT:-300}"
refresh="${CORPUS_REFRESH:-0}"
packages_per_repo="${CORPUS_PACKAGES_PER_REPO:-1}"
results="$repo_root/tool/corpus/results.tsv"
mkdir -p "$corpus_root"
plugin_root="$(mktemp -d "$corpus_root/plugin.XXXXXX")" || exit 1
probe_root=''
active_options=''
active_backup=''
active_had_options=0
active_lock=''
active_lock_backup=''
active_had_lock=0

restore_options() {
  [[ -z "$active_options" ]] && return
  if [[ "$active_had_options" == 1 ]]; then
    mv -- "$active_backup" "$active_options"
  else
    rm -f -- "$active_options"
  fi
  active_options=''
  if [[ -n "$active_lock" ]]; then
    if [[ "$active_had_lock" == 1 ]]; then
      mv -- "$active_lock_backup" "$active_lock"
    else
      rm -f -- "$active_lock"
    fi
    active_lock=''
  fi
}

cleanup() {
  restore_options
  rm -rf -- "$plugin_root"
  if [[ -n "$probe_root" ]]; then
    rm -rf -- "$probe_root"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cp -R "$repo_root"/. "$plugin_root"/ || exit 1

# Dart can finish analysis without ever loading an incompatible plugin.
probe_root="$(mktemp -d "$corpus_root/probe.XXXXXX")" || exit 1
probe_log="$corpus_root/plugin-probe.log"
mkdir -p "$probe_root/lib" || exit 1
cat > "$probe_root/pubspec.yaml" <<'EOF'
name: corpus_plugin_probe
environment:
  sdk: ^3.11.0
EOF
cat > "$probe_root/analysis_options.yaml" <<EOF
plugins:
  dart_exception_lint:
    path: $plugin_root
EOF
printf '%s\n' "void pluginProbe() { throw 'probe'; }" > "$probe_root/lib/probe.dart"
if ! timeout "$timeout_seconds" dart pub get --offline --directory "$probe_root" >"$probe_log" 2>&1; then
  printf 'Could not resolve the corpus startup probe. See %s\n' "$probe_log" >&2
  exit 1
fi
timeout "$timeout_seconds" dart analyze --format machine "$probe_root" >>"$probe_log" 2>&1
probe_status=$?
if [[ "$probe_status" == 124 ]] || ! rg -qi '\|NO_MANUAL_THROW\|' "$probe_log"; then
  printf 'The corpus startup probe did not receive a plugin diagnostic. See %s\n' "$probe_log" >&2
  exit 1
fi

printf 'id\turl\tstatus\tpackages\tdiagnostics\tdependency_failures\tplugin_failures\trule_counts\tcommand\n' > "$results"

count=0
while IFS=$'\t' read -r id url manager commit package_path; do
  [[ -z "$id" || "$id" == \#* ]] && continue
  [[ "$id" =~ $project_filter ]] || continue
  ((count += 1))
  ((count > limit)) && break

  if [[ "$manager" == flutter ]]; then
    if ! command -v flutter >/dev/null 2>&1; then
      printf '%s\t%s\tflutter_unavailable\t0\t0\t0\t0\t\t%s\n' "$id" "$url" "flutter analyze" >> "$results"
      continue
    fi
    resolver=(flutter pub get)
    analyzer=(flutter analyze --no-pub --no-fatal-infos --no-fatal-warnings)
  else
    resolver=(dart pub get)
    analyzer=(dart analyze)
  fi

  checkout="$corpus_root/$id"
  if [[ "$refresh" == 1 && -d "$checkout" ]]; then
    rm -rf "$checkout"
  fi
  newly_cloned=0
  if [[ ! -d "$checkout/.git" ]]; then
    newly_cloned=1
    timeout "$timeout_seconds" git clone --depth 1 --no-checkout --filter=blob:none --quiet "$url" "$checkout" \
      2>"$corpus_root/$id.clone.log" || {
      printf '%s\t%s\tclone_failed\t0\t0\t0\t0\t\t%s\n' "$id" "$url" "git clone" >> "$results"
      continue
    }
  fi

  if [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]]; then
    printf '%s\t%s\tinvalid_commit\t0\t0\t0\t0\t\tmanifest validation\n' "$id" "$url" >> "$results"
    continue
  fi
  if [[ "$newly_cloned" == 0 && -n "$(git -C "$checkout" status --porcelain)" ]]; then
    printf '%s\t%s\tdirty_checkout\t0\t0\t0\t0\t\tcheckout preserved\n' "$id" "$url" >> "$results"
    continue
  fi
  if ! timeout "$timeout_seconds" git -C "$checkout" fetch --depth 1 --quiet origin "$commit" ||
      ! git -C "$checkout" checkout --detach --quiet "$commit"; then
    printf '%s\t%s\tcheckout_failed\t0\t0\t0\t0\t\tgit fetch pinned commit\n' "$id" "$url" >> "$results"
    continue
  fi
  if [[ -n "$package_path" && ! -f "$checkout/$package_path/pubspec.yaml" ]]; then
    printf '%s\t%s\tmissing_package\t0\t0\t0\t0\t\t%s\n' "$id" "$url" "$package_path/pubspec.yaml" >> "$results"
    continue
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
    backup="$plugin_root/corpus-package.options.backup"
    had_options=0
    if [[ -f "$options" ]]; then
      cp "$options" "$backup"
      had_options=1
    fi
    active_options="$options"
    active_backup="$backup"
    active_had_options="$had_options"
    active_lock="$package_dir/pubspec.lock"
    active_lock_backup="$plugin_root/corpus-package.lock.backup"
    active_had_lock=0
    if [[ -f "$active_lock" ]]; then
      cp -- "$active_lock" "$active_lock_backup"
      active_had_lock=1
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

    if timeout "$timeout_seconds" "${resolver[@]}" --directory "$package_dir" >"$corpus_root/$id.$package_count.pubget.log" 2>&1; then
      resolver_status=0
    else
      resolver_status=$?
      ((dependency_failures += 1))
    fi
    output_file="$corpus_root/$id.$package_count.analyze.log"
    if timeout "$timeout_seconds" "${analyzer[@]}" "$package_dir" >"$output_file" 2>&1; then
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
    found="$(rg -c 'catch_(runtime|async|inferred|unknown|throwing_third_party)_|no_null_assertion|no_manual_throw' "$output_file" 2>/dev/null || true)"
    [[ "$found" =~ ^[0-9]+$ ]] && ((diagnostic_count += found)) || true
    package_rule_counts="$(rg -o 'catch_runtime_throw_sources|catch_async_error_sources|catch_inferred_throwing_calls|catch_unknown_dynamic_calls|catch_throwing_third_party_calls|no_null_assertion|no_manual_throw' "$output_file" 2>/dev/null | sort | uniq -c | awk '{print $2 ":" $1}' | paste -sd, - || true)"
    if [[ -n "$package_rule_counts" ]]; then
      rule_counts="${rule_counts:+$rule_counts;}${package_count}:$package_rule_counts"
    fi
    restore_options
  done < <(
    if [[ -n "$package_path" ]]; then
      printf '%s\n' "$checkout/$package_path/pubspec.yaml"
    elif [[ -f "$checkout/pubspec.yaml" ]]; then
      printf '%s\n' "$checkout/pubspec.yaml"
    else
      find "$checkout" -name pubspec.yaml -not -path '*/.dart_tool/*' -print \
        | sort | head -n "$packages_per_repo"
    fi
  )

  if [[ "$package_count" == 0 ]]; then package_status=no_packages_found; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" "$url" "$package_status" "$package_count" "$diagnostic_count" \
    "$dependency_failures" "$plugin_failures" "$rule_counts" "${analyzer[*]}" >> "$results"
done < "$manifest"

printf 'Wrote %s\n' "$results"
