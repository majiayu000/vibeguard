#!/usr/bin/env bash
# VibeGuard TypeScript Guards — 共享函数库
#
# 所有 TypeScript 守卫脚本通过 source common.sh 引入，消除重复代码。
# 提供：list_ts_files、参数解析、临时文件管理
# 模式参考：guards/rust/common.sh

set -euo pipefail

# 列出 .ts/.tsx/.js/.jsx 源文件
# 优先级：VIBEGUARD_STAGED_FILES（pre-commit 模式，只扫 staged）> git ls-files > find
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

# 过滤掉测试文件
filter_non_test() {
  grep -vE '(\.(test|spec)\.(ts|tsx|js|jsx)$|/tests/|/__tests__/|/test/)' || true
}

# 解析 --strict 标志和 target_dir
# 用法: parse_guard_args "$@"
# 设置变量: TARGET_DIR, STRICT
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

# 临时文件清理目录
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
# In staged mode (VIBEGUARD_STAGED_FILES set), reads from the git index so that
# unstaged working-tree changes don't cause line-number skew.
check_suppression() {
  local file="$1" line_num="$2" rule_id="$3"
  local prev=$((line_num - 1))
  [[ $prev -lt 1 ]] && return 1

  local prev_line=""
  if [[ -n "${VIBEGUARD_STAGED_FILES:-}" ]]; then
    # Read from the staged index to match the line numbers produced by git diff --cached.
    local git_root
    git_root=$(git -C "$(dirname "$file")" rev-parse --show-toplevel 2>/dev/null) || true
    if [[ -n "$git_root" ]]; then
      local rel="${file#${git_root}/}"
      prev_line=$(git show ":${rel}" 2>/dev/null | sed -n "${prev}p") || prev_line=""
    fi
    # Fallback to working tree for new files not yet tracked in the index.
    if [[ -z "$prev_line" ]]; then
      [[ ! -f "$file" ]] && return 1
      prev_line=$(sed -n "${prev}p" "$file" 2>/dev/null) || prev_line=""
    fi
  else
    [[ ! -f "$file" ]] && return 1
    prev_line=$(sed -n "${prev}p" "$file" 2>/dev/null) || prev_line=""
  fi

  # Use //[[:space:]]* (not //.*) to avoid matching doc comments that merely
  # mention the directive (e.g. "// To suppress, use vibeguard-disable-next-line TS-01").
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
