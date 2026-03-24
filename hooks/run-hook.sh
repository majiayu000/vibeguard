#!/usr/bin/env bash
# VibeGuard Hook Wrapper — 全平台兼容的 hook 分发器
#
# settings.json 中所有 hook 通过此 wrapper 间接调用，
# 避免硬编码绝对路径。repo 搬家只需更新 ~/.vibeguard/repo-path。
#
# 环境变量：
#   VIBEGUARD_DISABLED_HOOKS  逗号分隔的 hook 名（不含 .sh），跳过指定 hook
#                             例: VIBEGUARD_DISABLED_HOOKS=post-edit-guard,analysis-paralysis-guard
#   VIBEGUARD_ENFORCEMENT     执行级别: block(默认) | warn | off
#                             warn: 所有 block 降级为 warn（exit 0 + stderr 提示）
#                             off:  跳过所有 hook
#   VIBEGUARD_PROFILE         运行时 profile: minimal | standard(默认) | strict
#                             minimal: 只运行 pre-write-guard, pre-edit-guard, pre-bash-guard
#                             standard: 运行 core + full hooks
#                             strict: 所有 hook + 额外检查
#
# 项目级配置（.vibeguard.json）：
#   若当前目录或 git root 存在 .vibeguard.json，读取其中的
#   disabled_hooks / enforcement / profile 字段作为项目级覆盖。
#   环境变量优先级高于 .vibeguard.json。
#
# 用法: bash ~/.vibeguard/run-hook.sh <hook-script-name> [args...]
# 示例: bash ~/.vibeguard/run-hook.sh stop-guard.sh

set -euo pipefail

HOOK_NAME="${1:?Usage: run-hook.sh <hook-name>}"
shift

# --- Enforcement: off = skip all ---
if [[ "${VIBEGUARD_ENFORCEMENT:-}" == "off" ]]; then
  exit 0
fi

# --- Load project-level .vibeguard.json (if exists) ---
_load_project_config() {
  local config_file=""
  # Try git root first, then cwd
  local git_root
  git_root="$(git rev-parse --show-toplevel 2>/dev/null)" || true
  if [[ -n "$git_root" && -f "$git_root/.vibeguard.json" ]]; then
    config_file="$git_root/.vibeguard.json"
  elif [[ -f ".vibeguard.json" ]]; then
    config_file=".vibeguard.json"
  fi

  if [[ -z "$config_file" ]]; then
    return
  fi

  # Only load if python3 available (graceful degradation)
  if ! command -v python3 &>/dev/null; then
    return
  fi

  # Extract fields — env vars take precedence over project config
  if [[ -z "${VIBEGUARD_DISABLED_HOOKS:-}" ]]; then
    local proj_disabled
    proj_disabled=$(python3 -c "
import json, sys
try:
    d = json.load(open('$config_file'))
    v = d.get('disabled_hooks', [])
    print(','.join(v) if isinstance(v, list) else str(v))
except: pass
" 2>/dev/null) || true
    if [[ -n "$proj_disabled" ]]; then
      export VIBEGUARD_DISABLED_HOOKS="$proj_disabled"
    fi
  fi

  if [[ -z "${VIBEGUARD_ENFORCEMENT:-}" ]]; then
    local proj_enforcement
    proj_enforcement=$(python3 -c "
import json, sys
try:
    d = json.load(open('$config_file'))
    print(d.get('enforcement', ''))
except: pass
" 2>/dev/null) || true
    if [[ -n "$proj_enforcement" ]]; then
      export VIBEGUARD_ENFORCEMENT="$proj_enforcement"
    fi
  fi

  if [[ -z "${VIBEGUARD_PROFILE:-}" ]]; then
    local proj_profile
    proj_profile=$(python3 -c "
import json, sys
try:
    d = json.load(open('$config_file'))
    print(d.get('profile', ''))
except: pass
" 2>/dev/null) || true
    if [[ -n "$proj_profile" ]]; then
      export VIBEGUARD_PROFILE="$proj_profile"
    fi
  fi
}

_load_project_config

# --- Re-check enforcement after project config ---
if [[ "${VIBEGUARD_ENFORCEMENT:-}" == "off" ]]; then
  exit 0
fi

# --- Profile filtering ---
PROFILE="${VIBEGUARD_PROFILE:-standard}"
HOOK_BASE="${HOOK_NAME%.sh}"

# minimal profile: only critical pre-hooks
MINIMAL_HOOKS="pre-write-guard pre-edit-guard pre-bash-guard"
if [[ "$PROFILE" == "minimal" ]]; then
  is_allowed=false
  for h in $MINIMAL_HOOKS; do
    if [[ "$HOOK_BASE" == "$h" ]]; then
      is_allowed=true
      break
    fi
  done
  if [[ "$is_allowed" == "false" ]]; then
    exit 0
  fi
fi

# --- Disabled hooks check ---
if [[ -n "${VIBEGUARD_DISABLED_HOOKS:-}" ]]; then
  IFS=',' read -ra DISABLED <<< "${VIBEGUARD_DISABLED_HOOKS}"
  for disabled in "${DISABLED[@]}"; do
    disabled="${disabled// /}"  # trim spaces
    disabled="${disabled%.sh}"  # normalize: remove .sh suffix
    if [[ "$HOOK_BASE" == "$disabled" ]]; then
      exit 0
    fi
  done
fi

# --- Locate repo and hook ---
REPO_PATH_FILE="${HOME}/.vibeguard/repo-path"
if [[ ! -f "$REPO_PATH_FILE" ]]; then
  echo "ERROR: ${REPO_PATH_FILE} not found. Re-run: bash <vibeguard-repo>/scripts/setup/install.sh" >&2
  exit 1
fi

REPO_DIR=$(<"$REPO_PATH_FILE")
HOOK_PATH="${REPO_DIR}/hooks/${HOOK_NAME}"

if [[ ! -f "$HOOK_PATH" ]]; then
  echo "ERROR: hook not found: ${HOOK_PATH}" >&2
  exit 1
fi

# --- Enforcement: warn = downgrade blocks to warnings ---
if [[ "${VIBEGUARD_ENFORCEMENT:-}" == "warn" ]]; then
  export VIBEGUARD_WARN_ONLY=1
fi

exec bash "$HOOK_PATH" "$@"
