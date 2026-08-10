header "Gemini CLI host adapter"

gemini_runtime="${REPO_DIR}/vibeguard-runtime/target/debug/vibeguard-runtime"
gemini_home="${TMP_HOME}/gemini-host-home"
gemini_dry_home="${TMP_HOME}/gemini-host-dry-home"
gemini_unmanaged_home="${TMP_HOME}/gemini-host-unmanaged-home"
gemini_bin_dir="${TMP_HOME}/gemini-host-bin"
mkdir -p "${gemini_home}/.gemini" "${gemini_dry_home}" "${gemini_bin_dir}"
printf '%s\n' '#!/usr/bin/env bash' '[[ "$1" == "hooks" && "$2" == "--help" ]]' \
  > "${gemini_bin_dir}/gemini"
chmod +x "${gemini_bin_dir}/gemini"
printf '%s\n' '{"theme":"custom","hooks":{"BeforeTool":[{"matcher":"read_file","hooks":[{"name":"custom","type":"command","command":"custom-hook"}]}]}}' \
  > "${gemini_home}/.gemini/settings.json"

gemini_target_script='set -euo pipefail
source "$1/scripts/setup/lib.sh"
source "$1/scripts/lib/install-state.sh"
source "$1/scripts/setup/targets/gemini-home.sh"
state_record_file() { :; }
configure_gemini_home_runtime'

gemini_install_out="$(
  HOME="${gemini_home}" \
  PATH="${gemini_bin_dir}:${PATH}" \
  VIBEGUARD_REPO_DIR="${REPO_DIR}" \
  VIBEGUARD_SETUP_RUNTIME="${gemini_runtime}" \
  VIBEGUARD_SETUP_GEMINI=1 \
  VIBEGUARD_SETUP_AUTO=1 \
  bash -c "${gemini_target_script}" _ "${REPO_DIR}" 2>&1
)"
assert_contains "${gemini_install_out}" "Gemini CLI adapter configured (CHANGED)" "Gemini target installs the adapter"
assert_cmd "Gemini wrapper is executable" test -x "${gemini_home}/.vibeguard/run-hook-gemini.sh"
assert_cmd "Gemini ownership marker is written" test -f "${gemini_home}/.vibeguard/gemini-enabled"
assert_cmd "Gemini settings preserve custom hooks and add one managed hook" python3 - \
  "${gemini_home}/.gemini/settings.json" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
entries = data["hooks"]["BeforeTool"]
hooks = [hook for entry in entries for hook in entry.get("hooks", [])]
names = [hook.get("name") for hook in hooks]
assert data["theme"] == "custom"
assert names.count("custom") == 1
assert names.count("vibeguard-before-tool") == 1
PY

gemini_reinstall_out="$(
  HOME="${gemini_home}" \
  VIBEGUARD_REPO_DIR="${REPO_DIR}" \
  VIBEGUARD_SETUP_RUNTIME="${gemini_runtime}" \
  VIBEGUARD_SETUP_GEMINI=1 \
  VIBEGUARD_SETUP_AUTO=1 \
  bash -c "${gemini_target_script}" _ "${REPO_DIR}" 2>&1
)"
assert_contains "${gemini_reinstall_out}" "Gemini CLI adapter configured (SKIP)" "Gemini target reinstall is idempotent"

gemini_check_out="$(
  HOME="${gemini_home}" \
  PATH="${gemini_bin_dir}:${PATH}" \
  VIBEGUARD_REPO_DIR="${REPO_DIR}" \
  VIBEGUARD_SETUP_RUNTIME="${gemini_runtime}" \
  bash -c 'source "$1/scripts/setup/lib.sh"; source "$1/scripts/setup/targets/gemini-home.sh"; check_gemini_home_installation' \
    _ "${REPO_DIR}" 2>&1
)"
assert_contains "${gemini_check_out}" "[OK] Gemini CLI BeforeTool adapter active" "Gemini target health check proves active configuration"

gemini_dry_out="$(
  HOME="${gemini_dry_home}" \
  VIBEGUARD_REPO_DIR="${REPO_DIR}" \
  VIBEGUARD_SETUP_RUNTIME="${gemini_runtime}" \
  VIBEGUARD_SETUP_GEMINI=1 \
  VIBEGUARD_SETUP_DRY_RUN=1 \
  bash -c "${gemini_target_script}" _ "${REPO_DIR}" 2>&1
)"
assert_contains "${gemini_dry_out}" '"matcher": "^(run_shell_command|write_file|replace)$"' "Gemini dry-run shows the exact matcher diff"
assert_cmd "Gemini dry-run does not write settings" test ! -e "${gemini_dry_home}/.gemini/settings.json"

gemini_cli_home_out="$(
  HOME="${gemini_home}" \
  GEMINI_CLI_HOME="${gemini_dry_home}" \
  VIBEGUARD_REPO_DIR="${REPO_DIR}" \
  VIBEGUARD_SETUP_RUNTIME="${gemini_runtime}" \
  VIBEGUARD_SETUP_GEMINI=1 \
  VIBEGUARD_SETUP_AUTO=1 \
  bash -c "${gemini_target_script}" _ "${REPO_DIR}" 2>&1
)"
assert_contains "${gemini_cli_home_out}" "Gemini CLI adapter configured (CHANGED)" "Gemini target honors GEMINI_CLI_HOME root semantics"
assert_cmd "GEMINI_CLI_HOME stores settings beneath its .gemini directory" \
  test -f "${gemini_dry_home}/.gemini/settings.json"

gemini_clean_out="$(
  HOME="${gemini_home}" \
  VIBEGUARD_REPO_DIR="${REPO_DIR}" \
  VIBEGUARD_SETUP_RUNTIME="${gemini_runtime}" \
  bash -c 'source "$1/scripts/setup/lib.sh"; source "$1/scripts/setup/targets/gemini-home.sh"; clean_gemini_home_installation' \
    _ "${REPO_DIR}" 2>&1
)"
assert_contains "${gemini_clean_out}" "Removed VibeGuard hook entry" "Gemini clean removes the managed entry"
assert_cmd "Gemini clean preserves custom settings and removes only VibeGuard" python3 - \
  "${gemini_home}/.gemini/settings.json" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
text = json.dumps(data)
assert data["theme"] == "custom"
assert "custom-hook" in text
assert "vibeguard-before-tool" not in text
PY
assert_cmd "Gemini clean removes wrapper" test ! -e "${gemini_home}/.vibeguard/run-hook-gemini.sh"

mkdir -p "${gemini_unmanaged_home}/.gemini"
printf '%s\n' 'not-json' > "${gemini_unmanaged_home}/.gemini/settings.json"
assert_cmd "Gemini clean ignores unmanaged settings without ownership evidence" env \
  HOME="${gemini_unmanaged_home}" \
  VIBEGUARD_REPO_DIR="${REPO_DIR}" \
  VIBEGUARD_SETUP_RUNTIME="${gemini_runtime}" \
  bash -c 'source "$1/scripts/setup/lib.sh"; source "$1/scripts/setup/targets/gemini-home.sh"; clean_gemini_home_installation' \
    _ "${REPO_DIR}"
assert_cmd "Gemini clean preserves unmanaged malformed settings byte-for-byte" \
  grep -qFx 'not-json' "${gemini_unmanaged_home}/.gemini/settings.json"
