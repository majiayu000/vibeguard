#!/usr/bin/env bash
# VibeGuard Rust Guards — 共享函数库
#
# 所有 Rust 守卫脚本通过 source common.sh 引入，消除重复代码。
# 提供：list_rs_files、参数解析、临时文件管理

set -euo pipefail

# Paths to always exclude from scanning (worktrees, build artifacts, IDE caches).
VIBEGUARD_EXCLUDE_PATHS='(.harness/worktrees/|/target/|/.git/|/node_modules/)'

# Test file patterns — files that are exclusively test code.
VIBEGUARD_TEST_FILE_PATTERN='(/tests/|/test_|_test\.rs$|tests\.rs$|test_helpers\.rs$|/examples/|/benches/)'

# 列出 .rs 源文件
# 优先级：VIBEGUARD_STAGED_FILES（pre-commit 模式，只扫 staged）> git ls-files > find
# 自动排除 worktree 副本和构建目录。
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

# 列出非测试 .rs 文件（在 list_rs_files 基础上排除 test 文件）
list_rs_prod_files() {
  list_rs_files "$1" | { grep -vE "${VIBEGUARD_TEST_FILE_PATTERN}" || true; }
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

# 临时文件清理目录：所有守卫共享同一清理 trap
_VG_TMPDIR=""

_vg_cleanup() {
  [[ -n "$_VG_TMPDIR" && -d "$_VG_TMPDIR" ]] && rm -rf "$_VG_TMPDIR" || true
}
trap '_vg_cleanup' EXIT

# 创建临时文件并自动在脚本退出时清理
# 用法: TMPFILE=$(create_tmpfile)
create_tmpfile() {
  if [[ -z "$_VG_TMPDIR" ]]; then
    _VG_TMPDIR=$(mktemp -d)
  fi
  mktemp "$_VG_TMPDIR/vg.XXXXXX"
}

# check_suppression FILE LINE_NUM RULE_ID
# Returns 0 if the line is suppressed by a vibeguard-disable-next-line comment, 1 otherwise.
check_suppression() {
  local file="$1" line="$2" rule="$3"
  local prev=$((line - 1))
  [[ $prev -lt 1 ]] && return 1
  local resolved="$file"
  if [[ ! -f "$resolved" && -n "${TARGET_DIR:-}" && -f "${TARGET_DIR}/${file}" ]]; then
    resolved="${TARGET_DIR}/${file}"
  fi
  [[ ! -f "$resolved" ]] && return 1
  local prev_content
  prev_content=$(sed -n "${prev}p" "${resolved}" 2>/dev/null || true)
  echo "${prev_content}" | grep -qE "vibeguard-disable-next-line[[:space:]].*${rule}" && return 0
  return 1
}

# filter_suppressed: reads "[RULE-ID] file:linenum ..." lines from stdin,
# removes any line whose previous line in the source file contains
# "vibeguard-disable-next-line RULE-ID".
filter_suppressed() {
  while IFS= read -r violation; do
    [[ -z "$violation" ]] && continue
    local rule rest file linenum
    rule=$(echo "$violation" | sed -n 's/^\[\([^]]*\)\].*/\1/p')
    if [[ -z "$rule" ]]; then
      echo "$violation"; continue
    fi
    rest=$(echo "$violation" | sed "s/^\[${rule}\][[:space:]]*//")
    file=$(echo "$rest" | cut -d: -f1)
    linenum=$(echo "$rest" | cut -d: -f2 | grep -oE '^[0-9]+' || true)
    if [[ -n "$file" && -n "$linenum" ]]; then
      if check_suppression "$file" "$linenum" "$rule"; then
        continue
      fi
    fi
    echo "$violation"
  done
}
