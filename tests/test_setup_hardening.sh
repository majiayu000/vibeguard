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
assert_cmd "retired Codex skill helper syntax is correct" python3 -m py_compile "${REPO_DIR}/scripts/setup/retire_codex_skills.py"
assert_cmd "shared setup primitives are declared" bash -c "
  source '${REPO_DIR}/scripts/setup/lib.sh'
  declare -F install_manifest_skills install_context_profiles inject_vibeguard_rules retire_legacy_codex_skills >/dev/null
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
assert_cmd "only untouched legacy skill copies are quarantined" python3 - <<'PY' "${REPO_DIR}" "${TMP_DIR}"
import hashlib
import importlib.util
import sys
from pathlib import Path

repo = Path(sys.argv[1])
root = Path(sys.argv[2]) / "retired-skill-migration"
skills = root / "codex" / "skills"
quarantine = root / "vibeguard" / "retired-codex-skills"
official = b"official legacy skill\n"
digest = hashlib.sha256(official).hexdigest()

spec = importlib.util.spec_from_file_location(
    "retire_codex_skills", repo / "scripts/setup/retire_codex_skills.py"
)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
module.RETIRED_SKILL_HASHES = {
    "implx": digest,
    "specrail-implement": digest,
    "specrail-workflow": digest,
    "specrail-install": digest,
    "specrail-pr-gate": digest,
}

for name in module.RETIRED_SKILL_HASHES:
    (skills / name).mkdir(parents=True)
    (skills / name / "SKILL.md").write_bytes(official)
(skills / "specrail-implement" / "SKILL.md").write_text("user edit\n", encoding="utf-8")
(skills / "specrail-workflow" / "notes.md").write_text("user file\n", encoding="utf-8")
(skills / "specrail-install").rename(skills / "specrail-install-source")
(skills / "specrail-install").symlink_to(skills / "specrail-install-source", target_is_directory=True)
(skills / "specrail-pr-gate" / "SKILL.md").unlink()
(skills / "specrail-pr-gate").rmdir()
(skills / "specrail-pr-gate").write_text("user-owned\n", encoding="utf-8")
quarantine.mkdir(parents=True)
(quarantine / "implx").mkdir()
(quarantine / "implx" / "SKILL.md").write_text("earlier backup\n", encoding="utf-8")

retired, preserved = module.retire_codex_skills(skills, quarantine)
assert (retired, preserved) == (1, 4)
assert not (skills / "implx").exists()
assert (quarantine / "implx.1" / "SKILL.md").read_bytes() == official
assert (skills / "specrail-implement" / "SKILL.md").read_text() == "user edit\n"
assert (skills / "specrail-workflow" / "notes.md").is_file()
assert (skills / "specrail-install").is_symlink()
assert (skills / "specrail-pr-gate").read_text() == "user-owned\n"
PY

assert_cmd "Codex setup retires legacy skills before installing active skills" python3 - <<'PY' "${REPO_DIR}"
from pathlib import Path
import sys

text = (Path(sys.argv[1]) / "scripts/setup/targets/codex-home.sh").read_text(encoding="utf-8")
call = "retire_legacy_codex_skills"
install = "install_manifest_skills"
assert call in text and install in text
assert text.index(call) < text.index(install)
PY

assert_cmd "vibeguard-runtime builds for install-state tests" cargo build --manifest-path "${REPO_DIR}/vibeguard-runtime/Cargo.toml" --quiet

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
