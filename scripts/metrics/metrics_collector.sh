#!/usr/bin/env bash
set -euo pipefail

# VibeGuard Metrics Collector
# Collect anti-hallucination quantitative indicators and output readable reports
#
# How to use:
#   bash vibeguard/scripts/metrics_collector.sh [project_dir]

PROJECT_DIR="${1:-.}"
VIBEGUARD_DIR="${VIBEGUARD_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
source "$(dirname "$0")/lib/guard_paths.sh"
TODAY=$(date '+%Y-%m-%d')

echo "======================================"
echo "VibeGuard Metrics Report"
echo "Project: ${PROJECT_DIR}"
echo "Date: ${TODAY}"
echo "======================================"
echo

# --- M3: Duplicate code rate ---
echo "--- M3: Duplicate Definitions ---"

DUP_CHECK=$(find_guard "python/check_duplicates.py" "$PROJECT_DIR")
if [[ -n "${DUP_CHECK}" ]]; then
  dup_output=$(cd "${PROJECT_DIR}" && python3 "${DUP_CHECK}" 2>&1 || true)
  dup_count=$(python3 -c "
import re, sys
text = sys.stdin.read()
# Match patterns like '3 groups of duplicates' or 'Found 3 groups of duplicates'
m = re.search(r'(\d+)\s*(?:group duplicate definition|groups?\s+of\s+duplicat)', text)
print(m.group(1) if m else '0')
" <<< "${dup_output}")
  echo "  Duplicate groups: ${dup_count}"
  if [[ "${dup_count}" == "0" ]]; then
    echo "  Status: PASS (target: < 5)"
  elif [[ "${dup_count}" -lt 5 ]]; then
    echo "  Status: OK (target: < 5)"
  elif [[ "${dup_count}" -lt 10 ]]; then
    echo "  Status: YELLOW (target: < 5)"
  else
    echo "  Status: RED (target: < 5)"
  fi
else
  echo "  check_duplicates.py not found, skipping"
fi
echo

# --- M4: Naming violation rate ---
echo "--- M4: Naming Violations ---"

NAMING_CHECK=$(find_guard "python/check_naming_convention.py" "$PROJECT_DIR")
if [[ -n "${NAMING_CHECK}" ]]; then
  naming_output=$(cd "${PROJECT_DIR}" && python3 "${NAMING_CHECK}" 2>&1 || true)
  naming_count=$(python3 -c "
import re, sys
text = sys.stdin.read()
# Match patterns like '5 issues' or '5 issues'
m = re.search(r'(\d+)\s*(?:issues|issues?)', text)
print(m.group(1) if m else '0')
" <<< "${naming_output}")
  echo "  Naming violations: ${naming_count}"
  if [[ "${naming_count}" == "0" ]]; then
    echo "  Status: PASS (target: 0)"
  elif [[ "${naming_count}" -lt 5 ]]; then
    echo "  Status: YELLOW (target: 0)"
  else
    echo "  Status: RED (target: 0)"
  fi
else
  echo "  check_naming_convention.py not found, skipping"
fi
echo

# --- M5: Architecture guard pass rate ---
echo "--- M5: Architecture Guard Pass Rate ---"

guard_file=$(find_quality_guard "$PROJECT_DIR")
if [[ -n "${guard_file}" ]]; then
  guard_output=$(cd "${PROJECT_DIR}" && python3 -m pytest "${guard_file}" -v 2>&1 || true)
  passed=$(echo "${guard_output}" | grep -c " PASSED" || echo "0")
  failed=$(echo "${guard_output}" | grep -c " FAILED" || echo "0")
  total=$((passed + failed))
  if [[ ${total} -gt 0 ]]; then
    rate=$((passed * 100 / total))
    echo "  Passed: ${passed}/${total} (${rate}%)"
    if [[ ${rate} -eq 100 ]]; then
      echo "  Status: PASS (target: 100%)"
    elif [[ ${rate} -ge 80 ]]; then
      echo "  Status: YELLOW (target: 100%)"
    else
      echo "  Status: RED (target: 100%)"
    fi
  else
    echo "  No tests found"
  fi
else
  echo "  test_code_quality_guards.py not found, skipping"
fi
echo

# --- Commit Stats ---
echo "--- Commit Statistics (last 7 days) ---"

if git -C "${PROJECT_DIR}" rev-parse --is-inside-work-tree &>/dev/null; then
  commit_count=$(git -C "${PROJECT_DIR}" log --since="7 days ago" --oneline 2>/dev/null | wc -l | tr -d ' ')
  echo "  Commits (7d): ${commit_count}"

  # Check for any revert commits (potential regressions)
  revert_count=$(git -C "${PROJECT_DIR}" log --since="7 days ago" --oneline --grep="revert\|fix:" -i 2>/dev/null | wc -l | tr -d ' ')
  echo "  Fixes/Reverts (7d): ${revert_count}"

  if [[ ${commit_count} -gt 0 ]]; then
    fix_rate=$((revert_count * 100 / commit_count))
    echo "  Fix rate: ${fix_rate}% (M1 proxy, target: < 2%)"
  fi
else
  echo "  Not a git repository, skipping"
fi
echo

echo "======================================"
echo "Report complete"
echo "======================================"
