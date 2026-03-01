#!/usr/bin/env bash
set -euo pipefail

# VibeGuard Compliance Check
# 检查当前项目是否符合 VibeGuard 防幻觉规范
#
# 使用方法：
#   bash vibeguard/scripts/compliance_check.sh [project_dir]
#   bash vibeguard/scripts/compliance_check.sh /path/to/my-project

PROJECT_DIR="${1:-.}"
VIBEGUARD_DIR="${VIBEGUARD_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
PASS=0
FAIL=0
WARN=0

check_pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
check_fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
check_warn() { echo "  [WARN] $1"; WARN=$((WARN + 1)); }

echo "======================================"
echo "VibeGuard Compliance Check"
echo "Project: ${PROJECT_DIR}"
echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
echo "======================================"
echo

# --- Layer 1: 反重复系统 ---
echo "--- Layer 1: Anti-Duplication ---"

if [[ -f "${VIBEGUARD_DIR}/guards/python/check_duplicates.py" ]]; then
  check_pass "check_duplicates.py available (vibeguard guards)"
elif [[ -f "${PROJECT_DIR}/scripts/check_duplicates.py" ]]; then
  check_pass "check_duplicates.py exists (project-local)"
else
  check_warn "check_duplicates.py not found (install vibeguard or copy guards/python/)"
fi

# --- Layer 2: 命名约束 ---
echo "--- Layer 2: Naming Convention ---"

if [[ -f "${VIBEGUARD_DIR}/guards/python/check_naming_convention.py" ]]; then
  check_pass "check_naming_convention.py available (vibeguard guards)"
elif [[ -f "${PROJECT_DIR}/scripts/check_naming_convention.py" ]]; then
  check_pass "check_naming_convention.py exists (project-local)"
else
  check_warn "check_naming_convention.py not found (install vibeguard or copy guards/python/)"
fi

# --- Layer 3: Pre-commit Hooks ---
echo "--- Layer 3: Pre-commit Hooks ---"

if [[ -f "${PROJECT_DIR}/.pre-commit-config.yaml" ]]; then
  check_pass ".pre-commit-config.yaml exists"

  if grep -q "gitleaks" "${PROJECT_DIR}/.pre-commit-config.yaml"; then
    check_pass "gitleaks secret scanning configured"
  else
    check_warn "gitleaks not found in pre-commit config"
  fi

  if grep -q "ruff" "${PROJECT_DIR}/.pre-commit-config.yaml"; then
    check_pass "ruff linting configured"
  else
    check_warn "ruff not found in pre-commit config"
  fi
elif [[ -f "${PROJECT_DIR}/.husky/pre-commit" || -f "${PROJECT_DIR}/lefthook.yml" || -f "${PROJECT_DIR}/.git/hooks/pre-commit" ]]; then
  check_pass "git hook based pre-commit guard exists (husky/lefthook/.git/hooks)"
  check_warn "no .pre-commit-config.yaml; ensure secret/lint hooks are covered in your hook implementation"
else
  check_fail "no pre-commit guard found (.pre-commit-config.yaml / .husky/pre-commit / lefthook)"
fi

# --- Layer 4: 架构守卫 ---
echo "--- Layer 4: Architecture Guards ---"

guard_file=$(find "${PROJECT_DIR}" -path "*/architecture/test_code_quality_guards.py" -type f 2>/dev/null | head -1)
if [[ -n "${guard_file}" ]]; then
  check_pass "test_code_quality_guards.py exists: ${guard_file}"
else
  check_warn "test_code_quality_guards.py not found (recommended: copy from vibeguard/guards/python/)"
fi

# --- Layer 5: Workflows ---
echo "--- Layer 5: Skill/Workflow ---"

if [[ -d "${HOME}/.claude/skills/vibeguard" ]]; then
  check_pass "vibeguard skill installed in ~/.claude/skills/"
else
  check_fail "vibeguard skill not found in ~/.claude/skills/ (run setup.sh)"
fi

# --- Layer 6: Prompt Rules ---
echo "--- Layer 6: Prompt Rules ---"

PROJECT_RULE_FILE=""
if [[ -f "${PROJECT_DIR}/CLAUDE.md" ]]; then
  PROJECT_RULE_FILE="${PROJECT_DIR}/CLAUDE.md"
  check_pass "CLAUDE.md exists in project"
elif [[ -f "${PROJECT_DIR}/AGENTS.md" ]]; then
  PROJECT_RULE_FILE="${PROJECT_DIR}/AGENTS.md"
  check_pass "AGENTS.md exists in project (used as project-level rule source)"
fi

if [[ -n "${PROJECT_RULE_FILE}" ]]; then
  if grep -qiE "search before create|先搜后写" "${PROJECT_RULE_FILE}"; then
    check_pass "SEARCH BEFORE CREATE rule present"
  else
    check_warn "SEARCH BEFORE CREATE rule not found in project rule file"
  fi

  if grep -qiE "no backward|不做.*向后兼容|no.*backward.*compat|兼容旧代码|兼容层" "${PROJECT_RULE_FILE}"; then
    check_pass "NO BACKWARD COMPATIBILITY rule present"
  else
    check_warn "NO BACKWARD COMPATIBILITY rule not found in project rule file"
  fi

  if grep -qiE "hardcod|硬编码" "${PROJECT_RULE_FILE}"; then
    check_pass "NO HARDCODING rule present"
  else
    check_warn "NO HARDCODING rule not found in project rule file"
  fi
else
  check_fail "project rule file not found (expected CLAUDE.md or AGENTS.md)"
fi

if [[ -f "${HOME}/.claude/CLAUDE.md" ]]; then
  check_pass "Global CLAUDE.md exists"

  if grep -qiE "vibeguard|防幻觉" "${HOME}/.claude/CLAUDE.md"; then
    check_pass "VibeGuard rules present in global CLAUDE.md"
  else
    check_warn "VibeGuard rules not found in global CLAUDE.md (run setup.sh)"
  fi
else
  check_fail "Global CLAUDE.md not found"
fi

# --- Summary ---
echo
echo "======================================"
echo "Results:"
echo "  PASS: ${PASS}"
echo "  WARN: ${WARN}"
echo "  FAIL: ${FAIL}"
echo "======================================"

if [[ ${FAIL} -gt 0 ]]; then
  echo
  echo "Action required: Fix FAIL items above."
  echo "Run vibeguard/setup.sh to install missing components."
  exit 1
elif [[ ${WARN} -gt 0 ]]; then
  echo
  echo "Recommendations: Address WARN items for full compliance."
  exit 0
else
  echo
  echo "Full compliance achieved."
  exit 0
fi
