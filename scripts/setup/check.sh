#!/usr/bin/env bash
# VibeGuard installation health check.
#
# Modes
#   bash setup.sh --check                # full report (default, exit always 0)
#   bash setup.sh --check --strict       # exit 1/2 on warnings/problems
#   bash setup.sh --check --quiet        # only show problem rows + summary
#   bash setup.sh --check --json         # machine-readable JSON, no TTY output
#   bash setup.sh --check --no-summary   # legacy behavior (no rollup, exit 0)
#   bash setup.sh --check --install      # install final verification, fail on broken required state
#
# Exit code
#   Default mode  : 0 always (backward compatible with pre-summary callers).
#   --strict      : 0 healthy, 1 degraded (warn only), 2 broken (FAIL/BROKEN/MISSING).
#   --json        : implies --strict (machine consumers want a real exit code).
#   --no-summary  : 0 always.
#   --install     : 0 healthy/degraded, 2 broken required state.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=../lib/install-state.sh
source "${SCRIPT_DIR}/../lib/install-state.sh"
# shellcheck source=../lib/project_config.sh
source "${SCRIPT_DIR}/../lib/project_config.sh"
# shellcheck source=../lib/status_report.sh
source "${SCRIPT_DIR}/../lib/status_report.sh"
# shellcheck source=targets/claude-home.sh
source "${SCRIPT_DIR}/targets/claude-home.sh"
# shellcheck source=targets/codex-home.sh
source "${SCRIPT_DIR}/targets/codex-home.sh"

# --- Argument parsing ---
QUIET=0
JSON=0
STRICT=0
WITH_SUMMARY=1
INSTALL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiet|-q)     QUIET=1; shift ;;
    --json)         JSON=1; shift ;;
    --strict)       STRICT=1; shift ;;
    --install)      INSTALL=1; shift ;;
    --no-summary)   WITH_SUMMARY=0; shift ;;
    --help|-h)
      cat <<'USAGE'
Usage: setup.sh --check [--quiet | --json | --strict | --install | --no-summary]

  --quiet        Suppress healthy [OK] rows; only print problems + summary.
  --strict       Reflect health in the exit code: 0 healthy, 1 degraded,
                 2 broken (FAIL/BROKEN/MISSING). Without --strict the exit
                 code is always 0 for backwards compatibility.
  --install      Final install verification mode: exit 2 on broken required
                 state, but allow WARN/INFO rows for optional integrations.
  --json         Emit a single-line JSON document (counts + events + verdict)
                 to stdout. Disables human-readable output. Implies --strict.
  --no-summary   Legacy mode: no rollup table, always exit 0.
                 Equivalent to the pre-summary behavior.

Exit codes (--strict / --json / --install only):
  0  healthy
  1  degraded (warnings only; --strict/--json)
  2  broken (FAIL/BROKEN/MISSING present)
USAGE
      exit 0
      ;;
    *)
      red "ERROR: unknown argument to --check: $1"
      exit 64
      ;;
  esac
done

# --json implies --strict so machine consumers always get a real exit code.
if [[ "${JSON}" -eq 1 ]]; then
  STRICT=1
fi

# Conflict detection — pick one output style.
if [[ "${JSON}" -eq 1 && "${QUIET}" -eq 1 ]]; then
  red "ERROR: --json and --quiet are mutually exclusive"
  exit 64
fi
if [[ "${JSON}" -eq 1 && "${WITH_SUMMARY}" -eq 0 ]]; then
  red "ERROR: --json and --no-summary are mutually exclusive"
  exit 64
fi
if [[ "${JSON}" -eq 1 && "${INSTALL}" -eq 1 ]]; then
  red "ERROR: --json and --install are mutually exclusive"
  exit 64
fi

_check_repo_git_hook() {
  local hook_name="$1"
  local expected_target="$2"
  local hook_path="${_vg_hook_dir}/${hook_name}"

  if [[ ! -e "${hook_path}" && ! -L "${hook_path}" ]]; then
    red "[MISSING] VibeGuard repo ${hook_name} hook (${hook_path})"
    return 0
  fi
  if [[ ! -L "${hook_path}" ]]; then
    red "[BROKEN] VibeGuard repo ${hook_name} hook is not a symlink: ${hook_path}"
    return 0
  fi

  local actual_target
  actual_target="$(readlink "${hook_path}" 2>/dev/null || true)"
  if [[ -z "${actual_target}" ]]; then
    red "[BROKEN] VibeGuard repo ${hook_name} hook target cannot be read: ${hook_path}"
    return 0
  fi
  if [[ "${actual_target}" != "${expected_target}" ]]; then
    red "[BROKEN] VibeGuard repo ${hook_name} hook target drift: ${actual_target} (expected: ${expected_target})"
    return 0
  fi
  if [[ ! -e "${hook_path}" ]]; then
    red "[BROKEN] VibeGuard repo ${hook_name} hook target missing: ${actual_target}"
    return 0
  fi
  if [[ ! -x "${hook_path}" ]]; then
    red "[BROKEN] VibeGuard repo ${hook_name} hook target not executable: ${actual_target}"
    return 0
  fi
  if [[ "${hook_name}" == "pre-push" && "${expected_target}" == "${HOME}/.vibeguard/pre-push" ]]; then
    local wrapper_repo_path="${HOME}/.vibeguard/repo-path"
    local wrapper_repo=""
    local wrapper_source=""
    if [[ -f "${wrapper_repo_path}" ]]; then
      wrapper_repo="$(<"${wrapper_repo_path}")"
    fi
    wrapper_source="${wrapper_repo}/hooks/git/pre-push"
    if [[ -z "${wrapper_repo}" || ! -f "${wrapper_source}" ]]; then
      red "[BROKEN] VibeGuard repo pre-push hook wrapper source missing: ${wrapper_source}"
      return 0
    fi
    if [[ ! -r "${wrapper_source}" ]]; then
      red "[BROKEN] VibeGuard repo pre-push hook wrapper source not readable: ${wrapper_source}"
      return 0
    fi
  fi

  green "[OK] VibeGuard repo ${hook_name} hook installed"
}

_check_installed_snapshot_version() {
  local version_file="${HOME}/.vibeguard/installed/version"
  local installed_version=""
  local repo_version=""

  if [[ ! -f "${version_file}" ]]; then
    yellow "[WARN] Installed hooks+guards snapshot version missing (${version_file}); run: bash setup.sh --yes"
    return 0
  fi

  installed_version="$(tr -d '[:space:]' < "${version_file}")"
  repo_version="$(git -C "${REPO_DIR}" rev-parse --short HEAD 2>/dev/null || true)"

  if [[ -z "${repo_version}" ]]; then
    yellow "[INFO] Installed hooks+guards snapshot version: ${installed_version:-unknown} (repo HEAD unavailable)"
    return 0
  fi
  if [[ -z "${installed_version}" ]]; then
    yellow "[WARN] Installed hooks+guards snapshot version empty (${version_file}); run: bash setup.sh --yes"
    return 0
  fi
  if [[ "${installed_version}" != "${repo_version}" ]]; then
    yellow "[WARN] Installed hooks+guards snapshot is stale: ${installed_version} (current repo: ${repo_version}; run: bash setup.sh --yes)"
    return 0
  fi

  green "[OK] Installed hooks+guards snapshot matches repo HEAD (${repo_version})"
}

# run_legacy_checks
#   The original sequence of inline probes. Each probe prints a single
#   `[LEVEL] message` line via green/yellow/red. We do not reorder or
#   rewrite these — the test suite and downstream tooling grep them.
run_legacy_checks() {
  echo "VibeGuard Installation Status"
  echo "=============================="

  # Check hook wrapper
  VIBEGUARD_HOME="${HOME}/.vibeguard"
  if [[ -f "${VIBEGUARD_HOME}/repo-path" ]] && [[ -f "${VIBEGUARD_HOME}/run-hook.sh" ]]; then
    _repo=$(<"${VIBEGUARD_HOME}/repo-path")
    if [[ -d "$_repo/hooks" ]]; then
      green "[OK] Hook wrapper ready (repo: ${_repo})"
    else
      red "[BROKEN] repo-path points to missing directory: ${_repo}"
    fi
  else
    yellow "[MISSING] Hook wrapper not installed (~/.vibeguard/run-hook.sh)"
  fi
  if [[ -x "${VIBEGUARD_HOME}/installed/bin/vibeguard-runtime" ]]; then
    green "[OK] vibeguard-runtime runtime binary installed"
    _check_installed_snapshot_version
  else
    red "[MISSING] vibeguard-runtime runtime binary (~/.vibeguard/installed/bin/vibeguard-runtime)"
  fi

  check_claude_home_installation

  # Check scheduled GC
  if [[ "$(uname)" == "Darwin" ]]; then
    if launchctl print "gui/$(id -u)/com.vibeguard.gc" &>/dev/null; then
      green "[OK] Scheduled GC active via launchd (com.vibeguard.gc)"
    elif [[ -f "${HOME}/Library/LaunchAgents/com.vibeguard.gc.plist" ]]; then
      yellow "[WARN] Scheduled GC plist exists but not loaded"
    else
      yellow "[INFO] Scheduled GC not installed (optional)"
    fi
  elif [[ "$(uname)" == "Linux" ]] && command -v systemctl &>/dev/null; then
    if systemctl --user is-active vibeguard-gc.timer &>/dev/null; then
      green "[OK] Scheduled GC active via systemd (vibeguard-gc.timer)"
    elif [[ -f "${HOME}/.config/systemd/user/vibeguard-gc.timer" ]]; then
      yellow "[WARN] Scheduled GC unit exists but timer not active"
    else
      yellow "[INFO] Scheduled GC not installed (optional, run: bash scripts/install-systemd.sh)"
    fi
  fi

  check_codex_home_installation

  # Check repository git hooks used by VibeGuard's own development workflow.
  echo
  echo "Repository Git Hooks"
  echo "------------------------------"
  if _vg_hook_dir="$(git -C "${REPO_DIR}" rev-parse --path-format=absolute --git-path hooks 2>/dev/null)"; then
    _check_repo_git_hook "pre-commit" "${HOME}/.vibeguard/pre-commit"
    _check_repo_git_hook "pre-push" "${HOME}/.vibeguard/pre-push"
  else
    yellow "[INFO] Repository git hooks not checked (not a git repository)"
  fi

  # Check project-level runtime config
  echo
  echo "Project Config"
  echo "------------------------------"
  project_config_file="$(vg_project_config_file)"
  if [[ -z "${project_config_file}" || ! -f "${project_config_file}" ]]; then
    yellow "[INFO] No project config found (.vibeguard.json optional)"
  else
    if project_config_out="$(vg_validate_project_config "${project_config_file}" 2>&1)"; then
      green "[OK] Project config valid (${project_config_file})"
    else
      red "[FAIL] Project config invalid (${project_config_file})"
      while IFS= read -r line; do
        red "  ${line}"
      done <<< "${project_config_out}"
    fi
  fi

  # Check AUTO_RUN_AGENT_DIR
  if [[ -n "${AUTO_RUN_AGENT_DIR:-}" ]] && [[ -d "${AUTO_RUN_AGENT_DIR}" ]]; then
    green "[OK] AUTO_RUN_AGENT_DIR=${AUTO_RUN_AGENT_DIR}"
  else
    yellow "[INFO] AUTO_RUN_AGENT_DIR not set (auto-optimize Phase 4 requires it)"
  fi

  # Check ast-grep (required by TS and Rust AST-level guards)
  if command -v ast-grep >/dev/null 2>&1; then
    green "[OK] ast-grep: $(ast-grep --version 2>/dev/null | head -1)"
  else
    yellow "[MISSING] ast-grep not installed — TS/Rust AST guards will SKIP (install: brew install ast-grep)"
  fi

  # Check TypeScript guards
  for guard in check_any_abuse.sh check_console_residual.sh common.sh; do
    if [[ -x "${REPO_DIR}/guards/typescript/${guard}" ]]; then
      green "[OK] TypeScript guard: ${guard}"
    else
      red "[MISSING] TypeScript guard: ${guard}"
    fi
  done

  # Check Codex CLI (optional)
  if command -v codex &>/dev/null; then
    green "[OK] Codex CLI available (enables /vibeguard:cross-review)"
  else
    yellow "[INFO] Codex CLI not found (install: npm i -g @openai/codex for /vibeguard:cross-review)"
  fi

  # Check install state (drift detection)
  echo
  echo "Install State"
  echo "------------------------------"
  drift_output=$(state_check_drift 2>/dev/null)
  if [[ "$drift_output" == "NO_STATE" ]]; then
    yellow "[INFO] No install state found (re-run setup.sh to enable state tracking)"
  elif echo "$drift_output" | grep -q "STATUS: CLEAN"; then
    tracked=$(echo "$drift_output" | grep "Total tracked" | head -1)
    green "[OK] ${tracked}"
  else
    _hard_drift=0
    _semantic_drift=0
    while IFS= read -r line; do
      [[ "${line}" =~ ^(MISSING|DRIFT): ]] || continue
      _drift_path="${line#*: }"
      _drift_path="${_drift_path%% (*}"
      if [[ "${line}" == DRIFT:* ]] && _semantic_msg="$(codex_semantic_drift_message "${_drift_path}" 2>/dev/null)"; then
        yellow "  INFO: ${_semantic_msg}"
        _semantic_drift=1
      else
        red "  ${line}"
        _hard_drift=1
      fi
    done <<< "${drift_output}"
    if [[ "${_hard_drift}" -eq 1 ]]; then
      yellow "[WARN] Run 'bash setup.sh' to repair drifted files"
    elif [[ "${_semantic_drift}" -eq 1 ]]; then
      yellow "[INFO] Install-state checksum drift is semantic-only for shared Codex files"
    fi
  fi

  # Check awk POSIX compliance (BSD awk has no \s \d \w \b)
  echo
  echo "Guard Script Portability"
  echo "------------------------------"
  _awk_violations=$(create_tmpfile 2>/dev/null || mktemp)
  # Detect non-POSIX regex shortcuts only in awk command contexts. Python
  # heredocs and quoted Python regexes may legitimately use \s, \d, \w, or \b.
  python3 - <<'PY' "${REPO_DIR}/guards" > "$_awk_violations" 2>/dev/null || true
from __future__ import annotations

import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
awk_word = re.compile(r"\b(?:awk|gawk|mawk|nawk)\b")
non_posix = re.compile(r"/[^/\"']*\\[sdwb][^/\"']*/")

for path in sorted(root.rglob("*.sh")):
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        continue

    in_awk_program = False
    quote = ""
    for line_no, line in enumerate(lines, 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue

        inspect_line = False
        if in_awk_program:
            inspect_line = True
            if quote and quote in line:
                in_awk_program = False
                quote = ""
        elif awk_word.search(line):
            inspect_line = True
            after_awk = awk_word.split(line, maxsplit=1)[1]
            single_count = after_awk.count("'")
            double_count = after_awk.count('"')
            if single_count % 2 == 1:
                in_awk_program = True
                quote = "'"
            elif double_count % 2 == 1:
                in_awk_program = True
                quote = '"'

        if inspect_line and non_posix.search(line):
            print(f"{path}:{line_no}:{line}")
PY
  if [[ -s "$_awk_violations" ]]; then
    count=$(wc -l < "$_awk_violations" | tr -d ' ')
    red "[FAIL] ${count} awk line(s) use non-POSIX regex (\\s \\d \\w \\b — breaks on BSD awk):"
    while IFS= read -r v; do
      red "  ${v}"
    done < "$_awk_violations"
  else
    green "[OK] All awk blocks use POSIX-compatible regex"
  fi
  rm -f "$_awk_violations" 2>/dev/null || true
}

# --- Capture and dispatch ---
# We capture stdout once, mirror it (or suppress it for --json/--quiet),
# then post-process for the summary, JSON, and exit code.
capture_buf="$(mktemp -t vg-status-buf.XXXXXX 2>/dev/null || mktemp)"
trap 'rm -f "${capture_buf}" 2>/dev/null || true' EXIT
status_init "${capture_buf}"

if [[ "${JSON}" -eq 1 ]]; then
  # JSON mode: probe output goes only to the buffer; nothing leaks to stdout.
  run_legacy_checks > "${capture_buf}" 2>&1
elif [[ "${QUIET}" -eq 1 ]]; then
  # Quiet mode: capture everything, then re-emit only problems + summary.
  run_legacy_checks > "${capture_buf}" 2>&1
else
  # Default mode: stream to user AND capture for the summary.
  run_legacy_checks 2>&1 | tee "${capture_buf}"
fi

status_record_buffer

if [[ "${JSON}" -eq 1 ]]; then
  status_emit_json
  exit "$(status_exit_code)"
fi

if [[ "${WITH_SUMMARY}" -eq 1 ]]; then
  if [[ "${QUIET}" -eq 1 ]]; then
    status_print_summary --quiet
  else
    status_print_summary
  fi
  if [[ "${STRICT}" -eq 1 ]]; then
    exit "$(status_exit_code)"
  fi
  if [[ "${INSTALL}" -eq 1 ]]; then
    exit "$(status_install_exit_code)"
  fi
  # Without --strict, preserve the original always-exit-0 contract so the
  # existing test_setup.sh harness, the install scripts, and external CI
  # callers do not start failing because of a previously-tolerated INFO
  # or BROKEN row.
  exit 0
fi

# --no-summary: preserve the legacy behavior (no rollup, always exit 0).
exit 0
