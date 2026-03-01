#!/usr/bin/env bash
# VibeGuard — 守卫脚本路径探测（共享函数）
# 被 compliance_check.sh 和 metrics_collector.sh source

# 查找守卫脚本：优先 VIBEGUARD_DIR/guards/，fallback 项目本地
# 用法: path=$(find_guard "python/check_duplicates.py" "$PROJECT_DIR")
find_guard() {
  local relative_path="$1"
  local project_dir="${2:-.}"
  local vg_path="${VIBEGUARD_DIR}/guards/${relative_path}"
  local local_path="${project_dir}/scripts/$(basename "${relative_path}")"

  if [[ -f "${vg_path}" ]]; then
    echo "${vg_path}"
  elif [[ -f "${local_path}" ]]; then
    echo "${local_path}"
  fi
}

# 查找项目中的 test_code_quality_guards.py
# 用法: path=$(find_quality_guard "$PROJECT_DIR")
find_quality_guard() {
  local project_dir="${1:-.}"
  find "${project_dir}" -path "*/architecture/test_code_quality_guards.py" -type f 2>/dev/null | head -1
}
