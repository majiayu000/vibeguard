#!/usr/bin/env bash
# VibeGuard Rust Guards — 共享函数库
#
# 所有 Rust 守卫脚本通过 source common.sh 引入，消除重复代码。
# 提供：list_rs_files、参数解析、临时文件管理

set -euo pipefail

# 列出 .rs 源文件（优先 git ls-files，非 git 仓库降级 find）
list_rs_files() {
  local dir="$1"
  if git -C "${dir}" rev-parse --is-inside-work-tree &>/dev/null; then
    git -C "${dir}" ls-files '*.rs' | while IFS= read -r f; do echo "${dir}/${f}"; done
  else
    find "${dir}" -name '*.rs' -not -path '*/target/*' -not -path '*/.git/*'
  fi
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
