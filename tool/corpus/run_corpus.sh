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
    analyzer_command=("${analyzer[@]}")
    analysis_roots=("$package_dir")
    if [[ "$manager" == flutter ]]; then
      analyzer_command+=("--protocol-traffic-log=$protocol_log")
      # A nested example can finish its own plugin context first and make
      # Flutter exit before the selected package publishes diagnostics.
      analysis_roots=()
      for directory in lib bin test integration_test tool; do
        if [[ -d "$package_dir/$directory" ]]; then
          analysis_roots+=("$package_dir/$directory")
        fi
      done
      if [[ "${#analysis_roots[@]}" == 0 ]]; then
        analysis_roots=("$package_dir")
      fi
    fi
    status_code=0
    timeout "$timeout_seconds" "${analyzer_command[@]}" "${analysis_roots[@]}" >"$output_file" 2>&1 || status_code=$?
    case "$status_code" in
      0) status=ok ;;
      124) status=timeout ;;
      *) status=analyzer_failed ;;
    esac
    if rg -q 'Failed to compile|executing an analyzer plugin|Plugin execution failed' "$output_file" ||
        { [[ "$manager" == flutter && -f "$protocol_log" ]] && rg -q '"plugin\.error"' "$protocol_log"; }; then
      ((plugin_failures += 1))
      status=plugin_failed
    elif [[ "$manager" == flutter && "$status" == ok ]] &&
        ! rg 'PluginNoti:.*"analysis\.errors"' "$protocol_log" 2>/dev/null | rg -F -- "\"$package_dir/" >/dev/null; then
      ((plugin_failures += 1))
      status=plugin_incomplete
    fi
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
