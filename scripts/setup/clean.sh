#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VIBEGUARD_REPO_DIR="${VIBEGUARD_REPO_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"

exec bash "${SCRIPT_DIR}/install.sh" --clean "$@"
