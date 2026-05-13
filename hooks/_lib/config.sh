#!/usr/bin/env bash
# VibeGuard layered config reader.
#
# Resolution order (highest to lowest):
#   1. Environment variable (e.g. VG_U16_LIMIT)
#   2. JSON config file at $VIBEGUARD_CONFIG_FILE, defaults to
#      ${VIBEGUARD_LOG_DIR:-$HOME/.vibeguard}/config.json
#   3. Hardcoded default passed by the caller
#
# Malformed JSON, missing keys, or wrong-typed values fall through to the
# next layer silently — never break a hook because of a bad config edit.

if [[ -n "${_VG_CONFIG_SH_LOADED:-}" ]]; then
  return 0
fi
_VG_CONFIG_SH_LOADED=1

_VG_CONFIG_FILE="${VIBEGUARD_CONFIG_FILE:-${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}/config.json}"

# vg_config_get_int <env_name> <json_dotted_path> <default_int>
# Echoes resolved integer to stdout. Always succeeds — falls back to default
# on any failure path.
vg_config_get_int() {
  local env_name="$1" json_path="$2" default_val="$3"
  local val

  val="${!env_name:-}"
  if [[ -n "$val" && "$val" =~ ^[0-9]+$ ]]; then
    printf '%s' "$val"
    return 0
  fi

  if [[ -f "$_VG_CONFIG_FILE" ]]; then
    val=$(VG_CFG_FILE="$_VG_CONFIG_FILE" VG_CFG_PATH="$json_path" python3 -c '
import json, os, sys
try:
    with open(os.environ["VG_CFG_FILE"]) as f:
        cfg = json.load(f)
except Exception:
    sys.exit(1)
node = cfg
for key in os.environ["VG_CFG_PATH"].split("."):
    if isinstance(node, dict) and key in node:
        node = node[key]
    else:
        sys.exit(1)
if isinstance(node, bool) or not isinstance(node, int):
    sys.exit(1)
print(node)
' 2>/dev/null) || val=""
    if [[ -n "$val" && "$val" =~ ^[0-9]+$ ]]; then
      printf '%s' "$val"
      return 0
    fi
  fi

  printf '%s' "$default_val"
}

# vg_config_get_str <env_name> <json_dotted_path> <default_str>
vg_config_get_str() {
  local env_name="$1" json_path="$2" default_val="$3"
  local val

  val="${!env_name:-}"
  if [[ -n "$val" ]]; then
    printf '%s' "$val"
    return 0
  fi

  if [[ -f "$_VG_CONFIG_FILE" ]]; then
    val=$(VG_CFG_FILE="$_VG_CONFIG_FILE" VG_CFG_PATH="$json_path" python3 -c '
import json, os, sys
try:
    with open(os.environ["VG_CFG_FILE"]) as f:
        cfg = json.load(f)
except Exception:
    sys.exit(1)
node = cfg
for key in os.environ["VG_CFG_PATH"].split("."):
    if isinstance(node, dict) and key in node:
        node = node[key]
    else:
        sys.exit(1)
if not isinstance(node, str):
    sys.exit(1)
print(node)
' 2>/dev/null) || val=""
    if [[ -n "$val" ]]; then
      printf '%s' "$val"
      return 0
    fi
  fi

  printf '%s' "$default_val"
}
