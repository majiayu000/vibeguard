#!/usr/bin/env bash
# VibeGuard live-truth regression tests

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIVE_TRUTH="${REPO_DIR}/scripts/live_truth.py"

PASS=0
FAIL=0
TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }
header(){ printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

assert_cmd() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (exit code: $?)"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local output="$1" expected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$output" | grep -qF -- "$expected"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (expected to contain: $expected)"
    FAIL=$((FAIL + 1))
  fi
}

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

header "syntax and checklist"
assert_cmd "live_truth.py syntax is valid" python3 -m py_compile "${LIVE_TRUTH}"
checklist_out="$(python3 "${LIVE_TRUTH}" checklist)"
assert_contains "${checklist_out}" "artifact_sections: facts, inferences, unresolved_gaps" "checklist declares compact artifact sections"
assert_contains "${checklist_out}" "latest:" "checklist covers latest"
assert_contains "${checklist_out}" "pr-ready:" "checklist covers pr-ready"
assert_contains "${checklist_out}" "published:" "checklist covers published"

header "git latest evidence"
REMOTE_DIR="${TMP_DIR}/remote.git"
SEED_DIR="${TMP_DIR}/seed"
CURRENT_DIR="${TMP_DIR}/current"
STALE_DIR="${TMP_DIR}/stale"

git init --bare "${REMOTE_DIR}" >/dev/null
git clone "${REMOTE_DIR}" "${SEED_DIR}" >/dev/null 2>&1
(
  cd "${SEED_DIR}"
  git checkout -b main >/dev/null 2>&1
  printf 'v1\n' > README.md
  git add README.md
  git -c user.name="VibeGuard Test" -c user.email="test@vibeguard.local" commit -m "initial" >/dev/null
  git push origin main >/dev/null 2>&1
)
git --git-dir="${REMOTE_DIR}" symbolic-ref HEAD refs/heads/main
git clone "${REMOTE_DIR}" "${CURRENT_DIR}" >/dev/null 2>&1
git clone "${REMOTE_DIR}" "${STALE_DIR}" >/dev/null 2>&1

latest_pass_out="$(python3 "${LIVE_TRUTH}" latest --repo "${CURRENT_DIR}" --remote origin --branch main)"
assert_contains "${latest_pass_out}" "verdict: pass" "latest passes when local and remote refs match"
assert_contains "${latest_pass_out}" "dirty: no" "latest records clean worktree state"
assert_contains "${latest_pass_out}" "unresolved_gaps:" "latest output includes gaps section"

(
  cd "${SEED_DIR}"
  printf 'v2\n' >> README.md
  git add README.md
  git -c user.name="VibeGuard Test" -c user.email="test@vibeguard.local" commit -m "advance remote" >/dev/null
  git push origin main >/dev/null 2>&1
)
latest_fail_out="$(python3 "${LIVE_TRUTH}" latest --repo "${STALE_DIR}" --remote origin --branch main 2>&1 || true)"
assert_contains "${latest_fail_out}" "verdict: fail" "latest fails when local branch is behind"
assert_contains "${latest_fail_out}" "behind: 1" "latest records behind count"

header "PR ready fixture"
PR_READY_FIXTURE="${TMP_DIR}/pr-ready.json"
cat > "${PR_READY_FIXTURE}" <<'JSON'
{
  "url": "https://github.com/example/repo/pull/10",
  "state": "OPEN",
  "isDraft": false,
  "mergeable": "MERGEABLE",
  "reviewDecision": "APPROVED",
  "baseRefName": "main",
  "headRefOid": "abcdef0123456789",
  "updatedAt": "2026-05-18T00:00:00Z",
  "comments": [{"body": "ready"}],
  "latestReviews": [{"state": "APPROVED"}],
  "statusCheckRollup": [
    {"name": "ci", "status": "COMPLETED", "conclusion": "SUCCESS"},
    {"context": "lint", "state": "SUCCESS"}
  ]
}
JSON
pr_ready_out="$(python3 "${LIVE_TRUTH}" pr-ready --fixture "${PR_READY_FIXTURE}")"
assert_contains "${pr_ready_out}" "verdict: pass" "pr-ready passes with open mergeable approved PR"
assert_contains "${pr_ready_out}" "checks_passing: 2" "pr-ready records passing check count"
assert_contains "${pr_ready_out}" "review_decision: APPROVED" "pr-ready records review decision"

PR_REVIEW_REQUIRED_FIXTURE="${TMP_DIR}/pr-review-required.json"
python3 - "${PR_READY_FIXTURE}" "${PR_REVIEW_REQUIRED_FIXTURE}" <<'PY'
import json
import sys
from pathlib import Path

source, target = map(Path, sys.argv[1:])
data = json.loads(source.read_text(encoding="utf-8"))
data["reviewDecision"] = "REVIEW_REQUIRED"
target.write_text(json.dumps(data), encoding="utf-8")
PY
review_required_out="$(python3 "${LIVE_TRUTH}" pr-ready --fixture "${PR_REVIEW_REQUIRED_FIXTURE}" 2>&1 || true)"
assert_contains "${review_required_out}" "verdict: fail" "pr-ready fails when review is still required"
assert_contains "${review_required_out}" "review decision is REVIEW_REQUIRED" "pr-ready reports review-required blocker"

header "published artifact mismatch fixture"
PUBLISHED_FIXTURE="${TMP_DIR}/published-mismatch.json"
cat > "${PUBLISHED_FIXTURE}" <<'JSON'
{
  "package": "vibeguard",
  "registry": "npm",
  "registry_version": "1.2.0",
  "repo_tag": "v1.2.0",
  "repo_commit": "1111111111111111111111111111111111111111",
  "registry_commit": "1111111111111111111111111111111111111111",
  "repo_readme_sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "registry_readme_sha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
}
JSON
published_out="$(python3 "${LIVE_TRUTH}" published --fixture "${PUBLISHED_FIXTURE}" 2>&1 || true)"
assert_contains "${published_out}" "verdict: fail" "published fails on artifact checksum mismatch"
assert_contains "${published_out}" "registry version matches repo tag" "published still records matching version inference"
assert_contains "${published_out}" "registry README differs from repo README checksum" "published reports checksum mismatch"

echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
