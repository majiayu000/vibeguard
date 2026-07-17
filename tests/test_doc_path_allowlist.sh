#!/usr/bin/env bash
# Focused regression tests for structured doc-path allowlist validation.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATOR="${REPO_DIR}/scripts/ci/validate-doc-paths.sh"
PASS=0
FAIL=0
TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }

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

assert_fails_with() {
  local desc="$1" expected="$2"
  shift 2
  TOTAL=$((TOTAL + 1))
  local output
  if output="$("$@" 2>&1)"; then
    red "$desc (expected failure)"
    FAIL=$((FAIL + 1))
  elif grep -qF -- "$expected" <<< "$output"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (expected output to contain: $expected)"
    printf '%s\n' "$output"
    FAIL=$((FAIL + 1))
  fi
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

new_fixture() {
  local name="$1"
  local root="${TMP_DIR}/${name}"
  mkdir -p \
    "${root}/docs" \
    "${root}/plan" \
    "${root}/scripts/lib" \
    "${root}/scripts" \
    "${root}/rules/claude-rules/common"
  printf 'runtime source\n' > "${root}/scripts/tool.sh"
  printf 'installed source\n' > "${root}/rules/claude-rules/common/security.md"
  cat > "${root}/scripts/lib/vibeguard_manifest.py" <<'PY'
#!/usr/bin/env python3
import sys

if sys.argv[1:] != ["rule-links"]:
    raise SystemExit(2)
print("rules/claude-rules/common/security.md\tcommon/security.md\tcommon")
PY
  cat > "${root}/docs/runtime.md" <<'MD'
Runtime alias: `vibeguard/scripts/tool.sh`.
Runtime alias again: `vibeguard/scripts/tool.sh`.
MD
  printf "Installed alias: \`common/security.md\`.\n" > "${root}/docs/installed.md"
  cat > "${root}/plan/history.md" <<'MD'
Historical reference: `retired/tool.sh`.
Planned reference: `future/tool.sh`.
MD
  cat > "${root}/.vibeguard-doc-paths-allowlist" <<'ALLOW'
vibeguard/scripts/tool.sh | runtime_alias | docs/runtime.md | scripts/tool.sh | Runtime root alias
common/security.md | installed_alias | docs/installed.md | rules/claude-rules/common/security.md | Installed native rule target
retired/tool.sh | historical | plan/** | - | Completed plan evidence
future/tool.sh | planned | plan/** | - | Approved future path
ALLOW
  git -C "${root}" init -q
  git -C "${root}" add .
  printf '%s\n' "${root}"
}

valid_fixture="$(new_fixture valid)"
assert_cmd "four categories and single-entry multi-occurrence pass" \
  bash "${VALIDATOR}" "${valid_fixture}" "${valid_fixture}"

first_out="$(bash "${VALIDATOR}" "${valid_fixture}" "${valid_fixture}")"
second_out="$(bash "${VALIDATOR}" "${valid_fixture}" "${valid_fixture}")"
TOTAL=$((TOTAL + 1))
if [[ "${first_out}" == "${second_out}" ]]; then
  green "same tracked tree produces deterministic output"
  PASS=$((PASS + 1))
else
  red "same tracked tree produces deterministic output"
  FAIL=$((FAIL + 1))
fi

format_fixture="$(new_fixture format)"
printf 'broken | historical | plan/** | -\n' >> "${format_fixture}/.vibeguard-doc-paths-allowlist"
assert_fails_with "invalid five-field format fails" "invalid_allowlist_format" \
  bash "${VALIDATOR}" "${format_fixture}" "${format_fixture}"

category_fixture="$(new_fixture category)"
printf 'retired/other.sh | unknown | plan/** | - | Unknown category\n' >> \
  "${category_fixture}/.vibeguard-doc-paths-allowlist"
printf "Other: \`retired/other.sh\`.\n" >> "${category_fixture}/plan/history.md"
git -C "${category_fixture}" add .
assert_fails_with "unknown category fails" "invalid_allowlist_category" \
  bash "${VALIDATOR}" "${category_fixture}" "${category_fixture}"

source_fixture="$(new_fixture source)"
printf 'retired/other.sh | historical | plan/** | scripts/tool.sh | Bad absent source\n' >> \
  "${source_fixture}/.vibeguard-doc-paths-allowlist"
printf "Other: \`retired/other.sh\`.\n" >> "${source_fixture}/plan/history.md"
git -C "${source_fixture}" add .
assert_fails_with "historical canonical source must be absent" "invalid_absent_source" \
  bash "${VALIDATOR}" "${source_fixture}" "${source_fixture}"

scope_fixture="$(new_fixture scope)"
printf 'retired/other.sh | historical | docs/runtime.md | - | Scope is too broad\n' >> \
  "${scope_fixture}/.vibeguard-doc-paths-allowlist"
assert_fails_with "historical scope outside approved roots fails" "invalid_allowlist_scope" \
  bash "${VALIDATOR}" "${scope_fixture}" "${scope_fixture}"

unused_fixture="$(new_fixture unused)"
printf 'retired/unused.sh | historical | plan/** | - | No live occurrence\n' >> \
  "${unused_fixture}/.vibeguard-doc-paths-allowlist"
assert_fails_with "unused entry fails" "unused_allowlist_entry: retired/unused.sh" \
  bash "${VALIDATOR}" "${unused_fixture}" "${unused_fixture}"

duplicate_fixture="$(new_fixture duplicate)"
duplicate_line="$(head -n 1 "${duplicate_fixture}/.vibeguard-doc-paths-allowlist")"
printf '%s\n' "${duplicate_line}" >> "${duplicate_fixture}/.vibeguard-doc-paths-allowlist"
assert_fails_with "normalized duplicate entry fails" "duplicate_allowlist_entry" \
  bash "${VALIDATOR}" "${duplicate_fixture}" "${duplicate_fixture}"

overlap_fixture="$(new_fixture overlap)"
printf 'vibeguard/scripts/tool.sh | runtime_alias | docs/** | scripts/tool.sh | Overlapping scope\n' >> \
  "${overlap_fixture}/.vibeguard-doc-paths-allowlist"
assert_fails_with "one occurrence matching multiple entries fails" "overlapping_allowlist_entries" \
  bash "${VALIDATOR}" "${overlap_fixture}" "${overlap_fixture}"

runtime_fixture="$(new_fixture runtime)"
printf "Old: \`vibeguard/scripts/old-tool.sh\`.\n" >> "${runtime_fixture}/docs/runtime.md"
printf 'vibeguard/scripts/old-tool.sh | runtime_alias | docs/runtime.md | scripts/tool.sh | Stale alias\n' >> \
  "${runtime_fixture}/.vibeguard-doc-paths-allowlist"
git -C "${runtime_fixture}" add .
assert_fails_with "stale runtime alias fails" "invalid_runtime_alias" \
  bash "${VALIDATOR}" "${runtime_fixture}" "${runtime_fixture}"

installed_fixture="$(new_fixture installed)"
printf "Wrong: \`common/missing.md\`.\n" >> "${installed_fixture}/docs/installed.md"
printf 'common/missing.md | installed_alias | docs/installed.md | rules/claude-rules/common/security.md | Invalid manifest pair\n' >> \
  "${installed_fixture}/.vibeguard-doc-paths-allowlist"
git -C "${installed_fixture}" add .
assert_fails_with "installed alias outside rule-links pair fails" "invalid_installed_alias" \
  bash "${VALIDATOR}" "${installed_fixture}" "${installed_fixture}"

manifest_fixture="$(new_fixture manifest)"
printf '#!/usr/bin/env python3\nraise SystemExit(7)\n' > \
  "${manifest_fixture}/scripts/lib/vibeguard_manifest.py"
git -C "${manifest_fixture}" add .
assert_fails_with "manifest command failure is visible" "manifest_mapping_error" \
  bash "${VALIDATOR}" "${manifest_fixture}" "${manifest_fixture}"

read_fixture="$(new_fixture read)"
rm "${read_fixture}/docs/runtime.md"
assert_fails_with "tracked Markdown read failure is visible" "markdown_read_error" \
  bash "${VALIDATOR}" "${read_fixture}" "${read_fixture}"

non_git_fixture="${TMP_DIR}/non-git"
mkdir -p "${non_git_fixture}"
assert_fails_with "Git enumeration failure is visible" "git_enumeration_error" \
  bash "${VALIDATOR}" "${non_git_fixture}" "${non_git_fixture}"

echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
