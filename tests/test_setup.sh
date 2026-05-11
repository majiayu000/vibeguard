#!/usr/bin/env bash
# VibeGuard setup regression testing
#
# Usage: bash tests/test_setup.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SETTINGS_HELPER="${REPO_DIR}/scripts/lib/settings_json.py"
CODEX_HOOKS_HELPER="${REPO_DIR}/scripts/lib/codex_hooks_json.py"
HOOKS_MANIFEST_HELPER="${REPO_DIR}/scripts/lib/hooks_manifest.py"
MANIFEST_HELPER="${REPO_DIR}/scripts/lib/vibeguard_manifest.py"
PROJECT_CONFIG_HELPER="${REPO_DIR}/scripts/lib/project_config_validate.py"
CHAT_CONTRACT_ANCHOR="Compact Chat Contract: progress updates, concise answers, plain formatting."
CODEX_CONFIG_HELPER="${REPO_DIR}/scripts/lib/codex_config_toml.py"

PASS=0
FAIL=0
TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }
header(){ printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

assert_contains() {
  local output="$1" expected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$output" | grep -qF -- "$expected"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (expected to contain: $expected)"
    FAIL=$((FAIL + 1))
  fi
}

assert_cmd() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (exit code: $?)"
    FAIL=$((FAIL + 1))
  fi
}

assert_manifest_skill_links_installed() {
  local target="$1"
  local dest_dir="$2"
  local links
  if ! links="$(python3 "${MANIFEST_HELPER}" skill-links --target "${target}")"; then
    return 1
  fi

  local source_path skill found=0
  while IFS=$'\t' read -r source_path skill; do
    [[ -n "${source_path}" && -n "${skill}" ]] || continue
    found=1
    [[ -L "${dest_dir}/${skill}" ]] || return 1
  done <<< "${links}"
  [[ "${found}" -eq 1 ]]
}

assert_runtime_config_seeded() {
  python3 - <<'PY' "${HOME}/.vibeguard/config.json"
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
checks = [
    data.get("write_mode") == "warn",
    data.get("u16", {}).get("limit") == 800,
    data.get("circuit_breaker", {}).get("threshold") == 3,
    data.get("circuit_breaker", {}).get("cooldown_seconds") == 300,
    data.get("paralysis", {}).get("threshold") == 7,
]
raise SystemExit(0 if all(checks) else 1)
PY
}

assert_chat_contract_blocks_match() {
  python3 - <<'PY' "${REPO_DIR}" "${HOME}/.claude/CLAUDE.md"
from pathlib import Path
import re
import sys

repo_dir = Path(sys.argv[1])
installed_path = Path(sys.argv[2])
pattern = re.compile(r"^## Chat Contract\n.*?(?=^## |\Z)", re.MULTILINE | re.DOTALL)
paths = [
    repo_dir / "claude-md/vibeguard-rules.md",
    repo_dir / "templates/AGENTS.md",
    repo_dir / "docs/CLAUDE.md.example",
    installed_path,
]
blocks = []
for path in paths:
    match = pattern.search(path.read_text(encoding="utf-8"))
    if not match:
        raise SystemExit(1)
    blocks.append(match.group(0).strip())
raise SystemExit(0 if len(set(blocks)) == 1 else 1)
PY
}

assert_claude_rule_banner_matches_installed_rules() {
  local rules_dest="${HOME}/.claude/rules/vibeguard"
  local actual=0 declared file_count rule_file
  while IFS= read -r rule_file; do
    file_count=$(grep -cE '^## [A-Z]+-[0-9]+' "${rule_file}" 2>/dev/null || true)
    actual=$((actual + file_count))
  done < <(find "${rules_dest}" \( -type f -o -type l \) -name "*.md" 2>/dev/null)
  declared=$(grep -o '[0-9]* rules' "${HOME}/.claude/CLAUDE.md" 2>/dev/null | grep -o '[0-9]*' | head -1 || true)
  [[ "${declared}" == "${actual}" ]]
}

ORIG_HOME="${HOME}"
TMP_HOME="$(mktemp -d)"
ORIG_PATH="${PATH}"

cleanup() {
  export HOME="${ORIG_HOME}"
  export PATH="${ORIG_PATH}"
  rm -rf "${TMP_HOME}"
}
trap cleanup EXIT

export HOME="${TMP_HOME}"
# Keep rustup/cargo usable after HOME is redirected into the test sandbox.
if [[ -z "${CARGO_HOME:-}" && -d "${ORIG_HOME}/.cargo" ]]; then
  export CARGO_HOME="${ORIG_HOME}/.cargo"
fi
if [[ -z "${RUSTUP_HOME:-}" && -d "${ORIG_HOME}/.rustup" ]]; then
  export RUSTUP_HOME="${ORIG_HOME}/.rustup"
fi
mkdir -p "${TMP_HOME}/bin"
cat > "${TMP_HOME}/bin/launchctl" <<'SH'
#!/usr/bin/env bash
state="${HOME}/.launchctl-vibeguard-loaded"
case "${1:-}" in
  bootstrap)
    touch "$state"
    exit 0
    ;;
  bootout)
    rm -f "$state"
    exit 0
    ;;
  print)
    [[ -f "$state" ]] && exit 0
    exit 113
    ;;
  list)
    [[ -f "$state" ]] && printf '0\t0\tcom.vibeguard.gc\n'
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
SH
chmod +x "${TMP_HOME}/bin/launchctl"
export PATH="${TMP_HOME}/bin:${PATH}"

header "setup scripts syntax"
assert_cmd "setup.sh syntax is correct" bash -n "${REPO_DIR}/setup.sh"
assert_cmd "scripts/setup/install.sh syntax is correct" bash -n "${REPO_DIR}/scripts/setup/install.sh"
assert_cmd "scripts/setup/check.sh syntax is correct" bash -n "${REPO_DIR}/scripts/setup/check.sh"
assert_cmd "scripts/setup/clean.sh syntax is correct" bash -n "${REPO_DIR}/scripts/setup/clean.sh"
assert_cmd "scripts/setup/codex-status.sh syntax is correct" bash -n "${REPO_DIR}/scripts/setup/codex-status.sh"
assert_cmd "scripts/codex-contract-check.sh syntax is correct" bash -n "${REPO_DIR}/scripts/codex-contract-check.sh"
assert_cmd "scripts/install-systemd.sh syntax is correct" bash -n "${REPO_DIR}/scripts/install-systemd.sh"
assert_cmd "scripts/lib/install-state.sh syntax is correct" bash -n "${REPO_DIR}/scripts/lib/install-state.sh"
assert_cmd "scripts/lib/settings_json.py syntax is correct" python3 -m py_compile "${SETTINGS_HELPER}"
assert_cmd "scripts/lib/hooks_manifest.py syntax is correct" python3 -m py_compile "${HOOKS_MANIFEST_HELPER}"
assert_cmd "scripts/lib/project_config_validate.py syntax is correct" python3 -m py_compile "${PROJECT_CONFIG_HELPER}"
assert_cmd "scripts/lib/claude_md.py syntax is correct" python3 -m py_compile "${REPO_DIR}/scripts/lib/claude_md.py"
assert_cmd "scripts/lib/codex_hooks_json.py syntax is correct" python3 -m py_compile "${CODEX_HOOKS_HELPER}"
assert_cmd "scripts/lib/codex_config_toml.py syntax is correct" python3 -m py_compile "${CODEX_CONFIG_HELPER}"
assert_cmd "scripts/setup/regenerate-hooks-from-manifest.sh syntax is correct" bash -n "${REPO_DIR}/scripts/setup/regenerate-hooks-from-manifest.sh"
assert_cmd "scripts/ci/validate-hooks-manifest.sh syntax is correct" bash -n "${REPO_DIR}/scripts/ci/validate-hooks-manifest.sh"
assert_cmd "CLAUDE.md template uses generated rule count placeholder" grep -q "__VIBEGUARD_RULE_COUNT__" "${REPO_DIR}/claude-md/vibeguard-rules.md"

header "install-state argv safety"
install_state_home="${TMP_HOME}/install-state quote ' home"
install_state_repo="${TMP_HOME}/repo quote ' newline"$'\n'"dir"
install_state_dest="${install_state_home}/tracked quote ' newline"$'\n'"file.txt"
install_state_source="generated/source quote ' newline"$'\n'"file.txt"
install_state_profile="core quote ' profile"
install_state_languages="rust,py'thon"$'\n'"go"
mkdir -p "${install_state_home}/.vibeguard" "$(dirname "${install_state_dest}")" "${install_state_repo}"
printf '%s' "${install_state_repo}" > "${install_state_home}/.vibeguard/repo-path"
printf 'tracked\n' > "${install_state_dest}"
assert_cmd "install-state accepts quoted/newline values via argv" env \
  HOME="${install_state_home}" \
  SPECIAL_PROFILE="${install_state_profile}" \
  SPECIAL_LANGUAGES="${install_state_languages}" \
  SPECIAL_DEST="${install_state_dest}" \
  SPECIAL_SOURCE="${install_state_source}" \
  bash -c '
    set -euo pipefail
    source "$1"
    state_init "$SPECIAL_PROFILE" "$SPECIAL_LANGUAGES"
    state_record_file "$SPECIAL_DEST" "$SPECIAL_SOURCE" "copy"
    state_check_drift >/dev/null
    state_list >/dev/null
  ' bash "${REPO_DIR}/scripts/lib/install-state.sh"
assert_cmd "install-state preserves quoted/newline JSON values" python3 - \
  "${install_state_home}/.vibeguard/install-state.json" \
  "${install_state_profile}" \
  "${install_state_languages}" \
  "${install_state_repo}" \
  "${install_state_dest}" \
  "${install_state_source}" <<'PY'
import json
import sys

state_file, profile, languages, repo_dir, dest, source = sys.argv[1:7]
with open(state_file, encoding="utf-8") as f:
    state = json.load(f)

entry = state["files"][dest]
assert state["profile"] == profile
assert state["languages"] == languages.split(",")
assert state["repo_dir"] == repo_dir
assert entry["source"] == source
assert entry["type"] == "copy"
assert entry["checksum"].startswith("sha256:")
PY

header "manifest skill enumeration failure"
manifest_failure_stdout="${TMP_HOME}/manifest-failure.stdout"
manifest_failure_stderr="${TMP_HOME}/manifest-failure.stderr"
if bash -c "source '${REPO_DIR}/scripts/setup/lib.sh'; MANIFEST_HELPER=/bin/false; manifest_skill_links_checked '~/.claude/skills/'" >"${manifest_failure_stdout}" 2>"${manifest_failure_stderr}"; then
  red "manifest skill enumeration fails on helper error (expected failure)"
  FAIL=$((FAIL + 1))
else
  green "manifest skill enumeration fails on helper error"
  PASS=$((PASS + 1))
fi
TOTAL=$((TOTAL + 1))
manifest_failure_err="$(cat "${manifest_failure_stderr}")"
assert_contains "${manifest_failure_err}" "failed to enumerate manifest skills" "manifest skill enumeration failure is visible on stderr"
assert_cmd "manifest skill enumeration failure leaves stdout empty" test ! -s "${manifest_failure_stdout}"

manifest_empty_helper="${TMP_HOME}/empty-manifest-helper.py"
cat > "${manifest_empty_helper}" <<'PY'
#!/usr/bin/env python3
raise SystemExit(0)
PY
manifest_empty_stdout="${TMP_HOME}/manifest-empty.stdout"
manifest_empty_stderr="${TMP_HOME}/manifest-empty.stderr"
if bash -c "source '${REPO_DIR}/scripts/setup/lib.sh'; MANIFEST_HELPER='${manifest_empty_helper}'; manifest_skill_links_checked '~/.claude/skills/'" >"${manifest_empty_stdout}" 2>"${manifest_empty_stderr}"; then
  red "manifest skill enumeration fails on empty target output (expected failure)"
  FAIL=$((FAIL + 1))
else
  green "manifest skill enumeration fails on empty target output"
  PASS=$((PASS + 1))
fi
TOTAL=$((TOTAL + 1))
manifest_empty_err="$(cat "${manifest_empty_stderr}")"
assert_contains "${manifest_empty_err}" "no manifest skills declared for ~/.claude/skills/" "manifest skill empty target failure is visible on stderr"
assert_cmd "manifest skill empty target leaves stdout empty" test ! -s "${manifest_empty_stdout}"

manifest_whitespace_helper="${TMP_HOME}/whitespace-manifest-helper.py"
cat > "${manifest_whitespace_helper}" <<'PY'
#!/usr/bin/env python3
print("   ")
raise SystemExit(0)
PY
manifest_whitespace_stdout="${TMP_HOME}/manifest-whitespace.stdout"
manifest_whitespace_stderr="${TMP_HOME}/manifest-whitespace.stderr"
if bash -c "source '${REPO_DIR}/scripts/setup/lib.sh'; MANIFEST_HELPER='${manifest_whitespace_helper}'; manifest_skill_links_checked '~/.claude/skills/'" >"${manifest_whitespace_stdout}" 2>"${manifest_whitespace_stderr}"; then
  red "manifest skill enumeration fails on whitespace-only target output (expected failure)"
  FAIL=$((FAIL + 1))
else
  green "manifest skill enumeration fails on whitespace-only target output"
  PASS=$((PASS + 1))
fi
TOTAL=$((TOTAL + 1))
manifest_whitespace_err="$(cat "${manifest_whitespace_stderr}")"
assert_contains "${manifest_whitespace_err}" "no manifest skills declared for ~/.claude/skills/" "manifest skill whitespace-only target failure is visible on stderr"

cleanup_whitespace_stdout="${TMP_HOME}/cleanup-whitespace.stdout"
cleanup_whitespace_stderr="${TMP_HOME}/cleanup-whitespace.stderr"
if bash -c "source '${REPO_DIR}/scripts/setup/lib.sh'; MANIFEST_HELPER='${manifest_whitespace_helper}'; manifest_skill_links_for_cleanup '~/.claude/skills/'" >"${cleanup_whitespace_stdout}" 2>"${cleanup_whitespace_stderr}"; then
  green "cleanup skill enumeration warns on whitespace-only target output"
  PASS=$((PASS + 1))
else
  red "cleanup skill enumeration warns on whitespace-only target output (exit code: $?)"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
cleanup_whitespace_err="$(cat "${cleanup_whitespace_stderr}")"
assert_contains "${cleanup_whitespace_err}" "no manifest skills declared for ~/.claude/skills/" "cleanup whitespace-only target warning is visible on stderr"
assert_cmd "cleanup whitespace-only target leaves stdout empty" test ! -s "${cleanup_whitespace_stdout}"

header "clean continues when manifest skill enumeration fails"
broken_clean_home="${TMP_HOME}/broken-clean-home"
mkdir -p \
  "${broken_clean_home}/.claude/commands" \
  "${broken_clean_home}/.claude/agents" \
  "${broken_clean_home}/.claude/context-profiles" \
  "${broken_clean_home}/.claude/rules/vibeguard/common" \
  "${broken_clean_home}/.codex" \
  "${broken_clean_home}/.vibeguard"
touch "${broken_clean_home}/.claude/commands/vibeguard"
touch "${broken_clean_home}/.claude/agents/dispatcher.md"
touch "${broken_clean_home}/.claude/context-profiles/dev.md"
touch "${broken_clean_home}/.claude/rules/vibeguard/common/security.md"
touch "${broken_clean_home}/.vibeguard/run-hook-codex.sh"
python3 "${SETTINGS_HELPER}" upsert-vibeguard --settings-file "${broken_clean_home}/.claude/settings.json" --repo-dir "${REPO_DIR}" --profile full >/dev/null
python3 "${CODEX_HOOKS_HELPER}" upsert-vibeguard --hooks-file "${broken_clean_home}/.codex/hooks.json" --wrapper "${broken_clean_home}/.vibeguard/run-hook-codex.sh" >/dev/null
cat > "${broken_clean_home}/.codex/config.toml" <<'TOML'
[mcp_servers.vibeguard]
command = "node"
args = ["/legacy/mcp-server/dist/index.js"]
TOML
broken_clean_out="$(
  HOME="${broken_clean_home}" bash -c "
    set -euo pipefail
    source '${REPO_DIR}/scripts/setup/lib.sh'
    source '${REPO_DIR}/scripts/lib/install-state.sh'
    source '${REPO_DIR}/scripts/setup/targets/claude-home.sh'
    source '${REPO_DIR}/scripts/setup/targets/codex-home.sh'
    MANIFEST_HELPER=/bin/false
    clean_claude_home_installation
    clean_codex_home_installation
  " 2>&1
)"
assert_contains "${broken_clean_out}" "skipping skill link cleanup" "clean warns when manifest skill enumeration fails"
assert_cmd "clean continues after Claude manifest failure" test ! -e "${broken_clean_home}/.claude/commands/vibeguard"
assert_cmd "clean removes Claude agents after manifest failure" test ! -e "${broken_clean_home}/.claude/agents/dispatcher.md"
assert_cmd "clean removes Claude rules after manifest failure" test ! -e "${broken_clean_home}/.claude/rules/vibeguard"
assert_cmd "clean removes Claude hooks after manifest failure" bash -c "! grep -q 'pre-bash-guard.sh' '${broken_clean_home}/.claude/settings.json'"
assert_cmd "clean continues after Codex manifest failure" bash -c "! grep -q 'vibeguard-pre-bash-guard.sh' '${broken_clean_home}/.codex/hooks.json'"
assert_cmd "clean removes Codex wrapper after manifest failure" test ! -e "${broken_clean_home}/.vibeguard/run-hook-codex.sh"
assert_cmd "clean removes legacy Codex MCP after manifest failure" bash -c "! grep -q '^\[mcp_servers\.vibeguard\]' '${broken_clean_home}/.codex/config.toml'"

header "retired manifest skill cleanup"
retired_home="${TMP_HOME}/retired-skill-home"
mkdir -p \
  "${retired_home}/.claude/skills" \
  "${retired_home}/.codex/skills" \
  "${retired_home}/.vibeguard"
ln -s "${REPO_DIR}/skills/vibeguard" "${retired_home}/.claude/skills/vibeguard"
ln -s "${REPO_DIR}/skills/old-retired" "${retired_home}/.claude/skills/old-retired"
ln -s "${REPO_DIR}/skills/user-skill" "${retired_home}/.claude/skills/user-skill"
mkdir -p "${retired_home}/.claude/skills/old-dir"
ln -s "${REPO_DIR}/workflows/old-flow" "${retired_home}/.codex/skills/old-flow"
python3 - <<'PY' "${retired_home}"
import json
import sys
from pathlib import Path

home = Path(sys.argv[1])
state = {
    "version": 1,
    "files": {
        str(home / ".claude/skills/vibeguard"): {"source": "skills/vibeguard", "type": "symlink"},
        str(home / ".claude/skills/old-retired"): {"source": "skills/old-retired", "type": "symlink"},
        str(home / ".claude/skills/old-dir"): {"source": "skills/old-dir", "type": "symlink"},
        str(home / ".codex/skills/old-flow"): {"source": "workflows/old-flow", "type": "symlink"},
    },
}
(home / ".vibeguard/install-state.json").write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
PY
retired_cleanup_out="$(
  HOME="${retired_home}" bash -c "
    set -euo pipefail
    source '${REPO_DIR}/scripts/setup/lib.sh'
    source '${REPO_DIR}/scripts/lib/install-state.sh'
    cleanup_retired_manifest_skill_links '~/.claude/skills/' '${retired_home}/.claude/skills'
    cleanup_retired_manifest_skill_links '~/.codex/skills/' '${retired_home}/.codex/skills'
  " 2>&1
)"
assert_contains "${retired_cleanup_out}" "Removed retired VibeGuard skill link" "retired skill cleanup reports removed managed links"
assert_cmd "retired cleanup keeps active manifest Claude skill" test -L "${retired_home}/.claude/skills/vibeguard"
assert_cmd "retired cleanup removes tracked retired Claude skill" test ! -L "${retired_home}/.claude/skills/old-retired"
assert_cmd "retired cleanup removes tracked retired Codex skill" test ! -L "${retired_home}/.codex/skills/old-flow"
assert_cmd "retired cleanup preserves untracked user skill" test -L "${retired_home}/.claude/skills/user-skill"
assert_cmd "retired cleanup preserves retired regular directories" test -d "${retired_home}/.claude/skills/old-dir"

header "hooks manifest"
assert_cmd "hooks manifest validates" bash "${REPO_DIR}/scripts/ci/validate-hooks-manifest.sh"
assert_cmd "hooks/CLAUDE.md table is generated from manifest" bash "${REPO_DIR}/scripts/setup/regenerate-hooks-from-manifest.sh" --check
assert_cmd "Codex helper specs come from hook manifest" bash -c "python3 '${HOOKS_MANIFEST_HELPER}' codex-specs | grep -q 'vibeguard-pre-bash-guard.sh'"

header "scheduled GC templates"
assert_cmd "scheduled GC script exists at canonical path" test -x "${REPO_DIR}/scripts/gc/gc-scheduled.sh"
assert_cmd "launchd plist points to canonical GC script path" grep -q "__VIBEGUARD_DIR__/scripts/gc/gc-scheduled.sh" "${REPO_DIR}/scripts/setup/com.vibeguard.gc.plist"
assert_cmd "systemd service points to canonical GC script path" grep -q "__VIBEGUARD_DIR__/scripts/gc/gc-scheduled.sh" "${REPO_DIR}/scripts/systemd/vibeguard-gc.service"
assert_cmd "systemd installer chmods canonical GC script path" grep -q 'scripts/gc/gc-scheduled.sh' "${REPO_DIR}/scripts/install-systemd.sh"
assert_cmd "scheduled GC installers do not reference legacy root path" bash -c "! grep -q 'scripts/gc-scheduled.sh' '${REPO_DIR}/scripts/setup/com.vibeguard.gc.plist' '${REPO_DIR}/scripts/systemd/vibeguard-gc.service' '${REPO_DIR}/scripts/install-systemd.sh'"

header "seed legacy config"
mkdir -p "${HOME}/.claude" "${HOME}/.codex"
cat > "${HOME}/.claude/settings.json" <<'JSON'
{
  "mcpServers": {
    "vibeguard": {
      "type": "stdio",
      "command": "node",
      "args": ["/legacy/mcp-server/dist/index.js"]
    }
  },
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "mcp__vibeguard__guard_check",
        "hooks": [
          {
            "type": "command",
            "command": "bash /legacy/post-guard-check.sh"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash /legacy/session-tagger.sh"
          }
        ]
      },
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash /legacy/cognitive-reminder.sh"
          }
        ]
      }
    ]
  }
}
JSON
cat > "${HOME}/.codex/hooks.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "node /existing/non-vibeguard.js"
          }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash /legacy/run-hook-codex.sh pre-bash-guard.sh"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash /legacy/session-tagger.sh"
          }
        ]
      }
    ]
  }
}
JSON
cat > "${HOME}/.codex/config.toml" <<'TOML'
[mcp_servers.vibeguard]
command = "node"
args = ["/legacy/mcp-server/dist/index.js"]
TOML
assert_cmd "Legacy Claude MCP configuration has been written" grep -q "mcp-server/dist/index.js" "${HOME}/.claude/settings.json"
assert_cmd "Legacy Codex MCP configuration written" grep -q '^\[mcp_servers\.vibeguard\]' "${HOME}/.codex/config.toml"
assert_cmd "Pre-existing non-VibeGuard Codex hook is present" grep -q 'node /existing/non-vibeguard.js' "${HOME}/.codex/hooks.json"

header "setup --check"
check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
assert_contains "${check_out}" "VibeGuard Installation Status" "--check route to status check"

bad_project_config="${TMP_HOME}/bad-vibeguard.json"
cat > "${bad_project_config}" <<'JSON'
{
  "profile": "strictest",
  "gc": {
    "log_threshold_mb": 0
  }
}
JSON
invalid_project_check_out="$(VIBEGUARD_PROJECT_CONFIG="${bad_project_config}" bash "${REPO_DIR}/setup.sh" --check 2>&1)"
assert_contains "${invalid_project_check_out}" "[FAIL] Project config invalid" "--check reports invalid .vibeguard.json"
assert_contains "${invalid_project_check_out}" ".profile: unsupported value" "--check reports invalid project profile"
assert_contains "${invalid_project_check_out}" ".gc.log_threshold_mb: expected integer >= 1" "--check reports invalid project gc threshold"
invalid_project_install_out="$(VIBEGUARD_PROJECT_CONFIG="${bad_project_config}" bash "${REPO_DIR}/setup.sh" --dry-run 2>&1 || true)"
assert_contains "${invalid_project_install_out}" "ERROR: invalid project config" "setup install refuses invalid .vibeguard.json"
assert_contains "${invalid_project_install_out}" ".profile: unsupported value" "setup install reports invalid project profile"

header "setup install"
dry_run_settings_sha_before="$(shasum -a 256 "${HOME}/.claude/settings.json" | cut -d' ' -f1)"
dry_run_codex_hooks_sha_before="$(shasum -a 256 "${HOME}/.codex/hooks.json" | cut -d' ' -f1)"
dry_run_codex_config_sha_before="$(shasum -a 256 "${HOME}/.codex/config.toml" | cut -d' ' -f1)"
dry_run_out="$(bash "${REPO_DIR}/setup.sh" --dry-run 2>&1)"
dry_run_settings_sha_after="$(shasum -a 256 "${HOME}/.claude/settings.json" | cut -d' ' -f1)"
dry_run_codex_hooks_sha_after="$(shasum -a 256 "${HOME}/.codex/hooks.json" | cut -d' ' -f1)"
dry_run_codex_config_sha_after="$(shasum -a 256 "${HOME}/.codex/config.toml" | cut -d' ' -f1)"
assert_contains "${dry_run_out}" "Mode: dry-run" "--dry-run reports dry-run mode"
assert_contains "${dry_run_out}" "${HOME}/.claude/settings.json" "--dry-run prints settings.json diff"
assert_contains "${dry_run_out}" "${HOME}/.claude/CLAUDE.md" "--dry-run prints CLAUDE.md diff"
assert_contains "${dry_run_out}" "${HOME}/.codex/AGENTS.md" "--dry-run prints Codex AGENTS.md diff"
assert_cmd "--dry-run does not modify ~/.claude/settings.json" test "${dry_run_settings_sha_before}" = "${dry_run_settings_sha_after}"
assert_cmd "--dry-run does not modify ~/.codex/hooks.json" test "${dry_run_codex_hooks_sha_before}" = "${dry_run_codex_hooks_sha_after}"
assert_cmd "--dry-run does not modify ~/.codex/config.toml" test "${dry_run_codex_config_sha_before}" = "${dry_run_codex_config_sha_after}"
assert_cmd "--dry-run does not create ~/.claude/CLAUDE.md" test ! -e "${HOME}/.claude/CLAUDE.md"
assert_cmd "--dry-run does not create ~/.codex/AGENTS.md" test ! -e "${HOME}/.codex/AGENTS.md"

confirm_fail_out="$(bash "${REPO_DIR}/setup.sh" 2>&1 || true)"
assert_contains "${confirm_fail_out}" "requires explicit confirmation" "non-interactive setup requires --yes for high-context writes"
assert_contains "${confirm_fail_out}" "~/.vibeguard/config.json seeded" "setup seeds runtime config file before high-context confirmation"
assert_cmd "~/.vibeguard/config.json exists after setup seed" test -f "${HOME}/.vibeguard/config.json"
assert_cmd "~/.vibeguard/config.json includes advertised runtime keys after seed" assert_runtime_config_seeded

mkdir -p "${HOME}/.claude/skills" "${HOME}/.codex/skills" "${HOME}/.vibeguard"
ln -s "${REPO_DIR}/skills/old-retired" "${HOME}/.claude/skills/old-retired"
ln -s "${REPO_DIR}/workflows/old-flow" "${HOME}/.codex/skills/old-flow"
python3 - <<'PY' "${HOME}"
import json
import sys
from pathlib import Path

home = Path(sys.argv[1])
state = {
    "version": 1,
    "files": {
        str(home / ".claude/skills/old-retired"): {"source": "skills/old-retired", "type": "symlink"},
        str(home / ".codex/skills/old-flow"): {"source": "workflows/old-flow", "type": "symlink"},
    },
}
(home / ".vibeguard/install-state.json").write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
PY
install_out="$(bash "${REPO_DIR}/setup.sh" --yes)"
assert_contains "${install_out}" "Setup complete! All components installed." "Default route to installation process"
assert_contains "${install_out}" "Removed retired VibeGuard skill link" "setup install removes tracked retired skill links"
assert_cmd "setup install removes tracked retired Claude skill" test ! -L "${HOME}/.claude/skills/old-retired"
assert_cmd "setup install removes tracked retired Codex skill" test ! -L "${HOME}/.codex/skills/old-flow"
assert_cmd "vg-helper binary installed after setup" test -x "${HOME}/.vibeguard/installed/bin/vg-helper"
assert_contains "${install_out}" "~/.vibeguard/config.json present (preserved)" "setup preserves seeded runtime config during install"
assert_cmd "~/.claude/skills/vibeguard exists after installation" test -L "${HOME}/.claude/skills/vibeguard"
assert_cmd "~/.codex/skills/vibeguard exists after installation" test -L "${HOME}/.codex/skills/vibeguard"
assert_cmd "~/.claude/skills/agentsmd-audit exists after installation" test -L "${HOME}/.claude/skills/agentsmd-audit"
assert_cmd "~/.claude/skills/trajectory-review exists after installation" test -L "${HOME}/.claude/skills/trajectory-review"
assert_cmd "~/.codex/skills/agentsmd-audit exists after installation" test -L "${HOME}/.codex/skills/agentsmd-audit"
assert_cmd "~/.codex/skills/trajectory-review exists after installation" test -L "${HOME}/.codex/skills/trajectory-review"
assert_cmd "all manifest Claude skill links are installed" assert_manifest_skill_links_installed "~/.claude/skills/" "${HOME}/.claude/skills"
assert_cmd "all manifest Codex skill links are installed" assert_manifest_skill_links_installed "~/.codex/skills/" "${HOME}/.codex/skills"
assert_cmd "Clean legacy Claude MCP block after installation" bash -c "! grep -q 'mcp-server/dist/index.js' '${HOME}/.claude/settings.json'"
assert_cmd "No longer write to mcpServers after installation" bash -c "! grep -q 'mcpServers' '${HOME}/.claude/settings.json'"
assert_cmd "settings helper detects pre hooks configured" python3 "${SETTINGS_HELPER}" check --settings-file "${HOME}/.claude/settings.json" --target pre-hooks
assert_cmd "settings helper detects post hooks configured" python3 "${SETTINGS_HELPER}" check --settings-file "${HOME}/.claude/settings.json" --target post-hooks
assert_cmd "post-guard-check is not enabled in the default installation" bash -c "! grep -q 'post-guard-check.sh' '${HOME}/.claude/settings.json'"
assert_cmd "skills-loader is not enabled in the default installation" bash -c "! grep -q 'skills-loader.sh' '${HOME}/.claude/settings.json'"
assert_cmd "The default core profile does not enable full hooks" bash -c "python3 '${SETTINGS_HELPER}' check --settings-file '${HOME}/.claude/settings.json' --target full-hooks >/dev/null 2>&1; test \$? -ne 0"
assert_cmd "~/.codex/hooks.json exists after installation" test -f "${HOME}/.codex/hooks.json"
assert_cmd "Enable codex_hooks feature after installation" grep -Eq '^codex_hooks[[:space:]]*=[[:space:]]*true$' "${HOME}/.codex/config.toml"
assert_cmd "Clean legacy Codex MCP block after installation" bash -c "! grep -q '^\[mcp_servers\.vibeguard\]' '${HOME}/.codex/config.toml'"
assert_cmd "Codex hooks are namespaced (vibeguard prefix)" bash -c "grep -q 'vibeguard-pre-bash-guard.sh' '${HOME}/.codex/hooks.json' && grep -q 'vibeguard-post-build-check.sh' '${HOME}/.codex/hooks.json' && grep -q 'vibeguard-stop-guard.sh' '${HOME}/.codex/hooks.json' && grep -q 'vibeguard-learn-evaluator.sh' '${HOME}/.codex/hooks.json'"
assert_cmd "Codex helper validates managed hooks" python3 "${CODEX_HOOKS_HELPER}" check-vibeguard --hooks-file "${HOME}/.codex/hooks.json" --wrapper "${HOME}/.vibeguard/run-hook-codex.sh"
assert_cmd "Legacy non-namespaced Codex hook command is removed" bash -c "! grep -q 'run-hook-codex.sh pre-bash-guard.sh' '${HOME}/.codex/hooks.json'"
assert_cmd "run-hook-codex rejects non-namespaced hook names" bash -c "out=\$(printf '{\"hook_event_name\":\"PreToolUse\",\"tool_input\":{\"command\":\"rm -rf /\"}}' | bash '${REPO_DIR}/hooks/run-hook-codex.sh' pre-bash-guard.sh); test -z \"\$out\""
assert_cmd "Codex hooks do not contain cognitive-reminder" bash -c "! grep -q 'cognitive-reminder.sh' '${HOME}/.codex/hooks.json'"
assert_cmd "Codex hooks do not contain session-tagger" bash -c "! grep -q 'session-tagger.sh' '${HOME}/.codex/hooks.json'"
assert_cmd "Pre-existing non-VibeGuard hook is preserved" grep -q 'node /existing/non-vibeguard.js' "${HOME}/.codex/hooks.json"
assert_cmd "Codex hooks include managed + preserved entries" python3 -c "import json; data=json.load(open('${HOME}/.codex/hooks.json')); total=sum(len(entries) for entries in data.get('hooks', {}).values() if isinstance(entries, list)); raise SystemExit(0 if total >= 5 else 1)"
assert_cmd "~/.claude/CLAUDE.md includes the chat contract anchor after installation" grep -qF "${CHAT_CONTRACT_ANCHOR}" "${HOME}/.claude/CLAUDE.md"
assert_cmd "~/.claude/CLAUDE.md rule banner matches installed rules" assert_claude_rule_banner_matches_installed_rules
assert_cmd "~/.codex/AGENTS.md exists after installation" test -f "${HOME}/.codex/AGENTS.md"
assert_cmd "~/.codex/AGENTS.md includes managed markers after installation" bash -c "grep -q '<!-- vibeguard-start -->' '${HOME}/.codex/AGENTS.md' && grep -q '<!-- vibeguard-end -->' '${HOME}/.codex/AGENTS.md'"
assert_cmd "~/.codex/AGENTS.md includes key Codex-visible anchors" bash -c "grep -qF 'Compact Chat Contract' '${HOME}/.codex/AGENTS.md' && grep -qF '| W-03 |' '${HOME}/.codex/AGENTS.md' && grep -qF '| SEC-13 |' '${HOME}/.codex/AGENTS.md'"
assert_cmd "templates/AGENTS.md includes the chat contract anchor" grep -qF "${CHAT_CONTRACT_ANCHOR}" "${REPO_DIR}/templates/AGENTS.md"
assert_cmd "docs/CLAUDE.md.example includes the chat contract anchor" grep -qF "${CHAT_CONTRACT_ANCHOR}" "${REPO_DIR}/docs/CLAUDE.md.example"
assert_cmd "chat contract block matches across source, installed output, and templates" assert_chat_contract_blocks_match

header "setup protects user customizations"
python3 - <<'PY' "${HOME}/.claude/settings.json" "${HOME}"
import json
import sys
from pathlib import Path

settings = Path(sys.argv[1])
home = sys.argv[2]
data = json.loads(settings.read_text(encoding="utf-8"))
for entry in data["hooks"]["PreToolUse"]:
    if entry.get("matcher") == "Bash":
        entry["hooks"][0]["command"] = f"flock /tmp/vibeguard.lock bash {home}/.vibeguard/run-hook.sh pre-bash-guard.sh"
settings.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
custom_settings_out="$(bash "${REPO_DIR}/setup.sh" --yes 2>&1)"
assert_contains "${custom_settings_out}" "preserving customized VibeGuard hook command for pre-bash-guard.sh" "setup warns when preserving customized hook command"
assert_contains "${custom_settings_out}" "~/.vibeguard/config.json present (preserved)" "setup preserves existing runtime config file"
assert_cmd "customized hook command is preserved by default" grep -q "flock /tmp/vibeguard.lock" "${HOME}/.claude/settings.json"
force_settings_out="$(bash "${REPO_DIR}/setup.sh" --yes --force-overwrite 2>&1)"
assert_contains "${force_settings_out}" "Mode: force-overwrite" "--force-overwrite mode is visible"
assert_cmd "--force-overwrite restores canonical hook command" bash -c "! grep -q 'flock /tmp/vibeguard.lock' '${HOME}/.claude/settings.json'"

_CUSTOM_RULE="${HOME}/.claude/rules/vibeguard/common/security.md"
rm -f "${_CUSTOM_RULE}"
printf 'local custom security rule\n' > "${_CUSTOM_RULE}"
rule_protect_out="$(bash "${REPO_DIR}/setup.sh" --yes 2>&1 || true)"
assert_contains "${rule_protect_out}" "refusing to overwrite modified local rule file" "setup refuses to overwrite modified local rule copies"
assert_cmd "modified local rule copy remains a regular file" bash -c "[ -f '${_CUSTOM_RULE}' ] && [ ! -L '${_CUSTOM_RULE}' ]"
rule_force_out="$(bash "${REPO_DIR}/setup.sh" --yes --force-overwrite 2>&1)"
assert_contains "${rule_force_out}" "FORCE: replacing local rule copy" "--force-overwrite reports local rule replacement"
assert_cmd "--force-overwrite restores rule symlink" test -L "${_CUSTOM_RULE}"

header "codex config helper failure propagates"
_ORIG_CODEX_CONFIG_HELPER="${REPO_DIR}/scripts/lib/codex_config_toml.py"
_BACKUP_CODEX_CONFIG_HELPER="${TMP_HOME}/codex_config_toml.py.backup"
cp "${_ORIG_CODEX_CONFIG_HELPER}" "${_BACKUP_CODEX_CONFIG_HELPER}"
cat > "${_ORIG_CODEX_CONFIG_HELPER}" <<'PY'
#!/usr/bin/env python3
raise SystemExit(42)
PY
fail_install_out="$(bash "${REPO_DIR}/setup.sh" --yes 2>&1 || true)"
cp "${_BACKUP_CODEX_CONFIG_HELPER}" "${_ORIG_CODEX_CONFIG_HELPER}"
assert_contains "${fail_install_out}" "Failed to enable codex_hooks feature in config.toml" "setup reports codex_hooks helper failure"
assert_cmd "setup exits before reporting success when codex_hooks helper fails" bash -c "! grep -q 'Setup complete! All components installed.' <<< '${fail_install_out}'"

header "setup --check rejects invalid codex config"
_VALID_CODEX_CONFIG="${TMP_HOME}/config.toml.valid.backup"
cp "${HOME}/.codex/config.toml" "${_VALID_CODEX_CONFIG}"
cat > "${HOME}/.codex/config.toml" <<'TOML'
not valid toml =
[features]
codex_hooks = true
TOML
invalid_codex_check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
cp "${_VALID_CODEX_CONFIG}" "${HOME}/.codex/config.toml"
assert_contains "${invalid_codex_check_out}" "[BROKEN] ~/.codex/config.toml is malformed TOML" "--check reports invalid ~/.codex/config.toml"
assert_cmd "invalid config does not report codex_hooks enabled" bash -c "! grep -qF '[OK] codex_hooks feature enabled in config.toml' <<< '${invalid_codex_check_out}'"

header "setup --check rejects invalid UTF-8 codex config"
python3 - <<'PY' "${HOME}/.codex/config.toml"
from pathlib import Path
import sys
Path(sys.argv[1]).write_bytes(b'[features]\ncodex_hooks = true\n\xff')
PY
invalid_utf8_codex_check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
cp "${_VALID_CODEX_CONFIG}" "${HOME}/.codex/config.toml"
assert_contains "${invalid_utf8_codex_check_out}" "[BROKEN] ~/.codex/config.toml is malformed TOML" "--check reports invalid UTF-8 ~/.codex/config.toml"
assert_cmd "invalid UTF-8 config does not report codex_hooks enabled" bash -c "! grep -qF '[OK] codex_hooks feature enabled in config.toml' <<< '${invalid_utf8_codex_check_out}'"

header "setup --check validates codex AGENTS"
_VALID_CODEX_AGENTS="${TMP_HOME}/AGENTS.md.valid.backup"
cp "${HOME}/.codex/AGENTS.md" "${_VALID_CODEX_AGENTS}"
: > "${HOME}/.codex/AGENTS.md"
zero_byte_agents_check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
cp "${_VALID_CODEX_AGENTS}" "${HOME}/.codex/AGENTS.md"
assert_contains "${zero_byte_agents_check_out}" "[BROKEN] ~/.codex/AGENTS.md is 0 bytes" "--check reports 0-byte ~/.codex/AGENTS.md"
python3 - <<'PY' "${HOME}/.codex/AGENTS.md"
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
path.write_text(text.replace("<!-- vibeguard-end -->", "", 1), encoding="utf-8")
PY
missing_end_agents_check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
cp "${_VALID_CODEX_AGENTS}" "${HOME}/.codex/AGENTS.md"
assert_contains "${missing_end_agents_check_out}" "[BROKEN] ~/.codex/AGENTS.md marker mismatch" "--check reports missing Codex AGENTS end marker"
printf '<!-- vibeguard-start -->\n' >> "${HOME}/.codex/AGENTS.md"
duplicate_start_agents_check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
cp "${_VALID_CODEX_AGENTS}" "${HOME}/.codex/AGENTS.md"
assert_contains "${duplicate_start_agents_check_out}" "[BROKEN] ~/.codex/AGENTS.md marker mismatch" "--check reports duplicate Codex AGENTS start marker"
python3 - <<'PY' "${HOME}/.codex/AGENTS.md"
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
path.write_text(text.replace("| SEC-13 |", "| SEC-X |", 1), encoding="utf-8")
PY
missing_anchor_agents_check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
cp "${_VALID_CODEX_AGENTS}" "${HOME}/.codex/AGENTS.md"
assert_contains "${missing_anchor_agents_check_out}" "[BROKEN] ~/.codex/AGENTS.md missing required anchors" "--check reports missing Codex AGENTS required anchors"
printf '# malicious injection appended by something\n' >> "${HOME}/.codex/AGENTS.md"
external_agents_check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
cp "${_VALID_CODEX_AGENTS}" "${HOME}/.codex/AGENTS.md"
assert_contains "${external_agents_check_out}" "[WARN] ~/.codex/AGENTS.md has 1 non-empty unmanaged line(s) outside VibeGuard block" "--check warns on unmanaged Codex AGENTS content"
assert_contains "${external_agents_check_out}" "Codex native hooks: PreToolUse(Bash), PostToolUse(Bash), Stop(stop-guard/learn-evaluator)" "--check reports exact Codex native hook scope"

header "setup --check stays read-only"
python3 - <<'PY' "${HOME}/.claude/CLAUDE.md"
from pathlib import Path
import re
path = Path(__import__('sys').argv[1])
text = path.read_text(encoding='utf-8')
updated = re.sub(r'\b\d+ rules\b', '999 rules', text, count=1)
path.write_text(updated, encoding='utf-8')
PY
before_sha="$(shasum -a 256 "${HOME}/.claude/CLAUDE.md" | cut -d' ' -f1)"
agents_before_sha="$(shasum -a 256 "${HOME}/.codex/AGENTS.md" | cut -d' ' -f1)"
check_again_out="$(bash "${REPO_DIR}/setup.sh" --check)"
after_sha="$(shasum -a 256 "${HOME}/.claude/CLAUDE.md" | cut -d' ' -f1)"
agents_after_sha="$(shasum -a 256 "${HOME}/.codex/AGENTS.md" | cut -d' ' -f1)"
assert_contains "${check_again_out}" "CLAUDE.md declares 999 rules" "--check reports CLAUDE.md drift"
assert_contains "${check_again_out}" "[OK] vg-helper runtime binary installed" "--check reports vg-helper installed"
assert_cmd "--check does not rewrite ~/.claude/CLAUDE.md" test "${before_sha}" = "${after_sha}"
assert_cmd "--check does not rewrite ~/.codex/AGENTS.md" test "${agents_before_sha}" = "${agents_after_sha}"
assert_cmd "--check does not drop or duplicate the chat contract block" python3 -c "from pathlib import Path; text = Path('${HOME}/.claude/CLAUDE.md').read_text(encoding='utf-8'); raise SystemExit(0 if text.count('${CHAT_CONTRACT_ANCHOR}') == 1 else 1)"
repair_out="$(bash "${REPO_DIR}/setup.sh" --yes)"
assert_contains "${repair_out}" "Setup complete! All components installed." "re-running setup after drift still succeeds"
assert_cmd "repair restores CLAUDE.md rule banner count" assert_claude_rule_banner_matches_installed_rules
assert_cmd "repeat setup keeps exactly one chat contract block" python3 -c "from pathlib import Path; text = Path('${HOME}/.claude/CLAUDE.md').read_text(encoding='utf-8'); raise SystemExit(0 if text.count('${CHAT_CONTRACT_ANCHOR}') == 1 else 1)"

header "upsert idempotency with non-standard wrapper path"
# Run upsert twice with a wrapper path that does not contain 'run-hook-codex.sh'.
# Without the _has_entry dedup fix, the second upsert would append duplicates.
_IDEMPOTENT_HOOKS="${TMP_HOME}/.codex/hooks-idempotent.json"
_IDEMPOTENT_WRAPPER="${TMP_HOME}/test/wrapper.sh"
python3 "${CODEX_HOOKS_HELPER}" upsert-vibeguard --hooks-file "${_IDEMPOTENT_HOOKS}" --wrapper "${_IDEMPOTENT_WRAPPER}" >/dev/null
python3 "${CODEX_HOOKS_HELPER}" upsert-vibeguard --hooks-file "${_IDEMPOTENT_HOOKS}" --wrapper "${_IDEMPOTENT_WRAPPER}" >/dev/null
assert_cmd "double-upsert with non-standard wrapper produces exactly 4 Stop entries (not 8)" python3 -c "
import json
data = json.load(open('${_IDEMPOTENT_HOOKS}'))
stop_entries = data.get('hooks', {}).get('Stop', [])
raise SystemExit(0 if len(stop_entries) == 2 else 1)
"
assert_cmd "double-upsert with non-standard wrapper: check-vibeguard passes" python3 "${CODEX_HOOKS_HELPER}" check-vibeguard --hooks-file "${_IDEMPOTENT_HOOKS}" --wrapper "${_IDEMPOTENT_WRAPPER}"

header "remove-vibeguard cleans custom-wrapper-path hooks"
# Issue fix: _is_vibeguard_command must recognise vibeguard-* scripts even when
# the wrapper path does not contain 'run-hook-codex.sh'.
python3 "${CODEX_HOOKS_HELPER}" remove-vibeguard --hooks-file "${_IDEMPOTENT_HOOKS}"
assert_cmd "remove-vibeguard removes custom-wrapper vibeguard hooks" bash -c "! grep -q 'vibeguard-pre-bash-guard.sh' '${_IDEMPOTENT_HOOKS}'"
assert_cmd "remove-vibeguard removes all managed hook scripts" bash -c "! grep -qE 'vibeguard-(pre-bash-guard|post-build-check|stop-guard|learn-evaluator)\\.sh' '${_IDEMPOTENT_HOOKS}'"

header "_has_entry validates type and timeout (Issue 2 guard)"
# A stale entry that has the correct command but is missing 'type: command' or
# has a spurious timeout must NOT satisfy check-vibeguard (silent false positive).
_STALE_HOOKS="${TMP_HOME}/.codex/hooks-stale.json"
_STALE_WRAPPER="${TMP_HOME}/test/stale-wrapper.sh"
# Write an entry with correct command but no 'type' field and no 'timeout'.
python3 -c "
import json, sys
data = {
  'hooks': {
    'PreToolUse': [{
      'matcher': 'Bash',
      'hooks': [{'command': 'bash ${_STALE_WRAPPER} vibeguard-pre-bash-guard.sh'}]
    }]
  }
}
with open('${_STALE_HOOKS}', 'w') as f:
    json.dump(data, f, indent=2)
"
assert_cmd "check-vibeguard rejects stale entry missing type field" bash -c "! python3 '${CODEX_HOOKS_HELPER}' check-vibeguard --hooks-file '${_STALE_HOOKS}' --wrapper '${_STALE_WRAPPER}'"
# After upsert the entry must be repaired and check must pass.
python3 "${CODEX_HOOKS_HELPER}" upsert-vibeguard --hooks-file "${_STALE_HOOKS}" --wrapper "${_STALE_WRAPPER}" >/dev/null
assert_cmd "upsert repairs stale entry; check-vibeguard then passes" python3 "${CODEX_HOOKS_HELPER}" check-vibeguard --hooks-file "${_STALE_HOOKS}" --wrapper "${_STALE_WRAPPER}"
# Write a Stop entry with correct command but a spurious timeout (Stop spec has none).
python3 -c "
import json
data = {
  'hooks': {
    'Stop': [{
      'hooks': [{'type': 'command', 'command': 'bash ${_STALE_WRAPPER} vibeguard-stop-guard.sh', 'timeout': 99}]
    }]
  }
}
with open('${_STALE_HOOKS}', 'w') as f:
    json.dump(data, f, indent=2)
"
assert_cmd "check-vibeguard rejects Stop entry with spurious timeout" bash -c "! python3 '${CODEX_HOOKS_HELPER}' check-vibeguard --hooks-file '${_STALE_HOOKS}' --wrapper '${_STALE_WRAPPER}'"
# Write a Stop entry with correct command+type but a spurious matcher (Stop spec has none).
python3 -c "
import json
data = {
  'hooks': {
    'Stop': [{
      'matcher': 'Bash',
      'hooks': [{'type': 'command', 'command': 'bash ${_STALE_WRAPPER} vibeguard-stop-guard.sh'}]
    }]
  }
}
with open('${_STALE_HOOKS}', 'w') as f:
    json.dump(data, f, indent=2)
"
assert_cmd "check-vibeguard rejects Stop entry with spurious matcher" bash -c "! python3 '${CODEX_HOOKS_HELPER}' check-vibeguard --hooks-file '${_STALE_HOOKS}' --wrapper '${_STALE_WRAPPER}'"
# After upsert the entry must be repaired and check must pass.
python3 "${CODEX_HOOKS_HELPER}" upsert-vibeguard --hooks-file "${_STALE_HOOKS}" --wrapper "${_STALE_WRAPPER}" >/dev/null
assert_cmd "upsert repairs Stop entry with spurious matcher; check-vibeguard then passes" python3 "${CODEX_HOOKS_HELPER}" check-vibeguard --hooks-file "${_STALE_HOOKS}" --wrapper "${_STALE_WRAPPER}"

header "setup --clean"
printf 'user codex note\n' >> "${HOME}/.codex/AGENTS.md"
clean_out="$(bash "${REPO_DIR}/setup.sh" --clean)"
assert_contains "${clean_out}" "VibeGuard cleaned." "--clean route to cleanup process"
assert_cmd "~/.claude/skills/vibeguard has been removed after cleaning" test ! -e "${HOME}/.claude/skills/vibeguard"
assert_cmd "~/.claude/skills/agentsmd-audit has been removed after cleaning" test ! -e "${HOME}/.claude/skills/agentsmd-audit"
assert_cmd "~/.claude/skills/trajectory-review has been removed after cleaning" test ! -e "${HOME}/.claude/skills/trajectory-review"
assert_cmd "~/.codex/skills/agentsmd-audit has been removed after cleaning" test ! -e "${HOME}/.codex/skills/agentsmd-audit"
assert_cmd "~/.codex/skills/trajectory-review has been removed after cleaning" test ! -e "${HOME}/.codex/skills/trajectory-review"
assert_cmd "~/.codex/hooks.json is preserved after cleaning (for non-VibeGuard hooks)" test -f "${HOME}/.codex/hooks.json"
assert_cmd "VibeGuard managed Codex AGENTS block removed after cleaning" bash -c "! grep -q 'vibeguard-start' '${HOME}/.codex/AGENTS.md'"
assert_cmd "Unmanaged Codex AGENTS content remains after cleaning" grep -q 'user codex note' "${HOME}/.codex/AGENTS.md"
assert_cmd "VibeGuard managed Codex hooks removed after cleaning" bash -c "! grep -q 'vibeguard-pre-bash-guard.sh' '${HOME}/.codex/hooks.json' && ! grep -q 'vibeguard-post-build-check.sh' '${HOME}/.codex/hooks.json' && ! grep -q 'vibeguard-stop-guard.sh' '${HOME}/.codex/hooks.json' && ! grep -q 'vibeguard-learn-evaluator.sh' '${HOME}/.codex/hooks.json'"
assert_cmd "Pre-existing non-VibeGuard hook remains after cleaning" grep -q 'node /existing/non-vibeguard.js' "${HOME}/.codex/hooks.json"
assert_cmd "legacy Codex MCP block has been removed after cleaning" bash -c "[ ! -f '${HOME}/.codex/config.toml' ] || ! grep -q '^\[mcp_servers\.vibeguard\]' '${HOME}/.codex/config.toml'"

header "setup install --languages rust"
install_lang_out="$(bash "${REPO_DIR}/setup.sh" --yes --profile core --languages rust)"
assert_contains "${install_lang_out}" "Languages: rust" "--languages parameter takes effect"
assert_cmd "--languages after installation --check executable" bash -c "bash '${REPO_DIR}/setup.sh' --check >/dev/null 2>&1"

header "setup --clean (after --languages)"
clean_lang_out="$(bash "${REPO_DIR}/setup.sh" --clean)"
assert_contains "${clean_lang_out}" "VibeGuard cleaned." "languages profile cleaned successfully"

header "setup install --profile full"
install_full_out="$(bash "${REPO_DIR}/setup.sh" --yes --profile full)"
assert_contains "${install_full_out}" "Profile: full" "full profile parameter takes effect"
assert_cmd "full profile configuration full hooks" python3 "${SETTINGS_HELPER}" check --settings-file "${HOME}/.claude/settings.json" --target full-hooks
assert_cmd "full profile enable stop-guard" grep -q "stop-guard.sh" "${HOME}/.claude/settings.json"
assert_cmd "full profile enable learn-evaluator" grep -q "learn-evaluator.sh" "${HOME}/.claude/settings.json"
assert_cmd "full profile enable post-build-check" grep -q "post-build-check.sh" "${HOME}/.claude/settings.json"

header "setup --clean (after full)"
clean_full_out="$(bash "${REPO_DIR}/setup.sh" --clean)"
assert_contains "${clean_full_out}" "VibeGuard cleaned." "full profile cleaned successfully"
assert_cmd "full hooks have been removed after cleaning" bash -c "python3 '${SETTINGS_HELPER}' check --settings-file '${HOME}/.claude/settings.json' --target full-hooks >/dev/null 2>&1; test \$? -ne 0"

header "setup install --profile strict"
install_strict_out="$(bash "${REPO_DIR}/setup.sh" --yes --profile strict)"
assert_contains "${install_strict_out}" "Profile: strict" "strict profile parameter takes effect"
assert_cmd "strict profile still configures full hooks" python3 "${SETTINGS_HELPER}" check --settings-file "${HOME}/.claude/settings.json" --target full-hooks
assert_cmd "strict profile does not enable session-tagger" bash -c "! grep -q 'session-tagger.sh' '${HOME}/.claude/settings.json' && ! grep -q 'session-tagger.sh' '${HOME}/.codex/hooks.json'"
assert_cmd "strict profile does not enable cognitive-reminder" bash -c "! grep -q 'cognitive-reminder.sh' '${HOME}/.claude/settings.json' && ! grep -q 'cognitive-reminder.sh' '${HOME}/.codex/hooks.json'"

header "setup --clean (after strict)"
clean_strict_out="$(bash "${REPO_DIR}/setup.sh" --clean)"
assert_contains "${clean_strict_out}" "VibeGuard cleaned." "strict profile cleaned successfully"

echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
