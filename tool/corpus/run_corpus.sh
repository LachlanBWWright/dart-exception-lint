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
results="${CORPUS_RESULTS:-$repo_root/tool/corpus/results.tsv}"
results_tmp=''
diagnostic_names='catch_(runtime_throw_sources|async_error_sources|inferred_throwing_calls|unknown_dynamic_calls|throwing_third_party_calls)|no_null_assertion|no_manual_throw|invalid_exception_(analysis_config|contract)|unsupported_exception_analysis_environment'
mkdir -p "$corpus_root" || exit 1
corpus_root="$(cd "$corpus_root" && pwd)" || exit 1
plugin_root="$(mktemp -d "$corpus_root/plugin.XXXXXX")" || exit 1
probe_root=''
evaluation_root=''
active_checkout=''
active_worktree=''
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

remove_worktree() {
  [[ -z "$active_worktree" ]] && return 0
  git -C "$active_checkout" worktree remove --force "$active_worktree" || return 1
  active_checkout=''
  active_worktree=''
}

flutter_plugin_completed() {
  local protocol_log=$1
  local package_dir=$2
  # Flutter can exit after the first Analysis Server plugin becomes idle.
  # Check the final state of every plugin process observed in this run.
  awk -v prefix="\"$package_dir/" '
    /PluginNoti:.*"analysis\.errors"/ && index($0, prefix) { published = 1 }
    /PluginNoti:.*"plugin\.status"/ && match($0, /"isAnalyzing"::(true|false)/) {
      state = substr($0, RSTART, RLENGTH)
      plugin = $0
      if (sub(/^.*}:file::/, "", plugin)) {
        active[plugin] = state ~ /true$/
      }
    }
    END {
      if (!published) exit 1
      for (plugin in active) {
        completed = 1
        if (active[plugin]) exit 1
      }
      if (!completed) exit 1
    }
  ' "$protocol_log"
}

analyze_scope() {
  local source_root=$1
  local output_log=$2
  local protocol_log=$3
  local analysis_command=("${analyzer[@]}")
  local code=0
  if [[ "$manager" == flutter ]]; then
    analysis_command+=("--protocol-traffic-log=$protocol_log")
    rm -f -- "$protocol_log"
  fi
  timeout "$timeout_seconds" "${analysis_command[@]}" "$source_root" >"$output_log" 2>&1 || code=$?
  if rg -q 'Failed to compile|executing an analyzer plugin|Plugin execution failed' "$output_log" ||
      { [[ "$manager" == flutter && -f "$protocol_log" ]] && rg -q '"plugin\.error"' "$protocol_log"; }; then
    printf '%s\n' plugin_failed
  elif [[ "$code" == 124 ]]; then
    printf '%s\n' timeout
  elif [[ "$code" != 0 ]]; then
    printf '%s\n' analyzer_failed
  elif [[ "$manager" == flutter ]] && ! flutter_plugin_completed "$protocol_log" "$source_root"; then
    printf '%s\n' plugin_incomplete
  else
    printf '%s\n' ok
  fi
}

cleanup() {
  restore_options
  remove_worktree || true
  if [[ -n "$results_tmp" ]]; then rm -f -- "$results_tmp"; fi
  rm -rf -- "$plugin_root"
  if [[ -n "$probe_root" ]]; then
    rm -rf -- "$probe_root"
  fi
  if [[ -n "$evaluation_root" ]]; then
    rmdir -- "$evaluation_root" || true
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

results_tmp="$(mktemp -- "$results.tmp.XXXXXX")" || exit 1
printf 'id\turl\tstatus\tpackages\tdiagnostics\tdependency_failures\tplugin_failures\trule_counts\tcommand\n' > "$results_tmp"
evaluation_root="$(mktemp -d "$corpus_root/evaluate.XXXXXX")" || exit 1

count=0
while IFS=$'\t' read -r id url manager commit package_path; do
  [[ -z "$id" || "$id" == \#* ]] && continue
  [[ "$id" =~ $project_filter ]] || continue
  ((count += 1))
  ((count > limit)) && break

  if [[ "$manager" == flutter ]]; then
    if ! command -v flutter >/dev/null 2>&1; then
      printf '%s\t%s\tflutter_unavailable\t0\t0\t0\t0\t\t%s\n' "$id" "$url" "flutter analyze" >> "$results_tmp"
      continue
    fi
    resolver=(flutter pub get --no-example)
    analyzer=(flutter analyze --no-pub --no-fatal-infos --no-fatal-warnings)
  else
    resolver=(dart pub get --no-example)
    analyzer=(dart analyze --no-fatal-warnings)
  fi

  if [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]]; then
    printf '%s\t%s\tinvalid_commit\t0\t0\t0\t0\t\t%s\n' "$id" "$url" "manifest validation" >> "$results_tmp"
    continue
  fi

  checkout="$corpus_root/$id"
  if [[ "$refresh" == 1 && -d "$checkout" ]]; then
    rm -rf "$checkout"
  fi
  if [[ -d "$checkout/.git" ]]; then
    if [[ -n "$(git -C "$checkout" status --porcelain)" ]]; then
      printf '%s\t%s\tdirty_checkout\t0\t0\t0\t0\t\t%s\n' "$id" "$url" "checkout preserved" >> "$results_tmp"
      continue
    fi
  elif [[ "$(git -C "$checkout" rev-parse --is-bare-repository 2>/dev/null)" != true ]]; then
    timeout "$timeout_seconds" git clone --bare --depth 1 --filter=blob:none --quiet "$url" "$checkout" \
      2>"$corpus_root/$id.clone.log" || {
      printf '%s\t%s\tclone_failed\t0\t0\t0\t0\t\t%s\n' "$id" "$url" "git clone" >> "$results_tmp"
      continue
    }
  fi
  if ! GIT_NO_LAZY_FETCH=1 git -C "$checkout" cat-file -e "$commit^{commit}" 2>/dev/null &&
      ! timeout "$timeout_seconds" git -C "$checkout" fetch --depth 1 --quiet origin "$commit"; then
    printf '%s\t%s\tcheckout_failed\t0\t0\t0\t0\t\t%s\n' "$id" "$url" "git fetch pinned commit" >> "$results_tmp"
    continue
  fi

  # Flutter's tooling can modify nested files outside the selected package.
  # Run in a fresh worktree so those writes cannot touch the cached checkout.
  evaluation="$evaluation_root/$id"
  if ! git -C "$checkout" worktree add --quiet --detach "$evaluation" "$commit"; then
    printf '%s\t%s\tcheckout_failed\t0\t0\t0\t0\t\t%s\n' "$id" "$url" "git worktree add" >> "$results_tmp"
    continue
  fi
  active_checkout="$checkout"
  active_worktree="$evaluation"
  if [[ -n "$package_path" && ! -f "$evaluation/$package_path/pubspec.yaml" ]]; then
    printf '%s\t%s\tmissing_package\t0\t0\t0\t0\t\t%s\n' "$id" "$url" "$package_path/pubspec.yaml" >> "$results_tmp"
    remove_worktree || exit 1
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
    [[ "$package_dir" == "$evaluation/.dart_tool"* ]] && continue
    ((package_count += 1))
    workspace_options=()
    directory="$package_dir"
    while [[ "$directory" == "$evaluation/"* ]]; do
      directory="$(dirname -- "$directory")"
      ancestor_options="$directory/analysis_options.yaml"
      if [[ -f "$ancestor_options" && ! -L "$ancestor_options" ]]; then
        workspace_options+=("$ancestor_options")
      fi
    done
    if [[ "${#workspace_options[@]}" != 0 ]] && ! (
      cd "$plugin_root" && timeout "$timeout_seconds" dart run tool/corpus/isolate_workspace_plugins.dart "${workspace_options[@]}"
    ) >"$corpus_root/$id.$package_count.workspace.log" 2>&1; then
      if [[ "$package_status" == ok ]]; then package_status=configuration_failed; fi
      continue
    fi
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
    nested_packages=()
    while IFS= read -r -d '' nested_manifest; do
      [[ "$nested_manifest" == "$package_dir/pubspec.yaml" ]] && continue
      nested_package="${nested_manifest#"$package_dir/"}"
      nested_packages+=("${nested_package%/pubspec.yaml}")
    done < <(
      find "$package_dir" \( -name .dart_tool -o -name .git \) -prune -o \
        -type f -name pubspec.yaml -print0
    )
    : > "$options"
    if [[ "${#nested_packages[@]}" != 0 ]]; then
      printf 'analyzer:\n  exclude:\n' >> "$options"
      for nested_package in "${nested_packages[@]}"; do
        printf "    - '%s/**'\n" "${nested_package//\'/\'\'}" >> "$options"
      done
    fi
    cat >> "$options" <<EOF
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

    dependency_log="$corpus_root/$id.$package_count.pubget.log"
    output_file="$corpus_root/$id.$package_count.analyze.log"
    protocol_log="$corpus_root/$id.$package_count.protocol.log"
    if [[ "$manager" == flutter ]]; then rm -f -- "$protocol_log"; fi
    if ! timeout "$timeout_seconds" "${resolver[@]}" --directory "$package_dir" >"$dependency_log" 2>&1; then
      ((dependency_failures += 1))
      printf 'Dependency resolution failed. See %s\n' "$dependency_log" > "$output_file"
      if [[ "$package_status" == ok ]]; then package_status=dependency_failed; fi
      restore_options
      continue
    fi
    analysis_roots=("$package_dir")
    if [[ "$manager" == flutter ]]; then
      # Separate processes keep a finished context from terminating a sibling
      # context. The selected roots also keep embedded examples out of analysis.
      analysis_roots=()
      for directory in lib bin test integration_test tool; do
        scope="$package_dir/$directory"
        if [[ -d "$scope" ]] && [[ -n "$(find "$scope" -type f -name '*.dart' -print -quit)" ]]; then
          analysis_roots+=("$scope")
        fi
      done
      if [[ "${#analysis_roots[@]}" == 0 ]]; then
        analysis_roots=("$package_dir")
      fi
    fi
    status=ok
    failed_plugin=0
    scope_count=0
    if [[ "${#analysis_roots[@]}" != 1 ]]; then
      : > "$output_file"
      : > "$protocol_log"
    fi
    for scope in "${analysis_roots[@]}"; do
      ((scope_count += 1))
      scope_output="$output_file"
      scope_protocol="$protocol_log"
      if [[ "${#analysis_roots[@]}" != 1 ]]; then
        scope_output="$corpus_root/$id.$package_count.$scope_count.analyze.log"
        scope_protocol="$corpus_root/$id.$package_count.$scope_count.protocol.log"
      fi
      scope_status="$(analyze_scope "$scope" "$scope_output" "$scope_protocol")"
      if [[ "$status" == ok ]]; then status="$scope_status"; fi
      if [[ "$scope_status" == plugin_failed || "$scope_status" == plugin_incomplete ]]; then
        failed_plugin=1
      fi
      if [[ "${#analysis_roots[@]}" != 1 ]]; then
        cat "$scope_output" >> "$output_file"
        if [[ -f "$scope_protocol" ]]; then cat "$scope_protocol" >> "$protocol_log"; fi
      fi
    done
    ((plugin_failures += failed_plugin))
    if [[ "$package_status" == ok ]]; then package_status="$status"; fi
    mapfile -t matches < <(
      rg -o --replace '$3' "^[[:space:]]*(error|warning|info)[[:space:]].*[[:space:]](-|•)[[:space:]]($diagnostic_names)[[:space:]]*$" "$output_file" || true
    )
    ((diagnostic_count += ${#matches[@]}))
    if [[ "${#matches[@]}" != 0 ]]; then
      package_rule_counts="$(printf '%s\n' "${matches[@]}" | sort | uniq -c | awk '{print $2 ":" $1}' | paste -sd, -)"
      rule_counts="${rule_counts:+$rule_counts;}${package_count}:$package_rule_counts"
    fi
    restore_options
  done < <(
    if [[ -n "$package_path" ]]; then
      printf '%s\n' "$evaluation/$package_path/pubspec.yaml"
    elif [[ -f "$evaluation/pubspec.yaml" ]]; then
      printf '%s\n' "$evaluation/pubspec.yaml"
    else
      find "$evaluation" -name pubspec.yaml -not -path '*/.dart_tool/*' -print \
        | sort | head -n "$packages_per_repo"
    fi
  )
  remove_worktree || exit 1

  if [[ "$package_count" == 0 ]]; then package_status=no_packages_found; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" "$url" "$package_status" "$package_count" "$diagnostic_count" \
    "$dependency_failures" "$plugin_failures" "$rule_counts" "${analyzer[*]}" >> "$results_tmp"
done < "$manifest"

mv -- "$results_tmp" "$results" || exit 1
results_tmp=''
printf 'Wrote %s\n' "$results"
