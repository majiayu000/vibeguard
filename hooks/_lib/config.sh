#!/usr/bin/env bash
# VibeGuard layered config reader.
#
# Resolution order:
#   1. Environment variable supplied by the caller.
#   2. JSON config file at $_VG_CONFIG_FILE / $VIBEGUARD_CONFIG_FILE, or
#      ${VIBEGUARD_LOG_DIR:-$HOME/.vibeguard}/config.json.
#   3. Caller-provided default.
#
# Config parse errors, missing keys, and wrong types fall through to the next
# layer so a bad user edit cannot break hook execution.

if [[ -n "${_VG_CONFIG_SH_LOADED:-}" ]]; then
  return 0
fi
_VG_CONFIG_SH_LOADED=1

_vg_config_file() {
  printf '%s' "${_VG_CONFIG_FILE:-${VIBEGUARD_CONFIG_FILE:-${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}/config.json}}"
}

_vg_config_runtime_get() {
  local kind="$1" config_file="$2" json_path="$3"
  if [[ -n "${_VIBEGUARD_RUNTIME:-}" && -x "${_VIBEGUARD_RUNTIME:-}" ]]; then
    "$_VIBEGUARD_RUNTIME" config-get "$kind" "$config_file" "$json_path" 2>/dev/null
  else
    return 1
  fi
}

vg_config_get_int() {
  local env_name="$1" json_path="$2" default_val="$3"
  local val config_file

  val="${!env_name:-}"
  if [[ -n "$val" && "$val" =~ ^[0-9]+$ ]]; then
    printf '%s' "$val"
    return 0
  fi

  config_file="$(_vg_config_file)"
  if [[ -f "$config_file" ]]; then
    val=$(_vg_config_runtime_get int "$config_file" "$json_path") || val=""
    if [[ -n "$val" && "$val" =~ ^[0-9]+$ ]]; then
      printf '%s' "$val"
      return 0
    fi

    val=$(python3 - "$config_file" "$json_path" <<'PY'
import json
import sys

config_file, json_path = sys.argv[1:3]
try:
    with open(config_file, encoding="utf-8") as f:
        node = json.load(f)
except Exception:
    raise SystemExit(1)

for key in json_path.split("."):
    if isinstance(node, dict) and key in node:
        node = node[key]
    else:
        raise SystemExit(1)

if isinstance(node, bool) or not isinstance(node, int):
    raise SystemExit(1)
print(node)
PY
    ) || val=""
    if [[ -n "$val" && "$val" =~ ^[0-9]+$ ]]; then
      printf '%s' "$val"
      return 0
    fi
  fi

  printf '%s' "$default_val"
}

vg_config_get_str() {
  local env_name="$1" json_path="$2" default_val="$3"
  local val config_file

  val="${!env_name:-}"
  if [[ -n "$val" ]]; then
    printf '%s' "$val"
    return 0
  fi

  config_file="$(_vg_config_file)"
  if [[ -f "$config_file" ]]; then
    val=$(_vg_config_runtime_get string "$config_file" "$json_path") || val=""
    if [[ -n "$val" ]]; then
      printf '%s' "$val"
      return 0
    fi

    val=$(python3 - "$config_file" "$json_path" <<'PY'
import json
import sys

config_file, json_path = sys.argv[1:3]
try:
    with open(config_file, encoding="utf-8") as f:
        node = json.load(f)
except Exception:
    raise SystemExit(1)

for key in json_path.split("."):
    if isinstance(node, dict) and key in node:
        node = node[key]
    else:
        raise SystemExit(1)

if not isinstance(node, str):
    raise SystemExit(1)
print(node)
PY
    ) || val=""
    if [[ -n "$val" ]]; then
      printf '%s' "$val"
      return 0
    fi
  fi

  printf '%s' "$default_val"
}
