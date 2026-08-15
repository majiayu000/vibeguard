#!/usr/bin/env bash
# Focused setup hardening regression tests.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SETTINGS_HELPER="${REPO_DIR}/scripts/lib/settings_json.py"
CODEX_HOOKS_HELPER="${REPO_DIR}/scripts/lib/codex_hooks_json.py"

PASS=0
FAIL=0
TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red() { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }
header() { printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

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

TMP_DIR="$(mktemp -d)"
export TMP_DIR
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

export PYTHONPATH="${REPO_DIR}/scripts/lib:${PYTHONPATH:-}"

header "shared helper syntax"
assert_cmd "file_ops.py syntax is correct" python3 -m py_compile "${REPO_DIR}/scripts/lib/file_ops.py"
assert_cmd "hook_config_model.py syntax is correct" python3 -m py_compile "${REPO_DIR}/scripts/lib/hook_config_model.py"
assert_cmd "shared setup primitives are declared" bash -c "
  source '${REPO_DIR}/scripts/setup/lib.sh'
  declare -F install_manifest_skills install_context_profiles inject_vibeguard_rules retire_legacy_codex_skills retire_bundled_codex_skill_copies clean_retired_bundled_codex_skill_copies >/dev/null
"
assert_cmd "install-state uses Python hashlib instead of shell sha tools" bash -c "
  ! grep -Eq 'shasum|sha256sum|subprocess\\.run' '${REPO_DIR}/scripts/lib/install-state.sh'
"

header "atomic writes and install-state hashing"
assert_cmd "file_ops writes and hashes atomically" python3 - <<'PY'
from pathlib import Path
from file_ops import sha256_file, write_json_atomic, write_text_atomic

root = Path(__import__("os").environ["TMP_DIR"])
text_path = root / "nested" / "file.txt"
json_path = root / "nested" / "data.json"
write_text_atomic(text_path, "abc\n")
write_json_atomic(json_path, {"ok": True})
assert text_path.read_text(encoding="utf-8") == "abc\n"
assert '"ok": true' in json_path.read_text(encoding="utf-8")
assert sha256_file(text_path) == "edeaaff3f1774ad2888673770c6d64097e391bc362d7d6fb34982ddf0efd18cb"
PY

header "retired Codex skill migration"
assert_cmd "configured CODEX_HOME selects the Codex install root" env \
  HOME="${TMP_DIR}/default-home" \
  CODEX_HOME="${TMP_DIR}/custom-codex" \
  EXPECTED_CODEX_DIR="${TMP_DIR}/custom-codex" \
  bash -c '
    source "$1/scripts/setup/lib.sh"
    test "$CODEX_DIR" = "$EXPECTED_CODEX_DIR"
  ' _ "${REPO_DIR}"

assert_cmd "retired skill enumeration avoids GNU-only find flags" bash -c '
  ! grep -Eq -- "-mindepth|-maxdepth" "$1/scripts/setup/workflow-skills.sh"
' _ "${REPO_DIR}"

assert_cmd "only untouched legacy skill copies are quarantined" bash -c '
  set -euo pipefail
  repo="$1"
  root="$2/retired-skill-migration"
  skills="$root/codex/skills"
  actual_skills="$root/codex/actual-skills"
  quarantine="$root/vibeguard/retired-codex-skills"
  source "$repo/scripts/setup/lib.sh"
  STATE_FILE="$root/install-state.json"
  STATE_PREVIOUS_FILE="$root/install-state.previous.json"
  mkdir -p "$actual_skills"
  ln -s "$actual_skills" "$skills"
  official="official legacy skill"
  for name in implx specrail-implement specrail-workflow specrail-install specrail-pr-gate; do
    mkdir -p "$skills/$name"
    printf "%s\n" "$official" > "$skills/$name/SKILL.md"
  done
  digest="$(setup_runtime_sha256_file "$skills/implx/SKILL.md")"
  retired_codex_skill_hash() { printf "%s\n" "$digest"; }
  printf "user edit\n" > "$skills/specrail-implement/SKILL.md"
  printf "user file\n" > "$skills/specrail-workflow/notes.md"
  mv "$skills/specrail-install" "$skills/specrail-install-source"
  ln -s "$skills/specrail-install-source" "$skills/specrail-install"
  unlink "$skills/specrail-pr-gate/SKILL.md"
  rmdir "$skills/specrail-pr-gate"
  printf "user-owned\n" > "$skills/specrail-pr-gate"
  mkdir -p "$quarantine/implx"
  printf "earlier backup\n" > "$quarantine/implx/SKILL.md"

  retire_legacy_codex_skills "$skills" "$quarantine"
  test -L "$skills"
  test ! -e "$skills/implx"
  test "$(cat "$quarantine/implx.1/SKILL.md")" = "$official"
  test "$(cat "$skills/specrail-implement/SKILL.md")" = "user edit"
  test -f "$skills/specrail-workflow/notes.md"
  test -L "$skills/specrail-install"
  test "$(cat "$skills/specrail-pr-gate")" = "user-owned"
' _ "${REPO_DIR}" "${TMP_DIR}"

assert_cmd "Codex setup retires legacy skills before installing active skills" python3 - <<'PY' "${REPO_DIR}"
from pathlib import Path
import sys

text = (Path(sys.argv[1]) / "scripts/setup/targets/codex-home.sh").read_text(encoding="utf-8")
call = "retire_legacy_codex_skills"
bundled_call = "retire_bundled_codex_skill_copies"
install = "install_manifest_skills"
assert call in text and bundled_call in text and install in text
assert text.index(call) < text.index(install)
assert text.index(bundled_call) < text.index(install)
PY

assert_cmd "only state-owned retired bundled Codex skill copies are quarantined" bash -c '
  set -euo pipefail
  repo="$1"
  root="$2/retired-bundled-skills"
  skills="$root/codex/skills"
  source "$repo/scripts/setup/lib.sh"
  STATE_FILE="$root/install-state.json"
  STATE_PREVIOUS_FILE="$root/install-state.previous.json"
  mkdir -p "$skills/vibeguard" "$skills/plan-flow" "$skills/fixflow"
  printf "managed\n" > "$skills/vibeguard/SKILL.md"
  printf "managed\n" > "$skills/plan-flow/SKILL.md"
  printf "user-owned\n" > "$skills/fixflow/SKILL.md"

  state_managed_tree_owned() {
    [[ "$(basename "$1")" != "fixflow" ]]
  }
  setup_runtime() {
    test "$1" = setup-state-remove-managed-tree
    dest="$4"
    mv "$dest" "$dest.retired"
    printf "QUARANTINED\t%s\n" "$dest.retired"
  }

  retire_bundled_codex_skill_copies "$skills"
  test ! -e "$skills/vibeguard"
  test ! -e "$skills/plan-flow"
  test -f "$skills/vibeguard.retired/SKILL.md"
  test -f "$skills/plan-flow.retired/SKILL.md"
  test "$(cat "$skills/fixflow/SKILL.md")" = "user-owned"
' _ "${REPO_DIR}" "${TMP_DIR}"

assert_cmd "vibeguard-runtime builds for install-state tests" cargo build --manifest-path "${REPO_DIR}/vibeguard-runtime/Cargo.toml" --quiet

assert_cmd "real retirement quarantines only exact managed copies and is repeatable" env \
  VIBEGUARD_SETUP_RUNTIME="${REPO_DIR}/vibeguard-runtime/target/debug/vibeguard-runtime" \
  bash -c '
    set -euo pipefail
    repo="$1"
    root="$2/real-retired-bundled-skills"
    skills="$root/custom-codex/skills"
    export HOME="$root/home"
    CODEX_DIR="$root/custom-codex"
    source "$repo/scripts/setup/lib.sh"
    source "$repo/scripts/lib/install-state.sh"
    STATE_FILE="$HOME/.vibeguard/install-state.json"
    STATE_PREVIOUS_FILE="$HOME/.vibeguard/install-state.previous.json"
    mkdir -p "$skills/vibeguard" "$skills/plan-flow" "$skills/fixflow" "$HOME/.vibeguard"
    printf "managed\n" > "$skills/vibeguard/SKILL.md"
    printf "modified\n" > "$skills/plan-flow/SKILL.md"
    printf "managed\n" > "$skills/fixflow/SKILL.md"
    ln -s SKILL.md "$skills/fixflow/user-link"
    python3 - "$STATE_FILE" "$skills" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

state_path = Path(sys.argv[1])
skills = Path(sys.argv[2])
managed = hashlib.sha256(b"managed\n").hexdigest()
files = {}
for name, source in (
    ("vibeguard", "skills/vibeguard"),
    ("plan-flow", "workflows/plan-flow"),
    ("fixflow", "workflows/fixflow"),
):
    files[str(skills / name / "SKILL.md")] = {
        "source": f"{source}/SKILL.md",
        "type": "copy",
        "checksum": f"sha256:{managed}",
    }
state = {
    "version": 1,
    "generation": 1,
    "complete": True,
    "profile": "core",
    "languages": [],
    "files": files,
}
state_path.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
PY

    retire_bundled_codex_skill_copies "$skills"
    retire_bundled_codex_skill_copies "$skills"
    test ! -e "$skills/vibeguard"
    test "$(cat "$skills/plan-flow/SKILL.md")" = "modified"
    test -L "$skills/fixflow/user-link"
    test "$(setup_runtime setup-state-quarantine-count "$STATE_FILE")" = "1"
  ' _ "${REPO_DIR}" "${TMP_DIR}"

INSTALL_STATE_HOME="${TMP_DIR}/install-state-home"
INSTALL_STATE_DEST="${INSTALL_STATE_HOME}/tracked.txt"
INSTALL_STATE_REPORT="${TMP_DIR}/install-state-report.txt"
mkdir -p "${INSTALL_STATE_HOME}/.vibeguard"
printf '%s' "${REPO_DIR}" > "${INSTALL_STATE_HOME}/.vibeguard/repo-path"
printf 'tracked\n' > "${INSTALL_STATE_DEST}"
assert_cmd "install-state records and detects drift with hashlib" env \
  HOME="${INSTALL_STATE_HOME}" \
  INSTALL_STATE_DEST="${INSTALL_STATE_DEST}" \
  INSTALL_STATE_REPORT="${INSTALL_STATE_REPORT}" \
  bash -c '
    set -euo pipefail
    source "$1"
    state_init core python
    state_record_file "${INSTALL_STATE_DEST}" generated/tracked.txt copy
    state_check_drift > "${INSTALL_STATE_REPORT}"
    grep -q "STATUS: CLEAN" "${INSTALL_STATE_REPORT}"
    printf changed > "${INSTALL_STATE_DEST}"
    state_check_drift > "${INSTALL_STATE_REPORT}"
    grep -q "DRIFT:" "${INSTALL_STATE_REPORT}"
  ' bash "${REPO_DIR}/scripts/lib/install-state.sh"

header "typed hook config identity"
CODEX_HOOKS="${TMP_DIR}/codex-hooks.json"
CODEX_WRAPPER="${TMP_DIR}/custom-wrapper.sh"
cat > "${CODEX_HOOKS}" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "python /tmp/user_hook.py --label vibeguard-pre-bash-guard.sh"
          }
        ]
      }
    ]
  }
}
JSON
python3 "${CODEX_HOOKS_HELPER}" upsert-vibeguard --hooks-file "${CODEX_HOOKS}" --wrapper "${CODEX_WRAPPER}" >/dev/null
python3 "${CODEX_HOOKS_HELPER}" remove-vibeguard --hooks-file "${CODEX_HOOKS}" >/dev/null
assert_cmd "Codex remove preserves user hook arguments mentioning managed names" python3 - <<'PY' "${CODEX_HOOKS}"
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
commands = [
    hook["command"]
    for entries in data.get("hooks", {}).values()
    for entry in entries
    for hook in entry.get("hooks", [])
]
assert "python /tmp/user_hook.py --label vibeguard-pre-bash-guard.sh" in commands
assert all(not (command.startswith("bash ") and "vibeguard-" in command) for command in commands)
PY

CLAUDE_SETTINGS="${TMP_DIR}/claude-settings.json"
cat > "${CLAUDE_SETTINGS}" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "python /tmp/user_hook.py --label pre-bash-guard.sh"
          }
        ]
      }
    ]
  }
}
JSON
python3 "${SETTINGS_HELPER}" upsert-vibeguard --settings-file "${CLAUDE_SETTINGS}" --repo-dir "${REPO_DIR}" --profile core >/dev/null
python3 "${SETTINGS_HELPER}" remove-vibeguard --settings-file "${CLAUDE_SETTINGS}" >/dev/null
assert_cmd "Claude remove preserves user hook arguments mentioning managed names" python3 - <<'PY' "${CLAUDE_SETTINGS}"
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
commands = [
    hook["command"]
    for entries in data.get("hooks", {}).values()
    for entry in entries
    for hook in entry.get("hooks", [])
]
assert commands == ["python /tmp/user_hook.py --label pre-bash-guard.sh"]
PY

SPACE_HOME="${TMP_DIR}/home with spaces"
mkdir -p "${SPACE_HOME}"
assert_cmd "Claude hook command quotes HOME paths with spaces" env \
  HOME="${SPACE_HOME}" \
  PYTHONPATH="${REPO_DIR}/scripts/lib:${PYTHONPATH:-}" \
  python3 - <<'PY'
import os
import shlex
import settings_json

command = settings_json._hook_command("/repo", "pre-bash-guard.sh")
parts = shlex.split(command)
assert parts == [
    "bash",
    f"{os.environ['HOME']}/.vibeguard/run-hook.sh",
    "pre-bash-guard.sh",
]
assert settings_json._is_canonical_hook_command(command, "pre-bash-guard.sh")
unquoted_command = f"bash {os.environ['HOME']}/.vibeguard/run-hook.sh pre-bash-guard.sh"
assert not settings_json._is_canonical_hook_command(unquoted_command, "pre-bash-guard.sh")
custom_bash_command = f"bash -x {os.environ['HOME']}/.vibeguard/run-hook.sh pre-bash-guard.sh"
assert not settings_json._is_canonical_hook_command(custom_bash_command, "pre-bash-guard.sh")
PY

printf '\nSetup hardening tests: %s/%s passed\n' "${PASS}" "${TOTAL}"
if [[ "${FAIL}" -ne 0 ]]; then
  exit 1
fi
