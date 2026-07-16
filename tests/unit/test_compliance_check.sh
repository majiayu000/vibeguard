#!/usr/bin/env bash
# Unit tests for scripts/verify/compliance_check.sh language-aware guard discovery.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
CHECKER="${REPO_DIR}/scripts/verify/compliance_check.sh"

PASS=0
FAIL=0
TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red() { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }

assert_eq() {
  local desc="$1"
  local expected="$2"
  local actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "${actual}" == "${expected}" ]]; then
    green "${desc}"
    PASS=$((PASS + 1))
  else
    red "${desc} (expected ${expected}, got ${actual})"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1"
  local output="$2"
  local expected="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qF "${expected}" <<< "${output}"; then
    green "${desc}"
    PASS=$((PASS + 1))
  else
    red "${desc} (missing: ${expected})"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local desc="$1"
  local output="$2"
  local unexpected="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qF "${unexpected}" <<< "${output}"; then
    red "${desc} (unexpected: ${unexpected})"
    FAIL=$((FAIL + 1))
  else
    green "${desc}"
    PASS=$((PASS + 1))
  fi
}

assert_count() {
  local desc="$1"
  local output="$2"
  local expected_text="$3"
  local expected_count="$4"
  local actual_count
  actual_count="$(grep -cF "${expected_text}" <<< "${output}" || true)"
  assert_eq "${desc}" "${expected_count}" "${actual_count}"
}

make_project() {
  local project_dir="$1"
  mkdir -p "${project_dir}"
  printf '%s\n' \
    'repos:' \
    '  - repo: local' \
    '    hooks:' \
    '      - id: gitleaks' \
    '      - id: ruff' \
    > "${project_dir}/.pre-commit-config.yaml"
  printf '%s\n' \
    'Search before writing.' \
    'No backward compatibility.' \
    'No hardcoding.' \
    > "${project_dir}/CLAUDE.md"
}

run_checker() {
  local checker="$1"
  local project_dir="$2"
  local guard_root="${3:-}"
  set +e
  if [[ -n "${guard_root}" ]]; then
    LAST_OUTPUT="$({
      cd "${OUTSIDE_CWD}" || exit 97
      HOME="${FIXTURE_HOME}" VIBEGUARD_DIR="${guard_root}" \
        bash "${checker}" "${project_dir}"
    } 2>&1)"
  else
    LAST_OUTPUT="$({
      cd "${OUTSIDE_CWD}" || exit 97
      unset VIBEGUARD_DIR
      HOME="${FIXTURE_HOME}" bash "${checker}" "${project_dir}"
    } 2>&1)"
  fi
  LAST_STATUS=$?
  set -e
}

copy_distribution() {
  local target="$1"
  mkdir -p "${target}/scripts/verify" "${target}/scripts/lib" "${target}/schemas"
  cp "${REPO_DIR}/scripts/verify/compliance_check.sh" "${target}/scripts/verify/"
  cp "${REPO_DIR}/scripts/lib/guard_paths.sh" "${target}/scripts/lib/"
  cp "${REPO_DIR}/scripts/lib/hooks_manifest.py" "${target}/scripts/lib/"
  cp "${REPO_DIR}/scripts/lib/project_config_validate.py" "${target}/scripts/lib/"
  cp "${REPO_DIR}/scripts/lib/project_schema_contract.py" "${target}/scripts/lib/"
  cp "${REPO_DIR}/scripts/lib/vibeguard_manifest.py" "${target}/scripts/lib/"
  cp "${REPO_DIR}/schemas/vibeguard-project.schema.json" "${target}/schemas/"
  cp "${REPO_DIR}/schemas/install-modules.json" "${target}/schemas/"
  cp -R "${REPO_DIR}/guards" "${target}/guards"
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

PROJECT_DIR="${TMP_DIR}/project"
RUST_PROJECT="${TMP_DIR}/rust project"
GO_PROJECT="${TMP_DIR}/go project"
JS_PROJECT="${TMP_DIR}/javascript project"
TS_PROJECT="${TMP_DIR}/typescript project"
TS_JS_PROJECT="${TMP_DIR}/typescript javascript project"
MIXED_PROJECT="${TMP_DIR}/mixed project"
MISSING_CONFIG_PROJECT="${TMP_DIR}/missing config project"
MISSING_LANGUAGES_PROJECT="${TMP_DIR}/missing languages project"
EMPTY_LANGUAGES_PROJECT="${TMP_DIR}/empty languages project"
INVALID_JSON_PROJECT="${TMP_DIR}/invalid json project"
INVALID_TYPE_PROJECT="${TMP_DIR}/invalid type project"
UNSUPPORTED_LANGUAGE_PROJECT="${TMP_DIR}/unsupported language project"
FIXTURE_HOME="${TMP_DIR}/home"
OUTSIDE_CWD="${TMP_DIR}/outside cwd"
OVERRIDE_ROOT="${TMP_DIR}/explicit root"
MISSING_MAPPING_ROOT="${TMP_DIR}/missing mapping distribution"
INVALID_PATHS_ROOT="${TMP_DIR}/invalid paths distribution"
CONTROL_PATH_ROOT="${TMP_DIR}/control path distribution"
MALFORMED_OUTPUT_ROOT="${TMP_DIR}/malformed output distribution"

mkdir -p \
  "${FIXTURE_HOME}/.claude/skills/vibeguard" \
  "${FIXTURE_HOME}/.claude/rules/vibeguard" \
  "${OUTSIDE_CWD}" \
  "${OVERRIDE_ROOT}/guards/python"

for project in \
  "${PROJECT_DIR}" \
  "${RUST_PROJECT}" \
  "${GO_PROJECT}" \
  "${JS_PROJECT}" \
  "${TS_PROJECT}" \
  "${TS_JS_PROJECT}" \
  "${MIXED_PROJECT}" \
  "${MISSING_CONFIG_PROJECT}" \
  "${MISSING_LANGUAGES_PROJECT}" \
  "${EMPTY_LANGUAGES_PROJECT}" \
  "${INVALID_JSON_PROJECT}" \
  "${INVALID_TYPE_PROJECT}" \
  "${UNSUPPORTED_LANGUAGE_PROJECT}"; do
  make_project "${project}"
done

printf '%s\n' '{"languages":["python"]}' > "${PROJECT_DIR}/.vibeguard.json"
printf '%s\n' '{"languages":["rust"]}' > "${RUST_PROJECT}/.vibeguard.json"
printf '%s\n' '{"languages":["go"]}' > "${GO_PROJECT}/.vibeguard.json"
printf '%s\n' '{"languages":["javascript"]}' > "${JS_PROJECT}/.vibeguard.json"
printf '%s\n' '{"languages":["typescript"]}' > "${TS_PROJECT}/.vibeguard.json"
printf '%s\n' '{"languages":["typescript","javascript"]}' > "${TS_JS_PROJECT}/.vibeguard.json"
printf '%s\n' '{"languages":["rust","go","typescript","javascript"]}' > "${MIXED_PROJECT}/.vibeguard.json"
printf '%s\n' '{}' > "${MISSING_LANGUAGES_PROJECT}/.vibeguard.json"
printf '%s\n' '{"languages":[]}' > "${EMPTY_LANGUAGES_PROJECT}/.vibeguard.json"
printf '%s\n' '{"languages":["rust"]' > "${INVALID_JSON_PROJECT}/.vibeguard.json"
printf '%s\n' '{"languages":"rust"}' > "${INVALID_TYPE_PROJECT}/.vibeguard.json"
printf '%s\n' '{"languages":["ruby"]}' > "${UNSUPPORTED_LANGUAGE_PROJECT}/.vibeguard.json"
printf '%s\n' 'VibeGuard anti-hallucination rules.' > "${FIXTURE_HOME}/.claude/CLAUDE.md"
printf '%s\n' '# duplicate fixture' > "${OVERRIDE_ROOT}/guards/python/check_duplicates.py"
printf '%s\n' '# naming fixture' > "${OVERRIDE_ROOT}/guards/python/check_naming_convention.py"

printf '\n=== compliance_check language-aware guard discovery ===\n'

run_checker "${CHECKER}" "${PROJECT_DIR}"
default_output="${LAST_OUTPUT}"
default_status="${LAST_STATUS}"

assert_eq "default invocation preserves compliance exit contract" 0 "${default_status}"
assert_contains \
  "default invocation finds bundled duplicate guard from external cwd" \
  "${default_output}" \
  "check_duplicates.py available (${REPO_DIR}/guards/python/check_duplicates.py)"
assert_contains \
  "default invocation finds bundled naming guard from external cwd" \
  "${default_output}" \
  "check_naming_convention.py available (${REPO_DIR}/guards/python/check_naming_convention.py)"
assert_not_contains \
  "default invocation does not emit duplicate guard not-found warning" \
  "${default_output}" \
  "check_duplicates.py not found"
assert_not_contains \
  "default invocation does not emit naming guard not-found warning" \
  "${default_output}" \
  "check_naming_convention.py not found"
assert_contains "Python project reports manifest guard module" "${default_output}" "guard module guards-python available"
assert_contains "Python project preserves ruff check" "${default_output}" "ruff linting configured"
assert_contains "Python project preserves architecture guard check" "${default_output}" "test_code_quality_guards.py not found"

run_checker "${CHECKER}" "${PROJECT_DIR}" "${OVERRIDE_ROOT}"
override_output="${LAST_OUTPUT}"
override_status="${LAST_STATUS}"

assert_eq "explicit root preserves compliance exit contract" 0 "${override_status}"
assert_contains \
  "explicit root with spaces wins for duplicate guard" \
  "${override_output}" \
  "check_duplicates.py available (${OVERRIDE_ROOT}/guards/python/check_duplicates.py)"
assert_contains \
  "explicit root with spaces wins for naming guard" \
  "${override_output}" \
  "check_naming_convention.py available (${OVERRIDE_ROOT}/guards/python/check_naming_convention.py)"
assert_not_contains \
  "explicit root does not fall back to repository duplicate guard" \
  "${override_output}" \
  "check_duplicates.py available (${REPO_DIR}/guards/python/check_duplicates.py)"
assert_not_contains \
  "explicit root does not fall back to repository naming guard" \
  "${override_output}" \
  "check_naming_convention.py available (${REPO_DIR}/guards/python/check_naming_convention.py)"

run_checker "${CHECKER}" "${RUST_PROJECT}"
assert_eq "Rust project preserves compliance exit contract" 0 "${LAST_STATUS}"
assert_contains "Rust project reports manifest guard module" "${LAST_OUTPUT}" "guard module guards-rust available"
for python_surface in check_duplicates.py check_naming_convention.py "ruff linting" test_code_quality_guards.py; do
  assert_not_contains "Rust project omits Python surface: ${python_surface}" "${LAST_OUTPUT}" "${python_surface}"
done

run_checker "${CHECKER}" "${GO_PROJECT}"
assert_eq "Go project preserves compliance exit contract" 0 "${LAST_STATUS}"
assert_contains "Go project reports manifest guard module" "${LAST_OUTPUT}" "guard module guards-go available"

run_checker "${CHECKER}" "${JS_PROJECT}"
assert_eq "JavaScript project preserves compliance exit contract" 0 "${LAST_STATUS}"
assert_contains "JavaScript maps to TypeScript guard module" "${LAST_OUTPUT}" "guard module guards-typescript available"

run_checker "${CHECKER}" "${TS_PROJECT}"
assert_eq "TypeScript project preserves compliance exit contract" 0 "${LAST_STATUS}"
assert_contains "TypeScript project reports manifest guard module" "${LAST_OUTPUT}" "guard module guards-typescript available"

run_checker "${CHECKER}" "${TS_JS_PROJECT}"
assert_eq "TypeScript and JavaScript project preserves exit contract" 0 "${LAST_STATUS}"
assert_count "TypeScript and JavaScript share one guard module report" "${LAST_OUTPUT}" "guard module guards-typescript available" 1

run_checker "${CHECKER}" "${MIXED_PROJECT}"
assert_eq "mixed project preserves compliance exit contract" 0 "${LAST_STATUS}"
assert_count "mixed project reports Rust guard once" "${LAST_OUTPUT}" "guard module guards-rust available" 1
assert_count "mixed project reports Go guard once" "${LAST_OUTPUT}" "guard module guards-go available" 1
assert_count "mixed project reports shared TypeScript guard once" "${LAST_OUTPUT}" "guard module guards-typescript available" 1

for undeclared_project in "${MISSING_CONFIG_PROJECT}" "${MISSING_LANGUAGES_PROJECT}" "${EMPTY_LANGUAGES_PROJECT}"; do
  run_checker "${CHECKER}" "${undeclared_project}"
  assert_eq "undeclared language scope preserves compliance exit contract: ${undeclared_project}" 0 "${LAST_STATUS}"
  assert_contains "undeclared language scope emits warning: ${undeclared_project}" "${LAST_OUTPUT}" "project language scope undeclared"
  assert_not_contains "undeclared language scope does not fabricate guard coverage: ${undeclared_project}" "${LAST_OUTPUT}" "guard module guards-"
  assert_not_contains "undeclared language scope does not fall back to Python: ${undeclared_project}" "${LAST_OUTPUT}" "check_duplicates.py"
done

for invalid_project in "${INVALID_JSON_PROJECT}" "${INVALID_TYPE_PROJECT}" "${UNSUPPORTED_LANGUAGE_PROJECT}"; do
  run_checker "${CHECKER}" "${invalid_project}"
  assert_eq "invalid language config fails compliance: ${invalid_project}" 1 "${LAST_STATUS}"
  assert_contains "invalid language config emits named failure: ${invalid_project}" "${LAST_OUTPUT}" "project language configuration invalid"
  assert_not_contains "invalid language config does not fall back to Python: ${invalid_project}" "${LAST_OUTPUT}" "check_duplicates.py"
done

copy_distribution "${MISSING_MAPPING_ROOT}"
python3 - "${MISSING_MAPPING_ROOT}/schemas/install-modules.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
manifest = json.loads(path.read_text(encoding="utf-8"))
manifest["modules"] = [module for module in manifest["modules"] if module.get("id") != "guards-rust"]
path.write_text(json.dumps(manifest), encoding="utf-8")
PY
run_checker "${MISSING_MAPPING_ROOT}/scripts/verify/compliance_check.sh" "${RUST_PROJECT}"
assert_eq "missing language guard mapping fails compliance" 1 "${LAST_STATUS}"
assert_contains "missing language guard mapping emits named failure" "${LAST_OUTPUT}" "language guard module resolution failed"
assert_not_contains "missing language guard mapping does not fall back to Python" "${LAST_OUTPUT}" "check_duplicates.py"

copy_distribution "${INVALID_PATHS_ROOT}"
python3 - "${INVALID_PATHS_ROOT}/schemas/install-modules.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
manifest = json.loads(path.read_text(encoding="utf-8"))
for module in manifest["modules"]:
    if module.get("id") == "guards-rust":
        module["paths"] = []
path.write_text(json.dumps(manifest), encoding="utf-8")
PY
run_checker "${INVALID_PATHS_ROOT}/scripts/verify/compliance_check.sh" "${RUST_PROJECT}"
assert_eq "empty guard paths fail compliance" 1 "${LAST_STATUS}"
assert_contains "empty guard paths emit named failure" "${LAST_OUTPUT}" "language guard module resolution failed"
assert_not_contains "empty guard paths do not fall back to Python" "${LAST_OUTPUT}" "check_duplicates.py"

copy_distribution "${CONTROL_PATH_ROOT}"
python3 - "${CONTROL_PATH_ROOT}/schemas/install-modules.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
manifest = json.loads(path.read_text(encoding="utf-8"))
for module in manifest["modules"]:
    if module.get("id") == "guards-rust":
        module["paths"] = ["guards/rust/\nforged"]
path.write_text(json.dumps(manifest), encoding="utf-8")
PY
run_checker "${CONTROL_PATH_ROOT}/scripts/verify/compliance_check.sh" "${RUST_PROJECT}"
assert_eq "control-character guard path fails compliance" 1 "${LAST_STATUS}"
assert_contains "control-character guard path emits named failure" "${LAST_OUTPUT}" "language guard module resolution failed"
assert_not_contains "control-character guard path cannot forge availability" "${LAST_OUTPUT}" "guard module forged available"
assert_not_contains "control-character guard path does not fall back to Python" "${LAST_OUTPUT}" "check_duplicates.py"

copy_distribution "${MALFORMED_OUTPUT_ROOT}"
printf '%s\n' \
  'import sys' \
  'if "guard-modules" in sys.argv:' \
  '    print("forged")' \
  'else:' \
  '    raise SystemExit(1)' \
  > "${MALFORMED_OUTPUT_ROOT}/scripts/lib/vibeguard_manifest.py"
run_checker "${MALFORMED_OUTPUT_ROOT}/scripts/verify/compliance_check.sh" "${RUST_PROJECT}"
assert_eq "malformed helper record fails compliance" 1 "${LAST_STATUS}"
assert_contains "malformed helper record emits named failure" "${LAST_OUTPUT}" "language guard module resolution returned a malformed record"
assert_not_contains "malformed helper record cannot forge availability" "${LAST_OUTPUT}" "guard module forged available"

echo
printf 'Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n' \
  "${TOTAL}" "${PASS}" "${FAIL}"
[[ "${FAIL}" -gt 0 ]] && exit 1 || exit 0
