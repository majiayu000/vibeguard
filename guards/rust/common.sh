#!/usr/bin/env bash
# VibeGuard Rust Guards — shared function library
#
# All Rust guard scripts are imported through source common.sh to eliminate duplicate code.
# Provide: list_rs_files, parameter parsing, temporary file management

set -euo pipefail

# Paths to always exclude from scanning (worktrees, build artifacts, IDE caches).
VIBEGUARD_EXCLUDE_PATHS='(.harness/worktrees/|/target/|/.git/|/node_modules/)'

# Test file patterns — files that are exclusively test code.
VIBEGUARD_TEST_FILE_PATTERN='(/tests/|/test_|_test\.rs$|tests\.rs$|test_helpers\.rs$|/examples/|/benches/)'

# List .rs source files
# Priority: VIBEGUARD_STAGED_FILES (pre-commit mode, only scan staged) > git ls-files > find
# Automatically exclude worktree copies and build directories.
list_rs_files() {
  local dir="$1"
  if [[ -n "${VIBEGUARD_STAGED_FILES:-}" ]] && [[ -f "${VIBEGUARD_STAGED_FILES}" ]]; then
    grep '\.rs$' "${VIBEGUARD_STAGED_FILES}" | { grep -vE "${VIBEGUARD_EXCLUDE_PATHS}" || true; }
  elif git -C "${dir}" rev-parse --is-inside-work-tree &>/dev/null; then
    git -C "${dir}" ls-files '*.rs' \
      | { grep -vE "${VIBEGUARD_EXCLUDE_PATHS}" || true; } \
      | while IFS= read -r f; do echo "${dir}/${f}"; done
  else
    find "${dir}" -name '*.rs' -not -path '*/target/*' -not -path '*/.git/*' -not -path '*/.harness/worktrees/*'
  fi
}

# List non-test .rs files (exclude test files based on list_rs_files)
list_rs_prod_files() {
  list_rs_files "$1" | { grep -vE "${VIBEGUARD_TEST_FILE_PATTERN}" || true; }
}

# Parse --strict flag and target_dir
# Usage: parse_guard_args "$@"
# Set variables: TARGET_DIR, STRICT
parse_guard_args() {
  TARGET_DIR="."
  STRICT=false
  local positional_count=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --strict)
        STRICT=true
        ;;
      --help|-h)
        echo "Usage: $0 [--strict] [target_dir]" >&2
        return 1
        ;;
      --*)
        echo "Unknown option: $1" >&2
        return 1
        ;;
      *)
        positional_count=$((positional_count + 1))
        if [[ ${positional_count} -gt 1 ]]; then
          echo "Too many positional arguments: $*" >&2
          return 1
        fi
        TARGET_DIR="$1"
        ;;
    esac
    shift
  done
}

# Temporary file cleaning directory: all guards share the same cleaning trap
_VG_TMPDIR=""

_vg_cleanup() {
  [[ -n "$_VG_TMPDIR" && -d "$_VG_TMPDIR" ]] && rm -rf "$_VG_TMPDIR" || true
}
trap '_vg_cleanup' EXIT

#Create temporary files and automatically clean them when the script exits
# Usage: TMPFILE=$(create_tmpfile)
create_tmpfile() {
  if [[ -z "$_VG_TMPDIR" ]]; then
    _VG_TMPDIR=$(mktemp -d)
  fi
  mktemp "$_VG_TMPDIR/vg.XXXXXX"
}

# ---------------------------------------------------------------------------
# Inline suppression: // vibeguard-disable-next-line <RULE-ID> [-- reason]
# ---------------------------------------------------------------------------

# check_suppression FILE LINE_NUM RULE_ID
# Returns 0 (suppressed) if the line before LINE_NUM has a disable comment for RULE_ID.
# In pre-commit mode (VIBEGUARD_STAGED_FILES set) reads from staged content so that
# unstaged suppression comments cannot bypass checks on staged violations.
check_suppression() {
  local file="$1" line_num="$2" rule_id="$3"
  local prev=$((line_num - 1))
  [[ $prev -lt 1 ]] && return 1
  local prev_line
  if [[ -n "${VIBEGUARD_STAGED_FILES:-}" ]]; then
    # Pre-commit mode: read from staged content, not the working tree.
    # git show ":path" requires a path relative to the repo root.
    # Use python3 realpath resolution to handle macOS /var→/private/var symlinks.
    local rel_file="$file"
    if [[ "$file" == /* ]]; then
      local git_root
      git_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
      if [[ -n "$git_root" ]]; then
        if command -v python3 >/dev/null 2>&1; then
          rel_file=$(python3 -c "import os,sys; f=os.path.realpath(sys.argv[1]); r=os.path.realpath(sys.argv[2]); print(f[len(r)+1:] if f.startswith(r+os.sep) else sys.argv[1])" "$file" "$git_root" 2>/dev/null || echo "$file")
        else
          [[ "$file" == "$git_root/"* ]] && rel_file="${file#$git_root/}"
        fi
      fi
    fi
    prev_line=$(git show ":${rel_file}" 2>/dev/null | sed -n "${prev}p" || true)
  else
    [[ ! -f "$file" ]] && return 1
    prev_line=$(sed -n "${prev}p" "$file" 2>/dev/null || true)
  fi
  if printf '%s' "$prev_line" \
      | grep -qE "^[[:space:]]*//[[:space:]]*vibeguard-disable-next-line[[:space:]]+${rule_id}([[:space:]]|--|$)"; then
    return 0
  fi
  return 1
}

# apply_suppression_filter TMPFILE
# Reads findings from TMPFILE in format "[RULE-ID] file:line ..." and removes those
# suppressed by a vibeguard-disable-next-line comment on the preceding source line.
# Modifies TMPFILE in-place.
apply_suppression_filter() {
  local tmpfile="$1"
  [[ ! -s "$tmpfile" ]] && return 0

  local filtered_file
  filtered_file=$(create_tmpfile)

  while IFS= read -r finding; do
    # Must start with [RULE-ID] to be a suppressible finding
    local rule_id
    rule_id=$(printf '%s' "$finding" | sed -n 's/^\[\([^]]*\)\].*/\1/p')

    if [[ -z "$rule_id" ]]; then
      printf '%s\n' "$finding" >> "$filtered_file"
      continue
    fi

    # Strip "[RULE-ID] " prefix to get "file:line ..."
    local rest
    rest="${finding#\[${rule_id}\] }"

    # Extract line number: first :digits sequence (file:line separator)
    local line_num
    line_num=$(printf '%s' "$rest" | grep -oE ':[0-9]+' | head -1 | tr -d ':' || true)

    if [[ -z "$line_num" ]]; then
      printf '%s\n' "$finding" >> "$filtered_file"
      continue
    fi

    # Extract file path: everything before :line_num
    local file_path
    file_path=$(printf '%s' "$rest" | sed "s/:${line_num}.*$//")

    if [[ ! -f "$file_path" ]]; then
      printf '%s\n' "$finding" >> "$filtered_file"
      continue
    fi

    if check_suppression "$file_path" "$line_num" "$rule_id"; then
      continue  # suppressed — skip this finding
    fi

    printf '%s\n' "$finding" >> "$filtered_file"
  done < "$tmpfile"

  cp "$filtered_file" "$tmpfile"
}
