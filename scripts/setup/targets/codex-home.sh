#!/usr/bin/env bash

install_codex_home_assets() {
  echo "Step 6: Install Codex skills"
  mkdir -p "${CODEX_DIR}/skills"
  for skill in plan-flow fixflow optflow plan-mode auto-optimize; do
    if [[ -d "${REPO_DIR}/workflows/${skill}" ]]; then
      safe_symlink "${REPO_DIR}/workflows/${skill}" "${CODEX_DIR}/skills/${skill}"
      state_record_file "${CODEX_DIR}/skills/${skill}" "workflows/${skill}" "symlink"
      green "  ${skill} -> ~/.codex/skills/${skill}"
    else
      yellow "  SKIP ${skill} (source not found)"
    fi
  done
  safe_symlink "${REPO_DIR}/skills/vibeguard" "${CODEX_DIR}/skills/vibeguard"
  state_record_file "${CODEX_DIR}/skills/vibeguard" "skills/vibeguard" "symlink"
  green "  vibeguard -> ~/.codex/skills/vibeguard"
  echo

  echo "Step 6.5: Install Codex hooks"
  # Copy Codex-specific hook wrapper
  cp "${REPO_DIR}/hooks/run-hook-codex.sh" "${HOME}/.vibeguard/run-hook-codex.sh"
  chmod +x "${HOME}/.vibeguard/run-hook-codex.sh"
  state_record_file "${HOME}/.vibeguard/run-hook-codex.sh" "hooks/run-hook-codex.sh" "copy"
  green "  ~/.vibeguard/run-hook-codex.sh ready"

  # Generate ~/.codex/hooks.json
  local wrapper="${HOME}/.vibeguard/run-hook-codex.sh"
  cat > "${CODEX_DIR}/hooks.json" <<HOOKSJSON
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash ${wrapper} pre-bash-guard.sh",
            "timeout": 10
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash ${wrapper} post-build-check.sh",
            "timeout": 30
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ${wrapper} stop-guard.sh"
          }
        ]
      },
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ${wrapper} learn-evaluator.sh"
          }
        ]
      }
    ]
  }
}
HOOKSJSON
  state_record_file "${CODEX_DIR}/hooks.json" "generated/codex-hooks.json" "copy"
  green "  ~/.codex/hooks.json generated (4 hooks)"

  # Enable codex_hooks feature flag in config.toml
  _enable_codex_hooks_feature
  echo
}

_enable_codex_hooks_feature() {
  local config="${CODEX_DIR}/config.toml"
  if [[ ! -f "$config" ]]; then
    # config.toml doesn't exist yet, create minimal one
    cat > "$config" <<'TOML'
[features]
codex_hooks = true
TOML
    green "  codex_hooks feature enabled (new config.toml)"
    return
  fi

  # Check if already enabled
  if grep -Eq '^codex_hooks[[:space:]]*=[[:space:]]*true$' "$config" 2>/dev/null; then
    green "  codex_hooks feature already enabled"
    return
  fi

  # Check if [features] section exists
  if grep -q '^\[features\]' "$config" 2>/dev/null; then
    # Add codex_hooks under existing [features] section
    sed -i '' '/^\[features\]/a\
codex_hooks = true' "$config"
    green "  codex_hooks feature enabled (added to [features])"
  else
    # Append [features] section
    printf '\n[features]\ncodex_hooks = true\n' >> "$config"
    green "  codex_hooks feature enabled (new [features] section)"
  fi
}

_remove_legacy_codex_mcp_config() {
  local config="${CODEX_DIR}/config.toml"
  python3 - "$config" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    print("SKIP")
    raise SystemExit(0)

old = path.read_text(encoding="utf-8")
lines = old.splitlines()
kept: list[str] = []
in_legacy_section = False
changed = False

for line in lines:
    if line.startswith("[") and line.endswith("]"):
        if line == "[mcp_servers.vibeguard]":
            in_legacy_section = True
            changed = True
            continue
        in_legacy_section = False

    if in_legacy_section:
        changed = True
        continue

    kept.append(line)

new = "\n".join(kept).strip()
new = (new + "\n") if new else ""

if not changed and new == old:
    print("SKIP")
elif new:
    path.write_text(new, encoding="utf-8")
    print("CHANGED")
else:
    path.unlink(missing_ok=True)
    print("CHANGED")
PY
}

_has_legacy_codex_mcp_config() {
  local config="${CODEX_DIR}/config.toml"
  [[ -f "${config}" ]] && grep -q '^\[mcp_servers\.vibeguard\]' "${config}" 2>/dev/null
}

configure_codex_home_runtime() {
  echo "Step 9.2: Remove legacy Codex MCP config"
  local cleanup_result
  cleanup_result="$(_remove_legacy_codex_mcp_config)"
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
  local link
  for skill in plan-flow fixflow optflow plan-mode vibeguard auto-optimize; do
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
  done

  # Check hooks
  if [[ -f "${CODEX_DIR}/hooks.json" ]]; then
    local hook_count
    hook_count=$(python3 -c "
import json
with open('${CODEX_DIR}/hooks.json') as f:
    data = json.load(f)
total = sum(len(entries) for entries in data.get('hooks', {}).values())
print(total)
" 2>/dev/null || echo "?")
    green "[OK] Codex hooks.json (${hook_count} hook entries)"
  else
    yellow "[MISSING] Codex hooks.json not installed"
  fi

  if [[ -f "${HOME}/.vibeguard/run-hook-codex.sh" ]]; then
    green "[OK] Codex hook wrapper (~/.vibeguard/run-hook-codex.sh)"
  else
    yellow "[MISSING] Codex hook wrapper not installed"
  fi

  # Check feature flag
  if [[ -f "${CODEX_DIR}/config.toml" ]] && grep -Eq '^codex_hooks[[:space:]]*=[[:space:]]*true$' "${CODEX_DIR}/config.toml" 2>/dev/null; then
    green "[OK] codex_hooks feature enabled in config.toml"
  else
    yellow "[MISSING] codex_hooks feature not enabled in ~/.codex/config.toml"
  fi

  if _has_legacy_codex_mcp_config; then
    yellow "[LEGACY] Legacy VibeGuard MCP block still present in ~/.codex/config.toml"
  else
    green "[OK] No legacy VibeGuard MCP block in ~/.codex/config.toml"
  fi
}

clean_codex_home_installation() {
  local skill
  for skill in plan-flow fixflow optflow plan-mode vibeguard auto-optimize; do
    rm -f "${CODEX_DIR}/skills/${skill}"
  done

  # Remove hooks
  rm -f "${CODEX_DIR}/hooks.json"
  rm -f "${HOME}/.vibeguard/run-hook-codex.sh"
  yellow "Removed Codex hooks.json + wrapper"

  # Disable codex_hooks feature flag (leave config.toml intact otherwise)
  if [[ -f "${CODEX_DIR}/config.toml" ]]; then
    sed -i '' '/^codex_hooks[[:space:]]*=[[:space:]]*true$/d' "${CODEX_DIR}/config.toml" 2>/dev/null || true
  fi

  local cleanup_result
  cleanup_result="$(_remove_legacy_codex_mcp_config)"
  if [[ "${cleanup_result}" == "CHANGED" ]]; then
    yellow "Removed legacy VibeGuard MCP block from ~/.codex/config.toml"
  fi
}
