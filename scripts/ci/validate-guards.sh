#!/usr/bin/env bash
# VibeGuard CI: Verify that all guard scripts are executable and have correct syntax
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
errors=0

echo "Validating guard scripts..."

# Check for Rust guards
for script in "${REPO_DIR}"/guards/rust/*.sh; do
  [[ -f "$script" ]] || continue
  name=$(basename "$script")

  if [[ ! -x "$script" ]]; then
    echo "FAIL: ${name} is not executable"
    ((errors++))
  fi

  if ! bash -n "$script" 2>/dev/null; then
    echo "FAIL: ${name} has syntax errors"
    ((errors++))
  else
    echo "OK: ${name}"
  fi
done

# Check TypeScript guards (bash script)
for script in "${REPO_DIR}"/guards/typescript/*.sh; do
  [[ -f "$script" ]] || continue
  name=$(basename "$script")

  if [[ ! -x "$script" ]]; then
    echo "FAIL: ${name} is not executable"
    ((errors++))
  fi

  if ! bash -n "$script" 2>/dev/null; then
    echo "FAIL: ${name} has syntax errors"
    ((errors++))
  else
    echo "OK: ${name}"
  fi
done

# Check Go guards (bash script)
for script in "${REPO_DIR}"/guards/go/*.sh; do
  [[ -f "$script" ]] || continue
  name=$(basename "$script")

  if [[ ! -x "$script" ]]; then
    echo "FAIL: ${name} is not executable"
    ((errors++))
  fi

  if ! bash -n "$script" 2>/dev/null; then
    echo "FAIL: ${name} has syntax errors"
    ((errors++))
  else
    echo "OK: ${name}"
  fi
done

# Check Python guards
for script in "${REPO_DIR}"/guards/python/*.py; do
  [[ -f "$script" ]] || continue
  name=$(basename "$script")

  if ! python3 -m py_compile "$script" 2>/dev/null; then
    echo "FAIL: ${name} has syntax errors"
    ((errors++))
  else
    echo "OK: ${name}"
  fi
done

echo
if [[ ${errors} -eq 0 ]]; then
  echo "All guard scripts valid."
else
  echo "FAILED: ${errors} errors found."
  exit 1
fi
