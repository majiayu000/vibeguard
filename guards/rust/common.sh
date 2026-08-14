#!/usr/bin/env bash
# VibeGuard Rust Guards — shared function library
#
# All Rust guard scripts are imported through source common.sh to eliminate duplicate code.
# Provide: list_rs_files, parameter parsing, temporary file management

set -euo pipefail

# Paths to always exclude from scanning (worktrees, build artifacts, IDE caches).
VIBEGUARD_EXCLUDE_PATHS='(.harness/worktrees/|/target/|/.git/|/node_modules/)'

# Fallback only. The authoritative test-path classifier is
# `vibeguard-runtime test-path-filter`; keep this for old/unbuilt runtime paths.
VIBEGUARD_TEST_FILE_PATTERN='((^|/)tests/|(^|/)test/|(^|/)__tests__/|(^|/)spec/|(^|/)fixtures/|(^|/)mocks/|(^|/)testdata/|(^|/)examples/|(^|/)benches/|(^|/)test_|_test\.rs$|_[tT][eE][sS][tT][sS]\.[rR][sS]$|tests\.rs$|test_helpers\.rs$)'

vibeguard_rust_runtime_path() {
  local script_dir repo_dir candidate
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_dir="$(cd "${script_dir}/../.." && pwd)"
  for candidate in \
    "${VIBEGUARD_RUNTIME:-}" \
    "${repo_dir}/vibeguard-runtime/target/release/vibeguard-runtime" \
    "${repo_dir}/vibeguard-runtime/target/debug/vibeguard-runtime" \
    "${HOME:-}/.vibeguard/installed/bin/vibeguard-runtime"; do
    [[ -n "${candidate}" && -f "${candidate}" && -x "${candidate}" ]] || continue
    printf '%s\n' "${candidate}"
    return 0
  done
  return 1
}

filter_rs_prod_paths() {
  local tmp runtime_path
  tmp=$(create_tmpfile)
  cat > "${tmp}"
  if runtime_path="$(vibeguard_rust_runtime_path 2>/dev/null)" \
    && "${runtime_path}" test-path-filter --prod < "${tmp}" 2>/dev/null; then
    return 0
  fi
  grep -vE "${VIBEGUARD_TEST_FILE_PATTERN}" "${tmp}" || true
}

# List .rs source files
# Priority: VIBEGUARD_STAGED_FILES (pre-commit mode, only scan staged) > git ls-files > find
# Automatically exclude worktree copies and build directories.
list_rs_files() {
  local dir="$1"
  if [[ -n "${VIBEGUARD_STAGED_FILES:-}" ]] && [[ -f "${VIBEGUARD_STAGED_FILES}" ]]; then
    grep '\.rs$' "${VIBEGUARD_STAGED_FILES}" 2>/dev/null \
      | { grep -vE "${VIBEGUARD_EXCLUDE_PATHS}" || true; } \
      || true
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
  list_rs_files "$1" | filter_rs_prod_paths
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
# Rename-aware staged diff
# ---------------------------------------------------------------------------
# `git diff --cached -- <new-path>` cannot pair a staged rename because the
# old path falls outside the pathspec, so a renamed file shows up as fully
# added and every pre-existing line looks new. Resolve the rename source once
# per process and diff both sides of the pathspec instead.

_VG_STAGED_RENAME_NEW=()
_VG_STAGED_RENAME_OLD=()
_VG_STAGED_RENAME_MAP_LOADED=""

_vg_load_staged_rename_map() {
  if [[ -z "${_VG_STAGED_RENAME_MAP_LOADED}" ]]; then
    # PERF-OK: one rename-aware name-status diff per guard process.
    local status first_path second_path
    while IFS= read -r -d '' status && IFS= read -r -d '' first_path; do
      if [[ "$status" == R* || "$status" == C* ]]; then
        IFS= read -r -d '' second_path || break
        if [[ "$status" == R* ]]; then
          _VG_STAGED_RENAME_NEW+=("$second_path")
          _VG_STAGED_RENAME_OLD+=("$first_path")
        fi
      fi
    done < <(git diff --cached -M --name-status -z 2>/dev/null)
    _VG_STAGED_RENAME_MAP_LOADED=1
  fi
}

# vg_path_is_test PATH
# True when PATH is classified as test/fixture code. Avoid filter_rs_prod_paths
# here because its temp-file pipeline is unnecessary for a single path.
vg_path_is_test() {
  local path="$1" runtime_path output
  if runtime_path="$(vibeguard_rust_runtime_path 2>/dev/null)" \
    && output="$(printf '%s\n' "$path" | "${runtime_path}" test-path-filter --prod 2>/dev/null)"; then
    [[ -z "$output" ]]
    return
  fi
  printf '%s\n' "$path" | grep -qE "${VIBEGUARD_TEST_FILE_PATTERN}"
}

# vg_path_enforcement_class PATH
# Print the path properties that determine whether Rust guards enforce a file.
# Rename pairing is safe only when every property is unchanged; otherwise the
# destination must be treated as newly governed code.
vg_path_enforcement_class() {
  local path="$1"
  local normalized="/${path#/}"
  local source=0 excluded=0 test=0
  [[ "$path" == *.rs ]] && source=1
  printf '%s\n' "$normalized" | grep -qE "${VIBEGUARD_EXCLUDE_PATHS}" && excluded=1
  vg_path_is_test "$path" && test=1
  printf '%s:%s:%s\n' "$source" "$excluded" "$test"
}

vg_staged_inline_test_removed() {
  git diff --cached -M -U0 -- ":(top)$1" ":(top)$2" 2>/dev/null \
    | grep -qE '^-[[:space:]]*#\[cfg\(test\)\]'
}

# vg_staged_file_diff FILE
# Prints the staged -U0 diff for one file, pairing staged renames so that
# moved-but-unchanged lines do not appear as additions. Pairing is skipped when
# the rename crosses a test/production boundary (e.g. tests/helper.rs → src/helper.rs),
# because the destination is newly under production enforcement.
vg_staged_file_diff() {
  local f="$1"
  local git_root rel old old_class new_class inline_test_removed=0 i
  rel="$f"
  if [[ "$f" == /* ]]; then
    git_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
    if [[ -n "$git_root" ]]; then
      if command -v python3 >/dev/null 2>&1; then
        # realpath resolution handles macOS /var -> /private/var symlinks.
        rel=$(python3 -c "import os,sys; f=os.path.realpath(sys.argv[1]); r=os.path.realpath(sys.argv[2]); print(f[len(r)+1:] if f.startswith(r+os.sep) else sys.argv[1])" "$f" "$git_root" 2>/dev/null || echo "$f")
      else
        [[ "$f" == "$git_root/"* ]] && rel="${f#$git_root/}"
      fi
    fi
  fi
  _vg_load_staged_rename_map
  old=""
  for ((i = 0; i < ${#_VG_STAGED_RENAME_NEW[@]}; i++)); do
    if [[ "${_VG_STAGED_RENAME_NEW[$i]}" == "$rel" ]]; then
      old="${_VG_STAGED_RENAME_OLD[$i]}"
      break
    fi
  done
  if [[ -n "$old" ]]; then
    old_class=$(vg_path_enforcement_class "$old")
    new_class=$(vg_path_enforcement_class "$rel")
    vg_staged_inline_test_removed "$old" "$rel" && inline_test_removed=1
    if [[ "$old_class" == "$new_class" && "$inline_test_removed" -eq 0 ]]; then
      git diff --cached -M -U0 -- ":(top)${old}" ":(top)${rel}" 2>/dev/null
    else
      git diff --cached -U0 -- "$f" 2>/dev/null
    fi
  else
    git diff --cached -U0 -- "$f" 2>/dev/null
  fi
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
