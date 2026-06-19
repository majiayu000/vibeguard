#!/usr/bin/env bash
set -euo pipefail

# Resolve symlinks so this script works when invoked via npm's .bin/ shim
SCRIPT_PATH="${BASH_SOURCE[0]}"
while [ -L "$SCRIPT_PATH" ]; do
  SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
  SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
  [[ $SCRIPT_PATH != /* ]] && SCRIPT_PATH="$SCRIPT_DIR/$SCRIPT_PATH"
done
REPO_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
SETUP_DIR="${REPO_DIR}/scripts/setup"

print_usage() {
  cat <<'USAGE'
Usage: bash setup.sh [command] [options]

Commands:
  install              Install VibeGuard (default when no command is given)
  doctor               Show a human-friendly installation health report
  verify-install       Machine check for CI/post-install verification
  verify-project       Machine check for project health
  verify-dev-repo      Machine check for VibeGuard development repo health
  --check              Compatibility alias for doctor
  --clean             Uninstall managed VibeGuard assets
  --codex-status      Show read-only Codex-specific status
  packs               Manage guard packs
  demo                Run guard-pack demo
  --help, -h          Show this help

Install options:
  --yes, -y
  --dry-run
  --build-from-source
  --runtime-version vX.Y.Z
  --require-provenance
  --with-scheduler
  --force-overwrite
  --profile minimal|core|full|strict
  --languages lang1,lang2

Check options:
  --json
  --quiet
  --strict
  --install
  --no-summary       Legacy doctor/--check only; verify-* commands reject it
  --profile minimal|core|full|strict

Examples:
  bash setup.sh --yes
  bash setup.sh doctor
  bash setup.sh verify-install
  bash setup.sh verify-project --json
  bash setup.sh --check --profile strict
  bash setup.sh --profile strict --languages rust,python

Migration:
  bash setup.sh --check --strict   -> bash setup.sh verify-project
  bash setup.sh --check --json     -> bash setup.sh verify-project --json
  bash setup.sh --check --install  -> bash setup.sh verify-install
USAGE
}

run_setup() {
  local script="$1"
  shift || true

  if [[ ! -f "${SETUP_DIR}/${script}" ]]; then
    echo "ERROR: missing setup script: ${SETUP_DIR}/${script}" >&2
    exit 1
  fi

  VIBEGUARD_REPO_DIR="${REPO_DIR}" bash "${SETUP_DIR}/${script}" "$@"
}

reject_no_summary_for_machine_check() {
  local command_name="$1"
  shift || true
  local arg
  for arg in "$@"; do
    if [[ "${arg}" == "--no-summary" ]]; then
      echo "ERROR: ${command_name} does not support --no-summary; machine checks must preserve exit codes." >&2
      exit 64
    fi
  done
}

has_arg() {
  local needle="$1"
  shift || true
  local arg
  for arg in "$@"; do
    if [[ "${arg}" == "${needle}" ]]; then
      return 0
    fi
  done
  return 1
}

run_check_alias() {
  if has_arg "--install" "$@"; then
    reject_no_summary_for_machine_check "--check --install" "$@"
    run_setup "check.sh" "$@"
    return
  fi
  if has_arg "--strict" "$@" || has_arg "--json" "$@"; then
    if has_arg "--json" "$@"; then
      reject_no_summary_for_machine_check "--check --json" "$@"
    else
      reject_no_summary_for_machine_check "--check --strict" "$@"
    fi
    if has_arg "--project" "$@"; then
      run_setup "check.sh" "$@"
    else
      run_setup "check.sh" --project "$@"
    fi
    return
  fi
  run_setup "check.sh" "$@"
}

case "${1:-}" in
  --help|-h|help)
    print_usage
    ;;
  doctor)
    shift || true
    run_setup "check.sh" "$@"
    ;;
  verify-install)
    shift || true
    reject_no_summary_for_machine_check "verify-install" "$@"
    run_setup "check.sh" --install "$@"
    ;;
  verify-project)
    shift || true
    reject_no_summary_for_machine_check "verify-project" "$@"
    run_setup "check.sh" --strict --project "$@"
    ;;
  verify-dev-repo)
    shift || true
    reject_no_summary_for_machine_check "verify-dev-repo" "$@"
    run_setup "check.sh" --strict --dev-repo "$@"
    ;;
  --check)
    shift || true
    run_check_alias "$@"
    ;;
  --clean)
    shift || true
    run_setup "clean.sh" "$@"
    ;;
  --codex-status)
    shift || true
    run_setup "codex-status.sh" "$@"
    ;;
  packs)
    shift || true
    run_setup "guard-packs.sh" "$@"
    ;;
  demo)
    shift || true
    run_setup "guard-packs.sh" demo "$@"
    ;;
  install)
    shift || true
    _has_pack_arg=0
    for _arg in "$@"; do
      if [[ "${_arg}" == "--pack" || "${_arg}" == --pack=* ]]; then
        _has_pack_arg=1
        break
      fi
    done
    if [[ "${_has_pack_arg}" == "1" ]]; then
      run_setup "guard-packs.sh" install "$@"
    else
      run_setup "install.sh" "$@"
    fi
    ;;
  *)
    run_setup "install.sh" "$@"
    ;;
esac
