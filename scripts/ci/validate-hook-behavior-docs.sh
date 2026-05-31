#!/usr/bin/env bash
# Ensure public docs do not overstate hook blocking behavior.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_DIR"

failures=0

require_absent() {
  local file="$1"
  local pattern="$2"
  local message="$3"
  if grep -Fq "$pattern" "$file"; then
    echo "FAIL: ${message}" >&2
    failures=$((failures + 1))
  fi
}

require_present() {
  local file="$1"
  local pattern="$2"
  local message="$3"
  if ! grep -Fq "$pattern" "$file"; then
    echo "FAIL: ${message}" >&2
    failures=$((failures + 1))
  fi
}

require_absent "README.md" '| AI tries to finish with unverified changes | `stop-guard` | **Gate**' \
  "README.md must not describe stop-guard as a blocking Gate"
require_present "README.md" '| AI tries to finish with unverified changes | `stop-guard` | **Signal**' \
  "README.md must describe stop-guard as a non-blocking Signal"
require_present "README.md" '| `Stop` | `stop-guard.sh` | Uncommitted changes signal (logs a `gate` event, non-blocking Stop) |' \
  "README.md Codex hook table must explain stop-guard logs gate events without blocking Stop"

require_absent "docs/README_CN.md" '| AI 想结束但还没有验证改动 | `stop-guard` | **闸门**' \
  "docs/README_CN.md must not describe stop-guard as a blocking gate"
require_present "docs/README_CN.md" '| AI 想结束但还没有验证改动 | `stop-guard` | **信号**' \
  "docs/README_CN.md must describe stop-guard as a signal"
require_present "docs/README_CN.md" '| `Stop` | `stop-guard.sh` | 未验证改动信号（记录 `gate` 事件，但 Stop 不阻塞） |' \
  "docs/README_CN.md Codex hook table must explain non-blocking Stop behavior"

require_absent "docs/CLAUDE.md.example" '| `Stop` has unverified source code changes | **Gate**' \
  "docs/CLAUDE.md.example must not describe stop-guard as a blocking Gate"
require_present "docs/CLAUDE.md.example" '| `Stop` has unverified source code changes | **Signal**' \
  "docs/CLAUDE.md.example must describe stop-guard as a signal"

require_present "scripts/setup/targets/claude-home.sh" 'Stop signal + Build check + Learn evaluator' \
  "setup status must avoid the old Stop gate wording"

if [[ "$failures" -gt 0 ]]; then
  exit 1
fi

echo "OK: hook behavior docs match stop-guard non-blocking semantics"
