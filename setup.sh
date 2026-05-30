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
