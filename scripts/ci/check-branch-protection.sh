#!/usr/bin/env bash
# VibeGuard CI: 检查 GitHub 分支是否启用“PR 必须通过 CI”
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  bash scripts/ci/check-branch-protection.sh [repo_slug] [branch]

Examples:
  bash scripts/ci/check-branch-protection.sh
  bash scripts/ci/check-branch-protection.sh majiayu000/vibeguard main

Env:
  VG_REQUIRED_CHECKS   Comma-separated required checks (default: validate-and-test)
  VG_REQUIRE_STRICT    true/false (default: true)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: gh CLI not found." >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "ERROR: gh is not authenticated. Run: gh auth login" >&2
  exit 1
fi

infer_repo_slug() {
  local remote_url
  remote_url="$(git -C "${REPO_DIR}" remote get-url origin)"
  remote_url="${remote_url#https://github.com/}"
  remote_url="${remote_url#git@github.com:}"
  remote_url="${remote_url%.git}"
  echo "${remote_url}"
}

REPO_SLUG="${1:-$(infer_repo_slug)}"
BRANCH="${2:-main}"
REQUIRED_CHECKS="${VG_REQUIRED_CHECKS:-validate-and-test}"
REQUIRE_STRICT="${VG_REQUIRE_STRICT:-true}"

RAW_JSON="$(gh api "repos/${REPO_SLUG}/branches/${BRANCH}/protection" 2>/dev/null)" || {
  echo "FAIL: Branch protection not enabled for ${REPO_SLUG}:${BRANCH}"
  exit 1
}

python3 - <<'PY' "${RAW_JSON}" "${REQUIRED_CHECKS}" "${REQUIRE_STRICT}" "${REPO_SLUG}" "${BRANCH}"
import json
import sys

data = json.loads(sys.argv[1])
required_checks = [x.strip() for x in sys.argv[2].split(",") if x.strip()]
require_strict = (sys.argv[3].lower() == "true")
repo = sys.argv[4]
branch = sys.argv[5]

status = data.get("required_status_checks") or {}
strict = bool(status.get("strict"))
contexts = {c.get("context") for c in status.get("checks", []) if isinstance(c, dict)}
contexts.update(status.get("contexts") or [])

missing = [c for c in required_checks if c not in contexts]
if missing:
    print(f"FAIL: missing required checks on {repo}:{branch}")
    for c in missing:
        print(f"  - {c}")
    raise SystemExit(1)

if require_strict and not strict:
    print(f"FAIL: strict mode is disabled on {repo}:{branch}")
    raise SystemExit(1)

print(f"OK: branch protection check passed for {repo}:{branch}")
print(f"OK: required checks -> {', '.join(required_checks)}")
print(f"OK: strict -> {strict}")
PY
