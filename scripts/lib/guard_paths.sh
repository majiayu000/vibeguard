#!/usr/bin/env bash
# VibeGuard — guard script path detection (shared function)
# Sourced by compliance_check.sh and metrics_collector.sh

# Find guard scripts: VIBEGUARD_DIR/guards/ first, fallback project local
# Usage: path=$(find_guard "python/check_duplicates.py" "$PROJECT_DIR")
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

# Find test_code_quality_guards.py in the project
# Usage: path=$(find_quality_guard "$PROJECT_DIR")
find_quality_guard() {
  local project_dir="${1:-.}"
  find "${project_dir}" -path "*/architecture/test_code_quality_guards.py" -type f 2>/dev/null | head -1
}
