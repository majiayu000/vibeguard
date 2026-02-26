#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
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
