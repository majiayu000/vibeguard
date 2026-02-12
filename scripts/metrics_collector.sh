#!/usr/bin/env bash
set -euo pipefail

# VibeGuard Metrics Collector
# 收集防幻觉量化指标，输出可读报告
#
# 使用方法：
#   bash vibeguard/scripts/metrics_collector.sh [project_dir]

PROJECT_DIR="${1:-.}"
TODAY=$(date '+%Y-%m-%d')

echo "======================================"
echo "VibeGuard Metrics Report"
echo "Project: ${PROJECT_DIR}"
echo "Date: ${TODAY}"
echo "======================================"
echo

# --- M3: 重复代码率 ---
echo "--- M3: Duplicate Definitions ---"

if [[ -f "${PROJECT_DIR}/scripts/check_duplicates.py" ]]; then
  dup_output=$(cd "${PROJECT_DIR}" && python scripts/check_duplicates.py 2>&1 || true)
  dup_count=$(echo "${dup_output}" | grep -c "组重复定义\|groups of duplicates" || echo "0")
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

# --- M4: 命名违规率 ---
echo "--- M4: Naming Violations ---"

if [[ -f "${PROJECT_DIR}/scripts/check_naming_convention.py" ]]; then
  naming_output=$(cd "${PROJECT_DIR}" && python scripts/check_naming_convention.py 2>&1 || true)
  naming_count=$(echo "${naming_output}" | grep -oP '\d+ 个问题|\d+ issues' | grep -oP '\d+' || echo "0")
  if [[ -z "${naming_count}" ]]; then
    naming_count="0"
  fi
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

# --- M5: 架构守卫通过率 ---
echo "--- M5: Architecture Guard Pass Rate ---"

guard_file=$(find "${PROJECT_DIR}" -path "*/architecture/test_code_quality_guards.py" -type f 2>/dev/null | head -1)
if [[ -n "${guard_file}" ]]; then
  guard_output=$(cd "${PROJECT_DIR}" && python -m pytest "${guard_file}" -v 2>&1 || true)
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
