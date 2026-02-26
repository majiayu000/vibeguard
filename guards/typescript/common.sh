#!/usr/bin/env bash
# VibeGuard TypeScript Guards — 共享函数库
#
# 所有 TypeScript 守卫脚本通过 source common.sh 引入，消除重复代码。
# 提供：list_ts_files、参数解析、临时文件管理
# 模式参考：guards/rust/common.sh

set -euo pipefail

# 列出 .ts/.tsx/.js/.jsx 源文件（优先 git ls-files，非 git 仓库降级 find）
# 默认排除测试文件和 node_modules
list_ts_files() {
  local dir="$1"
  if git -C "${dir}" rev-parse --is-inside-work-tree &>/dev/null; then
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
