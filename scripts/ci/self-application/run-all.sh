#!/usr/bin/env bash
# Run VibeGuard's self-application sentinels.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="${1:-$(cd "${SCRIPT_DIR}/../../.." && pwd)}"

checks=(
  "check-sec13-self-apply.sh"
  "check-sec13-risk-fields.sh"
  "check-sec14-mcp-descriptions.sh"
  "check-sec17-skill-governance-blueprint.sh"
  "check-u29-no-silent-degrade.sh"
  "check-pkg-correction-argv-only.sh"
  "check-codex-wrapper-thin.sh"
  "check-hook-production-python-free.sh"
  "check-hook-output-rewriting.sh"
  "check-rust-test-path-classifier.sh"
)

failures=0
echo "Running VibeGuard self-application checks..."
for check in "${checks[@]}"; do
  echo
  echo "==> ${check}"
  check_cmd=(bash "${SCRIPT_DIR}/${check}" "${REPO_DIR}")

  if "${check_cmd[@]}"; then
    echo "OK: ${check}"
  else
    echo "FAIL: ${check}"
    failures=$((failures + 1))
  fi
done

echo
if [[ "${failures}" -eq 0 ]]; then
  echo "All self-application checks passed."
else
  echo "FAILED: ${failures} self-application check(s) failed."
  exit 1
fi
