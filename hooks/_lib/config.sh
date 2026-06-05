#!/usr/bin/env bash
# VibeGuard layered config reader.
#
# Resolution order:
#   1. Environment variable supplied by the caller.
#   2. JSON config file at $_VG_CONFIG_FILE / $VIBEGUARD_CONFIG_FILE, or
#      ${VIBEGUARD_LOG_DIR:-$HOME/.vibeguard}/config.json.
#   3. Caller-provided default.
#
# Standalone helper reads stay permissive for non-critical tuning fields. The
# wrapper policy gate validates malformed JSON before hooks execute, so parse
# errors cannot silently weaken runtime enforcement.

if [[ -n "${_VG_CONFIG_SH_LOADED:-}" ]]; then
  return 0
fi
_VG_CONFIG_SH_LOADED=1
_VG_CONFIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_vg_config_file() {
  printf '%s' "${_VG_CONFIG_FILE:-${VIBEGUARD_CONFIG_FILE:-${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}/config.json}}"
}

_vg_config_runtime_path() {
  local candidate
  for candidate in \
    "${VIBEGUARD_RUNTIME:-}" \
    "${_VIBEGUARD_RUNTIME:-}" \
    "${_VG_CONFIG_LIB_DIR}/../../vibeguard-runtime/target/debug/vibeguard-runtime" \
    "${_VG_CONFIG_LIB_DIR}/../../vibeguard-runtime/target/release/vibeguard-runtime" \
    "${HOME}/.vibeguard/installed/bin/vibeguard-runtime"; do
    if [[ -n "${candidate}" && -f "${candidate}" && -x "${candidate}" ]]; then
      if "${candidate}" runtime-config-get-int __VIBEGUARD_MISSING_ENV__ missing.path 0 "${TMPDIR:-/tmp}/vibeguard-missing-config-probe.json" >/dev/null 2>&1; then
        printf '%s\n' "${candidate}"
        return 0
      fi
    fi
  done
  return 1
}

vg_config_get_int() {
  local env_name="$1" json_path="$2" default_val="$3"
  local val config_file runtime_path

  val="${!env_name:-}"
  if [[ -n "$val" && "$val" =~ ^[0-9]+$ ]]; then
    printf '%s' "$val"
    return 0
  fi

  config_file="$(_vg_config_file)"
  if runtime_path="$(_vg_config_runtime_path)"; then
    if val=$("${runtime_path}" runtime-config-get-int "$env_name" "$json_path" "$default_val" "$config_file" 2>/dev/null); then
      printf '%s' "$val"
      return 0
    fi
    printf 'VibeGuard runtime config error: runtime-config-get-int failed; using default for %s\n' "$json_path" >&2
    printf '%s' "$default_val"
    return 0
  fi

  if [[ -f "$config_file" ]]; then
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
  local val config_file runtime_path

  val="${!env_name:-}"
  if [[ -n "$val" ]]; then
    printf '%s' "$val"
    return 0
  fi

  config_file="$(_vg_config_file)"
  if runtime_path="$(_vg_config_runtime_path)"; then
    if val=$("${runtime_path}" runtime-config-get-str "$env_name" "$json_path" "$default_val" "$config_file" 2>/dev/null); then
      printf '%s' "$val"
      return 0
    fi
    printf 'VibeGuard runtime config error: runtime-config-get-str failed; using default for %s\n' "$json_path" >&2
    printf '%s' "$default_val"
    return 0
  fi

  if [[ -f "$config_file" ]]; then
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

vg_u16_warn_limit() {
  local hard_limit="$1"
  local warn_limit

  warn_limit=$(vg_config_get_int VG_U16_WARN_LIMIT u16.warn_limit 400)
  if [[ "$warn_limit" -ge "$hard_limit" ]]; then
    printf '%s' "$hard_limit"
  else
    printf '%s' "$warn_limit"
  fi
}
