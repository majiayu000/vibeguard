#!/usr/bin/env bash
# VibeGuard Guard — Test Integrity Detection (W-12)
#
# Detect attack vectors that an AI agent might use to fake test passes:
# 1. Library Shadowing - local files overwrite standard library modules
# 2. Empty Stub Detection — Test function without assertions
#
# Usage:
# bash check_test_integrity.sh [target_dir] # Scan the specified directory
# bash check_test_integrity.sh # Scan the current directory
#
#Exit code:
# 0 — No problem
#1 — Find the problem

set -euo pipefail

TARGET_DIR="${1:-.}"
ISSUES=0

yellow() { printf '\033[33m[W-12] %s\033[0m\n' "$1"; }
red()    { printf '\033[31m[W-12] %s\033[0m\n' "$1"; }
green()  { printf '\033[32m%s\033[0m\n' "$1"; }

echo "Test Integrity Check (W-12): ${TARGET_DIR}"
echo "---"

# =========================================================
# 1. Library shadow file detection
# =========================================================
echo "Check library shadow files..."

# Python standard library module name (the most common shadow target)
PYTHON_STDLIB_MODULES=(
  os sys re io json math time copy enum abc
  abc ast builtins collections datetime decimal
  functools hashlib hmac http inspect io itertools
  logging math operator os pathlib pickle platform
  queue random re shutil signal socket ssl stat string
  struct subprocess sys tempfile threading time types
  typing unittest urllib uuid warnings weakref
  numpy pandas requests flask django pytest
)

SHADOW_FOUND=0
for mod in "${PYTHON_STDLIB_MODULES[@]}"; do
  shadow_file="${TARGET_DIR}/${mod}.py"
  if [[ -f "$shadow_file" ]]; then
    rel_path="${shadow_file#${TARGET_DIR}/}"
    red "Library shadow file: ${rel_path} (shadows '${mod}' module)"
    SHADOW_FOUND=$((SHADOW_FOUND + 1))
    ISSUES=$((ISSUES + 1))
  fi
  # Also check package-style shadow: json/__init__.py can shadow the 'json' module
  shadow_pkg="${TARGET_DIR}/${mod}/__init__.py"
  if [[ -f "$shadow_pkg" ]]; then
    rel_path="${shadow_pkg#${TARGET_DIR}/}"
    red "Library shadow package: ${rel_path} (shadows '${mod}' package)"
    SHADOW_FOUND=$((SHADOW_FOUND + 1))
    ISSUES=$((ISSUES + 1))
  fi
done

# JavaScript/TypeScript library shadow detection
JS_STDLIB_MODULES=(
  path fs os crypto http https url util events
  assert stream buffer process child_process
)
for mod in "${JS_STDLIB_MODULES[@]}"; do
  for ext in js ts mjs cjs; do
    shadow_file="${TARGET_DIR}/${mod}.${ext}"
    if [[ -f "$shadow_file" ]]; then
      rel_path="${shadow_file#${TARGET_DIR}/}"
      red "Library shadow file: ${rel_path} (shadows Node.js '${mod}' module)"
      SHADOW_FOUND=$((SHADOW_FOUND + 1))
      ISSUES=$((ISSUES + 1))
    fi
  done
done

if [[ "$SHADOW_FOUND" -eq 0 ]]; then
  echo "Library shadow file not found"
fi

# =========================================================
# 2. Null assertion test function detection (Python)
# =========================================================
echo "Check for null assertion test function (Python)..."

_SCAN_ERR=$(mktemp)
if ! EMPTY_STUBS=$(python3 -c '
import ast
import sys
import os

target = sys.argv[1]
violations = []

def find_test_files(root):
    for dirpath, dirnames, filenames in os.walk(root):
        # Skip common non-test directories
        dirnames[:] = [d for d in dirnames if d not in {
            "node_modules", ".git", "target", "dist", "build",
            "__pycache__", ".venv", "vendor", ".mypy_cache"
        }]
        for fname in filenames:
            if fname.startswith("test_") or fname.endswith("_test.py"):
                yield os.path.join(dirpath, fname)

def has_assertion(func_node):
    """Check if a function node contains any assertion-like calls."""
    for node in ast.walk(func_node):
        if isinstance(node, ast.Assert):
            return True
        if isinstance(node, ast.Call):
            func = node.func
            # assert* methods (unittest style)
            if isinstance(func, ast.Attribute) and func.attr.startswith("assert"):
                return True
            # pytest.raises, pytest.warns, etc.
            if isinstance(func, ast.Attribute) and func.attr in ("raises", "warns", "approx"):
                return True
            # expect() calls (jest/chai style via pytest-bdd etc.)
            if isinstance(func, ast.Name) and func.id in ("expect", "raises"):
                return True
    return False

for fpath in find_test_files(target):
    try:
        source = open(fpath, encoding="utf-8", errors="replace").read()
        tree = ast.parse(source, filename=fpath)
    except (SyntaxError, OSError):
        continue

    for node in ast.walk(tree):
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        if not node.name.startswith("test_") and node.name != "test":
            continue
        # Flag functions with only pass/... body — emptied test body is a direct
        # forgery pattern (W-12); treat the same as no-assertion functions.
        if not has_assertion(node):
            rel = os.path.relpath(fpath, target)
            violations.append(f"{rel}:{node.lineno}: {node.name}() has no assertions")

for v in violations:
    print(v)
' "$TARGET_DIR" 2>"$_SCAN_ERR"); then
  red "Scanner error: Python null assertion check failed, test integrity check aborted (fail-safe)"
  cat "$_SCAN_ERR" >&2
  rm -f "$_SCAN_ERR"
  ISSUES=$((ISSUES + 1))
else
  rm -f "$_SCAN_ERR"
fi

if [[ -n "$EMPTY_STUBS" ]]; then
  COUNT=$(echo "$EMPTY_STUBS" | wc -l | tr -d ' ')
  yellow "Test function without assertion: ${COUNT}"
  echo "$EMPTY_STUBS" | head -10
  [[ "$COUNT" -gt 10 ]] && echo " ... and $((COUNT - 10))"
  ISSUES=$((ISSUES + COUNT))
else
  echo "No assertion test function found"
fi

# =========================================================
# 3. Null assertion test function detection (TypeScript/JavaScript)
# =========================================================
echo "Check for null assertion test function (TypeScript/JavaScript)..."

_GREP_ERR=$(mktemp)
_GREP_OUT=""
_GREP_EXIT=0
_GREP_OUT=$(grep -rn \
  --include='*.test.ts' --include='*.test.js' \
  --include='*.spec.ts' --include='*.spec.js' \
  --include='*.test.tsx' --include='*.spec.tsx' \
  --exclude-dir=node_modules --exclude-dir=dist --exclude-dir=.git \
  -E '^\s*(it|test)\s*\(' \
  "$TARGET_DIR" 2>"$_GREP_ERR") || _GREP_EXIT=$?
# grep exit 1 = no matches (normal); exit 2+ = real error (fail-safe)
if [[ "$_GREP_EXIT" -gt 1 ]]; then
  red "Scanner error: grep JS/TS null assertion check failed (exit ${_GREP_EXIT}), test integrity check aborted (fail-safe)"
  cat "$_GREP_ERR" >&2
  rm -f "$_GREP_ERR"
  ISSUES=$((ISSUES + 1))
  JS_EMPTY_STUBS=""
else
  rm -f "$_GREP_ERR"
  JS_EMPTY_STUBS=""
  if [[ -n "$_GREP_OUT" ]]; then
    # Write to a temp file first to avoid SIGPIPE (141) under set -euo pipefail:
    # piping a while loop into `head -20` causes head to exit early, sending
    # SIGPIPE to the upstream while, which the shell treats as an error.
    _JS_TMP=$(mktemp)
    echo "$_GREP_OUT" | while IFS= read -r line; do
      file=$(echo "$line" | cut -d: -f1)
      lineno=$(echo "$line" | cut -d: -f2)
      # Check the next 15 lines for expect(
      if ! sed -n "${lineno},$((lineno + 15))p" "$file" 2>/dev/null | grep -qE 'expect\s*\(|assert\s*\(|should\.|\.toBe|\.toEqual|\.toContain|\.toThrow'; then
        echo "${file#${TARGET_DIR}/}:${lineno}"
      fi
    done > "$_JS_TMP"
    JS_EMPTY_STUBS=$(head -20 "$_JS_TMP")
    rm -f "$_JS_TMP"
  fi
fi

if [[ -n "$JS_EMPTY_STUBS" ]]; then
  COUNT=$(echo "$JS_EMPTY_STUBS" | wc -l | tr -d ' ')
  yellow "No assertion test block (JS/TS): ${COUNT} (manual confirmation required)"
  echo "$JS_EMPTY_STUBS" | head -10
  ISSUES=$((ISSUES + COUNT))
else
  echo "No assertion test block (JS/TS) found"
fi

# =========================================================
# Summarize
# =========================================================
echo ""
echo "---"
if [[ "$ISSUES" -gt 0 ]]; then
  red "${ISSUES} test integrity issues found (W-12)"
  exit 1
else
  green "Test integrity check passed"
  exit 0
fi
