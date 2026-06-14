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
  --with-scheduler
  --force-overwrite
  --profile minimal|core|full|strict
  --languages lang1,lang2

Check options:
  --json
  --quiet
  --strict
  --install
  --no-summary
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
    run_setup "check.sh" --install "$@"
    ;;
  verify-project)
    shift || true
    run_setup "check.sh" --strict --project "$@"
    ;;
  verify-dev-repo)
    shift || true
    run_setup "check.sh" --strict "$@"
    ;;
  --check)
    shift || true
    run_setup "check.sh" "$@"
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
