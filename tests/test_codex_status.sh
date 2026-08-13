#!/usr/bin/env bash
# VibeGuard Codex status and semantic drift regression tests

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

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

assert_not_contains() {
  local output="$1" unexpected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if ! echo "$output" | grep -qF -- "$unexpected"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (unexpectedly contains: $unexpected)"
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

ORIG_HOME="${HOME}"
ORIG_PATH="${PATH}"
TMP_HOME="$(mktemp -d)"
REPO_GIT_HOOK_DIR="$(git -C "${REPO_DIR}" rev-parse --path-format=absolute --git-path hooks 2>/dev/null || true)"
REPO_GIT_HOOK_BACKUP="${TMP_HOME}/repo-git-hooks-backup"

backup_repo_git_hooks() {
  [[ -n "${REPO_GIT_HOOK_DIR}" ]] || return 0
  mkdir -p "${REPO_GIT_HOOK_BACKUP}"
  local hook hook_path
  for hook in pre-commit pre-push; do
    hook_path="${REPO_GIT_HOOK_DIR}/${hook}"
    if [[ -e "${hook_path}" || -L "${hook_path}" ]]; then
      cp -pP "${hook_path}" "${REPO_GIT_HOOK_BACKUP}/${hook}"
    fi
  done
}

restore_repo_git_hooks() {
  [[ -n "${REPO_GIT_HOOK_DIR}" ]] || return 0
  mkdir -p "${REPO_GIT_HOOK_DIR}"
  local hook hook_path backup_path
  for hook in pre-commit pre-push; do
    hook_path="${REPO_GIT_HOOK_DIR}/${hook}"
    backup_path="${REPO_GIT_HOOK_BACKUP}/${hook}"
    rm -f "${hook_path}"
    if [[ -e "${backup_path}" || -L "${backup_path}" ]]; then
      cp -pP "${backup_path}" "${hook_path}"
    fi
  done
}

backup_repo_git_hooks

cleanup() {
  export HOME="${ORIG_HOME}"
  export PATH="${ORIG_PATH}"
  restore_repo_git_hooks
  rm -rf "${TMP_HOME}"
}
trap cleanup EXIT

export HOME="${TMP_HOME}"
if [[ -z "${CARGO_HOME:-}" && -d "${ORIG_HOME}/.cargo" ]]; then
  export CARGO_HOME="${ORIG_HOME}/.cargo"
fi
if [[ -z "${RUSTUP_HOME:-}" && -d "${ORIG_HOME}/.rustup" ]]; then
  export RUSTUP_HOME="${ORIG_HOME}/.rustup"
fi

mkdir -p "${TMP_HOME}/bin"
cat > "${TMP_HOME}/bin/launchctl" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  print) exit 1 ;;
  *) exit 0 ;;
esac
SH
chmod +x "${TMP_HOME}/bin/launchctl"
export PATH="${TMP_HOME}/bin:${PATH}"

header "install codex fixtures"
install_out="$(bash "${REPO_DIR}/setup.sh" --yes 2>&1)"
assert_contains "${install_out}" "Setup complete! All components installed." "setup install succeeds for Codex status tests"
assert_cmd "Codex AGENTS installed" test -f "${HOME}/.codex/AGENTS.md"
assert_cmd "Codex hooks installed" test -f "${HOME}/.codex/hooks.json"
assert_cmd "Codex config installed" test -f "${HOME}/.codex/config.toml"

header "codex status is read-only and reports current state"
mkdir -p "${HOME}/.vibeguard/projects/codex-status"
printf '%s' "${REPO_DIR}" > "${HOME}/.vibeguard/projects/codex-status/.project-root"
printf '%s\n' '{"ts":"2026-05-05T00:00:00Z","cli":"codex","hook":"pre-bash-guard","decision":"pass"}' > "${HOME}/.vibeguard/projects/codex-status/events.jsonl"

agents_before="$(shasum -a 256 "${HOME}/.codex/AGENTS.md" | cut -d' ' -f1)"
hooks_before="$(shasum -a 256 "${HOME}/.codex/hooks.json" | cut -d' ' -f1)"
config_before="$(shasum -a 256 "${HOME}/.codex/config.toml" | cut -d' ' -f1)"
status_out="$(bash "${REPO_DIR}/setup.sh" --codex-status)"
agents_after="$(shasum -a 256 "${HOME}/.codex/AGENTS.md" | cut -d' ' -f1)"
hooks_after="$(shasum -a 256 "${HOME}/.codex/hooks.json" | cut -d' ' -f1)"
config_after="$(shasum -a 256 "${HOME}/.codex/config.toml" | cut -d' ' -f1)"

assert_contains "${status_out}" "VibeGuard Codex Status" "Codex status command has a clear title"
assert_contains "${status_out}" "VibeGuard-managed Codex hooks semantic check passed" "Codex status reports hook semantic health"
assert_contains "${status_out}" "Installed profile: core" "Codex status reports the installed profile"
assert_contains "${status_out}" "Codex native support: profile-selected Bash/apply_patch gates; Stop hooks only in full/strict" "Codex status reports profile-selected native support"
assert_contains "${status_out}" "Repair command: bash setup.sh --yes --profile core" "Codex status repair preserves the installed profile"
assert_contains "${status_out}" "Latest Codex event: 2026-05-05T00:00:00Z | pre-bash-guard | pass | ${REPO_DIR}" "Codex status reports latest Codex event"
assert_cmd "Codex status does not rewrite AGENTS" test "${agents_before}" = "${agents_after}"
assert_cmd "Codex status does not rewrite hooks.json" test "${hooks_before}" = "${hooks_after}"
assert_cmd "Codex status does not rewrite config.toml" test "${config_before}" = "${config_after}"

header "standalone status follows the installed physical profile"
for profile in minimal full strict; do
  profile_install_out="$(bash "${REPO_DIR}/setup.sh" --yes --profile "${profile}" 2>&1)"
  assert_contains "${profile_install_out}" "Profile: ${profile}" "${profile} install selects the requested profile"
  profile_status_out="$(bash "${REPO_DIR}/setup.sh" --codex-status 2>&1)"
  assert_contains "${profile_status_out}" "Installed profile: ${profile}" "standalone status reads ${profile} from install-state"
  assert_contains "${profile_status_out}" "VibeGuard-managed Codex hooks semantic check passed" "standalone status validates ${profile} physical hooks"
  assert_contains "${profile_status_out}" "Repair command: bash setup.sh --yes --profile ${profile}" "${profile} repair command preserves profile"
  case "${profile}" in
    minimal)
      assert_cmd "minimal physical hooks exclude Stop" bash -c "! grep -q 'vibeguard-stop-guard.sh' '${HOME}/.codex/hooks.json'"
      ;;
    full|strict)
      assert_cmd "${profile} physical hooks include post-build" grep -q 'vibeguard-post-build-check.sh' "${HOME}/.codex/hooks.json"
      assert_cmd "${profile} physical hooks include Stop" grep -q 'vibeguard-stop-guard.sh' "${HOME}/.codex/hooks.json"
      ;;
  esac
done

header "standalone status rejects malformed installed profiles"
cp "${HOME}/.vibeguard/install-state.json" "${TMP_HOME}/install-state.valid.json"
bad_profile_cases=(
  '{}'
  '[]'
  '{"profile":null}'
  '{"profile":7}'
  '{"profile":""}'
  '{"profile":"turbo"}'
)
for index in "${!bad_profile_cases[@]}"; do
  printf '%s\n' "${bad_profile_cases[$index]}" > "${HOME}/.vibeguard/install-state.json"
  set +e
  bad_status_out="$(bash "${REPO_DIR}/setup.sh" --codex-status 2>&1)"
  bad_status_rc=$?
  set -e
  assert_cmd "bad install-state case ${index} makes standalone status fail" test "${bad_status_rc}" -ne 0
  assert_contains "${bad_status_out}" "ERROR:" "bad install-state case ${index} fails visibly"
done
cp "${TMP_HOME}/install-state.valid.json" "${HOME}/.vibeguard/install-state.json"

header "setup --check downgrades semantic-only Codex drift"
cp "${HOME}/.codex/config.toml" "${TMP_HOME}/config.toml.backup"
cp "${HOME}/.codex/hooks.json" "${TMP_HOME}/hooks.json.backup"
cat >> "${HOME}/.codex/config.toml" <<'TOML'

[profiles.default]
model = "gpt-5"
TOML
python3 - <<'PY' "${HOME}/.codex/hooks.json"
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
data.setdefault("hooks", {}).setdefault("PreToolUse", []).append({
    "matcher": "Bash",
    "hooks": [{"type": "command", "command": "node /user/non-vibeguard.js"}],
})
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
drift_out="$(bash "${REPO_DIR}/setup.sh" --check)"
cp "${TMP_HOME}/config.toml.backup" "${HOME}/.codex/config.toml"
cp "${TMP_HOME}/hooks.json.backup" "${HOME}/.codex/hooks.json"

assert_contains "${drift_out}" "${HOME}/.codex/config.toml (checksum drift; Codex config semantics OK)" "semantic config drift is downgraded"
assert_contains "${drift_out}" "${HOME}/.codex/hooks.json (checksum drift; VibeGuard hook semantics OK)" "semantic hooks drift is downgraded"
assert_not_contains "${drift_out}" "DRIFT: ${HOME}/.codex/config.toml" "semantic config drift is not reported as hard drift"
assert_not_contains "${drift_out}" "DRIFT: ${HOME}/.codex/hooks.json" "semantic hooks drift is not reported as hard drift"

echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
