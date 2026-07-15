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
  if grep -qF -- "$expected" <<< "$output"; then
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
  if grep -qF -- "$unexpected" <<< "$output"; then
    red "$desc (unexpectedly contained: $unexpected)"
    FAIL=$((FAIL + 1))
  else
    green "$desc"
    PASS=$((PASS + 1))
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

file_mode() {
  local file="$1"
  if stat -f '%Lp' "${file}" >/dev/null 2>&1; then
    stat -f '%Lp' "${file}"
  else
    stat -c '%a' "${file}"
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
    [[ -e "${dest_dir}/${skill}" ]] || return 1
  done <<< "${links}"
  [[ "${found}" -eq 1 ]]
}

managed_rule_banner_count_for_test() {
  python3 - <<'PY' "$1"
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
start = text.find("<!-- vibeguard-start -->")
end = text.find("<!-- vibeguard-end -->", start)
if start == -1 or end == -1 or end <= start:
    raise SystemExit(1)
match = re.search(r"([0-9]+) rules", text[start:end])
if not match:
    raise SystemExit(1)
print(match.group(1))
PY
}

assert_runtime_config_seeded() {
  python3 - <<'PY' "${HOME}/.vibeguard/config.json"
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
checks = [
    data.get("write_mode") == "warn",
    data.get("u16", {}).get("warn_limit") == 400,
    data.get("u16", {}).get("limit") == 800,
    data.get("circuit_breaker", {}).get("threshold") == 3,
    data.get("circuit_breaker", {}).get("cooldown_seconds") == 300,
    data.get("w14", {}).get("cooldown_seconds") == 3600,
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

rule_id_count_for_test() {
  local root="$1"
  local actual=0 file_count rule_file
  while IFS= read -r rule_file; do
    file_count=$(grep -cE '^##[[:space:]]+(RS|GO|TS|PY|U|SEC|W|TASTE)-[A-Za-z0-9-]+([[:space:]:]|$)' "${rule_file}" 2>/dev/null || true)
    actual=$((actual + file_count))
  done < <(find "${root}" \( -type f -o -type l \) -name "*.md" 2>/dev/null)
  printf '%s\n' "${actual}"
}

installed_languages_for_test() {
  python3 - <<'PY' "${HOME}/.vibeguard/install-state.json"
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    raise SystemExit(1)
data = json.loads(path.read_text(encoding="utf-8"))
languages = data.get("languages") or []
print(",".join(str(item).strip() for item in languages if str(item).strip()))
PY
}

manifest_rule_count_for_test() {
  local languages="${1:-}"
  local links source_path dest_rel label total=0 file_count
  if [[ -n "${languages}" ]]; then
    links="$(python3 "${MANIFEST_HELPER}" rule-links --languages "${languages}")"
  else
    links="$(python3 "${MANIFEST_HELPER}" rule-links)"
  fi
  while IFS=$'\t' read -r source_path dest_rel label; do
    [[ -n "${source_path}" && -n "${dest_rel}" && -n "${label}" ]] || continue
    file_count=$(rule_id_count_for_test "${REPO_DIR}/${source_path}")
    total=$((total + file_count))
  done <<< "${links}"
  if [[ -d "${HOME}/.vibeguard/user-rules" ]]; then
    file_count=$(rule_id_count_for_test "${HOME}/.vibeguard/user-rules")
    total=$((total + file_count))
  fi
  printf '%s\n' "${total}"
}

expected_rule_banner_count_for_test() {
  local rules_dest="${HOME}/.claude/rules/vibeguard"
  local front_injected_count=0 label label_count languages
  for label in common golang python rust typescript taste; do
    [[ -d "${rules_dest}/${label}" ]] || continue
    label_count=$(rule_id_count_for_test "${rules_dest}/${label}")
    front_injected_count=$((front_injected_count + label_count))
  done
  if [[ "${front_injected_count}" -gt 0 ]]; then
    printf '%s\n' "${front_injected_count}"
    return
  fi
  languages="$(installed_languages_for_test 2>/dev/null || true)"
  manifest_rule_count_for_test "${languages}"
}

assert_claude_rule_banner_matches_expected_rules() {
  local actual declared
  actual=$(expected_rule_banner_count_for_test)
  declared=$(managed_rule_banner_count_for_test "${HOME}/.claude/CLAUDE.md")
  [[ "${declared}" == "${actual}" ]]
}

assert_codex_rule_banner_matches_expected_rules() {
  local actual declared
  actual=$(expected_rule_banner_count_for_test)
  declared=$(managed_rule_banner_count_for_test "${HOME}/.codex/AGENTS.md")
  [[ "${declared}" == "${actual}" ]]
}

assert_repo_git_hook_target() {
  local hook_name="$1"
  local expected="$2"
  local hook_path="${REPO_GIT_HOOK_DIR}/${hook_name}"
  [[ -n "${REPO_GIT_HOOK_DIR}" ]] || return 1
  [[ -L "${hook_path}" ]] || return 1
  [[ "$(readlink "${hook_path}")" == "${expected}" ]] || return 1
  [[ -x "${hook_path}" ]]
}

assert_scheduled_gc_absent() {
  if [[ "$(uname)" == "Darwin" ]]; then
    [[ ! -f "${HOME}/Library/LaunchAgents/com.vibeguard.gc.plist" ]] || return 1
    ! launchctl print "gui/$(id -u)/com.vibeguard.gc" >/dev/null 2>&1
  elif [[ "$(uname)" == "Linux" ]]; then
    [[ ! -f "${HOME}/.config/systemd/user/vibeguard-gc.service" ]] || return 1
    [[ ! -f "${HOME}/.config/systemd/user/vibeguard-gc.timer" ]] || return 1
    ! systemctl --user is-active vibeguard-gc.timer >/dev/null 2>&1
  else
    return 0
  fi
}

assert_scheduled_gc_present() {
  if [[ "$(uname)" == "Darwin" ]]; then
    [[ -f "${HOME}/Library/LaunchAgents/com.vibeguard.gc.plist" ]] || return 1
    launchctl print "gui/$(id -u)/com.vibeguard.gc" >/dev/null 2>&1
  elif [[ "$(uname)" == "Linux" ]]; then
    [[ -f "${HOME}/.config/systemd/user/vibeguard-gc.service" ]] || return 1
    [[ -f "${HOME}/.config/systemd/user/vibeguard-gc.timer" ]] || return 1
    systemctl --user is-active vibeguard-gc.timer >/dev/null 2>&1
  else
    return 0
  fi
}

assert_gc_checker_repo_config_pinned() {
  local outside="${TMP_HOME}/gc-conflicting-cwd" output
  mkdir -p "${outside}"
  git -C "${outside}" init -q
  printf '{"gc":{"catchup_interval_hours":1}}\n' > "${outside}/.vibeguard.json"
  printf '1999996000\n' > "${HOME}/.vibeguard/gc-last-success"
  output="$(unset VIBEGUARD_PROJECT_CONFIG VIBEGUARD_GC_CATCHUP_INTERVAL_HOURS; cd "${outside}" && VIBEGUARD_TEST_UNAME=Linux VIBEGUARD_TEST_NOW_EPOCH=2000000000 bash "${REPO_DIR}/setup.sh" --check)"
  assert_contains "${output}" "[OK] Scheduled GC execution freshness" "freshness ignores conflicting caller-CWD project config"
  assert_contains "${output}" "threshold: 604800s / 168h" "freshness defaults to scheduler checkout-root config"
}

assert_launchd_gc_edge_gates() {
  local expected="${REPO_DIR}/scripts/gc/gc-scheduled.sh" plist="${HOME}/Library/LaunchAgents/com.vibeguard.gc.plist" output
  local copy_root="${TMP_HOME}/gc-nonexec-copy" copy_expected original_mode original_digest
  original_mode="$(file_mode "${expected}")"
  original_digest="$(shasum -a 256 "${expected}" | cut -d' ' -f1)"
  mkdir -p "${HOME}/Library/LaunchAgents" "${HOME}/.vibeguard"
  touch "${HOME}/.launchctl-vibeguard-loaded"
  : > "${HOME}/.launchctl-vibeguard-target"
  output="$(VIBEGUARD_TEST_UNAME=Darwin bash "${REPO_DIR}/setup.sh" --check)"
  assert_contains "${output}" "loaded job does not declare gc-scheduled.sh" "launchd loaded job without GC argument is broken"
  assert_not_contains "${output}" "Scheduled GC execution freshness" "launchd loaded job without GC argument skips freshness"
  mkdir -p "${copy_root}"
  git -C "${REPO_DIR}" archive HEAD | tar -x -C "${copy_root}"
  copy_expected="${copy_root}/scripts/gc/gc-scheduled.sh"
  printf '%s\n' "${copy_expected}" > "${HOME}/.launchctl-vibeguard-target"
  chmod -x "${copy_expected}"
  output="$(VIBEGUARD_TEST_UNAME=Darwin bash "${copy_root}/setup.sh" --check)"
  assert_contains "${output}" "target missing or not executable: ${copy_expected}" "launchd non-executable expected target is broken"
  assert_not_contains "${output}" "Scheduled GC execution freshness" "launchd non-executable expected target skips freshness"
  assert_cmd "launchd non-executable fixture preserves scheduler mode" test "$(file_mode "${expected}")" = "${original_mode}"
  assert_cmd "launchd non-executable fixture preserves scheduler digest" test "$(shasum -a 256 "${expected}" | cut -d' ' -f1)" = "${original_digest}"
  rm -f "${HOME}/.launchctl-vibeguard-loaded" "${HOME}/.launchctl-vibeguard-target"
  sed -e "s|__VIBEGUARD_DIR__|${REPO_DIR}|g" -e "s|__HOME__|${HOME}|g" "${REPO_DIR}/scripts/setup/com.vibeguard.gc.plist" > "${plist}"
  output="$(VIBEGUARD_TEST_UNAME=Darwin bash "${REPO_DIR}/setup.sh" --check)"
  assert_contains "${output}" "plist exists but not loaded" "launchd plist-only registration remains inactive"
  assert_not_contains "${output}" "Scheduled GC execution freshness" "launchd plist-only registration skips freshness"
  touch "${HOME}/.launchctl-vibeguard-loaded"
  printf '%s\n' "${expected}" > "${HOME}/.launchctl-vibeguard-target"
  printf '1999992800\n' > "${HOME}/.vibeguard/gc-last-success"
  rm -f "${HOME}/.vibeguard/gc-launchd.log"
  printf '[ERROR] launchd shared internal failure\n' > "${HOME}/.vibeguard/gc-cron.log"
  output="$(VIBEGUARD_TEST_UNAME=Darwin VIBEGUARD_TEST_NOW_EPOCH=2000000000 VIBEGUARD_GC_CATCHUP_INTERVAL_HOURS=2 bash "${REPO_DIR}/setup.sh" --check)"
  assert_contains "${output}" "internal evidence (gc-cron.log): [ERROR] launchd shared internal failure" "launchd freshness labels shared internal GC log"
}

assert_prepare_runtime_from_source_no_cargo_metadata() {
  python3 - <<'PY' "${REPO_DIR}/scripts/setup/install.sh"
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(
    r"^prepare_runtime_from_source\(\) \{\n(?P<body>.*?)(?=^}\n\nprepare_runtime_binary\(\) \{)",
    text,
    re.MULTILINE | re.DOTALL,
)
if not match:
    raise SystemExit(1)
raise SystemExit(1 if "cargo metadata" in match.group("body") else 0)
PY
}

ORIG_HOME="${HOME}"
TMP_HOME="$(mktemp -d)"
ORIG_PATH="${PATH}"
REPO_GIT_HOOK_DIR="$(git -C "${REPO_DIR}" rev-parse --path-format=absolute --git-path hooks 2>/dev/null || true)"
REPO_GIT_HOOK_BACKUP="${TMP_HOME}/repo-git-hooks-backup"
LINKED_WORKTREE_PATH=""

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
  if [[ -n "${LINKED_WORKTREE_PATH}" ]]; then
    git -C "${REPO_DIR}" worktree remove --force "${LINKED_WORKTREE_PATH}" >/dev/null 2>&1 || true
    git -C "${REPO_DIR}" worktree prune >/dev/null 2>&1 || true
  fi
  restore_repo_git_hooks
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
REAL_UNAME="$(command -v uname)"
REAL_DATE="$(command -v date)"
REAL_CARGO="$(command -v cargo || true)"
cat > "${TMP_HOME}/bin/uname" <<SH
#!/usr/bin/env bash
if [[ "\${VIBEGUARD_TEST_UNAME:-}" == "Linux" || "\${VIBEGUARD_TEST_UNAME:-}" == "Darwin" ]]; then
  case "\${1:-}" in
    -m)
      printf '%s\n' "\${VIBEGUARD_TEST_UNAME_M:-x86_64}"
      ;;
    -s|"")
      printf '%s\n' "\${VIBEGUARD_TEST_UNAME}"
      ;;
    *)
      exec "${REAL_UNAME}" "\$@"
      ;;
  esac
else
  exec "${REAL_UNAME}" "\$@"
fi
SH
chmod +x "${TMP_HOME}/bin/uname"
cat > "${TMP_HOME}/bin/date" <<SH
#!/usr/bin/env bash
if [[ "\${1:-}" == "+%s" && -n "\${VIBEGUARD_TEST_NOW_EPOCH:-}" ]]; then
  printf '%s\n' "\${VIBEGUARD_TEST_NOW_EPOCH}"
  exit 0
fi
exec "${REAL_DATE}" "\$@"
SH
chmod +x "${TMP_HOME}/bin/date"
cat > "${TMP_HOME}/bin/cargo" <<SH
#!/usr/bin/env bash
if [[ "\${VIBEGUARD_TEST_CARGO_UNAVAILABLE:-0}" == "1" ]]; then
  printf 'cargo unavailable for test\n' >&2
  exit 127
fi
if [[ -n "\${VIBEGUARD_TEST_CARGO_LOG:-}" ]]; then
  printf '%s\n' "\$*" >> "\${VIBEGUARD_TEST_CARGO_LOG}"
fi
if [[ -z "${REAL_CARGO}" ]]; then
  printf 'real cargo not found\n' >&2
  exit 127
fi
exec "${REAL_CARGO}" "\$@"
SH
chmod +x "${TMP_HOME}/bin/cargo"
cat > "${TMP_HOME}/bin/launchctl" <<'SH'
#!/usr/bin/env bash
state="${HOME}/.launchctl-vibeguard-loaded"
target_state="${HOME}/.launchctl-vibeguard-target"
plist_state="${HOME}/.launchctl-vibeguard-plist"
plist_gc_script_path() {
  local plist="$1"
  [[ -f "$plist" ]] || return 1
  awk '
    /<key>ProgramArguments<\/key>/ { in_args = 1; next }
    in_args && /<\/array>/ { exit }
    in_args && /gc-scheduled\.sh/ {
      line = $0
      sub(/^.*<string>/, "", line)
      sub(/<\/string>.*$/, "", line)
      print line
      exit
    }
  ' "$plist"
}
case "${1:-}" in
  bootstrap)
    plist="${3:-}"
    if [[ -f "$plist" ]]; then
      plist_gc_script_path "$plist" > "$target_state" || : > "$target_state"
      printf '%s\n' "$plist" > "$plist_state"
    else
      : > "$target_state"
      : > "$plist_state"
    fi
    touch "$state"
    exit 0
    ;;
  bootout)
    rm -f "$state" "$target_state" "$plist_state"
    exit 0
    ;;
  print)
    [[ -f "$state" ]] || exit 113
    target="$(cat "$target_state" 2>/dev/null || true)"
    plist="$(cat "$plist_state" 2>/dev/null || true)"
    [[ -n "$plist" ]] || plist="${HOME}/Library/LaunchAgents/com.vibeguard.gc.plist"
    cat <<EOF
gui/$(id -u)/com.vibeguard.gc = {
	path = $plist
	type = LaunchAgent
	state = not running

	program = /bin/bash
	arguments = {
		/bin/bash
EOF
    [[ -n "$target" ]] && printf '\t\t%s\n' "$target"
    cat <<EOF
		--scheduled
	}
}
EOF
    exit 0
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
cat > "${TMP_HOME}/bin/systemctl" <<'SH'
#!/usr/bin/env bash
state="${HOME}/.systemctl-vibeguard-gc-active"
if [[ "${1:-}" == "--user" ]]; then
  shift
fi
case "${1:-}" in
  daemon-reload)
    exit 0
    ;;
  enable)
    if [[ "${2:-}" == "--now" && "${3:-}" == "vibeguard-gc.timer" ]]; then
      if [[ "${VIBEGUARD_TEST_SYSTEMD_ENABLE_FAIL:-0}" == "1" ]]; then
        exit 1
      fi
      touch "$state"
    fi
    exit 0
    ;;
  start)
    if [[ "${2:-}" == "vibeguard-gc.timer" ]]; then
      touch "$state"
    fi
    exit 0
    ;;
  stop|disable)
    rm -f "$state"
    exit 0
    ;;
  is-active)
    [[ "${2:-}" == "vibeguard-gc.timer" && -f "$state" ]] && exit 0
    exit 3
    ;;
  status)
    [[ "${2:-}" == "vibeguard-gc.timer" && -f "$state" ]] && exit 0
    exit 3
    ;;
  list-timers)
    if [[ -f "$state" ]]; then
      printf 'NEXT LEFT LAST PASSED UNIT ACTIVATES\n'
      printf 'Sun 03:00 - - - vibeguard-gc.timer vibeguard-gc.service\n'
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
SH
chmod +x "${TMP_HOME}/bin/systemctl"
cat > "${TMP_HOME}/bin/gh" <<'SH'
#!/usr/bin/env bash
if [[ "${VIBEGUARD_TEST_DOWNLOAD_FAIL:-0}" == "1" || "${VIBEGUARD_TEST_GH_FAIL:-0}" == "1" ]]; then
  exit 1
fi
if [[ "${1:-}" == "attestation" && "${2:-}" == "verify" ]]; then
  if [[ "${3:-}" == "--help" ]]; then
    [[ "${VIBEGUARD_TEST_ATTESTATION_AVAILABLE:-0}" == "1" ]]
    exit $?
  fi
  [[ "${VIBEGUARD_TEST_ATTESTATION_OK:-0}" == "1" ]]
  exit $?
fi
if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
  [[ "${VIBEGUARD_TEST_GH_AUTH_OK:-0}" == "1" ]]
  exit $?
fi
if [[ "${1:-}" == "release" && "${2:-}" == "download" ]]; then
  shift 2
  tag="${1:-}"
  shift || true
  dir="."
  patterns=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir)
        dir="$2"; shift 2 ;;
      --pattern)
        patterns+=("$2"); shift 2 ;;
      --repo)
        shift 2 ;;
      *)
        shift ;;
    esac
  done
  [[ -n "${tag}" && -n "${VIBEGUARD_TEST_RELEASE_DIR:-}" ]] || exit 1
  if [[ -n "${VIBEGUARD_TEST_DOWNLOAD_LOG:-}" ]]; then
    printf 'gh tag=%s patterns=%s\n' "${tag}" "${patterns[*]}" >> "${VIBEGUARD_TEST_DOWNLOAD_LOG}"
  fi
  mkdir -p "${dir}"
  for pattern in "${patterns[@]}"; do
    if [[ "${pattern}" == "SHA256SUMS" && "${VIBEGUARD_TEST_BAD_SHA:-0}" == "1" ]]; then
      cp "${VIBEGUARD_TEST_RELEASE_DIR}/SHA256SUMS.bad" "${dir}/SHA256SUMS"
    elif [[ "${pattern}" == "vibeguard-runtime-releases.json" && "${VIBEGUARD_TEST_BAD_MANIFEST:-0}" == "1" ]]; then
      cp "${VIBEGUARD_TEST_RELEASE_DIR}/vibeguard-runtime-releases.bad.json" "${dir}/vibeguard-runtime-releases.json"
    elif [[ "${pattern}" == "vibeguard-runtime-releases.json" && "${VIBEGUARD_TEST_BAD_MANIFEST_SIZE:-0}" == "1" ]]; then
      cp "${VIBEGUARD_TEST_RELEASE_DIR}/vibeguard-runtime-releases.bad-size.json" "${dir}/vibeguard-runtime-releases.json"
    elif [[ "${pattern}" == "vibeguard-runtime-releases.json" && -f "${VIBEGUARD_TEST_RELEASE_DIR}/vibeguard-runtime-releases.${tag}.json" ]]; then
      cp "${VIBEGUARD_TEST_RELEASE_DIR}/vibeguard-runtime-releases.${tag}.json" "${dir}/vibeguard-runtime-releases.json"
    else
      cp "${VIBEGUARD_TEST_RELEASE_DIR}/${pattern}" "${dir}/${pattern}"
    fi
  done
  exit 0
fi
exit 1
SH
chmod +x "${TMP_HOME}/bin/gh"
cat > "${TMP_HOME}/bin/curl" <<'SH'
#!/usr/bin/env bash
if [[ "${VIBEGUARD_TEST_DOWNLOAD_FAIL:-0}" == "1" ]]; then
  exit 22
fi
out=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      out="$2"; shift 2 ;;
    -*)
      shift ;;
    *)
      url="$1"; shift ;;
  esac
done
[[ -n "${out}" && -n "${url}" && -n "${VIBEGUARD_TEST_RELEASE_DIR:-}" ]] || exit 1
asset="${url##*/}"
if [[ -n "${VIBEGUARD_TEST_DOWNLOAD_LOG:-}" ]]; then
  printf 'curl url=%s asset=%s\n' "${url}" "${asset}" >> "${VIBEGUARD_TEST_DOWNLOAD_LOG}"
fi
mkdir -p "$(dirname "${out}")"
if [[ "${asset}" == "SHA256SUMS" && "${VIBEGUARD_TEST_BAD_SHA:-0}" == "1" ]]; then
  cp "${VIBEGUARD_TEST_RELEASE_DIR}/SHA256SUMS.bad" "${out}"
elif [[ "${asset}" == "vibeguard-runtime-releases.json" && "${VIBEGUARD_TEST_BAD_MANIFEST:-0}" == "1" ]]; then
  cp "${VIBEGUARD_TEST_RELEASE_DIR}/vibeguard-runtime-releases.bad.json" "${out}"
elif [[ "${asset}" == "vibeguard-runtime-releases.json" && "${VIBEGUARD_TEST_BAD_MANIFEST_SIZE:-0}" == "1" ]]; then
  cp "${VIBEGUARD_TEST_RELEASE_DIR}/vibeguard-runtime-releases.bad-size.json" "${out}"
else
  cp "${VIBEGUARD_TEST_RELEASE_DIR}/${asset}" "${out}"
fi
SH
chmod +x "${TMP_HOME}/bin/curl"
export PATH="${TMP_HOME}/bin:${PATH}"

TEST_RELEASE_DIR="${TMP_HOME}/release-assets"
mkdir -p "${TEST_RELEASE_DIR}"
cargo build --manifest-path "${REPO_DIR}/vibeguard-runtime/Cargo.toml" >/dev/null
: > "${TEST_RELEASE_DIR}/SHA256SUMS"
for target in \
  aarch64-apple-darwin \
  x86_64-apple-darwin \
  x86_64-unknown-linux-musl \
  aarch64-unknown-linux-musl; do
  asset="${TEST_RELEASE_DIR}/vibeguard-runtime-${target}"
cat > "${asset}" <<SH
#!/usr/bin/env bash
set -euo pipefail
REAL_RUNTIME="${REPO_DIR}/vibeguard-runtime/target/debug/vibeguard-runtime"
if [[ "\${1:-}" == "version" && -n "\${VIBEGUARD_TEST_RUNTIME_VERSION:-}" ]]; then
  printf '%s\n' "\${VIBEGUARD_TEST_RUNTIME_VERSION#v}"
  exit 0
fi
if [[ "\${1:-}" == "version" && -n "\${VIBEGUARD_SETUP_RUNTIME_VERSION:-}" ]]; then
  printf '%s\n' "\${VIBEGUARD_SETUP_RUNTIME_VERSION#v}"
  exit 0
fi
if [[ -x "\${REAL_RUNTIME}" ]]; then
  exec "\${REAL_RUNTIME}" "\$@"
fi
case "\${1:-}" in
  project-config-validate)
    if [[ \$# -ne 2 ]]; then
      printf 'Usage: vibeguard-runtime project-config-validate <config-file>\\n' >&2
      exit 2
    fi
    exec python3 "${PROJECT_CONFIG_HELPER}" --quiet "\${2}" "${REPO_DIR}/schemas/vibeguard-project.schema.json"
    ;;
  project-config-value)
    if [[ \$# -ne 4 ]]; then
      printf 'Usage: vibeguard-runtime project-config-value <config-file> <json-path> <default>\\n' >&2
      exit 2
    fi
    config_file="\${2}"
    key_path="\${3}"
    default_value="\${4}"
    python3 "${PROJECT_CONFIG_HELPER}" --quiet "\${config_file}" "${REPO_DIR}/schemas/vibeguard-project.schema.json"
    python3 - "\${config_file}" "\${key_path}" "\${default_value}" <<'PY'
import json
import sys
from pathlib import Path

config_file, key_path, default_value = sys.argv[1:4]
try:
    value = json.loads(Path(config_file).read_text(encoding="utf-8"))
except Exception as exc:
    print(f"VibeGuard project config read failed: {config_file}: {exc}", file=sys.stderr)
    raise SystemExit(1)
for part in key_path.split("."):
    if not isinstance(value, dict) or part not in value:
        print(default_value)
        raise SystemExit(0)
    value = value[part]
if isinstance(value, bool) or value is None or isinstance(value, (dict, list)):
    print(default_value)
else:
    print(value)
PY
    ;;
  *)
    exit 0
    ;;
esac
SH
  chmod +x "${asset}"
  asset_hash="$(shasum -a 256 "${asset}" | cut -d' ' -f1)"
  printf '%s  %s\n' "${asset_hash}" "vibeguard-runtime-${target}" >> "${TEST_RELEASE_DIR}/SHA256SUMS"
done
python3 - <<'PY' "${TEST_RELEASE_DIR}/SHA256SUMS" "${TEST_RELEASE_DIR}/SHA256SUMS.bad"
from pathlib import Path
import sys

src = Path(sys.argv[1])
dest = Path(sys.argv[2])
lines = src.read_text(encoding="utf-8").splitlines()
bad_lines = []
for line in lines:
    digest, asset = line.split(None, 1)
    bad_lines.append("0" * len(digest) + "  " + asset)
lines = bad_lines
dest.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
python3 "${REPO_DIR}/scripts/ci/generate_runtime_release_manifest.py" \
  "$(tr -d '[:space:]' < "${REPO_DIR}/vibeguard-runtime/VERSION")" \
  "${TEST_RELEASE_DIR}" \
  "${TEST_RELEASE_DIR}/vibeguard-runtime-releases.json" \
  "majiayu000/vibeguard"
python3 "${REPO_DIR}/scripts/ci/generate_runtime_release_manifest.py" \
  "9.9.9" \
  "${TEST_RELEASE_DIR}" \
  "${TEST_RELEASE_DIR}/vibeguard-runtime-releases.v9.9.9.json" \
  "majiayu000/vibeguard"
python3 - <<'PY' "${TEST_RELEASE_DIR}/vibeguard-runtime-releases.json" "${TEST_RELEASE_DIR}/vibeguard-runtime-releases.bad.json" "${TEST_RELEASE_DIR}/vibeguard-runtime-releases.bad-size.json"
import json
import sys
from pathlib import Path

src = Path(sys.argv[1])
checksum_dest = Path(sys.argv[2])
size_dest = Path(sys.argv[3])
manifest = json.loads(src.read_text(encoding="utf-8"))
bad_checksum_manifest = json.loads(json.dumps(manifest))
for asset in bad_checksum_manifest["assets"].values():
    asset["sha256"] = "1" * 64
checksum_dest.write_text(json.dumps(bad_checksum_manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
bad_size_manifest = json.loads(json.dumps(manifest))
for asset in bad_size_manifest["assets"].values():
    asset["size"] += 1
size_dest.write_text(json.dumps(bad_size_manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
export VIBEGUARD_TEST_RELEASE_DIR="${TEST_RELEASE_DIR}"

assert_cmd "quiet runtime download rejects manifest size mismatch" bash -c '
  set -euo pipefail
  repo_dir="$1"
  tmp_home="$2"
  mkdir -p "${tmp_home}/quiet-size-mismatch-home"
  export HOME="${tmp_home}/quiet-size-mismatch-home"
  export VIBEGUARD_REPO_DIR="${repo_dir}"
  export VIBEGUARD_TEST_BAD_MANIFEST_SIZE=1
  source "${repo_dir}/scripts/setup/lib.sh"
  target="$(setup_runtime_release_target)"
  tag="$(setup_runtime_release_tag)"
  dest="${tmp_home}/quiet-size-mismatch-runtime"
  ! setup_download_prebuilt_runtime_quiet "${target}" "${tag}" "${dest}"
  test ! -e "${dest}"
' _ "${REPO_DIR}" "${TMP_HOME}"


for setup_test in \
  "${REPO_DIR}/tests/setup/syntax_manifest_tests.sh" \
  "${REPO_DIR}/tests/setup/install_flow_tests.sh" \
  "${REPO_DIR}/tests/setup/protection_clean_tests.sh" \
  "${REPO_DIR}/tests/setup/profile_flow_tests.sh"; do
  # shellcheck source=/dev/null
  source "${setup_test}"
done

echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
