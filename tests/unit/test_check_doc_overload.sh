#!/usr/bin/env bash
# Unit tests for guards/universal/check_doc_overload.sh (W-19)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="${REPO_ROOT}/guards/universal/check_doc_overload.sh"

PASS=0
FAIL=0

green() { printf '\033[32m  PASS\033[0m %s\n' "$1"; }
red()   { printf '\033[31m  FAIL\033[0m %s\n' "$1"; }

run_case() {
  local name="$1"
  local expected_exit="$2"
  local expected_pattern="$3"
  shift 3

  local output exit_code
  set +e
  output="$("$GUARD" "$@" 2>&1)"
  exit_code=$?
  set -e

  if [[ "$exit_code" -ne "$expected_exit" ]]; then
    red "$name (expected exit $expected_exit, got $exit_code)"
    echo "$output" | sed 's/^/    /'
    FAIL=$((FAIL + 1))
    return
  fi

  if [[ -n "$expected_pattern" ]] && ! grep -qE "$expected_pattern" <<< "$output"; then
    red "$name (expected pattern not found: $expected_pattern)"
    echo "$output" | sed 's/^/    /'
    FAIL=$((FAIL + 1))
    return
  fi

  green "$name"
  PASS=$((PASS + 1))
}

echo "=============================="
echo " W-19 check_doc_overload tests"
echo "=============================="

# --- Case 1: empty target dir → exit 0, no output spam ---
TMP=$(mktemp -d)
run_case "empty target dir exits 0" 0 "" "$TMP"
rm -rf "$TMP"

# --- Case 2: short, well-paired CLAUDE.md → exit 0, "OK" ---
TMP=$(mktemp -d)
cat > "$TMP/CLAUDE.md" <<'EOF'
# Project Guidelines
Short and tidy.

## Rule
- 不要 hardcode paths
- ✅ GOOD: read from env

EOF
run_case "short CLAUDE.md passes" 0 "OK" "$TMP"
rm -rf "$TMP"

# --- Case 3: oversize CLAUDE.md (> 200 lines) → warn, exit 0 (no --strict) ---
TMP=$(mktemp -d)
{ echo "# Long file"; for i in $(seq 1 250); do echo "Line $i content"; done; } > "$TMP/CLAUDE.md"
run_case "oversize CLAUDE.md warns (no --strict)" 0 "file is .* lines" "$TMP"
rm -rf "$TMP"

# --- Case 4: oversize warning remains non-blocking in --strict ---
TMP=$(mktemp -d)
{ echo "# Long file"; for i in $(seq 1 250); do echo "Line $i content"; done; } > "$TMP/CLAUDE.md"
run_case "oversize CLAUDE.md warns strict" 0 "Warnings: 1" --strict "$TMP"
rm -rf "$TMP"

# --- Case 5: hugesize CLAUDE.md (> 800 lines) with --strict → exit 1 ---
TMP=$(mktemp -d)
{ echo "# Huge file"; for i in $(seq 1 900); do echo "Line $i content"; done; } > "$TMP/CLAUDE.md"
run_case "huge CLAUDE.md fails strict" 1 "file is .* lines" --strict "$TMP"
rm -rf "$TMP"

# --- Case 6: vibeguard auto-gen region is excluded from line counting ---
TMP=$(mktemp -d)
{
  echo "# Project Guidelines"
  for i in $(seq 1 50); do echo "Line $i"; done
  echo "<!-- vibeguard-start -->"
  for i in $(seq 1 500); do echo "auto-gen line $i"; done
  echo "<!-- vibeguard-end -->"
} > "$TMP/CLAUDE.md"
run_case "auto-gen region excluded from counting" 0 "OK" "$TMP"
rm -rf "$TMP"

# --- Case 7: inline canonical rule redefinition → warn, even in --strict ---
TMP=$(mktemp -d)
cat > "$TMP/CLAUDE.md" <<'EOF'
# Project Guidelines

## NO SILENT DEGRADATION (U-29)
Detail explanation 1 of U-29 anti-pattern.
Detail explanation 2 of U-29 with code example.
EOF
run_case "inline canonical rule redefinition warns strict" 0 "canonical vibeguard rule U-29" --strict "$TMP"
rm -rf "$TMP"

# --- Case 8: too many prohibitions → warn, even in --strict ---
TMP=$(mktemp -d)
{
  echo "# Project Guidelines"
  for i in $(seq 1 35); do echo "- 禁止 doing thing $i"; done
} > "$TMP/CLAUDE.md"
run_case "too many prohibitions warns strict" 0 "Chinese prohibition rules" --strict "$TMP"
rm -rf "$TMP"

# --- Case 9: root AGENTS.md is checked ---
TMP=$(mktemp -d)
{ echo "# AGENTS.md"; for i in $(seq 1 250); do echo "Line $i"; done; } > "$TMP/AGENTS.md"
run_case "AGENTS.md is also inspected" 0 "AGENTS.md" "$TMP"
rm -rf "$TMP"

# --- Case 10: nested AGENTS.md is checked ---
TMP=$(mktemp -d)
mkdir -p "$TMP/packages/api"
{ echo "# Nested AGENTS.md"; for i in $(seq 1 250); do echo "Line $i"; done; } > "$TMP/packages/api/AGENTS.md"
run_case "nested AGENTS.md is inspected" 0 "packages/api/AGENTS.md" "$TMP"
rm -rf "$TMP"

echo
echo "=============================="
TOTAL=$((PASS + FAIL))
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="
[[ "$FAIL" -eq 0 ]]
