#!/usr/bin/env bash
# Lightweight .vibeguard.json reader for shell scripts.

_VG_PROJECT_CONFIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_VG_PROJECT_CONFIG_VALIDATOR="${_VG_PROJECT_CONFIG_LIB_DIR}/project_config_validate.py"
_VG_PROJECT_CONFIG_SCHEMA="${_VG_PROJECT_CONFIG_LIB_DIR}/../../schemas/vibeguard-project.schema.json"

vg_project_config_file() {
  if [[ -n "${VIBEGUARD_PROJECT_CONFIG:-}" ]]; then
    printf '%s\n' "${VIBEGUARD_PROJECT_CONFIG}"
    return 0
  fi

  local root=""
  root=$(git rev-parse --show-toplevel 2>/dev/null || true)
  if [[ -n "$root" && -f "${root}/.vibeguard.json" ]]; then
    printf '%s\n' "${root}/.vibeguard.json"
    return 0
  fi

  if [[ -f ".vibeguard.json" ]]; then
    printf '%s\n' ".vibeguard.json"
  fi
}

vg_validate_project_config() {
  local config_file="${1:-}"
  if [[ -z "$config_file" ]]; then
    config_file="$(vg_project_config_file)"
  fi

  if [[ -z "$config_file" || ! -f "$config_file" ]]; then
    return 0
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    printf 'VibeGuard project config invalid: python3 is required to validate %s\n' "$config_file" >&2
    return 1
  fi
  if [[ ! -f "$_VG_PROJECT_CONFIG_VALIDATOR" ]]; then
    printf 'VibeGuard project config invalid: validator missing at %s\n' "$_VG_PROJECT_CONFIG_VALIDATOR" >&2
    return 1
  fi
  if [[ ! -f "$_VG_PROJECT_CONFIG_SCHEMA" ]]; then
    printf 'VibeGuard project config invalid: schema missing at %s\n' "$_VG_PROJECT_CONFIG_SCHEMA" >&2
    return 1
  fi

  python3 "$_VG_PROJECT_CONFIG_VALIDATOR" --quiet "$config_file" "$_VG_PROJECT_CONFIG_SCHEMA"
}

vg_config_value() {
  local key_path="$1"
  local default_value="${2:-}"
  local config_file
  config_file="$(vg_project_config_file)"

  if [[ -z "$config_file" || ! -f "$config_file" ]] || ! command -v python3 >/dev/null 2>&1; then
    printf '%s\n' "$default_value"
    return 0
  fi

  if ! vg_validate_project_config "$config_file"; then
    return 2
  fi

  python3 - "$config_file" "$key_path" "$default_value" <<'PY'
import json
import sys

path, key_path, default = sys.argv[1:4]
try:
    with open(path, encoding="utf-8") as f:
        value = json.load(f)
    for part in key_path.split("."):
        if not isinstance(value, dict) or part not in value:
            print(default)
            sys.exit(0)
        value = value[part]
    if isinstance(value, bool) or value is None:
        print(default)
    else:
        print(value)
except Exception as exc:
    print(f"VibeGuard project config read failed: {path}: {exc}", file=sys.stderr)
    sys.exit(2)
PY
}

vg_config_positive_int() {
  local env_name="$1"
  local key_path="$2"
  local default_value="$3"
  local raw_value="${!env_name:-}"

  if [[ -z "$raw_value" ]]; then
    if ! raw_value="$(vg_config_value "$key_path" "$default_value")"; then
      return 2
    fi
  fi

  if [[ "$raw_value" =~ ^[0-9]+$ && "$raw_value" -gt 0 ]]; then
    printf '%s\n' "$raw_value"
  else
    printf '%s\n' "$default_value"
  fi
}
