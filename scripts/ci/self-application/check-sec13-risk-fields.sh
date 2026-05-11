#!/usr/bin/env bash
# SEC-13 MCP/settings risk-field scanner.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VIBEGUARD_REPO_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
REPO_DIR="${1:-${VIBEGUARD_REPO_DIR}}"
SCANNER="${VIBEGUARD_REPO_DIR}/guards/universal/check_sec13_mcp_config_risks.py"

python3 "${SCANNER}" "${REPO_DIR}"
