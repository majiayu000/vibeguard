#!/usr/bin/env bash
# VibeGuard TypeScript Guards — Shared function library
#
# All TypeScript guard scripts are introduced through source common.sh to eliminate duplicate code.
# Provide: list_ts_files, parameter parsing, temporary file management
# Pattern reference: guards/rust/common.sh

set -euo pipefail

# List .ts/.tsx/.js/.jsx source files
# Priority: VIBEGUARD_STAGED_FILES (pre-commit mode, only scan staged) > git ls-files > find
list_ts_files() {
  local dir="$1"
  if [[ -n "${VIBEGUARD_STAGED_FILES:-}" ]] && [[ -f "${VIBEGUARD_STAGED_FILES}" ]]; then
    grep -E '\.(ts|tsx|js|jsx)$' "${VIBEGUARD_STAGED_FILES}" || true
  elif git -C "${dir}" rev-parse --is-inside-work-tree &>/dev/null; then
    git -C "${dir}" ls-files '*.ts' '*.tsx' '*.js' '*.jsx' | while IFS= read -r f; do echo "${dir}/${f}"; done
  else
    find "${dir}" \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' \) \
      -not -path '*/node_modules/*' \
      -not -path '*/.git/*' \
      -not -path '*/dist/*' \
      -not -path '*/build/*'
  fi
}

# Filter out test files
filter_non_test() {
  grep -vE '(\.(test|spec)\.(ts|tsx|js|jsx)$|/tests/|/__tests__/|/test/)' || true
}

# Parse --strict / --baseline flags and target_dir
# Usage: parse_guard_args "$@"
# Set variables: TARGET_DIR, STRICT, BASELINE_COMMIT
parse_guard_args() {
  TARGET_DIR="."
  STRICT=false
  BASELINE_COMMIT=""
  local positional_count=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --strict)
        STRICT=true
        ;;
      --baseline)
        shift
        if [[ $# -eq 0 || -z "${1:-}" ]]; then
          echo "Error: --baseline requires a commit argument" >&2
          return 1
        fi
        BASELINE_COMMIT="$1"
        ;;
      --help|-h)
        echo "Usage: $0 [--strict] [--baseline <commit>] [target_dir]" >&2
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
  # Resolve to absolute canonical path (disambiguation of . / relative path / macOS /var→/private/var symbolic link)
  TARGET_DIR="$(cd "${TARGET_DIR}" 2>/dev/null && pwd -P || echo "${TARGET_DIR}")"

  # Verify that baseline commit exists to prevent invalid commits from causing empty linemaps and silently pass all checks
  if [[ -n "$BASELINE_COMMIT" ]]; then
    if ! git -C "${TARGET_DIR}" rev-parse --verify "${BASELINE_COMMIT}" >/dev/null 2>&1; then
      echo "Error: --baseline '${BASELINE_COMMIT}' is not a valid commit in '${TARGET_DIR}'" >&2
      return 1
    fi
  fi
}

# vg_build_diff_linemap OUTPUT_FILE [EXT_FILTER]
#
# Build diff and add new line number index file (each line format: "filepath:linenum").
# Used for baseline scanning: only new problems added to this diff will be reported, existing problems will not be reported.
#
# pre-commit mode (VIBEGUARD_STAGED_FILES is set): read git diff --cached
# baseline mode (BASELINE_COMMIT is set): read git diff BASELINE..HEAD
#
# Returns: 0 = success (linemap may be empty); 1 = not in any diff mode
vg_build_diff_linemap() {
  local out="$1"
  local ext_filter="${2:-}"
  : > "$out"

  command -v python3 >/dev/null 2>&1 || return 1

  local staged="${VIBEGUARD_STAGED_FILES:-}"
  local baseline="${BASELINE_COMMIT:-}"
  [[ -z "$staged" && -z "$baseline" ]] && return 1

  VG_STAGED="$staged" VG_BASELINE="$baseline" VG_EXT="$ext_filter" VG_OUT="$out" VG_TARGET_DIR="${TARGET_DIR:-.}" \
  python3 -c '
import sys, re, subprocess, os

staged     = os.environ.get("VG_STAGED", "")
baseline   = os.environ.get("VG_BASELINE", "")
ext_filter = os.environ.get("VG_EXT", "")
out_path   = os.environ.get("VG_OUT", "")
target_dir = os.environ.get("VG_TARGET_DIR", ".")

_git_root_cache = {}

def get_git_root(dirpath):
    """Detect git root from a directory; returns canonical absolute path."""
    key = os.path.realpath(dirpath)
    if key not in _git_root_cache:
        r = subprocess.run(
            ["git", "-C", key, "rev-parse", "--show-toplevel"],
            capture_output=True, text=True
        )
        _git_root_cache[key] = os.path.realpath(r.stdout.strip()) if r.returncode == 0 else ""
    return _git_root_cache[key]

def iter_files():
    if staged and os.path.isfile(staged):
        with open(staged) as fh:
            for line in fh:
                p = os.path.realpath(line.strip())
                if p and (not ext_filter or re.search(ext_filter, p)):
                    yield p
    elif baseline:
        root = get_git_root(target_dir)
        if not root:
            return
        result = subprocess.run(
            ["git", "-C", root, "diff", "--name-only", baseline + "..HEAD"],
            capture_output=True, text=True
        )
        for fname in result.stdout.splitlines():
            if fname and (not ext_filter or re.search(ext_filter, fname)):
                yield os.path.join(root, fname)

def added_linenos(fpath):
    file_dir = os.path.dirname(fpath) or "."
    git_root = get_git_root(file_dir)
    if not git_root:
        return []
    if baseline:
        cmd = ["git", "-C", git_root, "diff", "-U0", baseline + "..HEAD", "--", fpath]
    else:
        cmd = ["git", "-C", git_root, "diff", "--cached", "-U0", "--", fpath]
    result = subprocess.run(cmd, capture_output=True, text=True)
    cur = 0
    nums = []
    for line in result.stdout.splitlines():
        if line.startswith("@@"):
            m = re.search(r"\+(\d+)(?:,(\d+))?", line)
            if m:
                cur = int(m.group(1))
                cnt = int(m.group(2)) if m.group(2) is not None else 1
                if cnt == 0:
                    cur = 0
        elif line.startswith("+++"):
            continue
        elif line.startswith("+"):
            if cur > 0:
                nums.append(cur)
                cur += 1
        elif not line.startswith("-") and not line.startswith("\\\\"):
            if cur > 0:
                cur += 1
    return nums

with open(out_path, "w") as out:
    for fpath in iter_files():
        if not os.path.isfile(fpath):
            continue
        for n in added_linenos(fpath):
            out.write(fpath + ":" + str(n) + "\n")
'
  local _py_rc=$?
  if [[ $_py_rc -ne 0 ]]; then
    echo "Error: vg_build_diff_linemap failed (exit ${_py_rc})" >&2
    return $_py_rc
  fi
  return 0
}

# Temporary file cleaning directory
_VG_TMPDIR=""

_vg_cleanup() {
  [[ -n "$_VG_TMPDIR" && -d "$_VG_TMPDIR" ]] && rm -rf "$_VG_TMPDIR" || true
}
trap '_vg_cleanup' EXIT

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
    local rule_id
    rule_id=$(printf '%s' "$finding" | sed -n 's/^\[\([^]]*\)\].*/\1/p')

    if [[ -z "$rule_id" ]]; then
      printf '%s\n' "$finding" >> "$filtered_file"
      continue
    fi

    local rest
    rest="${finding#\[${rule_id}\] }"

    local line_num
    line_num=$(printf '%s' "$rest" | grep -oE ':[0-9]+' | head -1 | tr -d ':' || true)

    if [[ -z "$line_num" ]]; then
      printf '%s\n' "$finding" >> "$filtered_file"
      continue
    fi

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
