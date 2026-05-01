#!/usr/bin/env bash
# Run VibeGuard's self-application sentinels.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="${1:-$(cd "${SCRIPT_DIR}/../../.." && pwd)}"

checks=(
  "check-sec13-self-apply.sh"
  "check-u29-no-silent-degrade.sh"
  "check-hook-output-rewriting.sh"
  "check-u22-coverage.sh"
)

failures=0
echo "Running VibeGuard self-application checks..."
for check in "${checks[@]}"; do
  echo
  echo "==> ${check}"
  if [[ "${check}" == "check-u22-coverage.sh" ]]; then
    check_cmd=(env VIBEGUARD_U22_STRICT=1 bash "${SCRIPT_DIR}/${check}" "${REPO_DIR}")
  else
    check_cmd=(bash "${SCRIPT_DIR}/${check}" "${REPO_DIR}")
  fi

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
