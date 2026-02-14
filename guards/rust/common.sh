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
# 用法: eval "$(parse_guard_args "$@")"
# 设置变量: TARGET_DIR, STRICT
parse_guard_args() {
  local target_dir="${1:-.}"
  local strict=false

  if [[ "${1:-}" == "--strict" ]]; then
    strict=true
    target_dir="${2:-.}"
  elif [[ "${2:-}" == "--strict" ]]; then
    strict=true
  fi

  echo "TARGET_DIR='${target_dir}'; STRICT=${strict}"
}

# 创建临时文件并注册清理
# 用法: TMPFILE=$(create_tmpfile)
create_tmpfile() {
  local tmpfile
  tmpfile=$(mktemp)
  trap 'rm -f "'"${tmpfile}"'"' EXIT
  echo "${tmpfile}"
}
