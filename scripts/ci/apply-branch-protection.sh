#!/usr/bin/env bash
# VibeGuard CI: 为 GitHub 分支启用“PR 必须通过 CI”保护
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  bash scripts/ci/apply-branch-protection.sh [repo_slug] [branch]

Examples:
  bash scripts/ci/apply-branch-protection.sh
  bash scripts/ci/apply-branch-protection.sh majiayu000/vibeguard main

Env:
  VG_REQUIRED_CHECKS   Comma-separated required checks (default: validate-and-test)
  VG_STRICT            true/false, require branch up-to-date before merge (default: true)
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
  # 支持 https://github.com/owner/repo.git 与 git@github.com:owner/repo.git
  remote_url="${remote_url#https://github.com/}"
  remote_url="${remote_url#git@github.com:}"
  remote_url="${remote_url%.git}"
  echo "${remote_url}"
}

REPO_SLUG="${1:-$(infer_repo_slug)}"
BRANCH="${2:-main}"
REQUIRED_CHECKS="${VG_REQUIRED_CHECKS:-validate-and-test}"
STRICT_RAW="${VG_STRICT:-true}"

if [[ "${STRICT_RAW}" == "true" ]]; then
  STRICT_JSON=true
else
  STRICT_JSON=false
fi

CHECKS_JSON=$(python3 - <<'PY' "${REQUIRED_CHECKS}"
import json, sys
contexts = [x.strip() for x in sys.argv[1].split(",") if x.strip()]
checks = [{"context": c, "app_id": -1} for c in contexts]
print(json.dumps(checks, ensure_ascii=False))
PY
)

PAYLOAD=$(python3 - <<'PY' "${STRICT_JSON}" "${CHECKS_JSON}"
import json, sys
strict = (sys.argv[1].lower() == "true")
checks = json.loads(sys.argv[2])
payload = {
    "required_status_checks": {
        "strict": strict,
        "checks": checks,
    },
    "enforce_admins": False,
    "required_pull_request_reviews": None,
    "restrictions": None,
    "required_linear_history": False,
    "allow_force_pushes": False,
    "allow_deletions": False,
    "block_creations": False,
    "required_conversation_resolution": False,
    "lock_branch": False,
    "allow_fork_syncing": True,
}
print(json.dumps(payload, ensure_ascii=False))
PY
)

echo "Applying branch protection..."
echo "  repo   : ${REPO_SLUG}"
echo "  branch : ${BRANCH}"
echo "  checks : ${REQUIRED_CHECKS}"
echo "  strict : ${STRICT_RAW}"

gh api -X PUT "repos/${REPO_SLUG}/branches/${BRANCH}/protection" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  --input - >/dev/null <<EOF
${PAYLOAD}
EOF

echo "Branch protection applied."
