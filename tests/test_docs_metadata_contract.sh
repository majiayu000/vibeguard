#!/usr/bin/env bash
# Focused regression tests for repository-map and presentation metadata contracts.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
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
    red "$desc"
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

check_directory_map() {
  local repo_dir="$1" map_file="$2"
  local script_dir missing=0

  while IFS= read -r script_dir; do
    if ! grep -qF -- "\`${script_dir}/\`" "$map_file"; then
      printf 'missing script directory: %s/\n' "$script_dir" >&2
      missing=1
    fi
  done < <(
    git -C "$repo_dir" ls-files 'scripts/*/**' |
      awk -F/ 'NF >= 3 {print "scripts/" $2}' |
      LC_ALL=C sort -u
  )

  return "$missing"
}

assert_cmd "directory map covers every tracked first-level scripts directory" \
  check_directory_map "$REPO_DIR" "$REPO_DIR/docs/directory-map.md"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
fixture="$TMP_DIR/repo"
mkdir -p "$fixture/scripts/ci" "$fixture/scripts/unknown" "$fixture/docs"
printf '#!/usr/bin/env bash\n' > "$fixture/scripts/ci/check.sh"
printf '#!/usr/bin/env bash\n' > "$fixture/scripts/unknown/check.sh"
printf '| Path | Role |\n| --- | --- |\n| `scripts/ci/` | CI |\n' > "$fixture/docs/directory-map.md"
git -C "$fixture" init -q
git -C "$fixture" add .
assert_fails_with "unknown tracked scripts directory fails map validation" \
  "missing script directory: scripts/unknown/" \
  check_directory_map "$fixture" "$fixture/docs/directory-map.md"

assert_cmd "site uses patch-stable v1 series wording" \
  grep -qF 'starlight · vibeguard v1 series' "$REPO_DIR/site/index.html"
assert_cmd "historical 110-rule references carry snapshot context" \
  bash -c 'test "$(grep -c "110 rules.*2026-03-23 design snapshot\|2026-03-23 design snapshot.*110 rules" "$1")" -eq 2' _ \
  "$REPO_DIR/docs/internal/benchmarks/benchmark-design.md"
assert_cmd "plan-mode exposes one activation heading" \
  bash -c 'test "$(grep -c "^## When to Activate$" "$1")" -eq 1' _ \
  "$REPO_DIR/workflows/plan-mode/SKILL.md"

echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
