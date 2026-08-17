# Bundled-skill retirement regressions sourced by tests/test_setup_hardening.sh.

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
