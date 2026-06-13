#!/usr/bin/env bash

_codex_execution_mode() {
  local mode="${VIBEGUARD_EXECUTION_MODE:-}"
  if [[ -z "${mode}" && "${VIBEGUARD_SETUP_DEV_LINKED:-0}" == "1" ]]; then
    mode="dev-linked-repo"
  fi
  if [[ -z "${mode}" && -f "${HOME}/.vibeguard/execution-mode" ]]; then
    mode="$(tr -d '[:space:]' < "${HOME}/.vibeguard/execution-mode")"
  fi
  case "${mode}" in
    dev-linked|dev-linked-repo|repo|repo-linked)
      printf '%s\n' "dev-linked-repo" ;;
    *)
      printf '%s\n' "installed-snapshot" ;;
  esac
}

_codex_source_path() {
  local source_path="$1"
  if [[ "$(_codex_execution_mode)" == "dev-linked-repo" ]]; then
    printf '%s\n' "${REPO_DIR}/${source_path}"
  else
    printf '%s\n' "${HOME}/.vibeguard/installed/${source_path}"
  fi
}

_install_codex_manifest_skill() {
  local src="$1" dst="$2" source_path="$3" skill="$4"
  src="$(_codex_source_path "${source_path}")"
  if [[ ! -d "${src}" ]]; then
    red "  ERROR: ${skill} skill source missing: ${src}"
    return 1
  fi
  install_codex_skill_copy "${src}" "${dst}" "${source_path}"
  green "  ${skill} copied to ~/.codex/skills/${skill}"
}

install_codex_home_assets() {
  echo "Step 6: Install Codex skills"
  install_manifest_skills "~/.codex/skills/" "${CODEX_DIR}/skills" _install_codex_manifest_skill || return 1
  echo

  echo "Step 6.5: Install Codex hooks"
  # Copy Codex-specific hook wrapper
  cp "${REPO_DIR}/hooks/run-hook-codex.sh" "${HOME}/.vibeguard/run-hook-codex.sh"
  mkdir -p "${HOME}/.vibeguard/_lib"
  cp "${REPO_DIR}/hooks/_lib/codex_diag.sh" "${HOME}/.vibeguard/_lib/codex_diag.sh"
  cp "${REPO_DIR}/hooks/_lib/codex_runner.sh" "${HOME}/.vibeguard/_lib/codex_runner.sh"
  cp "${REPO_DIR}/hooks/_lib/timeout.sh" "${HOME}/.vibeguard/_lib/timeout.sh"
  cp "${REPO_DIR}/hooks/_lib/wrapper_env.sh" "${HOME}/.vibeguard/_lib/wrapper_env.sh"
  chmod +x "${HOME}/.vibeguard/run-hook-codex.sh"
  state_record_file "${HOME}/.vibeguard/run-hook-codex.sh" "hooks/run-hook-codex.sh" "copy"
  state_record_file "${HOME}/.vibeguard/_lib/codex_diag.sh" "hooks/_lib/codex_diag.sh" "copy"
  state_record_file "${HOME}/.vibeguard/_lib/codex_runner.sh" "hooks/_lib/codex_runner.sh" "copy"
  state_record_file "${HOME}/.vibeguard/_lib/timeout.sh" "hooks/_lib/timeout.sh" "copy"
  state_record_file "${HOME}/.vibeguard/_lib/wrapper_env.sh" "hooks/_lib/wrapper_env.sh" "copy"
  green "  ~/.vibeguard/run-hook-codex.sh ready"

  # Merge VibeGuard hooks into ~/.codex/hooks.json (do not overwrite existing hooks)
  local wrapper="${HOME}/.vibeguard/run-hook-codex.sh"
  local hooks_file="${CODEX_DIR}/hooks.json"
  local hooks_result
  hooks_result=$(setup_runtime setup-codex-hooks-upsert "${REPO_DIR}" "${hooks_file}" "${wrapper}" 2>/dev/null || echo "ERROR")
  if [[ "${hooks_result}" == "CHANGED" || "${hooks_result}" == "SKIP" ]]; then
    state_record_file "${hooks_file}" "generated/codex-hooks.json" "copy"
    green "  ~/.codex/hooks.json merged (VibeGuard hooks upserted)"
    yellow "  Codex capability profile: native Bash/apply_patch gates + PermissionRequest + Stop; Read hooks remain unavailable"
  else
    red "  Failed to update ~/.codex/hooks.json"
  fi

  # Enable native Codex hooks feature flag in config.toml
  _enable_codex_hooks_feature
  echo
}

install_codex_skill_copy() {
  local src="$1" dst="$2" source_path="$3"
  local parent parent_abs skills_abs tmp

  case "$(basename "${dst}")" in
    ""|"."|".."|*/*)
      red "  ERROR: invalid Codex skill destination: ${dst}"
      return 1
      ;;
  esac

  parent="$(dirname "${dst}")"
  mkdir -p "${parent}" "${CODEX_DIR}/skills"
  parent_abs="$(cd "${parent}" && pwd -P)"
  skills_abs="$(cd "${CODEX_DIR}/skills" && pwd -P)"
  if [[ "${parent_abs}" != "${skills_abs}" ]]; then
    red "  ERROR: refusing to install Codex skill outside ~/.codex/skills/: ${dst}"
    return 1
  fi

  tmp="${dst}.tmp.$$"
  rm -rf "${tmp}"
  mkdir -p "${tmp}"
  cp -R "${src}/." "${tmp}/"
  rm -rf "${dst}"
  mv "${tmp}" "${dst}"
  state_record_tree "${dst}" "${source_path}"
}

_enable_codex_hooks_feature() {
  local config="${CODEX_DIR}/config.toml"
  local result
  if ! result=$(setup_runtime setup-codex-config-enable-hooks "${config}" 2>/dev/null); then
    red "  Failed to enable hooks feature in config.toml"
    return 1
  fi
  case "${result}" in
    CHANGED)
      green "  hooks feature enabled in config.toml"
      ;;
    SKIP)
      green "  hooks feature already enabled"
      ;;
    *)
      red "  Failed to enable hooks feature in config.toml"
      return 1
      ;;
  esac
}

_remove_legacy_codex_mcp_config() {
  local config="${CODEX_DIR}/config.toml"
  setup_runtime setup-codex-config-remove-legacy-mcp "${config}"
}

_has_legacy_codex_mcp_config() {
  local config="${CODEX_DIR}/config.toml"
  [[ -f "${config}" ]] && grep -q '^\[mcp_servers\.vibeguard\]' "${config}" 2>/dev/null
}

codex_native_capability_summary() {
  printf '%s\n' "Codex native support: PreToolUse(Bash/apply_patch), PermissionRequest(Bash/apply_patch), PostToolUse(Bash/apply_patch), Stop"
}

inject_codex_home_rules() {
  echo "Step 10.1: Update VibeGuard rules in ~/.codex/AGENTS.md"
  local agents_md="${CODEX_DIR}/AGENTS.md"
  inject_vibeguard_rules "${agents_md}" "~/.codex/AGENTS.md" "generated/AGENTS.md"
}

configure_codex_home_runtime() {
  echo "Step 9.2: Remove legacy Codex MCP config"
  local cleanup_result
  if ! cleanup_result="$(_remove_legacy_codex_mcp_config 2>/dev/null)"; then
    red "  Failed to remove legacy Codex MCP config from ~/.codex/config.toml"
    return 1
  fi
  if [[ -f "${CODEX_DIR}/config.toml" ]]; then
    state_record_file "${CODEX_DIR}/config.toml" "generated/codex-config.toml" "copy"
  fi
  if [[ "${cleanup_result}" == "CHANGED" ]]; then
    green "  Removed legacy VibeGuard MCP block from ~/.codex/config.toml"
  else
    green "  No legacy Codex MCP config found"
  fi
  echo
}

check_codex_home_installation() {
  check_codex_agents_hygiene

  local link skill_links source_path skill
  skill_links="$(manifest_skill_links_checked "~/.codex/skills/")" || return 1
  while IFS=$'\t' read -r source_path skill; do
    [[ -n "${source_path}" && -n "${skill}" ]] || continue
    link="${CODEX_DIR}/skills/${skill}"
    if [[ -d "${link}" && ! -L "${link}" ]]; then
      if diff -qr "$(_codex_source_path "${source_path}")" "${link}" >/dev/null 2>&1; then
        green "[OK] ${skill} skill copied to ~/.codex/skills/"
      else
        yellow "[WARN] ${skill} skill copy differs from ${source_path}"
      fi
    elif [[ -L "${link}" ]]; then
      yellow "[WARN] ${skill} skill is still a symlink; re-run setup.sh to install a fresh copy"
    elif [[ -e "${link}" ]]; then
      red "[BROKEN] ${skill} skill path exists but is not a directory"
    else
      yellow "[MISSING] ${skill} skill not in ~/.codex/skills/"
    fi
  done <<< "${skill_links}"

  # Check hooks
  if [[ -f "${CODEX_DIR}/hooks.json" ]]; then
    local wrapper="${HOME}/.vibeguard/run-hook-codex.sh"
    local hook_count
    hook_count=$(setup_runtime setup-codex-hooks-count "${CODEX_DIR}/hooks.json" 2>/dev/null || echo "?")
    green "[OK] Codex hooks.json present (${hook_count} total entries)"

    if setup_runtime setup-codex-hooks-check "${REPO_DIR}" "${CODEX_DIR}/hooks.json" "${wrapper}" >/dev/null 2>&1; then
      green "[OK] VibeGuard hooks merged in ~/.codex/hooks.json"
    else
      yellow "[MISSING] VibeGuard hooks not fully configured in ~/.codex/hooks.json"
    fi

    local stale_hooks_report
    if stale_hooks_report="$(setup_runtime setup-codex-hooks-check-stale "${CODEX_DIR}/hooks.json" 2>&1)"; then
      :
    else
      while IFS= read -r line; do
        [[ -n "${line}" ]] && red "[BROKEN] ${line}"
      done <<< "${stale_hooks_report}"
    fi

    local timeout_hooks_report
    if timeout_hooks_report="$(setup_runtime setup-codex-hooks-check-timeouts "${REPO_DIR}" "${CODEX_DIR}/hooks.json" 2>&1)"; then
      :
    else
      while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        if [[ "${line}" == managed* ]]; then
          red "[BROKEN] ${line}"
        else
          yellow "[WARN] ${line}"
        fi
      done <<< "${timeout_hooks_report}"
    fi
  else
    yellow "[MISSING] Codex hooks.json not installed"
  fi

  if [[ -f "${HOME}/.vibeguard/run-hook-codex.sh" ]]; then
    green "[OK] Codex hook wrapper (~/.vibeguard/run-hook-codex.sh)"
  else
    yellow "[MISSING] Codex hook wrapper not installed"
  fi

  yellow "[INFO] Codex native hooks: PreToolUse(Bash/Edit/Write via apply_patch), PermissionRequest(Bash/Edit/Write via apply_patch), PostToolUse(Bash/Edit/Write via apply_patch), Stop(stop-guard/learn-evaluator); Read/Glob/Grep remain unavailable"

  # Check feature flag
  local config="${CODEX_DIR}/config.toml"
  local codex_hooks_status="MISSING"
  if [[ -f "${config}" ]]; then
    codex_hooks_status="$(setup_runtime setup-codex-config-check-hooks "${config}" 2>/dev/null || true)"
  fi
  if [[ "${codex_hooks_status}" == "OK" ]]; then
    green "[OK] hooks feature enabled in config.toml"
  elif [[ "${codex_hooks_status}" == "LEGACY" ]]; then
    yellow "[LEGACY] deprecated codex_hooks feature still present in ~/.codex/config.toml (repair: bash setup.sh --yes)"
  elif [[ "${codex_hooks_status}" == "INVALID" ]]; then
    red "[BROKEN] ~/.codex/config.toml is malformed TOML"
  else
    yellow "[MISSING] hooks feature not enabled in ~/.codex/config.toml"
  fi

  if _has_legacy_codex_mcp_config; then
    yellow "[LEGACY] Legacy VibeGuard MCP block still present in ~/.codex/config.toml"
  else
    green "[OK] No legacy VibeGuard MCP block in ~/.codex/config.toml"
  fi
}

codex_semantic_drift_message() {
  local path="$1"
  local config="${CODEX_DIR}/config.toml"
  local hooks_file="${CODEX_DIR}/hooks.json"

  if [[ "${path}" == "${config}" ]]; then
    local codex_hooks_status="MISSING"
    if [[ -f "${config}" ]]; then
      codex_hooks_status="$(setup_runtime setup-codex-config-check-hooks "${config}" 2>/dev/null || true)"
    fi
    if [[ "${codex_hooks_status}" == "OK" ]] && ! _has_legacy_codex_mcp_config; then
      printf '%s\n' "${path} (checksum drift; Codex config semantics OK)"
      return 0
    fi
  fi

  if [[ "${path}" == "${hooks_file}" ]]; then
    local wrapper="${HOME}/.vibeguard/run-hook-codex.sh"
    if [[ -f "${hooks_file}" ]] && setup_runtime setup-codex-hooks-check "${REPO_DIR}" "${hooks_file}" "${wrapper}" >/dev/null 2>&1; then
      printf '%s\n' "${path} (checksum drift; VibeGuard hook semantics OK)"
      return 0
    fi
  fi

  return 1
}

codex_latest_event_line() {
  python3 - <<'PY' "${HOME}" "${VIBEGUARD_LOG_DIR:-}"
from __future__ import annotations

import json
import sys
from pathlib import Path

home = Path(sys.argv[1])
log_root = Path(sys.argv[2]) if sys.argv[2] else home / ".vibeguard"
files = []
root_file = log_root / "events.jsonl"
if root_file.exists():
    files.append(root_file)
projects_dir = log_root / "projects"
if projects_dir.exists():
    files.extend(sorted(projects_dir.glob("*/events.jsonl")))

latest = None
latest_project = ""
for file in files:
    project_root_file = file.parent / ".project-root"
    project_root = project_root_file.read_text(encoding="utf-8", errors="replace").strip() if project_root_file.exists() else ""
    try:
        lines = file.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        continue
    for line in lines:
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("cli") != "codex" and event.get("agent_type") != "codex":
            continue
        ts = str(event.get("ts", ""))
        key = ts or "0000"
        if latest is None or key >= str(latest.get("ts", "")):
            latest = event
            latest_project = str(event.get("project_root") or project_root or file.parent)

if latest is None:
    print("NO_CODEX_EVENTS")
else:
    print(
        f"{latest.get('ts', 'unknown')} | "
        f"{latest.get('hook', 'unknown')} | "
        f"{latest.get('decision', 'unknown')} | "
        f"{latest_project}"
    )
PY
}

print_codex_status() {
  echo "VibeGuard Codex Status"
  echo "=============================="

  if command -v codex >/dev/null 2>&1; then
    local codex_path codex_version
    codex_path="$(command -v codex)"
    codex_version="$(codex --version 2>/dev/null | head -1 || true)"
    green "[OK] Codex CLI: ${codex_path}${codex_version:+ (${codex_version})}"
  else
    yellow "[INFO] Codex CLI not found"
  fi

  check_codex_agents_hygiene

  local hooks_file="${CODEX_DIR}/hooks.json"
  local wrapper="${HOME}/.vibeguard/run-hook-codex.sh"
  if [[ -f "${hooks_file}" ]]; then
    green "[OK] Codex hooks.json present"
    if setup_runtime setup-codex-hooks-check "${REPO_DIR}" "${hooks_file}" "${wrapper}" >/dev/null 2>&1; then
      green "[OK] VibeGuard-managed Codex hooks semantic check passed"
    else
      yellow "[WARN] VibeGuard-managed Codex hooks semantic check failed (repair: bash setup.sh --yes)"
    fi
  else
    yellow "[MISSING] Codex hooks.json not installed"
  fi

  if [[ -x "${wrapper}" ]]; then
    green "[OK] Codex hook wrapper executable: ${wrapper}"
  elif [[ -f "${wrapper}" ]]; then
    red "[BROKEN] Codex hook wrapper is not executable: ${wrapper}"
  else
    yellow "[MISSING] Codex hook wrapper: ${wrapper}"
  fi

  local config="${CODEX_DIR}/config.toml"
  local codex_hooks_status="MISSING"
  if [[ -f "${config}" ]]; then
    codex_hooks_status="$(setup_runtime setup-codex-config-check-hooks "${config}" 2>/dev/null || true)"
  fi
  if [[ "${codex_hooks_status}" == "OK" ]]; then
    green "[OK] hooks feature enabled"
  elif [[ "${codex_hooks_status}" == "LEGACY" ]]; then
    yellow "[LEGACY] deprecated codex_hooks feature still present"
  elif [[ "${codex_hooks_status}" == "INVALID" ]]; then
    red "[BROKEN] ~/.codex/config.toml is malformed TOML"
  else
    yellow "[MISSING] hooks feature not enabled"
  fi

  if _has_legacy_codex_mcp_config; then
    yellow "[LEGACY] Legacy VibeGuard MCP block still present"
  else
    green "[OK] No legacy VibeGuard MCP block"
  fi

  local latest_event
  latest_event="$(codex_latest_event_line)"
  if [[ "${latest_event}" == "NO_CODEX_EVENTS" ]]; then
    yellow "[INFO] No Codex events found in VibeGuard logs"
  else
    green "[OK] Latest Codex event: ${latest_event}"
  fi

  yellow "[INFO] $(codex_native_capability_summary); Read/Glob/Grep hooks require Claude Code"
  echo "Repair command: bash setup.sh --yes"
}

check_codex_agents_hygiene() {
  local agents_md="${CODEX_DIR}/AGENTS.md"
  if [[ ! -f "${agents_md}" ]]; then
    red "[MISSING] VibeGuard rules not in ~/.codex/AGENTS.md"
    return 0
  fi
  if [[ ! -s "${agents_md}" ]]; then
    red "[BROKEN] ~/.codex/AGENTS.md is 0 bytes (rerun setup)"
    return 0
  fi

  local start_marker="<!-- vibeguard-start -->"
  local end_marker="<!-- vibeguard-end -->"
  local start_count end_count
  start_count=$(grep -cF "${start_marker}" "${agents_md}" 2>/dev/null || true)
  end_count=$(grep -cF "${end_marker}" "${agents_md}" 2>/dev/null || true)
  if [[ "${start_count}" -ne 1 || "${end_count}" -ne 1 ]]; then
    red "[BROKEN] ~/.codex/AGENTS.md marker mismatch (start=${start_count}, end=${end_count}; rerun setup)"
    return 0
  fi

  local start_line end_line
  start_line=$(grep -nF "${start_marker}" "${agents_md}" | head -1 | cut -d: -f1)
  end_line=$(grep -nF "${end_marker}" "${agents_md}" | head -1 | cut -d: -f1)
  if [[ "${start_line}" -ge "${end_line}" ]]; then
    red "[BROKEN] ~/.codex/AGENTS.md marker order is invalid (rerun setup)"
    return 0
  fi

  local managed_block anchor
  local -a missing_anchors=()
  managed_block=$(sed -n "${start_line},${end_line}p" "${agents_md}")
  for anchor in \
    "#VibeGuard" \
    "## Constraints" \
    "## Chat Contract" \
    "## Key Detailed Rules" \
    "| L1 |" \
    "| W-03 |" \
    "| SEC-13 |"; do
    if ! grep -qF "${anchor}" <<< "${managed_block}"; then
      missing_anchors+=("${anchor}")
    fi
  done
  if [[ "${#missing_anchors[@]}" -gt 0 ]]; then
    red "[BROKEN] ~/.codex/AGENTS.md missing required anchors: ${missing_anchors[*]} (rerun setup)"
    return 0
  fi

  local rules_dest="${HOME}/.claude/rules/vibeguard"
  local actual_rule_count declared_count
  if [[ -d "${rules_dest}" ]]; then
    actual_rule_count=$(vibeguard_rule_id_count "${rules_dest}")
    if declared_count=$(vibeguard_managed_rule_banner_count "${agents_md}"); then
      if [[ "${actual_rule_count}" -eq "${declared_count}" ]]; then
        green "[OK] Rule count in ~/.codex/AGENTS.md: ${actual_rule_count} rules"
      else
        yellow "[DRIFT] ~/.codex/AGENTS.md declares ${declared_count} rules, actual: ${actual_rule_count}"
        yellow "[INFO] Re-run 'bash setup.sh' to repair the rule count banner in ~/.codex/AGENTS.md"
      fi
    else
      yellow "[DRIFT] ~/.codex/AGENTS.md missing VibeGuard rule count banner, actual: ${actual_rule_count}"
      yellow "[INFO] Re-run 'bash setup.sh' to repair the rule count banner in ~/.codex/AGENTS.md"
    fi
    local block_check_rc=0
    if vibeguard_managed_rules_block_matches_source "${agents_md}" "${actual_rule_count}"; then
      green "[OK] ~/.codex/AGENTS.md managed VibeGuard block matches current rules"
    else
      block_check_rc=$?
      if [[ "${block_check_rc}" -eq 1 ]]; then
        yellow "[DRIFT] ~/.codex/AGENTS.md managed VibeGuard block differs from current rules"
        yellow "[INFO] Re-run 'bash setup.sh' to repair the managed block in ~/.codex/AGENTS.md"
      else
        yellow "[WARN] ~/.codex/AGENTS.md managed block semantic check unavailable (repair: bash setup.sh --yes)"
      fi
    fi
  else
    yellow "[INFO] Rule count in ~/.codex/AGENTS.md not checked because ~/.claude/rules/vibeguard/ is missing"
  fi

  green "[OK] VibeGuard rules in ~/.codex/AGENTS.md"

  local outside_count outside_first
  outside_count=$(
    awk -v start="${start_line}" -v end="${end_line}" '
      (NR < start || NR > end) && $0 ~ /[^[:space:]]/ { count++ }
      END { print count + 0 }
    ' "${agents_md}"
  )
  if [[ "${outside_count}" -gt 0 ]]; then
    outside_first=$(
      awk -v start="${start_line}" -v end="${end_line}" '
        (NR < start || NR > end) && $0 ~ /[^[:space:]]/ { print substr($0, 1, 100); exit }
      ' "${agents_md}"
    )
    yellow "[WARN] ~/.codex/AGENTS.md has ${outside_count} non-empty unmanaged line(s) outside VibeGuard block: ${outside_first}"
  fi
}

clean_codex_home_installation() {
  if [[ -f "${CODEX_DIR}/AGENTS.md" ]]; then
    local agents_md_result
    agents_md_result=$(setup_runtime setup-md-remove "${CODEX_DIR}/AGENTS.md" 2>/dev/null || echo "ERROR")
    case "${agents_md_result}" in
      REMOVED|REMOVED_LEGACY) yellow "Removed VibeGuard rules from ~/.codex/AGENTS.md" ;;
      NOT_FOUND) yellow "No VibeGuard rules found in ~/.codex/AGENTS.md" ;;
      *) red "Failed to clean ~/.codex/AGENTS.md" ;;
    esac
  fi

  local skill_links source_path skill
  skill_links="$(manifest_skill_links_for_cleanup "~/.codex/skills/")"
  while IFS=$'\t' read -r source_path skill; do
    [[ -n "${source_path}" && -n "${skill}" ]] || continue
    rm -rf "${CODEX_DIR}/skills/${skill}"
  done <<< "${skill_links}"
  cleanup_retired_manifest_skill_links "~/.codex/skills/" "${CODEX_DIR}/skills"

  # Remove only VibeGuard-managed entries from hooks.json (do not delete third-party hooks)
  local hooks_cleanup_result
  hooks_cleanup_result=$(setup_runtime setup-codex-hooks-remove "${REPO_DIR}" "${CODEX_DIR}/hooks.json" 2>/dev/null || echo "ERROR")
  case "${hooks_cleanup_result}" in
    CHANGED)
      yellow "Removed VibeGuard hook entries from ~/.codex/hooks.json"
      ;;
    SKIP)
      yellow "No VibeGuard hook entries found in ~/.codex/hooks.json"
      ;;
    *)
      red "Failed to clean VibeGuard entries in ~/.codex/hooks.json"
      ;;
  esac

  rm -f "${HOME}/.vibeguard/run-hook-codex.sh"
  rm -f "${HOME}/.vibeguard/_lib/codex_diag.sh"
  rm -f "${HOME}/.vibeguard/_lib/codex_runner.sh"
  rm -f "${HOME}/.vibeguard/_lib/timeout.sh"
  rm -f "${HOME}/.vibeguard/_lib/wrapper_env.sh"
  rmdir "${HOME}/.vibeguard/_lib" 2>/dev/null || true
  yellow "Removed Codex hook wrapper"

  # Keep the Codex hooks feature flag untouched to avoid affecting other toolchains.

  local cleanup_result
  if ! cleanup_result="$(_remove_legacy_codex_mcp_config 2>/dev/null)"; then
    red "Failed to remove legacy Codex MCP config from ~/.codex/config.toml"
    return 1
  fi
  if [[ "${cleanup_result}" == "CHANGED" ]]; then
    yellow "Removed legacy VibeGuard MCP block from ~/.codex/config.toml"
  fi
}
