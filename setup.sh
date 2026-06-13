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
  doctor              Human-friendly installation diagnosis
  verify-install      Machine install verification (non-zero on broken required state)
  verify-project      Project config verification
  verify-dev-repo     Repository development hook verification
  --check             Compatibility health check wrapper
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
  --dev-linked
  --with-scheduler
  --force-overwrite
  --profile minimal|core|full|strict
  --languages lang1,lang2

Check options:
  --profile minimal|core|full|strict

Examples:
  bash setup.sh --yes
  bash setup.sh doctor
  bash setup.sh verify-install
  bash setup.sh --check --strict
  bash setup.sh --check --profile strict
  bash setup.sh --profile strict --languages rust,python
USAGE
}

run_setup() {
  local script="$1"
  shift || true

  if [[ ! -f "${SETUP_DIR}/${script}" ]]; then
    echo "ERROR: missing setup script: ${SETUP_DIR}/${script}" >&2
    exit 1
  fi

  VIBEGUARD_REPO_DIR="${REPO_DIR}" VIBEGUARD_CHECK_COMPAT="${VIBEGUARD_CHECK_COMPAT:-0}" bash "${SETUP_DIR}/${script}" "$@"
}

case "${1:-}" in
  --help|-h|help)
    print_usage
    ;;
  --check)
    shift || true
    VIBEGUARD_CHECK_COMPAT=1 run_setup "check.sh" "$@"
    ;;
  doctor|--doctor)
    shift || true
    run_setup "check.sh" --doctor "$@"
    ;;
  verify-install)
    shift || true
    run_setup "check.sh" --install "$@"
    ;;
  verify-project)
    shift || true
    run_setup "check.sh" --verify-project "$@"
    ;;
  verify-dev-repo)
    shift || true
    run_setup "check.sh" --verify-dev-repo "$@"
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
