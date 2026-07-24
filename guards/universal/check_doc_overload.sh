#!/usr/bin/env bash
# VibeGuard Guard — Agent-instruction document overload detection (W-19)
#
# Detect four anti-patterns in the effective agent-instruction surface:
#   1. File too long       — > 200 lines warns, > 800 lines fails in --strict
#   2. Unpaired prohibitions — > 30 Chinese 禁止/不要 rules without paired ✅ GOOD examples
#   3. Inline redefinition  — a canonical vibeguard rule ID from the curated
#                              CANONICAL_IDS list below appears ≥ 3 times in one file
#   4. Always-on rule injection — native rule files under `.claude/rules/`
#                              (or `rules/` when the target dir is a `.claude`
#                              home) that lack `paths:` frontmatter are injected
#                              into every session; their aggregate line count is
#                              part of the instruction surface even though the
#                              doc files themselves look small (GH-683)
#
# The vibeguard auto-gen region (between `<!-- vibeguard-start -->` and
# `<!-- vibeguard-end -->`) is excluded from line counting.
#
# Usage:
#   bash check_doc_overload.sh [target_dir]
#   bash check_doc_overload.sh --strict [target_dir]
#
# Exit code:
#   0 — No problem, or warning-only findings
#   1 — Fail-level violations found in --strict mode

set -euo pipefail

STRICT=false
TARGET_DIR="."
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=true ;;
    *) TARGET_DIR="$arg" ;;
  esac
done

WARN_LINES=200
FAIL_LINES=800
PROHIBITION_THRESHOLD=30
CANONICAL_REDEF_THRESHOLD=3

# Files to inspect (skip silently if missing). CLAUDE.md locations are fixed,
# while AGENTS.md can appear anywhere under a project subtree.
DOC_FILES=()
for relpath in CLAUDE.md .claude/CLAUDE.md; do
  full="${TARGET_DIR}/${relpath}"
  [[ -f "$full" ]] && DOC_FILES+=("$full")
done
while IFS= read -r -d '' full; do
  DOC_FILES+=("$full")
done < <(
  find "$TARGET_DIR" \
    \( \
      -path '*/.git' -o \
      -path '*/node_modules' -o \
      -path '*/target' -o \
      -path '*/vendor' -o \
      -path '*/dist' -o \
      -path '*/build' -o \
      -path '*/.venv' -o \
      -path '*/__pycache__' -o \
      -path '*/.claude/worktrees' \
    \) -prune -o \
    -type f -name 'AGENTS.md' -print0
)

# Always-on native rule surface: `.claude/rules/` under a project dir, or
# `rules/` when the target dir is itself a `.claude` home (~/.claude).
RULES_DIRS=()
[[ -d "${TARGET_DIR}/.claude/rules" ]] && RULES_DIRS+=("${TARGET_DIR}/.claude/rules")
if [[ "$(basename "$(cd "${TARGET_DIR}" && pwd)")" == ".claude" && -d "${TARGET_DIR}/rules" ]]; then
  RULES_DIRS+=("${TARGET_DIR}/rules")
fi

if [[ ${#DOC_FILES[@]} -eq 0 && ${#RULES_DIRS[@]} -eq 0 ]]; then
  exit 0
fi

WARNINGS=0
FAILURES=0
warn() {
  printf '\033[33m[W-19]\033[0m %s\n' "$1"
  WARNINGS=$((WARNINGS + 1))
}
fail() {
  printf '\033[31m[W-19]\033[0m %s\n' "$1"
  FAILURES=$((FAILURES + 1))
}

# Canonical vibeguard rule IDs that are commonly inlined in project CLAUDE.md.
# IDs are constructed via prefix + number to avoid being detected as
# mechanical-rule references by scripts/lib/vibeguard_manifest.py
# (the GUARD_RULE_RE regex would otherwise treat e.g. "U-29" as a guard ref).
DASH="-"
CANONICAL_IDS=(
  "U${DASH}17" "U${DASH}26" "U${DASH}27" "U${DASH}28" "U${DASH}29"
  "U${DASH}30" "U${DASH}31" "U${DASH}32"
  "W${DASH}01" "W${DASH}02" "W${DASH}03" "W${DASH}04"
  "W${DASH}10" "W${DASH}11" "W${DASH}12" "W${DASH}13"
  "W${DASH}15" "W${DASH}16" "W${DASH}17"
)

# A rule file is path-scoped (loaded on demand) only when its YAML frontmatter
# declares a `paths:` key; everything else is injected into every session.
_rule_is_path_scoped() {
  awk '
    NR == 1 { if ($0 != "---") exit; next }
    /^---[[:space:]]*$/ { exit }
    /^paths:/ { found = 1; exit }
    NR > 40 { exit }
    END { exit(found ? 0 : 1) }
  ' "$1"
}

echo "Doc Overload Check (W-19): ${TARGET_DIR}"
echo "---"

for file in ${DOC_FILES[@]+"${DOC_FILES[@]}"}; do
  # Strip the vibeguard auto-gen region so line counts reflect user-authored content
  CONTENT=$(awk '
    /<!-- vibeguard-start -->/ { skip = 1; next }
    /<!-- vibeguard-end -->/   { skip = 0; next }
    !skip
  ' "$file")

  LINES=$(printf '%s\n' "$CONTENT" | wc -l | tr -d ' ')

  # Check 1: line count
  if [[ "$LINES" -gt "$FAIL_LINES" ]]; then
    fail "$file:1 file is $LINES lines (limit $FAIL_LINES, ignoring vibeguard auto-gen region). Fix: keep a short index and move topic detail into .claude/references/"
  elif [[ "$LINES" -gt "$WARN_LINES" ]]; then
    warn "$file:1 file is $LINES lines (target ≤$WARN_LINES, ignoring vibeguard auto-gen region). Fix: keep a short index and move topic detail into .claude/references/"
  fi

  # Check 2: prohibition density
  DONT_COUNT=$(printf '%s\n' "$CONTENT" | grep -cE '禁止|不要' || true)
  if [[ "$DONT_COUNT" -gt "$PROHIBITION_THRESHOLD" ]]; then
    warn "$file:1 contains $DONT_COUNT Chinese prohibition rules (禁止/不要) above threshold $PROHIBITION_THRESHOLD. Fix: pair each with a concrete ✅ GOOD example or move warnings to references"
  fi

  # Check 3: inline redefinition of canonical vibeguard rules
  for rid in "${CANONICAL_IDS[@]}"; do
    COUNT=$(printf '%s\n' "$CONTENT" | grep -cE "[^[:alnum:]]${rid}[^[:alnum:]]|^${rid}[^[:alnum:]]" || true)
    if [[ "$COUNT" -ge "$CANONICAL_REDEF_THRESHOLD" ]]; then
      warn "$file:1 mentions canonical vibeguard rule $rid $COUNT times (canonical source: rules/claude-rules/). Fix: replace inline text with a single-line reference like 'see vibeguard $rid'"
    fi
  done
done

# Check 4: aggregate size of always-on native rule files (no `paths:` frontmatter)
if [[ ${#RULES_DIRS[@]} -gt 0 ]]; then
  ALWAYS_ON_TOTAL=0
  ALWAYS_ON_COUNT=0
  ALWAYS_ON_DETAIL=""
  while IFS= read -r -d '' rule_file; do
    _rule_is_path_scoped "$rule_file" && continue
    RULE_LINES=$(wc -l < "$rule_file" | tr -d ' ')
    ALWAYS_ON_TOTAL=$((ALWAYS_ON_TOTAL + RULE_LINES))
    ALWAYS_ON_COUNT=$((ALWAYS_ON_COUNT + 1))
    ALWAYS_ON_DETAIL="${ALWAYS_ON_DETAIL}${RULE_LINES}	${rule_file}
"
  done < <(find -L "${RULES_DIRS[@]}" -type f -name '*.md' -print0 2>/dev/null)

  if [[ "$ALWAYS_ON_TOTAL" -gt "$WARN_LINES" ]]; then
    TOP_RULES=$(printf '%s' "$ALWAYS_ON_DETAIL" | sort -rn | head -3 \
      | awk -F '	' '{ printf "%s (%s lines); ", $2, $1 }')
    RULE_MSG="always-on native rules inject ${ALWAYS_ON_TOTAL} lines across ${ALWAYS_ON_COUNT} files without paths: frontmatter"
    RULE_FIX="Fix: add paths: frontmatter to scope rules to file types, or demote long-tail rules to skills/on-demand references"
    if [[ "$ALWAYS_ON_TOTAL" -gt "$FAIL_LINES" ]]; then
      fail "${RULE_MSG} (limit ${FAIL_LINES}). Largest: ${TOP_RULES}${RULE_FIX}"
    else
      warn "${RULE_MSG} (target ≤${WARN_LINES}). Largest: ${TOP_RULES}${RULE_FIX}"
    fi
  fi
fi

echo "---"
if [[ "$WARNINGS" -eq 0 && "$FAILURES" -eq 0 ]]; then
  printf '\033[32m[W-19] OK: agent-instruction docs within sustainable size\033[0m\n'
  exit 0
fi

echo "Warnings: $WARNINGS"
echo "Failures: $FAILURES"
[[ "$STRICT" == "true" && "$FAILURES" -gt 0 ]] && exit 1
exit 0
