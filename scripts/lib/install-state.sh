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

state_runtime_path() {
  local repo_root candidate
  repo_root="$(cd "${INSTALL_STATE_LIB_DIR}/../.." && pwd)"
  for candidate in \
    "${VIBEGUARD_SETUP_RUNTIME:-}" \
    "${_INSTALL_TMP:-}/bin/vibeguard-runtime" \
    "${HOME}/.vibeguard/installed/bin/vibeguard-runtime" \
    "${repo_root}/vibeguard-runtime/target/release/vibeguard-runtime" \
    "${repo_root}/vibeguard-runtime/target/debug/vibeguard-runtime" \
    "vibeguard-runtime"; do
    [[ -n "${candidate}" ]] || continue
    if [[ "${candidate}" == */* ]]; then
      if [[ -x "${candidate}" ]] && state_runtime_supports "${candidate}"; then
        printf '%s\n' "${candidate}"
        return 0
      fi
    elif command -v "${candidate}" >/dev/null 2>&1; then
      candidate="$(command -v "${candidate}")"
      if state_runtime_supports "${candidate}"; then
        printf '%s\n' "${candidate}"
        return 0
      fi
    fi
  done
  return 1
}

state_runtime_supports() {
  local runtime="$1" probe_state="${TMPDIR:-/tmp}/vibeguard-runtime-probe.$$.json"
  "${runtime}" setup-state-list-symlinks-under \
    "${probe_state}" "${TMPDIR:-/tmp}" >/dev/null 2>&1 || return 1
  local command probe_out
  for command in \
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
  local runtime
  runtime="$(state_runtime_path)" || {
    printf 'ERROR: vibeguard-runtime not found for install-state operation\n' >&2
    return 127
  }
  "${runtime}" "$@"
}

# Validate both install-state generations before any active install mutation.
state_preflight() {
  local state_path
  for state_path in "$STATE_FILE" "$STATE_PREVIOUS_FILE"; do
    if [[ -L "$state_path" || (-e "$state_path" && ! -f "$state_path") ]]; then
      printf 'ERROR: install-state path must be a regular file or absent: %s\n' "$state_path" >&2
      return 1
    fi
    if [[ -f "$state_path" ]] \
      && ! state_runtime setup-state-list-tracked-under "$state_path" "${HOME}/.codex/skills" >/dev/null; then
      printf 'ERROR: refusing to mutate malformed install-state: %s\n' "$state_path" >&2
      return 1
    fi
  done
}

# Initialize or load state
state_init() {
  local profile="${1:-core}" languages="${2:-}" snapshot_tmp=""
  local current_status="" current_generation=0 previous_status="" previous_generation=0
  local base_generation=0 next_generation
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
  fi

  # Publish only a complete outgoing generation as the ownership snapshot.
  # An interrupted current generation must never replace the last complete one.
  if [[ -f "$STATE_FILE" ]]; then
    if [[ "$current_status" == "COMPLETE" ]]; then
      if [[ -n "$previous_status" && "$current_generation" -lt "$previous_generation" ]]; then
        printf 'ERROR: current install-state generation is older than previous snapshot\n' >&2
        return 1
      fi
      snapshot_tmp="$(mktemp "${STATE_PREVIOUS_FILE}.tmp.XXXXXX")" || return 1
      if ! cp -p -- "$STATE_FILE" "$snapshot_tmp"; then
        rm -f -- "$snapshot_tmp"
        printf 'ERROR: failed to stage previous install-state snapshot\n' >&2
        return 1
      fi
      if ! mv -f -- "$snapshot_tmp" "$STATE_PREVIOUS_FILE"; then
        rm -f -- "$snapshot_tmp"
        printf 'ERROR: failed to publish previous install-state snapshot\n' >&2
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
  state_runtime setup-state-init \
    "$STATE_FILE" "$profile" "$languages" "$next_generation"
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

# Remove state file (used by clean.sh)
state_clean() {
  rm -f "$STATE_FILE" "$STATE_PREVIOUS_FILE"
}
