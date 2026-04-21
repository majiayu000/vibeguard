#!/usr/bin/env bash
# VibeGuard Pre-Commit Guard — Automatic guard before git commit (Verifier mode)
#
# After installing to .git/hooks/pre-commit, git commit will run automatically every time.
# Automatically detect the project language → call the corresponding guard script under guards/ → run the build check.
#
# exit 0 = release
# exit 1 = prevent submission
#
# Skip method: VIBEGUARD_SKIP_PRECOMMIT=1 git commit -m "msg"

set -euo pipefail

if [[ "${VIBEGUARD_SKIP_PRECOMMIT:-0}" == "1" ]]; then
  exit 0
fi

# --- Locate resources ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "${SCRIPT_DIR}/log.sh" ]]; then
  source "${SCRIPT_DIR}/log.sh"
elif [[ -n "${VIBEGUARD_DIR:-}" ]] && [[ -f "${VIBEGUARD_DIR}/hooks/log.sh" ]]; then
  source "${VIBEGUARD_DIR}/hooks/log.sh"
else
  vg_log() { :; }
  vg_start_timer() { :; }
  VG_SOURCE_EXTS="rs py ts js tsx jsx go java kt swift rb"
fi
vg_start_timer

# Locate the guards directory
if [[ -n "${VIBEGUARD_DIR:-}" ]] && [[ -d "${VIBEGUARD_DIR}/guards" ]]; then
  GUARDS_DIR="${VIBEGUARD_DIR}/guards"
elif [[ -d "${SCRIPT_DIR}/../guards" ]]; then
  GUARDS_DIR="$(cd "${SCRIPT_DIR}/../guards" && pwd)"
else
  GUARDS_DIR=""
fi
# Shell-quote GUARDS_DIR for safe embedding in "bash -c" strings (handles spaces in path)
GUARDS_DIR_Q="$(printf '%q' "${GUARDS_DIR}")"

TIMEOUT="${VIBEGUARD_PRECOMMIT_TIMEOUT:-10}"
TIMEOUT_CMD=""
HAS_PYTHON3=0
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_CMD="gtimeout"
fi
command -v python3 >/dev/null 2>&1 && HAS_PYTHON3=1

# --- Collect staged source code files (single git diff, filter by extension) ---
_ALL_STAGED=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null || true)
STAGED_FILES=""
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  ext="${file##*.}"
  for e in $VG_SOURCE_EXTS; do
    if [[ "$ext" == "$e" ]]; then
      STAGED_FILES="${STAGED_FILES}${file}"$'\n'
      break
    fi
  done
done <<< "$_ALL_STAGED"
STAGED_FILES=$(echo "$STAGED_FILES" | sed '/^$/d')

if [[ -z "$STAGED_FILES" ]]; then
  exit 0
fi

FILE_COUNT=$(echo "$STAGED_FILES" | wc -l | tr -d ' ')

# --- Export the staged file list for use by guard scripts (only scan staged files, not all) ---
_STAGED_TMPFILE=$(mktemp)
_DIFF_ADDED_TMPFILE=$(mktemp)
_cleanup_staged() {
  rm -f "$_STAGED_TMPFILE" "$_DIFF_ADDED_TMPFILE" 2>/dev/null
}
trap '_cleanup_staged' EXIT
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
while IFS= read -r f; do
  [[ -n "$f" ]] && echo "${REPO_ROOT}/${f}"
done <<< "$STAGED_FILES" > "$_STAGED_TMPFILE"
export VIBEGUARD_STAGED_FILES="$_STAGED_TMPFILE"

# --- Export diff new line content (Baseline Scanning) ---
# VIBEGUARD_DIFF_ONLY=1 — Informs the guard that it is in pre-commit differential scan mode
# VIBEGUARD_DIFF_ADDED_LINES — points to a temporary file containing all staged new lines (+ prefix removed)
# The guard script can choose to read this file instead of scanning the entire file, so that only the new lines of code are checked.
export VIBEGUARD_DIFF_ONLY=1
# Single git diff call for all staged files (avoids O(n) git invocations)
git diff --cached -U0 2>/dev/null \
  | grep '^+' \
  | grep -v '^+++' \
  | sed 's/^+//' \
  > "$_DIFF_ADDED_TMPFILE" || true
export VIBEGUARD_DIFF_ADDED_LINES="$_DIFF_ADDED_TMPFILE"

# --- Language and project-root detection (driven by staged files, not only repo root) ---
find_project_root() {
  local dir="$1"
  local marker="$2"

  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/$marker" ]]; then
      echo "$dir"
      return 0
    fi
    dir=$(dirname "$dir")
  done

  return 1
}

add_unique_entry() {
  local var_name="$1"
  local value="$2"
  local current=""

  [[ -z "$value" ]] && return 0
  eval "current=\${$var_name-}"

  case $'\n'"$current"$'\n' in
    *$'\n'"$value"$'\n'*) return 0 ;;
  esac

  if [[ -n "$current" ]]; then
    printf -v "$var_name" '%s\n%s' "$current" "$value"
  else
    printf -v "$var_name" '%s' "$value"
  fi
}

DETECTED_LANGS=""
RUST_BUILD_ROOTS=""
TYPESCRIPT_BUILD_ROOTS=""
GO_BUILD_ROOTS=""
JAVASCRIPT_BUILD_FILES=""

while IFS= read -r file; do
  [[ -z "$file" ]] && continue

  abs_file="${REPO_ROOT}/${file}"
  file_dir=$(dirname "$abs_file")
  ext="${file##*.}"

  case "$ext" in
    rs)
      add_unique_entry DETECTED_LANGS "rust"
      add_unique_entry RUST_BUILD_ROOTS "$(find_project_root "$file_dir" "Cargo.toml" || true)"
      ;;
    ts|tsx)
      add_unique_entry DETECTED_LANGS "typescript"
      add_unique_entry TYPESCRIPT_BUILD_ROOTS "$(find_project_root "$file_dir" "tsconfig.json" || true)"
      ;;
    js|jsx)
      ts_root="$(find_project_root "$file_dir" "tsconfig.json" || true)"
      if [[ -n "$ts_root" ]]; then
        add_unique_entry DETECTED_LANGS "typescript"
        add_unique_entry TYPESCRIPT_BUILD_ROOTS "$ts_root"
      else
        add_unique_entry DETECTED_LANGS "javascript"
        if [[ "$ext" != "jsx" ]]; then
          add_unique_entry JAVASCRIPT_BUILD_FILES "$file"
        fi
      fi
      ;;
    mjs|cjs)
      add_unique_entry DETECTED_LANGS "javascript"
      add_unique_entry JAVASCRIPT_BUILD_FILES "$file"
      ;;
    py)
      add_unique_entry DETECTED_LANGS "python"
      ;;
    go)
      add_unique_entry DETECTED_LANGS "go"
      add_unique_entry GO_BUILD_ROOTS "$(find_project_root "$file_dir" "go.mod" || true)"
      ;;
  esac
done <<< "$STAGED_FILES"

DETECTED_LANGS=$(echo "$DETECTED_LANGS" | xargs)

# --- Timeout executor ---
run_with_timeout() {
  local cmd="$1"
  local code=0

  if [[ -n "${TIMEOUT_CMD}" ]]; then
    "${TIMEOUT_CMD}" "${TIMEOUT}" bash -c "$cmd" 2>&1 && return 0
    code=$?
    [[ $code -eq 124 ]] && return 124
    [[ $code -ne 127 ]] && return "$code"
  fi

  if [[ "${HAS_PYTHON3}" -eq 1 ]]; then
    python3 - "${TIMEOUT}" "$cmd" <<'PY' && return 0
import subprocess, sys
try:
    proc = subprocess.run(["bash", "-c", sys.argv[2]], timeout=int(sys.argv[1]))
    sys.exit(proc.returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)
except Exception:
    sys.exit(1)
PY
    return $?
  fi

  bash -c "$cmd" 2>&1 && return 0
  return $?
}

# --- Quality guards: call guards/ script (replaces inline grep) ---
GUARD_OUTPUT=""
GUARD_FAIL=0

run_guard() {
  local label="$1"
  local cmd="$2"
  local output code=0

  output=$(run_with_timeout "$cmd" 2>&1) || code=$?
  [[ $code -eq 124 ]] && return 0 # Timeout skip

  if [[ $code -ne 0 ]]; then
    GUARD_FAIL=1
    GUARD_OUTPUT="${GUARD_OUTPUT}\n[${label}]\n${output}\n"
  fi
}

if [[ -n "$GUARDS_DIR" ]]; then
  # Quote GUARDS_DIR for safe use inside bash -c strings (handles paths with spaces)
  GUARDS_DIR_Q=$(printf '%q' "${GUARDS_DIR}")
  for lang in $DETECTED_LANGS; do
    case "$lang" in
      rust)
        [[ -f "${GUARDS_DIR}/rust/check_unwrap_in_prod.sh" ]] && \
          run_guard "rust/unwrap" "bash ${GUARDS_DIR_Q}/rust/check_unwrap_in_prod.sh --strict ."
        ;;
      typescript|javascript)
        [[ -f "${GUARDS_DIR}/typescript/check_console_residual.sh" ]] && \
          run_guard "ts/console" "bash ${GUARDS_DIR_Q}/typescript/check_console_residual.sh --strict ."
        [[ -f "${GUARDS_DIR}/typescript/check_any_abuse.sh" ]] && \
          run_guard "ts/any" "bash ${GUARDS_DIR_Q}/typescript/check_any_abuse.sh --strict ."
        ;;
      python)
        [[ -f "${GUARDS_DIR}/python/check_naming_convention.py" ]] && \
          run_guard "py/naming" "python3 ${GUARDS_DIR_Q}/python/check_naming_convention.py ."
        [[ -f "${GUARDS_DIR}/python/check_dead_shims.py" ]] && \
          run_guard "py/dead_shims" "python3 ${GUARDS_DIR_Q}/python/check_dead_shims.py --strict ."
        ;;
      go)
        [[ -f "${GUARDS_DIR}/go/check_error_handling.sh" ]] && \
          run_guard "go/error_handling" "bash ${GUARDS_DIR_Q}/go/check_error_handling.sh --strict ."
        [[ -f "${GUARDS_DIR}/go/check_goroutine_leak.sh" ]] && \
          run_guard "go/goroutine_leak" "bash ${GUARDS_DIR_Q}/go/check_goroutine_leak.sh --strict ."
        [[ -f "${GUARDS_DIR}/go/check_defer_in_loop.sh" ]] && \
          run_guard "go/defer_in_loop" "bash ${GUARDS_DIR_Q}/go/check_defer_in_loop.sh --strict ."
        ;;
    esac
  done
fi

# --- Build check: all detected languages run (not elif) ---
BUILD_FAILS=""

run_build_check() {
  local cmd="$1"
  local fail_msg="$2"
  local code=0

  run_with_timeout "$cmd" >/dev/null 2>&1 || code=$?
  if [[ $code -ne 0 && $code -ne 124 ]]; then
    BUILD_FAILS="${BUILD_FAILS}  ${fail_msg}\n"
  fi
}

for lang in $DETECTED_LANGS; do
  case "$lang" in
    rust)
      while IFS= read -r build_root; do
        [[ -z "$build_root" ]] && continue
        build_root_q=$(printf '%q' "$build_root")
        run_build_check "cd ${build_root_q} && cargo check --quiet" "cargo check failed (${build_root})"
      done <<< "$RUST_BUILD_ROOTS"
      ;;
    typescript)
      while IFS= read -r build_root; do
        [[ -z "$build_root" ]] && continue
        build_root_q=$(printf '%q' "$build_root")
        run_build_check "cd ${build_root_q} && if ! command -v tsc >/dev/null 2>&1 && ! [ -f node_modules/.bin/tsc ]; then exit 0; fi; npx tsc --noEmit" "tsc --noEmit failed (${build_root})"
      done <<< "$TYPESCRIPT_BUILD_ROOTS"
      ;;
    javascript)
      if [[ -n "$JAVASCRIPT_BUILD_FILES" ]]; then
        javascript_files_q="$(printf '%s\n' "$JAVASCRIPT_BUILD_FILES" | sed '/^$/d' | while IFS= read -r file; do printf '%q\n' "$file"; done)"
        run_build_check "if ! command -v node >/dev/null 2>&1; then exit 0; fi; while IFS= read -r f; do [[ -z \"\$f\" || ! -f \"\$f\" ]] && continue; node --check \"\$f\" >/dev/null 2>&1 || exit 1; done <<'EOF'
${javascript_files_q}
EOF" "JavaScript syntax check failed (node --check)"
      fi
      ;;
    go)
      while IFS= read -r build_root; do
        [[ -z "$build_root" ]] && continue
        build_root_q=$(printf '%q' "$build_root")
        run_build_check "cd ${build_root_q} && go build ./..." "go build failed (${build_root})"
      done <<< "$GO_BUILD_ROOTS"
      ;;
  esac
done

# --- Summary ---
if [[ $GUARD_FAIL -eq 0 ]] && [[ -z "$BUILD_FAILS" ]]; then
  vg_log "pre-commit-guard" "git-commit" "pass" "staged ${FILE_COUNT} files, all clean [${DETECTED_LANGS}]" ""
  exit 0
fi

echo "VibeGuard Pre-Commit Guard: Problem detected"
echo "======================================="
echo "Detection language: ${DETECTED_LANGS:-none}"

if [[ $GUARD_FAIL -ne 0 ]]; then
  echo ""
  echo "Quality Guard:"
  echo -e "$GUARD_OUTPUT"
fi

if [[ -n "$BUILD_FAILS" ]]; then
  echo ""
  echo "Build failed:"
  echo -e "$BUILD_FAILS"
fi

echo ""
echo "After repairing, re-run git add && git commit"
echo "Emergency skip (manual operation only): VIBEGUARD_SKIP_PRECOMMIT=1 git commit -m \"msg\"" >&2

REASON="${GUARD_FAIL:+guard fail}${BUILD_FAILS:+${GUARD_FAIL:+, }build fail}"
DETAIL=$(echo "$STAGED_FILES" | head -5 | tr '\n' ' ')
# Write a summary of the guard output to the log (truncate the first 500 characters to avoid log bloat)
LOG_DETAIL="${DETAIL}"
if [[ -n "$GUARD_OUTPUT" ]]; then
  GUARD_SUMMARY=$(echo -e "$GUARD_OUTPUT" | head -20 | cut -c1-200 | tr '\n' '|')
  LOG_DETAIL="${DETAIL}||guards: ${GUARD_SUMMARY}"
fi
if [[ -n "$BUILD_FAILS" ]]; then
  BUILD_SUMMARY=$(echo -e "$BUILD_FAILS" | head -5 | tr '\n' '|')
  LOG_DETAIL="${LOG_DETAIL}||build: ${BUILD_SUMMARY}"
fi
vg_log "pre-commit-guard" "git-commit" "block" "$REASON" "$LOG_DETAIL"

exit 1
