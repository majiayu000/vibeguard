#!/usr/bin/env bash
set -euo pipefail

# VibeGuard Metrics Collector
# 收集防幻觉量化指标，输出可读报告
#
# 使用方法：
#   bash vibeguard/scripts/metrics_collector.sh [project_dir]

PROJECT_DIR="${1:-.}"
VIBEGUARD_DIR="${VIBEGUARD_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
TODAY=$(date '+%Y-%m-%d')

echo "======================================"
echo "VibeGuard Metrics Report"
echo "Project: ${PROJECT_DIR}"
echo "Date: ${TODAY}"
echo "======================================"
echo

# --- M3: 重复代码率 ---
echo "--- M3: Duplicate Definitions ---"

DUP_CHECK="${VIBEGUARD_DIR}/guards/python/check_duplicates.py"
[[ -f "${DUP_CHECK}" ]] || DUP_CHECK="${PROJECT_DIR}/scripts/check_duplicates.py"
if [[ -f "${DUP_CHECK}" ]]; then
  dup_output=$(cd "${PROJECT_DIR}" && python3 "${DUP_CHECK}" 2>&1 || true)
  dup_count=$(python3 -c "
import re, sys
text = sys.stdin.read()
# Match patterns like '3 组重复定义' or 'Found 3 groups of duplicates'
m = re.search(r'(\d+)\s*(?:组重复定义|groups?\s+of\s+duplicat)', text)
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

# --- M4: 命名违规率 ---
echo "--- M4: Naming Violations ---"

NAMING_CHECK="${VIBEGUARD_DIR}/guards/python/check_naming_convention.py"
[[ -f "${NAMING_CHECK}" ]] || NAMING_CHECK="${PROJECT_DIR}/scripts/check_naming_convention.py"
if [[ -f "${NAMING_CHECK}" ]]; then
  naming_output=$(cd "${PROJECT_DIR}" && python3 "${NAMING_CHECK}" 2>&1 || true)
  naming_count=$(python3 -c "
import re, sys
text = sys.stdin.read()
# Match patterns like '5 个问题' or '5 issues'
m = re.search(r'(\d+)\s*(?:个问题|issues?)', text)
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
  echo "  check_naming_convention.py not found (neither vibeguard guards nor project-local), skipping"
fi
echo

# --- M5: 架构守卫通过率 ---
echo "--- M5: Architecture Guard Pass Rate ---"

guard_file=$(find "${PROJECT_DIR}" -path "*/architecture/test_code_quality_guards.py" -type f 2>/dev/null | head -1)
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

# --- M6: TypeScript Guard Violations ---
echo "--- M6: TypeScript Guard Violations ---"

if [[ -f "${PROJECT_DIR}/package.json" || -f "${PROJECT_DIR}/tsconfig.json" ]]; then
  ts_guard_dir="${VIBEGUARD_DIR}/guards/typescript"
  if [[ -d "${ts_guard_dir}" ]]; then
    count_tag_issues() {
      local text="$1"
      local tag="$2"
      local matches
      matches=$(echo "${text}" | grep -E "^\\[${tag}\\]" | grep -vE "PASS|检测到|detected" || true)
      echo "${matches}" | sed '/^$/d' | wc -l | tr -d ' '
    }

    any_out=$(bash "${ts_guard_dir}/check_any_abuse.sh" "${PROJECT_DIR}" 2>&1 || true)
    any_count=$(count_tag_issues "${any_out}" "TS-01")

    console_out=$(bash "${ts_guard_dir}/check_console_residual.sh" "${PROJECT_DIR}" 2>&1 || true)
    console_count=$(count_tag_issues "${console_out}" "TS-03")

    api_out=$(bash "${ts_guard_dir}/check_no_api_direct_ai_call.sh" "${PROJECT_DIR}" 2>&1 || true)
    api_count=$(count_tag_issues "${api_out}" "TS-13")

    fallback_out=$(bash "${ts_guard_dir}/check_no_dual_track_fallback.sh" "${PROJECT_DIR}" 2>&1 || true)
    fallback_count=$(count_tag_issues "${fallback_out}" "TS-14")

    total_ts=$((any_count + console_count + api_count + fallback_count))
    echo "  any abuse (TS-01): ${any_count}"
    echo "  console residual (TS-03): ${console_count}"
    echo "  api direct ai call (TS-13): ${api_count}"
    echo "  dual-track fallback (TS-14): ${fallback_count}"
    echo "  Total TS violations: ${total_ts}"
    if [[ "${total_ts}" == "0" ]]; then
      echo "  Status: PASS (target: 0)"
    elif [[ "${total_ts}" -lt 5 ]]; then
      echo "  Status: YELLOW (target: 0)"
    else
      echo "  Status: RED (target: 0)"
    fi
  else
    echo "  guards/typescript not found, skipping"
  fi
else
  echo "  no package.json/tsconfig.json, skipping"
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
