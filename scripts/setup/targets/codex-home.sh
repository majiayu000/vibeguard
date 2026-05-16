#!/usr/bin/env bash

install_codex_home_assets() {
  echo "Step 6: Install Codex skills"
  mkdir -p "${CODEX_DIR}/skills"
  local skill_links source_path skill
  skill_links="$(manifest_skill_links_checked "~/.codex/skills/")" || return 1
  while IFS=$'\t' read -r source_path skill; do
    [[ -n "${source_path}" && -n "${skill}" ]] || continue
    if [[ -d "${REPO_DIR}/${source_path}" ]]; then
      safe_symlink "${REPO_DIR}/${source_path}" "${CODEX_DIR}/skills/${skill}"
      state_record_file "${CODEX_DIR}/skills/${skill}" "${source_path}" "symlink"
      green "  ${skill} -> ~/.codex/skills/${skill}"
    else
      yellow "  SKIP ${skill} (source not found: ${source_path})"
    fi
  done <<< "${skill_links}"
  echo

  echo "Step 6.5: Install Codex hooks"
  # Copy Codex-specific hook wrapper
  cp "${REPO_DIR}/hooks/run-hook-codex.sh" "${HOME}/.vibeguard/run-hook-codex.sh"
  mkdir -p "${HOME}/.vibeguard/_lib"
  cp "${REPO_DIR}/hooks/_lib/codex_diag.sh" "${HOME}/.vibeguard/_lib/codex_diag.sh"
  chmod +x "${HOME}/.vibeguard/run-hook-codex.sh"
  state_record_file "${HOME}/.vibeguard/run-hook-codex.sh" "hooks/run-hook-codex.sh" "copy"
  state_record_file "${HOME}/.vibeguard/_lib/codex_diag.sh" "hooks/_lib/codex_diag.sh" "copy"
  green "  ~/.vibeguard/run-hook-codex.sh ready"

  # Merge VibeGuard hooks into ~/.codex/hooks.json (do not overwrite existing hooks)
  local wrapper="${HOME}/.vibeguard/run-hook-codex.sh"
  local hooks_file="${CODEX_DIR}/hooks.json"
  local hooks_result
  hooks_result=$(python3 "${CODEX_HOOKS_HELPER}" upsert-vibeguard --hooks-file "${hooks_file}" --wrapper "${wrapper}" 2>/dev/null || echo "ERROR")
  if [[ "${hooks_result}" == "CHANGED" || "${hooks_result}" == "SKIP" ]]; then
    state_record_file "${hooks_file}" "generated/codex-hooks.json" "copy"
    green "  ~/.codex/hooks.json merged (VibeGuard hooks upserted)"
    yellow "  Codex capability profile: Bash approvals + Stop hooks are native; Edit/Write hooks stay unsupported here"
  else
    red "  Failed to update ~/.codex/hooks.json"
  fi

  # Enable Codex lifecycle hooks feature flag in config.toml
  _enable_codex_hooks_feature
  echo
}

_enable_codex_hooks_feature() {
  local config="${CODEX_DIR}/config.toml"
  local result
  if ! result=$(python3 "${CODEX_CONFIG_HELPER}" enable-codex-hooks --config-file "${config}" 2>/dev/null); then
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
  python3 "${CODEX_CONFIG_HELPER}" remove-legacy-vibeguard-mcp --config-file "${config}"
}

_has_legacy_codex_mcp_config() {
  local config="${CODEX_DIR}/config.toml"
  [[ -f "${config}" ]] && grep -q '^\[mcp_servers\.vibeguard\]' "${config}" 2>/dev/null
}

codex_native_capability_summary() {
  printf '%s\n' "Codex native support: PreToolUse(Bash), PostToolUse(Bash), Stop"
}

inject_codex_home_rules() {
  echo "Step 10.1: Update VibeGuard rules in ~/.codex/AGENTS.md"
  local rules_file="${REPO_DIR}/claude-md/vibeguard-rules.md"
  local agents_md="${CODEX_DIR}/AGENTS.md"
  local rules_diff rule_count
  rule_count=$(claude_rule_count_for_banner)
  mkdir -p "${CODEX_DIR}"
  if ! rules_diff=$(python3 "${CLAUDE_MD_HELPER}" diff-inject "${agents_md}" "${rules_file}" "${REPO_DIR}" "${rule_count}" 2>&1); then
    red "  Failed to compute ~/.codex/AGENTS.md diff"
    return 1
  fi
  if ! confirm_high_context_write "~/.codex/AGENTS.md" "${rules_diff}"; then
    if [[ "${VIBEGUARD_SETUP_DRY_RUN}" == "1" ]]; then
      echo
      return 0
    fi
    return 1
  fi
  if [[ "${rules_diff}" == "SKIP" ]]; then
    green "  ~/.codex/AGENTS.md already up to date"
    echo
    return 0
  fi
  local result
  if result=$(python3 "${CLAUDE_MD_HELPER}" inject "${agents_md}" "${rules_file}" "${REPO_DIR}" "${rule_count}" 2>&1); then
    if [[ -f "${agents_md}" ]]; then
      state_record_file "${agents_md}" "generated/AGENTS.md" "copy"
    fi
    green "  VibeGuard rules synced to ~/.codex/AGENTS.md (${result})"
  else
    red "  Failed to update ~/.codex/AGENTS.md"
  fi
  echo
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
    if [[ -L "${link}" ]]; then
      if [[ -e "${link}" ]]; then
        green "[OK] ${skill} skill symlinked to ~/.codex/skills/"
      else
        red "[BROKEN] ${skill} symlink exists but target missing: $(readlink "${link}")"
      fi
    else
      yellow "[MISSING] ${skill} skill not in ~/.codex/skills/"
    fi
  done <<< "${skill_links}"

  # Check hooks
  if [[ -f "${CODEX_DIR}/hooks.json" ]]; then
    local wrapper="${HOME}/.vibeguard/run-hook-codex.sh"
    local hook_count
    hook_count=$(python3 -c "
import json
with open('${CODEX_DIR}/hooks.json') as f:
    data = json.load(f)
total = sum(len(entries) for entries in data.get('hooks', {}).values() if isinstance(entries, list))
print(total)
" 2>/dev/null || echo "?")
    green "[OK] Codex hooks.json present (${hook_count} total entries)"

    if python3 "${CODEX_HOOKS_HELPER}" check-vibeguard --hooks-file "${CODEX_DIR}/hooks.json" --wrapper "${wrapper}" >/dev/null 2>&1; then
      green "[OK] VibeGuard hooks merged in ~/.codex/hooks.json"
    else
      yellow "[MISSING] VibeGuard hooks not fully configured in ~/.codex/hooks.json"
    fi
  else
    yellow "[MISSING] Codex hooks.json not installed"
  fi

  if [[ -f "${HOME}/.vibeguard/run-hook-codex.sh" ]]; then
    green "[OK] Codex hook wrapper (~/.vibeguard/run-hook-codex.sh)"
  else
    yellow "[MISSING] Codex hook wrapper not installed"
  fi

  yellow "[INFO] Codex native hooks: PreToolUse(Bash), PostToolUse(Bash), Stop(stop-guard/learn-evaluator); Edit/Write/Read require Claude Code or the app-server wrapper"

  # Check feature flag
  local config="${CODEX_DIR}/config.toml"
  local codex_hooks_status="MISSING"
  if [[ -f "${config}" ]]; then
    codex_hooks_status="$(python3 "${CODEX_CONFIG_HELPER}" check-codex-hooks --config-file "${config}" 2>/dev/null || true)"
  fi
  if [[ "${codex_hooks_status}" == "OK" ]]; then
    green "[OK] hooks feature enabled in config.toml"
  elif [[ "${codex_hooks_status}" == "LEGACY" ]]; then
    yellow "[LEGACY] deprecated codex_hooks feature is enabled; run setup.sh to migrate to hooks"
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
      codex_hooks_status="$(python3 "${CODEX_CONFIG_HELPER}" check-codex-hooks --config-file "${config}" 2>/dev/null || true)"
    fi
    if [[ "${codex_hooks_status}" == "OK" ]] && ! _has_legacy_codex_mcp_config; then
      printf '%s\n' "${path} (checksum drift; Codex config semantics OK)"
      return 0
    fi
  fi

  if [[ "${path}" == "${hooks_file}" ]]; then
    local wrapper="${HOME}/.vibeguard/run-hook-codex.sh"
    if [[ -f "${hooks_file}" ]] && python3 "${CODEX_HOOKS_HELPER}" check-vibeguard --hooks-file "${hooks_file}" --wrapper "${wrapper}" >/dev/null 2>&1; then
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
    if python3 "${CODEX_HOOKS_HELPER}" check-vibeguard --hooks-file "${hooks_file}" --wrapper "${wrapper}" >/dev/null 2>&1; then
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
    codex_hooks_status="$(python3 "${CODEX_CONFIG_HELPER}" check-codex-hooks --config-file "${config}" 2>/dev/null || true)"
  fi
  if [[ "${codex_hooks_status}" == "OK" ]]; then
    green "[OK] hooks feature enabled"
  elif [[ "${codex_hooks_status}" == "LEGACY" ]]; then
    yellow "[LEGACY] deprecated codex_hooks feature enabled"
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

  yellow "[INFO] $(codex_native_capability_summary); Edit/Write/Read require Claude Code or the app-server wrapper"
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
    agents_md_result=$(python3 "${CLAUDE_MD_HELPER}" remove "${CODEX_DIR}/AGENTS.md" 2>/dev/null || echo "ERROR")
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
    rm -f "${CODEX_DIR}/skills/${skill}"
  done <<< "${skill_links}"
  cleanup_retired_manifest_skill_links "~/.codex/skills/" "${CODEX_DIR}/skills"

  # Remove only VibeGuard-managed entries from hooks.json (do not delete third-party hooks)
  local hooks_cleanup_result
  hooks_cleanup_result=$(python3 "${CODEX_HOOKS_HELPER}" remove-vibeguard --hooks-file "${CODEX_DIR}/hooks.json" 2>/dev/null || echo "ERROR")
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
