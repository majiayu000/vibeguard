#!/usr/bin/env bash
# VibeGuard Project Init — Generate project-level guard configuration for the current warehouse
#
# Detect language/framework → List activated guards/rules → Generate project-level CLAUDE.md fragment
#
# Usage: bash project-init.sh [project_root]
set -euo pipefail

PROJECT_ROOT="${1:-$(pwd)}"
cd "$PROJECT_ROOT" || { echo "ERROR: Unable to enter directory $PROJECT_ROOT"; exit 1; }

VIBEGUARD_DIR="${VIBEGUARD_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"

echo "=== VibeGuard Project Init ==="
echo "Project: $PROJECT_ROOT"
echo

# --- Language/Framework Detection ---
LANGS=()
FRAMEWORKS=()
BUILD_CMDS=()
TEST_CMDS=()

if [[ -f "Cargo.toml" ]]; then
  LANGS+=("rust")
  BUILD_CMDS+=("cargo check")
  TEST_CMDS+=("cargo test")
  if grep -q "actix-web\|axum\|rocket" Cargo.toml 2>/dev/null; then
    FRAMEWORKS+=("rust-web")
  fi
fi

if [[ -f "tsconfig.json" ]]; then
  LANGS+=("typescript")
  BUILD_CMDS+=("npx tsc --noEmit")
  if [[ -f "package.json" ]]; then
    if grep -q '"test"' package.json 2>/dev/null; then
      TEST_CMDS+=("npm test")
    fi
    if grep -q "next" package.json 2>/dev/null; then
      FRAMEWORKS+=("nextjs")
    elif grep -q "react" package.json 2>/dev/null; then
      FRAMEWORKS+=("react")
    fi
  fi
elif [[ -f "package.json" ]]; then
  LANGS+=("javascript")
  if grep -q '"test"' package.json 2>/dev/null; then
    TEST_CMDS+=("npm test")
  fi
fi

if [[ -f "go.mod" ]]; then
  LANGS+=("go")
  BUILD_CMDS+=("go build ./...")
  TEST_CMDS+=("go test ./...")
fi

if [[ -f "pyproject.toml" ]] || [[ -f "requirements.txt" ]]; then
  LANGS+=("python")
  TEST_CMDS+=("pytest")
fi

if [[ ${#LANGS[@]} -eq 0 ]]; then
  echo "No known language detected, skipping."
  exit 0
fi

echo "Language detected: ${LANGS[*]}"
[[ ${#FRAMEWORKS[@]} -gt 0 ]] && echo "Frame detected: ${FRAMEWORKS[*]}"
echo

# --- List active guards ---
echo "--- activated guard ---"
GUARDS_DIR="$VIBEGUARD_DIR/guards"
ACTIVE_GUARDS=()

# Universal guard
if [[ -d "$GUARDS_DIR/universal" ]]; then
  for g in "$GUARDS_DIR/universal"/check_*.sh; do
    [[ -f "$g" ]] || continue
    ACTIVE_GUARDS+=("$(basename "$g")")
    echo "[General] $(basename "$g")"
  done
fi

# Language Guard
for lang in "${LANGS[@]}"; do
  LANG_DIR=""
  case "$lang" in
    rust) LANG_DIR="$GUARDS_DIR/rust" ;;
    typescript|javascript) LANG_DIR="$GUARDS_DIR/typescript" ;;
    go) LANG_DIR="$GUARDS_DIR/go" ;;
  esac
  if [[ -n "$LANG_DIR" ]] && [[ -d "$LANG_DIR" ]]; then
    for g in "$LANG_DIR"/check_*.sh; do
      [[ -f "$g" ]] || continue
      ACTIVE_GUARDS+=("$(basename "$g")")
      echo "  [${lang}] $(basename "$g")"
    done
  fi
done
echo "A total of ${#ACTIVE_GUARDS[@]} guards activated"
echo

# --- List activated native rules ---
echo "---Activated native rules ---"
RULES_DIR="$HOME/.claude/rules/vibeguard"
RULE_COUNT=0

if [[ -d "$RULES_DIR/common" ]]; then
  for rf in "$RULES_DIR/common"/*.md; do
    [[ -f "$rf" ]] || continue
    RC=$(grep -cE '^## [A-Z]+-[0-9]+' "$rf" 2>/dev/null || echo "0")
    RULE_COUNT=$((RULE_COUNT + RC))
    echo "[General] $(basename "$rf"): ${RC} rules"
  done
fi

for lang in "${LANGS[@]}"; do
  LANG_RULE_DIR=""
  case "$lang" in
    rust) LANG_RULE_DIR="$RULES_DIR/rust" ;;
    typescript|javascript) LANG_RULE_DIR="$RULES_DIR/typescript" ;;
    go|golang) LANG_RULE_DIR="$RULES_DIR/golang" ;;
    python) LANG_RULE_DIR="$RULES_DIR/python" ;;
  esac
  if [[ -n "$LANG_RULE_DIR" ]] && [[ -d "$LANG_RULE_DIR" ]]; then
    for rf in "$LANG_RULE_DIR"/*.md; do
      [[ -f "$rf" ]] || continue
      RC=$(grep -cE '^## [A-Z]+-[0-9]+' "$rf" 2>/dev/null || echo "0")
      RULE_COUNT=$((RULE_COUNT + RC))
      echo "[${lang}] $(basename "$rf"): ${RC} rules"
    done
  fi
done
echo "A total of ${RULE_COUNT} rules activated"
echo

# --- Check if project-level CLAUDE.md already exists ---
if [[ -f "CLAUDE.md" ]]; then
  echo "The project already has CLAUDE.md, skip generation."
  echo "It is recommended to add the following content manually:"
  echo
else
  echo "The project does not have CLAUDE.md, you can choose to generate it."
  echo
fi

# --- Output suggested CLAUDE.md fragment ---
echo "--- Suggested project CLAUDE.md snippet ---"
echo
echo '```markdown'
echo "# project constraints"
echo
echo "## build command"
for cmd in "${BUILD_CMDS[@]}"; do
  echo "- \`$cmd\`"
done
echo
echo "## test command"
for cmd in "${TEST_CMDS[@]}"; do
  echo "- \`$cmd\`"
done
echo

#monorepo detection
ENTRY_POINTS=$(find . -maxdepth 3 \( -name node_modules -o -name .git -o -name target -o -name vendor -o -name dist \) -prune -o \( -name "main.rs" -o -name "main.go" \) -print 2>/dev/null | wc -l | tr -d ' ')
if [[ "$ENTRY_POINTS" -gt 1 ]]; then
  echo "## Data consistency (Monorepo)"
  echo "Multiple entry projects (${ENTRY_POINTS} entries), pay attention to U-11~U-14 data consistency rules."
  echo
fi

echo "## VibeGuard guard"
echo "${#ACTIVE_GUARDS[@]} guards + ${RULE_COUNT} rules activated"
echo '```'
echo
# --- Automatically install git hooks ---
echo "--- Git Hooks ---"
PRE_COMMIT_WRAPPER="${HOME}/.vibeguard/pre-commit"
PRE_PUSH_HOOK_SRC="${VIBEGUARD_DIR}/hooks/git/pre-push"
GIT_HOOKS_DIR="${PROJECT_ROOT}/.git/hooks"
if [[ -d "${PROJECT_ROOT}/.git" ]] && [[ -f "$PRE_COMMIT_WRAPPER" ]]; then
  mkdir -p "$GIT_HOOKS_DIR"
  if [[ -f "$GIT_HOOKS_DIR/pre-commit" ]]; then
    echo ".git/hooks/pre-commit already exists, skip (manual override: ln -sf $PRE_COMMIT_WRAPPER $GIT_HOOKS_DIR/pre-commit)"
  else
    ln -sf "$PRE_COMMIT_WRAPPER" "$GIT_HOOKS_DIR/pre-commit"
    echo "pre-commit hook installed"
  fi
  if [[ -f "$PRE_PUSH_HOOK_SRC" ]]; then
    if [[ -f "$GIT_HOOKS_DIR/pre-push" ]]; then
      echo ".git/hooks/pre-push already exists, skip (manual overwrite: ln -sf $PRE_PUSH_HOOK_SRC $GIT_HOOKS_DIR/pre-push)"
    else
      ln -sf "$PRE_PUSH_HOOK_SRC" "$GIT_HOOKS_DIR/pre-push"
      echo "pre-push hook installed"
    fi
  else
    echo "Missing pre-push hook source file: $PRE_PUSH_HOOK_SRC"
  fi
elif [[ ! -d "${PROJECT_ROOT}/.git" ]]; then
  echo "Non-git repository, skip"
elif [[ ! -f "$PRE_COMMIT_WRAPPER" ]]; then
  echo " ~/.vibeguard/pre-commit does not exist, please run install.sh first"
fi
echo

echo "=== Done ==="
