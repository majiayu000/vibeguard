#!/usr/bin/env bash
# VibeGuard installation health check.
#
# Modes
#   bash setup.sh --check                # full report (default, exit always 0)
#   bash setup.sh doctor                 # same human report as --check
#   bash setup.sh verify-install         # CI/post-install check, fail on broken required state
#   bash setup.sh verify-project         # strict machine check, fail on degraded/broken
#   bash setup.sh verify-dev-repo        # strict machine check for this repo
#   bash setup.sh --check --strict       # exit 1/2 on warnings/problems
#   bash setup.sh --check --quiet        # only show problem rows + summary
#   bash setup.sh --check --json         # machine-readable JSON, no TTY output
#   bash setup.sh --check --no-summary   # legacy behavior (no rollup, exit 0)
#   bash setup.sh --check --install      # install final verification, fail on broken required state
#   bash setup.sh --check --project      # include current Git project's hooks
#   bash setup.sh --check --profile full # verify profile-specific hook coverage
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
PROJECT=0
DEV_REPO=0
PROFILE="${VIBEGUARD_SETUP_PROFILE:-}"
LANGUAGES="${VIBEGUARD_SETUP_LANGUAGES:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiet|-q)     QUIET=1; shift ;;
    --json)         JSON=1; shift ;;
    --strict)       STRICT=1; shift ;;
    --install)      INSTALL=1; shift ;;
    --project)      PROJECT=1; shift ;;
    --dev-repo)     DEV_REPO=1; shift ;;
    --no-summary)   WITH_SUMMARY=0; shift ;;
    --profile)
      [[ $# -lt 2 ]] && { red "ERROR: --profile requires a value (minimal|core|full|strict)"; exit 64; }
      PROFILE="$2"; shift 2 ;;
    --profile=*)
      PROFILE="${1#*=}"; shift ;;
    --help|-h)
      cat <<'USAGE'
Usage: setup.sh --check [--quiet | --json | --strict | --install | --project | --no-summary] [--profile minimal|core|full|strict]

Top-level commands:
  setup.sh doctor             Human-friendly report; exits 0 unless the checker cannot run.
                              Compatibility alias: setup.sh --check.
  setup.sh verify-install     CI/post-install verification; exits 2 on broken
                              required install state, allows optional WARN/INFO.
  setup.sh verify-project     Strict machine verification; exits 1 on degraded
                              state and 2 on broken state.
  setup.sh verify-dev-repo    Strict machine verification for the VibeGuard repo.

  --quiet        Suppress healthy [OK] rows; only print problems + summary.
  --strict       Reflect health in the exit code: 0 healthy, 1 degraded,
                 2 broken (FAIL/BROKEN/MISSING). Without --strict the exit
                 code is always 0 for backwards compatibility.
  --install      Final install verification mode: exit 2 on broken required
                 state, but allow WARN/INFO rows for optional integrations.
  --project      Include current Git project's pre-commit/pre-push hook checks.
                 Used by setup.sh verify-project.
  --json         Emit a single-line JSON document (counts + events + verdict)
                 to stdout. Disables human-readable output. Implies --strict.
  --no-summary   Legacy mode: no rollup table, always exit 0.
                 Equivalent to the pre-summary behavior.
  --profile      Override the install-state profile used for Claude hook
                 coverage checks. Defaults to the installed profile, then core.

Exit codes (--strict / --json / --install only):
  0  healthy
  1  degraded (warnings only; --strict/--json)
  2  broken (FAIL/BROKEN/MISSING present)

Migration:
  setup.sh --check --strict   -> setup.sh verify-project
  setup.sh --check --json     -> setup.sh verify-project --json
  setup.sh --check --install  -> setup.sh verify-install
USAGE
      exit 0
      ;;
    *)
      red "ERROR: unknown argument to --check: $1"
      exit 64
      ;;
  esac
done

check_installed_profile() {
  local state_out detected
  state_out="$(state_list 2>/dev/null)" || return 1
  detected="$(awk -F': ' '/^Profile:/ {print $2; exit}' <<< "${state_out}")"
  case "${detected}" in
    minimal|core|full|strict) printf '%s\n' "${detected}" ;;
    *) return 1 ;;
  esac
}

check_installed_languages() {
  local state_out detected
  state_out="$(state_list 2>/dev/null)" || return 1
  detected="$(awk -F': ' '/^Languages:/ {print $2; exit}' <<< "${state_out}")"
  [[ -n "${detected}" ]] || return 1
  printf '%s\n' "${detected}" | tr -d '[:space:]'
}

launchd_gc_script_path() {
  local plist="$1"
  [[ -f "${plist}" ]] || return 1
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
  ' "${plist}"
}

launchd_gc_script_path_from_print() {
  awk '
    /^[[:space:]]*arguments = \{/ { in_args = 1; next }
    in_args && /^[[:space:]]*\}/ { exit }
    in_args && /gc-scheduled\.sh/ {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      sub(/[[:space:]]*$/, "", line)
      print line
      exit
    }
  '
}

gc_last_actionable_failure() {
  local log_file="$1"
  [[ -f "${log_file}" && -r "${log_file}" ]] || return 1
  tail -n 200 "${log_file}" 2>/dev/null | awk '
    /Operation not permitted|Permission denied|\[ERROR\]|GC completed with errors/ { last = $0 }
    END { if (last != "") print last }
  '
}

check_scheduled_gc_freshness() {
  local scheduler_kind="$1" log_dir="${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}" project_config="${VIBEGUARD_PROJECT_CONFIG:-${REPO_DIR}/.vibeguard.json}"
  local success_file last_success="" attempt="" interval_hours now max_age age
  local wrapper_log wrapper_line="" internal_line="" evidence=0 permission_evidence=0
  success_file="${log_dir}/gc-last-success"
  if ! interval_hours="$(VIBEGUARD_PROJECT_CONFIG="${project_config}" vg_config_positive_int VIBEGUARD_GC_CATCHUP_INTERVAL_HOURS gc.catchup_interval_hours 168 2>/dev/null)"; then
    yellow "[WARN] Scheduled GC execution freshness unavailable: catch-up interval could not be read (rerun: bash setup.sh --yes --with-scheduler)"
    return 0
  fi
  now="$(date +%s 2>/dev/null || true)"
  if [[ ! "${now}" =~ ^[0-9]+$ ]]; then
    yellow "[WARN] Scheduled GC execution freshness unavailable: current time is invalid (rerun: bash setup.sh --yes --with-scheduler)"
    return 0
  fi
  max_age=$((interval_hours * 3600))
  if [[ -r "${success_file}" ]]; then
    last_success="$(cat "${success_file}" 2>/dev/null || true)"
  fi
  if [[ "${last_success}" =~ ^[0-9]+$ && ${#last_success} -le 18 ]]; then
    age=$((10#${now} - 10#${last_success}))
    if (( age >= 0 && age < max_age )); then
      green "[OK] Scheduled GC execution freshness: last success ${age}s ago (threshold: ${max_age}s / ${interval_hours}h)"
      return 0
    fi
  else
    age=""
  fi
  if [[ -n "${age}" && "${age}" -ge "${max_age}" ]]; then
    yellow "[WARN] Scheduled GC execution freshness stale: last success age ${age}s reached threshold ${max_age}s / ${interval_hours}h (rerun: bash setup.sh --yes --with-scheduler)"
  else
    yellow "[WARN] Scheduled GC execution freshness invalid: no valid last success recorded (threshold: ${max_age}s / ${interval_hours}h; rerun: bash setup.sh --yes --with-scheduler)"
  fi
  if [[ -r "${log_dir}/gc-last-attempt" ]]; then
    attempt="$(cat "${log_dir}/gc-last-attempt" 2>/dev/null || true)"
  fi
  if [[ "${attempt}" =~ ^[0-9]+$ && ${#attempt} -le 18 && "${last_success}" =~ ^[0-9]+$ && ${#last_success} -le 18 ]] &&
     (( 10#${attempt} > 10#${last_success} )); then
    yellow "[WARN] Scheduled GC execution attempt ${attempt} is newer than last success ${last_success}"
  fi
  case "${scheduler_kind}" in
    launchd) wrapper_log="${log_dir}/gc-launchd.log" ;;
    systemd) wrapper_log="${log_dir}/gc-systemd.log" ;;
    *) return 0 ;;
  esac
  wrapper_line="$(gc_last_actionable_failure "${wrapper_log}" || true)"
  internal_line="$(gc_last_actionable_failure "${log_dir}/gc-cron.log" || true)"
  if [[ -n "${wrapper_line}" ]]; then
    yellow "[WARN] Scheduled GC wrapper evidence (${wrapper_log##*/}): ${wrapper_line}"
    evidence=1
  fi
  if [[ -n "${internal_line}" ]]; then
    yellow "[WARN] Scheduled GC internal evidence (gc-cron.log): ${internal_line}"
    evidence=1
  fi
  if [[ "${wrapper_line}${internal_line}" == *"Operation not permitted"* || "${wrapper_line}${internal_line}" == *"Permission denied"* ]]; then
    permission_evidence=1
  fi
  [[ "${evidence}" -eq 1 ]] || yellow "[INFO] Scheduled GC diagnostics: no actionable failure found in bounded log tails"
  if [[ "${permission_evidence}" -eq 1 ]]; then
    yellow "[WARN] Scheduled GC permission hint: move the checkout out of protected directories or grant the ${scheduler_kind} scheduler disk access"
  fi
}

check_launchd_scheduled_gc() {
  local plist="${HOME}/Library/LaunchAgents/com.vibeguard.gc.plist"
  local expected="${REPO_DIR}/scripts/gc/gc-scheduled.sh"
  local plist_actual=""
  local active_actual=""
  local active_print=""
  local loaded=0

  if active_print="$(launchctl print "gui/$(id -u)/com.vibeguard.gc" 2>/dev/null)"; then
    loaded=1
    active_actual="$(launchd_gc_script_path_from_print <<< "${active_print}" 2>/dev/null || true)"
  fi
  if [[ -f "${plist}" ]]; then
    plist_actual="$(launchd_gc_script_path "${plist}" 2>/dev/null || true)"
  fi

  if [[ "${loaded}" -eq 1 ]]; then
    if [[ -z "${active_actual}" ]]; then
      red "[BROKEN] Scheduled GC active via launchd but loaded job does not declare gc-scheduled.sh"
    elif [[ "${active_actual}" != "${expected}" ]]; then
      red "[BROKEN] Scheduled GC launchd target drift: ${active_actual} (expected: ${expected}; rerun: bash setup.sh --yes --with-scheduler)"
    elif [[ ! -x "${expected}" ]]; then
      red "[BROKEN] Scheduled GC launchd target missing or not executable: ${expected}"
    else
      green "[OK] Scheduled GC active via launchd (com.vibeguard.gc)"
      check_scheduled_gc_freshness launchd
    fi

    if [[ ! -f "${plist}" ]]; then
      yellow "[WARN] Scheduled GC plist missing while launchd job is loaded: ${plist}"
    elif [[ -z "${plist_actual}" ]]; then
      yellow "[WARN] Scheduled GC plist does not declare gc-scheduled.sh: ${plist}"
    elif [[ "${plist_actual}" != "${expected}" ]]; then
      yellow "[WARN] Scheduled GC plist target drift: ${plist_actual} (expected: ${expected}; rerun: bash setup.sh --yes --with-scheduler or remove the plist)"
    fi
  elif [[ -f "${plist}" ]]; then
    if [[ -n "${plist_actual}" && "${plist_actual}" != "${expected}" ]]; then
      yellow "[WARN] Scheduled GC plist target drift: ${plist_actual} (expected: ${expected}; rerun: bash setup.sh --yes --with-scheduler or remove the plist)"
    elif [[ -n "${plist_actual}" && ! -x "${plist_actual}" ]]; then
      yellow "[WARN] Scheduled GC plist target missing or not executable: ${plist_actual}"
    else
      yellow "[WARN] Scheduled GC plist exists but not loaded"
    fi
  else
    yellow "[INFO] Scheduled GC not installed (optional, opt in: bash setup.sh --yes --with-scheduler)"
  fi
}

validate_setup_profile() {
  case "$1" in
    minimal|core|full|strict) ;;
    *) red "ERROR: unsupported profile: $1 (expected minimal|core|full|strict)"; exit 64 ;;
  esac
}

if [[ -n "${PROFILE}" ]]; then
  validate_setup_profile "${PROFILE}"
fi

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

if ! ensure_setup_runtime_available >/dev/null 2>&1; then
  if [[ "${JSON}" -ne 1 ]]; then
    yellow "[WARN] vibeguard-runtime unavailable for setup helper checks; run: bash setup.sh --yes"
  fi
fi

if [[ -z "${PROFILE}" ]]; then
  PROFILE="$(check_installed_profile 2>/dev/null || true)"
fi
PROFILE="${PROFILE:-core}"
validate_setup_profile "${PROFILE}"
if [[ -z "${LANGUAGES}" ]]; then
  LANGUAGES="$(check_installed_languages 2>/dev/null || true)"
fi

_execution_mode() {
  local mode="${VIBEGUARD_EXECUTION_MODE:-}"
  if [[ -z "${mode}" && -f "${HOME}/.vibeguard/execution-mode" ]]; then
    mode="$(tr -d '[:space:]' < "${HOME}/.vibeguard/execution-mode")"
  fi
  case "${mode}" in
    dev-linked|dev-linked-repo|repo|repo-linked)
      printf '%s\n' "dev-linked-repo" ;;
    *)
      printf '%s\n' "installed-snapshot" ;;
  esac
}

_execution_repo_dir() {
  local repo_path_file="${HOME}/.vibeguard/repo-path"
  if [[ -f "${repo_path_file}" ]]; then
    cat "${repo_path_file}"
    return 0
  fi
  return 1
}

_execution_source_path() {
  local rel_path="$1"
  local repo_dir
  if [[ "$(_execution_mode)" == "dev-linked-repo" ]]; then
    repo_dir="$(_execution_repo_dir 2>/dev/null || true)"
    if [[ -z "${repo_dir}" ]]; then
      printf '%s\n' "${HOME}/.vibeguard/missing-repo-path/${rel_path}"
    else
      printf '%s\n' "${repo_dir}/${rel_path}"
    fi
  else
    printf '%s\n' "${HOME}/.vibeguard/installed/${rel_path}"
  fi
}

_execution_source_label() {
  if [[ "$(_execution_mode)" == "dev-linked-repo" ]]; then
    printf '%s\n' "dev-linked repo"
  else
    printf '%s\n' "installed snapshot"
  fi
}

_check_execution_source_dir() {
  local surface="$1" rel_path="$2"
  local path
  path="$(_execution_source_path "${rel_path}")"
  if [[ -d "${path}" ]]; then
    green "[OK] ${surface} execution source: $(_execution_source_label) (${path})"
  else
    red "[BROKEN] ${surface} execution source missing: $(_execution_source_label) (${path})"
  fi
}

_check_execution_source_file() {
  local surface="$1" rel_path="$2"
  local path
  path="$(_execution_source_path "${rel_path}")"
  if [[ -f "${path}" ]]; then
    green "[OK] ${surface} execution source: $(_execution_source_label) (${path})"
  else
    red "[BROKEN] ${surface} execution source missing: $(_execution_source_label) (${path})"
  fi
}

_check_execution_sources() {
  echo
  echo "Execution Sources"
  echo "------------------------------"
  if [[ "$(_execution_mode)" == "dev-linked-repo" ]]; then
    yellow "[INFO] Execution mode: dev-linked repo (explicit opt-in)"
  else
    green "[OK] Execution mode: installed snapshot"
  fi
  _check_execution_source_dir "Hook wrapper" "hooks"
  _check_execution_source_file "Git pre-commit" "hooks/pre-commit-guard.sh"
  _check_execution_source_file "Git pre-push" "hooks/git/pre-push"
  _check_execution_source_dir "Native rules" "rules/claude-rules"
  _check_execution_source_dir "Claude commands" ".claude/commands"
  _check_execution_source_dir "Skills" "skills"
  if [[ -d "$(_execution_source_path "workflows")" ]]; then
    green "[OK] Workflow skills execution source: $(_execution_source_label) ($(_execution_source_path "workflows"))"
  else
    red "[BROKEN] Workflow skills execution source missing: $(_execution_source_label) ($(_execution_source_path "workflows"))"
  fi
  if [[ -x "${HOME}/.vibeguard/installed/bin/vibeguard-runtime" ]]; then
    green "[OK] Runtime execution source: installed snapshot (${HOME}/.vibeguard/installed/bin/vibeguard-runtime)"
  else
    red "[BROKEN] Runtime execution source missing: installed snapshot (${HOME}/.vibeguard/installed/bin/vibeguard-runtime)"
  fi
}

_check_git_hook() {
  local scope="$1"
  local hook_dir="$2"
  local hook_name="$3"
  local expected_target="$4"
  local hook_path="${hook_dir}/${hook_name}"

  if [[ ! -e "${hook_path}" && ! -L "${hook_path}" ]]; then
    red "[MISSING] ${scope} ${hook_name} hook (${hook_path})"
    return 0
  fi
  if [[ ! -L "${hook_path}" ]]; then
    red "[BROKEN] ${scope} ${hook_name} hook is not a symlink: ${hook_path}"
    return 0
  fi

  local actual_target
  actual_target="$(readlink "${hook_path}" 2>/dev/null || true)"
  if [[ -z "${actual_target}" ]]; then
    red "[BROKEN] ${scope} ${hook_name} hook target cannot be read: ${hook_path}"
    return 0
  fi
  if [[ "${actual_target}" != "${expected_target}" ]]; then
    red "[BROKEN] ${scope} ${hook_name} hook target drift: ${actual_target} (expected: ${expected_target})"
    return 0
  fi
  if [[ ! -e "${hook_path}" ]]; then
    red "[BROKEN] ${scope} ${hook_name} hook target missing: ${actual_target}"
    return 0
  fi
  if [[ ! -x "${hook_path}" ]]; then
    red "[BROKEN] ${scope} ${hook_name} hook target not executable: ${actual_target}"
    return 0
  fi
  if [[ "${expected_target}" == "${HOME}/.vibeguard/pre-commit" || "${expected_target}" == "${HOME}/.vibeguard/pre-push" ]]; then
    local source_rel source_path
    case "${hook_name}" in
      pre-commit) source_rel="hooks/pre-commit-guard.sh" ;;
      pre-push) source_rel="hooks/git/pre-push" ;;
      *) source_rel="" ;;
    esac
    if [[ -n "${source_rel}" ]]; then
      source_path="$(_execution_source_path "${source_rel}")"
      if [[ ! -f "${source_path}" ]]; then
        red "[BROKEN] ${scope} ${hook_name} hook execution source missing: ${source_path}"
        return 0
      fi
      if [[ ! -r "${source_path}" ]]; then
        red "[BROKEN] ${scope} ${hook_name} hook execution source not readable: ${source_path}"
        return 0
      fi
    fi
  fi

  green "[OK] ${scope} ${hook_name} hook installed"
}

_check_repo_git_hook() {
  local hook_name="$1"
  local expected_target="$2"
  _check_git_hook "VibeGuard repo" "${_vg_hook_dir}" "${hook_name}" "${expected_target}"
}

_check_project_git_hooks() {
  echo
  echo "Project Git Hooks"
  echo "------------------------------"

  local project_root project_hook_dir
  if ! project_root="$(git rev-parse --show-toplevel 2>/dev/null)" || [[ -z "${project_root}" ]]; then
    red "[MISSING] Project git hooks not checked (not a git repository)"
    return 0
  fi
  if ! project_hook_dir="$(git -C "${project_root}" rev-parse --path-format=absolute --git-path hooks 2>/dev/null)" || [[ -z "${project_hook_dir}" ]]; then
    red "[BROKEN] Project git hooks not checked (git hook path unavailable)"
    return 0
  fi

  _check_git_hook "Project" "${project_hook_dir}" "pre-commit" "${HOME}/.vibeguard/pre-commit"
  _check_git_hook "Project" "${project_hook_dir}" "pre-push" "${HOME}/.vibeguard/pre-push"
}

_check_installed_snapshot_version() {
  local version_file="${HOME}/.vibeguard/installed/version"
  local installed_version=""
  local repo_dir=""
  local repo_version=""

  if [[ ! -f "${version_file}" ]]; then
    yellow "[WARN] Installed hooks+guards snapshot version missing (${version_file}); run: bash setup.sh --yes"
    return 0
  fi

  installed_version="$(tr -d '[:space:]' < "${version_file}")"
  repo_dir="$(_execution_repo_dir 2>/dev/null || true)"

  if [[ -z "${repo_dir}" || ! -d "${repo_dir}" ]]; then
    yellow "[INFO] Installed hooks+guards snapshot version: ${installed_version:-unknown} (repo-path unavailable)"
    return 0
  fi
  repo_version="$(git -C "${repo_dir}" rev-parse --short HEAD 2>/dev/null || true)"

  if [[ -z "${repo_version}" ]]; then
    yellow "[INFO] Installed hooks+guards snapshot version: ${installed_version:-unknown} (repo-path HEAD unavailable)"
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

  green "[OK] Installed hooks+guards snapshot matches repo-path HEAD (${repo_version})"
}

_check_installed_runtime_version() {
  local runtime_path="${HOME}/.vibeguard/installed/bin/vibeguard-runtime"
  local expected actual

  expected="$(setup_runtime_expected_version 2>/dev/null)" || {
    red "[BROKEN] Runtime VERSION could not be resolved (${REPO_DIR}/vibeguard-runtime/VERSION)"
    return 0
  }
  actual="$("${runtime_path}" version 2>/dev/null)" || {
    red "[BROKEN] vibeguard-runtime cannot self-report version; run: bash setup.sh --yes"
    return 0
  }
  actual="${actual%%$'\n'*}"
  actual="${actual//$'\r'/}"

  if [[ "${actual}" != "${expected}" ]]; then
    red "[BROKEN] vibeguard-runtime version mismatch: ${actual:-unknown} (expected: ${expected}; run: bash setup.sh --yes)"
    return 0
  fi

  green "[OK] vibeguard-runtime version matches repo VERSION (${expected})"
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
  if [[ -f "${VIBEGUARD_HOME}/run-hook.sh" ]]; then
    if [[ "$(_execution_mode)" == "dev-linked-repo" ]]; then
      _repo="$(_execution_repo_dir 2>/dev/null || true)"
      if [[ -n "${_repo}" && -d "$_repo/hooks" ]]; then
        green "[OK] Hook wrapper ready (source: dev-linked repo: ${_repo})"
      else
        red "[BROKEN] Hook wrapper dev-linked repo source missing: ${_repo:-${VIBEGUARD_HOME}/repo-path}"
      fi
    elif [[ -d "${VIBEGUARD_HOME}/installed/hooks" ]]; then
      green "[OK] Hook wrapper ready (source: installed snapshot: ${VIBEGUARD_HOME}/installed/hooks)"
    else
      red "[BROKEN] Hook wrapper installed snapshot missing: ${VIBEGUARD_HOME}/installed/hooks"
    fi
  else
    yellow "[MISSING] Hook wrapper not installed (~/.vibeguard/run-hook.sh)"
  fi
  if [[ -x "${VIBEGUARD_HOME}/installed/bin/vibeguard-runtime" ]]; then
    green "[OK] vibeguard-runtime runtime binary installed"
    _check_installed_runtime_version
    _check_installed_snapshot_version
  else
    red "[MISSING] vibeguard-runtime runtime binary (~/.vibeguard/installed/bin/vibeguard-runtime)"
  fi
  _check_execution_sources

  check_claude_home_installation

  # Check scheduled GC
  if [[ "$(uname)" == "Darwin" ]]; then
    check_launchd_scheduled_gc
  elif [[ "$(uname)" == "Linux" ]] && command -v systemctl &>/dev/null; then
    if systemctl --user is-active vibeguard-gc.timer &>/dev/null; then
      green "[OK] Scheduled GC active via systemd (vibeguard-gc.timer)"
      check_scheduled_gc_freshness systemd
    elif [[ -f "${HOME}/.config/systemd/user/vibeguard-gc.timer" ]]; then
      yellow "[WARN] Scheduled GC unit exists but timer not active"
    else
      yellow "[INFO] Scheduled GC not installed (optional, opt in: bash setup.sh --yes --with-scheduler)"
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
  if [[ "${PROJECT}" -eq 1 ]]; then
    _check_project_git_hooks
  fi

  # Check project-level runtime config
  echo
  echo "Project Config"
  echo "------------------------------"
  if [[ "${INSTALL}" -eq 1 && "${PROJECT}" -ne 1 ]]; then
    yellow "[INFO] Project config not checked in install verification mode (use verify-project for project health)"
  elif [[ "${DEV_REPO}" -eq 1 && "${PROJECT}" -ne 1 ]]; then
    yellow "[INFO] Project config not checked in dev-repo verification mode (use verify-project for project health)"
  else
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
  while IFS= read -r _guard_file; do
    _line_no=0
    while IFS= read -r _guard_line || [[ -n "${_guard_line}" ]]; do
      _line_no=$((_line_no + 1))
      [[ "${_guard_line}" =~ ^[[:space:]]*# ]] && continue
      [[ "${_guard_line}" =~ (^|[^A-Za-z0-9_])(awk|gawk|mawk|nawk)([^A-Za-z0-9_]|$) ]] || continue
      if [[ "${_guard_line}" =~ /[^/\"\']*\\[sdwb][^/\"\']*/ ]]; then
        printf '%s:%s:%s\n' "${_guard_file}" "${_line_no}" "${_guard_line}" >> "$_awk_violations"
      fi
    done < "${_guard_file}"
  done < <(find "${REPO_DIR}/guards" -type f -name "*.sh" 2>/dev/null | sort)
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
