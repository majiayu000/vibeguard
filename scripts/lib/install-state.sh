#!/usr/bin/env bash
# VibeGuard Install State — Track installed files and support repair/drift detection
#
#State file: ~/.vibeguard/install-state.json
# Format:
# {
#   "version": 1,
#   "installed_at": "2026-03-23T17:00:00+08:00",
#   "profile": "full",
#   "languages": ["rust", "python"],
#   "repo_dir": "/path/to/vibeguard",
#   "files": {
#     "~/.claude/rules/vibeguard/common/coding-style.md": {
#       "source": "rules/claude-rules/common/coding-style.md",
#       "checksum": "sha256:abc123...",
#       "type": "copy"
#     },
#     "~/.claude/skills/vibeguard": {
#       "source": "skills/vibeguard",
#       "type": "symlink"
#     }
#   }
# }

STATE_VERSION=1
STATE_FILE="${HOME}/.vibeguard/install-state.json"
# Snapshot of the inventory from the previous install. state_init resets
# STATE_FILE, so without this the installer cannot tell "never installed" from
# "installed by VibeGuard and since deleted by the user" (GH719).
STATE_PREVIOUS_FILE="${HOME}/.vibeguard/install-state.previous.json"
INSTALL_STATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_VG_STATE_RUNTIME_CACHE=""
_VG_STATE_RUNTIME_CACHE_KEY=""

state_runtime_cache_key() {
  printf '%s\n' "${VIBEGUARD_SETUP_RUNTIME:-}|${_INSTALL_TMP:-}|${HOME}|${PATH}|${INSTALL_STATE_LIB_DIR}"
}

state_runtime_cache_clear() {
  _VG_STATE_RUNTIME_CACHE=""
  _VG_STATE_RUNTIME_CACHE_KEY=""
}

state_runtime_path() {
  local repo_root candidate cache_key
  repo_root="$(cd "${INSTALL_STATE_LIB_DIR}/../.." && pwd)"
  cache_key="$(state_runtime_cache_key)"
  if [[ -n "${_VG_STATE_RUNTIME_CACHE}" \
    && "${_VG_STATE_RUNTIME_CACHE_KEY}" == "${cache_key}" \
    && -x "${_VG_STATE_RUNTIME_CACHE}" ]]; then
    printf '%s\n' "${_VG_STATE_RUNTIME_CACHE}"
    return 0
  fi
  state_runtime_cache_clear
  for candidate in \
    "${VIBEGUARD_SETUP_RUNTIME:-}" \
    "${_INSTALL_TMP:-}/bin/vibeguard-runtime" \
    "${HOME}/.vibeguard/installed/bin/vibeguard-runtime" \
    "${HOME}/.vibeguard/vibeguard-runtime" \
    "${repo_root}/vibeguard-runtime/target/release/vibeguard-runtime" \
    "${repo_root}/vibeguard-runtime/target/debug/vibeguard-runtime" \
    "vibeguard-runtime"; do
    [[ -n "${candidate}" ]] || continue
    if [[ "${candidate}" == */* ]]; then
      if [[ -x "${candidate}" ]] && state_runtime_supports "${candidate}"; then
        _VG_STATE_RUNTIME_CACHE="${candidate}"
        _VG_STATE_RUNTIME_CACHE_KEY="${cache_key}"
        printf '%s\n' "${candidate}"
        return 0
      fi
    elif command -v "${candidate}" >/dev/null 2>&1; then
      candidate="$(command -v "${candidate}")"
      if state_runtime_supports "${candidate}"; then
        _VG_STATE_RUNTIME_CACHE="${candidate}"
        _VG_STATE_RUNTIME_CACHE_KEY="${cache_key}"
        printf '%s\n' "${candidate}"
        return 0
      fi
    fi
  done
  return 1
}

state_runtime_supports() {
  local runtime="$1" capability_out command probe_out
  capability_out="$("${runtime}" setup-state-capabilities 2>/dev/null)" || return 1
  [[ "${capability_out}" == "complete-snapshot-v2" ]] || return 1
  for command in \
    setup-state-init \
    setup-state-list \
    setup-state-list-project-hooks \
    setup-state-list-symlinks-under \
    setup-state-list-tracked-under \
    setup-state-record-file \
    setup-state-record-project-hook \
    setup-state-check-drift \
    setup-state-quarantine-count \
    setup-state-validate-managed-tree-transactions \
    setup-state-verify-managed-tree \
    setup-state-generation \
    setup-state-mark-complete; do
    probe_out="$("${runtime}" "${command}" 2>&1 || true)"
    if printf '%s\n' "${probe_out}" | grep -q "Unknown command"; then
      return 1
    fi
  done
}

state_runtime() {
  local runtime cache_key
  cache_key="$(state_runtime_cache_key)"
  if [[ -z "${_VG_STATE_RUNTIME_CACHE}" \
    || "${_VG_STATE_RUNTIME_CACHE_KEY}" != "${cache_key}" \
    || ! -x "${_VG_STATE_RUNTIME_CACHE}" ]]; then
    state_runtime_path >/dev/null || {
      printf 'ERROR: vibeguard-runtime not found for install-state operation\n' >&2
      return 127
    }
  fi
  runtime="${_VG_STATE_RUNTIME_CACHE}"
  "${runtime}" "$@"
}

state_reject_legacy_publish_artifacts() {
  local artifact status generation
  local -a artifacts=()
  shopt -s nullglob
  artifacts=("${STATE_FILE}.next."* "${STATE_PREVIOUS_FILE}.backup."*)
  shopt -u nullglob
  [[ "${#artifacts[@]}" -eq 0 ]] && return 0
  for artifact in "${artifacts[@]}"; do
    if [[ -L "$artifact" || ! -f "$artifact" ]]; then
      printf 'ERROR: legacy install-state publish artifact is not a regular file: %s\n' \
        "$artifact" >&2
      return 1
    fi
    IFS=$'\t' read -r status generation \
      < <(state_runtime setup-state-generation "$artifact") || return 1
    if [[ "$artifact" == "${STATE_PREVIOUS_FILE}.backup."* && "$status" != "COMPLETE" ]]; then
      printf 'ERROR: legacy install-state backup is incomplete: %s\n' "$artifact" >&2
      return 1
    fi
  done
  printf 'ERROR: unfinished legacy install-state publish artifact requires explicit recovery: %s\n' \
    "${artifacts[*]}" >&2
  return 1
}

# A symlink or directory at an install-state path is not "no state": treating
# it as absent lets a caller delete managed assets and only then fail on the
# malformed path, leaving a half-cleaned installation behind.
state_reject_nonregular_paths() {
  local state_path
  for state_path in "$STATE_FILE" "$STATE_PREVIOUS_FILE"; do
    if [[ -L "$state_path" || (-e "$state_path" && ! -f "$state_path") ]]; then
      printf 'ERROR: install-state path must be a regular file or absent: %s\n' "$state_path" >&2
      return 1
    fi
  done
}

# Validate both install-state generations before any active install mutation.
state_codex_skills_dir() {
  printf '%s\n' "${CODEX_DIR:-${CODEX_HOME:-${HOME}/.codex}}/skills"
}

state_preflight() {
  state_reject_legacy_publish_artifacts || return 1
  state_reject_nonregular_paths || return 1
  state_runtime setup-state-validate-managed-tree-transactions "$(state_codex_skills_dir)" || return 1
  if [[ -f "$STATE_FILE" ]] \
    && ! state_runtime setup-state-quarantine-count "$STATE_FILE" >/dev/null; then
    printf 'ERROR: refusing to mutate malformed install-state: %s\n' "$STATE_FILE" >&2
    return 1
  fi
  if [[ -f "$STATE_PREVIOUS_FILE" ]] \
    && ! state_runtime setup-state-quarantine-count "$STATE_PREVIOUS_FILE" "$STATE_FILE" >/dev/null; then
    printf 'ERROR: refusing to mutate malformed install-state: %s\n' "$STATE_PREVIOUS_FILE" >&2
    return 1
  fi
  state_preflight_generation_order
}

state_preflight_generation_order() {
  local current_status="" current_generation=0 previous_status="" previous_generation=0
  if [[ -f "$STATE_FILE" ]]; then
    IFS=$'\t' read -r current_status current_generation \
      < <(state_runtime setup-state-generation "$STATE_FILE") || return 1
  fi
  if [[ -f "$STATE_PREVIOUS_FILE" ]]; then
    IFS=$'\t' read -r previous_status previous_generation \
      < <(state_runtime setup-state-generation "$STATE_PREVIOUS_FILE") || return 1
    if [[ "$previous_status" != "COMPLETE" ]]; then
      printf 'ERROR: previous install-state generation is incomplete: %s\n' \
        "$STATE_PREVIOUS_FILE" >&2
      return 1
    fi
  fi
  if [[ "$current_status" == "COMPLETE" && -n "$previous_status" \
    && "$current_generation" -lt "$previous_generation" ]]; then
    printf 'ERROR: current install-state generation is older than previous snapshot\n' >&2
    return 1
  fi
  if [[ "$current_status" == "INCOMPLETE" ]]; then
    if [[ -n "$previous_status" \
      && "$current_generation" -ne $((previous_generation + 1)) ]]; then
      printf 'ERROR: incomplete install-state generation does not follow previous snapshot\n' >&2
      return 1
    elif [[ -z "$previous_status" && "$current_generation" -ne 1 ]]; then
      printf 'ERROR: incomplete install-state has no matching complete snapshot\n' >&2
      return 1
    fi
  fi
}

# Initialize or load state
state_init() {
  local profile="${1:-core}" languages="${2:-}" snapshot_tmp=""
  local carry_state=""
  local current_status="" current_generation=0 previous_status="" previous_generation=0
  local base_generation=0 next_generation disabled_output="" disabled_csv=""
  local retired_source retired_skill
  state_preflight || return 1

  if [[ -f "$STATE_FILE" ]]; then
    IFS=$'\t' read -r current_status current_generation \
      < <(state_runtime setup-state-generation "$STATE_FILE") || return 1
  fi
  if [[ -f "$STATE_PREVIOUS_FILE" ]]; then
    IFS=$'\t' read -r previous_status previous_generation \
      < <(state_runtime setup-state-generation "$STATE_PREVIOUS_FILE") || return 1
    if [[ "$previous_status" != "COMPLETE" ]]; then
      printf 'ERROR: previous install-state generation is incomplete: %s\n' \
        "$STATE_PREVIOUS_FILE" >&2
      return 1
    fi
    carry_state="$STATE_PREVIOUS_FILE"
  fi

  # Publish only a complete outgoing generation as the ownership snapshot.
  # An interrupted current generation must never replace the last complete one.
  if [[ -f "$STATE_FILE" ]]; then
    if [[ "$current_status" == "COMPLETE" ]]; then
      if [[ -n "$previous_status" && "$current_generation" -lt "$previous_generation" ]]; then
        printf 'ERROR: current install-state generation is older than previous snapshot\n' >&2
        return 1
      fi
      base_generation="$current_generation"
    elif [[ -n "$previous_status" ]]; then
      if [[ "$current_generation" -ne $((previous_generation + 1)) ]]; then
        printf 'ERROR: incomplete install-state generation does not follow previous snapshot\n' >&2
        return 1
      fi
      base_generation="$previous_generation"
    elif [[ "$current_generation" -eq 1 ]]; then
      base_generation=0
    else
      printf 'ERROR: incomplete install-state has no matching complete snapshot\n' >&2
      return 1
    fi
  elif [[ -n "$previous_status" ]]; then
    base_generation="$previous_generation"
  fi
  next_generation=$((base_generation + 1))
  if declare -F disabled_skills >/dev/null; then
    disabled_output="$(disabled_skills)" || return 1
  fi
  # A newly retired manifest skill is no longer present in disabled_skills,
  # but an interrupted generation can still be the only ownership inventory
  # for its public copy. Carry those known names through the retry preflight so
  # retirement can prove ownership instead of silently preserving stale bytes.
  if declare -F retired_bundled_codex_skills >/dev/null; then
    while IFS=$'\t' read -r retired_source retired_skill; do
      [[ -n "${retired_source}" && -n "${retired_skill}" ]] || continue
      [[ -z "${disabled_output}" ]] || disabled_output+=$'\n'
      disabled_output+="${retired_skill}"
    done < <(retired_bundled_codex_skills)
  fi
  disabled_csv="${disabled_output//$'\n'/,}"
  if [[ "$current_status" == "COMPLETE" ]]; then
    snapshot_tmp="$(mktemp "${STATE_PREVIOUS_FILE}.tmp.XXXXXX")" || {
      return 1
    }
    if ! cp -p -- "$STATE_FILE" "$snapshot_tmp"; then
      rm -f -- "$snapshot_tmp"
      printf 'ERROR: failed to stage previous install-state snapshot\n' >&2
      return 1
    fi
    if ! state_runtime setup-state-init \
      "$snapshot_tmp" "" "" "$current_generation" "" "$carry_state" complete-snapshot \
      "$(state_codex_skills_dir)"; then
      rm -f -- "$snapshot_tmp"
      return 1
    fi
    if ! mv -f -- "$snapshot_tmp" "$STATE_PREVIOUS_FILE"; then
      rm -f -- "$snapshot_tmp"
      printf 'ERROR: failed to publish previous install-state snapshot\n' >&2
      return 1
    fi
    carry_state="$STATE_PREVIOUS_FILE"
    if [[ -n "${VIBEGUARD_TEST_SETUP_STATE_AFTER_PREVIOUS_PUBLISH:-}" ]]; then
      printf 'ERROR: injected interruption after previous install-state publication\n' >&2
      return 97
    fi
  fi
  if [[ -n "${VIBEGUARD_TEST_SETUP_STATE_CURRENT_PUBLISH_FAILURE:-}" ]]; then
    printf 'ERROR: injected current install-state publication failure\n' >&2
    return 1
  fi
  state_runtime setup-state-init \
    "$STATE_FILE" "$profile" "$languages" "$next_generation" "$disabled_csv" "$carry_state" "" \
    "$(state_codex_skills_dir)"
}

state_mark_complete() {
  state_runtime setup-state-mark-complete "$STATE_FILE"
}

# Record a file installation
state_record_file() {
  local dest="$1" source="$2" install_type="${3:-copy}"
  state_runtime setup-state-record-file "$STATE_FILE" "$dest" "$source" "$install_type"
}

state_record_project_hook() {
  local repo_dir="$1" hook_path="$2" hook_name="$3"
  state_runtime setup-state-record-project-hook "$STATE_FILE" "$repo_dir" "$hook_path" "$hook_name"
}

# Record all files (regular or symlink) under a directory as installed artifacts.
# source_prefix is joined with each relative file path for traceability.
state_record_tree() {
  local dest_dir="$1" source_prefix="$2"
  [[ -d "$dest_dir" ]] || return 0

  while IFS= read -r file; do
    local rel source install_type
    rel="${file#"${dest_dir}/"}"
    source="${source_prefix%/}/${rel}"
    if [[ -L "$file" ]]; then install_type="symlink"; else install_type="copy"; fi
    state_record_file "$file" "$source" "$install_type"
  done < <(find "$dest_dir" \( -type f -o -type l \) 2>/dev/null)
}

# Check for drift — files that were installed but have been modified or removed
state_check_drift() {
  # A release that removed the active record from the current generation but
  # crashed before removing it from the previous snapshot leaves a
  # previous-only quarantine. The next install validates that generation and
  # aborts, so reporting CLEAN from the current file alone would be dishonest.
  if [[ -f "$STATE_PREVIOUS_FILE" ]] \
    && ! state_runtime setup-state-quarantine-count "$STATE_PREVIOUS_FILE" "$STATE_FILE" >/dev/null 2>&1; then
    printf 'PREVIOUS_GENERATION_INVALID: %s\n' "$STATE_PREVIOUS_FILE"
    return 1
  fi
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "NO_STATE"
    return 0
  fi

  state_runtime setup-state-check-drift "$STATE_FILE" 2>/dev/null
}

# List all tracked files
state_list() {
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "No install state found. Run setup.sh first."
    return 1
  fi

  state_runtime setup-state-list "$STATE_FILE"
}

# Resolve the installed profile without treating a malformed existing state as
# an absent installation. Only a genuinely missing state file defaults to core.
state_installed_profile() {
  local state_out detected current_status current_generation
  state_reject_legacy_publish_artifacts || return 1
  state_reject_nonregular_paths || return 1
  if [[ ! -e "$STATE_FILE" ]]; then
    if [[ -e "$STATE_PREVIOUS_FILE" ]]; then
      printf 'ERROR: current install-state is missing while previous snapshot exists: %s\n' \
        "$STATE_PREVIOUS_FILE" >&2
      return 1
    fi
    printf '%s\n' "core"
    return 0
  fi
  state_preflight_generation_order || return 1
  IFS=$'\t' read -r current_status current_generation \
    < <(state_runtime setup-state-generation "$STATE_FILE") || return 1
  if [[ "$current_status" != "COMPLETE" ]]; then
    printf 'ERROR: current install-state generation is incomplete: %s\n' "$STATE_FILE" >&2
    return 1
  fi
  if ! state_out="$(state_runtime setup-state-list "$STATE_FILE")"; then
    printf 'ERROR: failed to read install profile: %s\n' "$STATE_FILE" >&2
    return 1
  fi
  detected="$(awk -F': ' '/^Profile:/ {print $2; exit}' <<< "${state_out}")"
  case "${detected}" in
    minimal|core|full|strict) printf '%s\n' "${detected}" ;;
    *)
      printf 'ERROR: invalid install profile in %s: expected minimal, core, full, or strict\n' \
        "$STATE_FILE" >&2
      return 1
      ;;
  esac
}

# True when the path itself, or anything under it, was installed by VibeGuard —
# either in this run or in the install whose inventory state_init preserved.
state_is_tracked_path() {
  local path="$1" state_source tracked
  for state_source in "$STATE_PREVIOUS_FILE" "$STATE_FILE"; do
    [[ -f "$state_source" ]] || continue
    if ! tracked="$(state_runtime setup-state-list-tracked-under "$state_source" "$path")"; then
      printf 'ERROR: failed to read install-state ownership: %s\n' "$state_source" >&2
      return 2
    fi
    [[ -n "${tracked//[[:space:]]/}" ]] && return 0
  done
  return 1
}

state_managed_tree_owned() {
  local path="$1" source_prefix="$2" tracked_path="${3:-$1}"
  local state_source decision found=1
  for state_source in "$STATE_PREVIOUS_FILE" "$STATE_FILE"; do
    [[ -f "$state_source" ]] || continue
    if ! decision="$(state_runtime setup-state-verify-managed-tree \
      "$state_source" "$path" "$source_prefix" "$tracked_path")"; then
      printf 'ERROR: failed to verify install-state ownership: %s\n' "$state_source" >&2
      return 2
    fi
    if [[ "$decision" == "OWNED" ]]; then
      found=0
    fi
  done
  return "$found"
}

state_list_tracked_symlinks_under() {
  local dest_dir="$1"
  [[ -f "$STATE_FILE" ]] || return 0

  state_runtime setup-state-list-symlinks-under "$STATE_FILE" "$dest_dir"
}

state_list_project_hooks() {
  [[ -f "$STATE_FILE" ]] || return 0

  state_runtime setup-state-list-project-hooks "$STATE_FILE"
}

state_prepare_clean() {
  local current_count=0 previous_count=0 total_count
  state_reject_legacy_publish_artifacts || return 1
  state_reject_nonregular_paths || return 1
  state_runtime setup-state-validate-managed-tree-transactions \
    "$(state_codex_skills_dir)" "$STATE_FILE" "$STATE_PREVIOUS_FILE" || return 1
  if [[ -f "$STATE_FILE" ]]; then
    current_count="$(state_runtime setup-state-quarantine-count "$STATE_FILE")" || return 1
  fi
  if [[ -f "$STATE_PREVIOUS_FILE" ]]; then
    previous_count="$(state_runtime setup-state-quarantine-count "$STATE_PREVIOUS_FILE" "$STATE_FILE")" || return 1
  fi
  [[ "$current_count" =~ ^[0-9]+$ && "$previous_count" =~ ^[0-9]+$ ]] || return 1
  if [[ "$current_count" -gt 0 ]]; then
    total_count="$current_count"
  else
    total_count="$previous_count"
  fi
  _VG_STATE_CLEAN_QUARANTINE_COUNT="$total_count"
}

# Remove state only after revalidating quarantine ownership created during
# clean. The initial preflight runs before asset mutation; Codex cleanup may
# atomically quarantine a newly retired managed tree after that point.
state_clean() {
  state_prepare_clean || return 1
  local total_count="${_VG_STATE_CLEAN_QUARANTINE_COUNT}"
  if [[ "$total_count" -gt 0 ]]; then
    _VG_STATE_CLEAN_RESULT="RETAINED"
    return 0
  fi
  rm -f "$STATE_FILE" "$STATE_PREVIOUS_FILE"
  _VG_STATE_CLEAN_RESULT="REMOVED"
  _VG_STATE_CLEAN_QUARANTINE_COUNT=0
}
