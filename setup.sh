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
  *)
    run_setup "install.sh" "$@"
    ;;
esac
