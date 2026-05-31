#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${VIBEGUARD_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
exec python3 "${REPO_DIR}/scripts/lib/guard_packs.py" "$@"
