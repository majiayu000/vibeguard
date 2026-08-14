#!/usr/bin/env bash
# Regression coverage for installed guards that run through bare python3 on macOS.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

PASS=0
FAIL=0
SKIP=0
TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red() { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }

if command -v python3.9 >/dev/null 2>&1; then
  PYTHON39=(python3.9)
elif command -v uv >/dev/null 2>&1; then
  PYTHON39=(uv run --no-project --python 3.9 python)
else
  printf '\033[33m  SKIP: Python 3.9 and uv are unavailable\033[0m\n'
  printf 'Total: 1  Pass: 0  Fail: 0  Skip: 1\n'
  exit 0
fi

export PYTHONDONTWRITEBYTECODE=1

printf '\n=== Python 3.9 guard compatibility ===\n'

TOTAL=$((TOTAL + 1))
version="$("${PYTHON39[@]}" -c 'import platform; print(platform.python_version())')"
if [[ "$version" == 3.9.* ]]; then
  green "selected interpreter is Python 3.9 (${version})"
  PASS=$((PASS + 1))
else
  red "expected Python 3.9, got ${version}"
  FAIL=$((FAIL + 1))
fi

guard_files=(
  "${REPO_DIR}/guards/python/check_dead_shims.py"
  "${REPO_DIR}/guards/python/check_naming_convention.py"
  "${REPO_DIR}/guards/universal/check_circular_deps.py"
  "${REPO_DIR}/guards/universal/check_dependency_layers.py"
)

TOTAL=$((TOTAL + 1))
if "${PYTHON39[@]}" -c '
import runpy
import sys

for path in sys.argv[1:]:
    runpy.run_path(path, run_name="vibeguard_python39_smoke")
' "${guard_files[@]}"; then
  green "all affected guards load under Python 3.9"
  PASS=$((PASS + 1))
else
  red "an affected guard failed to load under Python 3.9"
  FAIL=$((FAIL + 1))
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
fixture="${tmpdir}/dead_shims"
mkdir -p "$fixture"
printf 'import os\n' > "${fixture}/import_only.py"
printf 'from pathlib import Path\n' > "${fixture}/import_from_only.py"
printf '"""compatibility module"""\nimport os\nfrom pathlib import Path\n__all__ = ["Path"]\n' > "${fixture}/mixed.py"
printf 'def live():\n    return 1\n' > "${fixture}/live.py"

TOTAL=$((TOTAL + 1))
dead_output="$("${PYTHON39[@]}" "${guard_files[0]}" "$fixture")"
dead_count="$(printf '%s\n' "$dead_output" | grep -c '^\[PY-13\]')"
if [[ "$dead_count" -eq 3 ]] \
    && printf '%s\n' "$dead_output" | grep -q 'import_only.py' \
    && printf '%s\n' "$dead_output" | grep -q 'import_from_only.py' \
    && printf '%s\n' "$dead_output" | grep -q 'mixed.py' \
    && ! printf '%s\n' "$dead_output" | grep -q 'live.py'; then
  green "Import, ImportFrom, mixed, and non-shim branches behave correctly"
  PASS=$((PASS + 1))
else
  red "dead-shim runtime branch coverage differed (count=${dead_count})"
  FAIL=$((FAIL + 1))
fi

empty_fixture="${tmpdir}/empty"
mkdir -p "$empty_fixture"
TOTAL=$((TOTAL + 1))
if "${PYTHON39[@]}" "${guard_files[1]}" "$empty_fixture" >/dev/null \
    && "${PYTHON39[@]}" "${guard_files[2]}" "$empty_fixture" >/dev/null \
    && "${PYTHON39[@]}" "${guard_files[3]}" "$empty_fixture" >/dev/null; then
  green "naming, circular-dependency, and layer guards execute under Python 3.9"
  PASS=$((PASS + 1))
else
  red "an affected guard failed during Python 3.9 execution"
  FAIL=$((FAIL + 1))
fi

echo
printf 'Total: %d  Pass: %d  Fail: %d  Skip: %d\n' "$TOTAL" "$PASS" "$FAIL" "$SKIP"
[[ "$FAIL" -eq 0 ]]
