#!/usr/bin/env bash

vg_log_root() {
  printf '%s' "${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}"
}

vg_log_scope_is_hash() {
  local value="$1"
  [[ "$value" =~ ^[0-9A-Fa-f]{8,64}$ && "$value" != */* && "$value" != *\\* ]]
}

vg_log_scope_git_root() {
  local path="$1"
  git -C "$path" rev-parse --show-toplevel 2>/dev/null || true
}

vg_log_scope_sha256_short() {
  local value="$1"
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$value" | shasum -a 256 | cut -c1-8
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$value" | sha256sum | cut -c1-8
    return 0
  fi
  printf '%s\n' "unable to compute project log hash: shasum or sha256sum is required" >&2
  return 1
}

vg_log_scope_project_log_file() {
  local log_root="$1"
  local project_ref="$2"
  local project_id project_root mapping mapped_root

  if vg_log_scope_is_hash "$project_ref"; then
    printf '%s/projects/%s/events.jsonl' "$log_root" "${project_ref:0:8}"
    return 0
  fi

  project_root="$(vg_log_scope_git_root "$project_ref")"
  if [[ -z "$project_root" ]]; then
    project_root="$project_ref"
  fi

  for mapping in "${log_root}/projects/"*/.project-root; do
    [[ -f "$mapping" ]] || continue
    mapped_root="$(cat "$mapping" 2>/dev/null || true)"
    if [[ "$mapped_root" == "$project_root" ]]; then
      printf '%s/events.jsonl' "$(dirname "$mapping")"
      return 0
    fi
  done

  project_id="$(vg_log_scope_sha256_short "$project_root")"
  printf '%s/projects/%s/events.jsonl' "$log_root" "$project_id"
}

vg_resolve_log_file() {
  local scope="$1"
  local project_ref="$2"
  local explicit_log_file="$3"
  local log_root

  if [[ -n "$explicit_log_file" ]]; then
    printf '%s' "$explicit_log_file"
    return 0
  fi

  log_root="$(vg_log_root)"
  case "$scope" in
    global)
      printf '%s/events.jsonl' "$log_root"
      ;;
    project)
      if [[ -z "$project_ref" ]]; then
        project_ref="$(vg_log_scope_git_root ".")"
      fi
      if [[ -z "$project_ref" ]]; then
        printf '%s/events.jsonl' "$log_root"
      else
        vg_log_scope_project_log_file "$log_root" "$project_ref"
      fi
      ;;
    *)
      printf '%s\n' "scope must be one of: project, global" >&2
      return 1
      ;;
  esac
}
