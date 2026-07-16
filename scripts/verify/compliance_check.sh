#!/usr/bin/env bash
set -euo pipefail

# VibeGuard Compliance Check
# Check whether the current project complies with the VibeGuard anti-hallucination specification
#
# How to use:
#   bash vibeguard/scripts/verify/compliance_check.sh [project_dir]
#   bash vibeguard/scripts/verify/compliance_check.sh /path/to/my-project

PROJECT_DIR="${1:-.}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VIBEGUARD_DIR="${VIBEGUARD_DIR:-${SCRIPT_ROOT}}"
source "${SCRIPT_DIR}/../lib/guard_paths.sh"
PASS=0
FAIL=0
WARN=0
LANGUAGES=""
LANGUAGE_SCOPE_VALID=true

check_pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
check_fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
check_warn() { echo "  [WARN] $1"; WARN=$((WARN + 1)); }
language_selected() { [[ ",${LANGUAGES}," == *",$1,"* ]]; }

echo "======================================"
echo "VibeGuard Compliance Check"
echo "Project: ${PROJECT_DIR}"
echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
echo "======================================"
echo

echo "--- Language Guard Packs ---"
PROJECT_CONFIG="${PROJECT_DIR}/.vibeguard.json"
if [[ ! -f "${PROJECT_CONFIG}" ]]; then
  check_warn "project language scope undeclared (.vibeguard.json not found)"
else
  if config_output="$(python3 \
    "${SCRIPT_ROOT}/scripts/lib/project_config_validate.py" \
    "${PROJECT_CONFIG}" \
    "${SCRIPT_ROOT}/schemas/vibeguard-project.schema.json" \
    --print-languages 2>&1)"; then
    LANGUAGES="${config_output}"
    if [[ -z "${LANGUAGES}" ]]; then
      check_warn "project language scope undeclared (.vibeguard.json languages missing or empty)"
    fi
  else
    check_fail "project language configuration invalid: ${config_output}"
    LANGUAGE_SCOPE_VALID=false
  fi
fi

if [[ "${LANGUAGE_SCOPE_VALID}" == "true" && -n "${LANGUAGES}" ]]; then
  if guard_modules_output="$(python3 \
    "${SCRIPT_ROOT}/scripts/lib/vibeguard_manifest.py" \
    guard-modules \
    --languages "${LANGUAGES}" \
    --manifest-file "${SCRIPT_ROOT}/schemas/install-modules.json" 2>&1)"; then
    while IFS= read -r module_line; do
      IFS=$'\t' read -r -a module_fields <<< "${module_line}"
      module_id="${module_fields[0]}"
      module_available=true
      for ((field_index = 1; field_index < ${#module_fields[@]}; field_index++)); do
        module_path="${module_fields[${field_index}]%/}"
        if [[ ! -e "${VIBEGUARD_DIR}/${module_path}" ]]; then
          module_available=false
          break
        fi
      done
      if [[ "${module_available}" == "true" ]]; then
        check_pass "guard module ${module_id} available"
      else
        check_warn "guard module ${module_id} unavailable under ${VIBEGUARD_DIR}"
      fi
    done <<< "${guard_modules_output}"
  else
    check_fail "language guard module resolution failed: ${guard_modules_output}"
    LANGUAGE_SCOPE_VALID=false
  fi
fi

# --- Layer 1: Anti-duplication system ---
if [[ "${LANGUAGE_SCOPE_VALID}" == "true" ]] && language_selected "python"; then
  echo "--- Layer 1: Anti-Duplication ---"

  dup_guard=$(find_guard "python/check_duplicates.py" "$PROJECT_DIR")
  if [[ -n "$dup_guard" ]]; then
    check_pass "check_duplicates.py available (${dup_guard})"
  else
    check_warn "check_duplicates.py not found (install vibeguard or copy guards/python/)"
  fi
fi

# --- Layer 2: Naming constraints ---
if [[ "${LANGUAGE_SCOPE_VALID}" == "true" ]] && language_selected "python"; then
  echo "--- Layer 2: Naming Convention ---"

  naming_guard=$(find_guard "python/check_naming_convention.py" "$PROJECT_DIR")
  if [[ -n "$naming_guard" ]]; then
    check_pass "check_naming_convention.py available (${naming_guard})"
  else
    check_warn "check_naming_convention.py not found (install vibeguard or copy guards/python/)"
  fi
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

  if [[ "${LANGUAGE_SCOPE_VALID}" == "true" ]] && language_selected "python"; then
    if grep -q "ruff" "${PROJECT_DIR}/.pre-commit-config.yaml"; then
      check_pass "ruff linting configured"
    else
      check_warn "ruff not found in pre-commit config"
    fi
  fi
else
  check_fail ".pre-commit-config.yaml not found"
fi

# --- Layer 4: Architecture Guard ---
if [[ "${LANGUAGE_SCOPE_VALID}" == "true" ]] && language_selected "python"; then
  echo "--- Layer 4: Architecture Guards ---"

  guard_file=$(find_quality_guard "$PROJECT_DIR")
  if [[ -n "${guard_file}" ]]; then
    check_pass "test_code_quality_guards.py exists: ${guard_file}"
  else
    check_warn "test_code_quality_guards.py not found (recommended: copy from vibeguard/guards/python/)"
  fi
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

if [[ -f "${PROJECT_DIR}/CLAUDE.md" ]]; then
  check_pass "CLAUDE.md exists in project"

  if grep -qiE "search before create|Search before writing" "${PROJECT_DIR}/CLAUDE.md"; then
    check_pass "SEARCH BEFORE CREATE rule present"
  else
    check_warn "SEARCH BEFORE CREATE rule not found in CLAUDE.md"
  fi

  if grep -qiE "no backward|no.*backward compatibility|no.*backward.*compat" "${PROJECT_DIR}/CLAUDE.md"; then
    check_pass "NO BACKWARD COMPATIBILITY rule present"
  else
    check_warn "NO BACKWARD COMPATIBILITY rule not found in CLAUDE.md"
  fi

  if grep -qiE "hardcod|hardcoding" "${PROJECT_DIR}/CLAUDE.md"; then
    check_pass "NO HARDCODING rule present"
  else
    check_warn "NO HARDCODING rule not found in CLAUDE.md"
  fi
else
  check_fail "CLAUDE.md not found in project"
fi

if [[ -f "${HOME}/.claude/CLAUDE.md" ]]; then
  check_pass "Global CLAUDE.md exists"

  if grep -qiE "vibeguard|anti-hallucination" "${HOME}/.claude/CLAUDE.md"; then
    check_pass "VibeGuard rules present in global CLAUDE.md"
  else
    check_warn "VibeGuard rules not found in global CLAUDE.md (run setup.sh)"
  fi
else
  check_fail "Global CLAUDE.md not found"
fi

# --- Layer 7: Rule YAML Syntax ---
echo "--- Layer 7: Rule YAML Syntax ---"

RULES_DIR="${HOME}/.claude/rules/vibeguard"
if [[ -d "${RULES_DIR}" ]]; then
  check_pass "VibeGuard rules directory exists: ${RULES_DIR}"

  # Check for broken YAML array syntax (bug #21858: paths: array breaks rule loading)
  if command -v rg >/dev/null 2>&1; then
    yaml_array_files=$(rg -l --multiline 'paths:\s*\n\s+-' "${RULES_DIR}" 2>/dev/null || true)
  else
    yaml_array_files=$(find "${RULES_DIR}" -name "*.md" -exec \
      awk '/^paths:/{p=1;next} p && /^[[:space:]]+-/{print FILENAME; exit} {p=0}' {} \; \
      2>/dev/null || true)
  fi
  if [[ -n "${yaml_array_files}" ]]; then
    check_fail "YAML array syntax in paths: (breaks rule loading, use CSV format) — ${yaml_array_files}"
  else
    check_pass "No YAML array syntax in paths frontmatter"
  fi

  # Check for quoted paths (bug #17204: quoted values preserved verbatim in glob)
  if command -v rg >/dev/null 2>&1; then
    quoted_files=$(rg -l "^paths:\\s+[\"']" "${RULES_DIR}" 2>/dev/null || true)
  else
    quoted_files=$(grep -rlE "^paths:[[:space:]]+[\"']" "${RULES_DIR}" 2>/dev/null || true)
  fi
  if [[ -n "${quoted_files}" ]]; then
    check_fail "Quoted paths detected (breaks glob matching, remove quotes) — ${quoted_files}"
  else
    check_pass "No quoted paths in rules frontmatter"
  fi
else
  check_warn "VibeGuard rules directory not found: ${RULES_DIR} (run setup.sh to install)"
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
