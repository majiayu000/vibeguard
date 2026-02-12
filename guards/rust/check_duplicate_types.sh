#!/usr/bin/env bash
set -euo pipefail

# VibeGuard Rust Guard: 检测跨文件重复类型定义 (RS-05)
#
# 扫描 pub struct/enum 的名称，报告同名类型出现在多个文件中的情况。
# 用法:
#   bash check_duplicate_types.sh [target_dir]
#   bash check_duplicate_types.sh --strict [target_dir]  # 有重复则退出码 1
#
# 排除: tests/ 目录

TARGET_DIR="${1:-.}"
STRICT=false

if [[ "${1:-}" == "--strict" ]]; then
  STRICT=true
  TARGET_DIR="${2:-.}"
elif [[ "${2:-}" == "--strict" ]]; then
  STRICT=true
fi

# 允许列表
ALLOWLIST_FILE="${TARGET_DIR}/.vibeguard-duplicate-types-allowlist"

declare -A ALLOWLIST
if [[ -f "${ALLOWLIST_FILE}" ]]; then
  while IFS= read -r name; do
    [[ -z "${name}" || "${name}" == \#* ]] && continue
    ALLOWLIST["${name}"]=1
  done < "${ALLOWLIST_FILE}"
fi

TMPFILE=$(mktemp)
trap 'rm -f "${TMPFILE}"' EXIT

# 提取：类型名 文件路径:行号
# 用 grep -oP 提取类型名（macOS 无 -P，改用 sed）
grep -rn --include='*.rs' \
  -E '^\s*pub\s+(struct|enum)\s+[A-Za-z_][A-Za-z0-9_]*' \
  "${TARGET_DIR}" \
  | grep -v '/tests/' \
  | grep -v '/test_' \
  | while IFS= read -r line; do
    # line 格式: path:linenum:  pub struct FooBar ...
    file_loc="${line%%:*}"                       # path
    rest="${line#*:}"
    linenum="${rest%%:*}"                        # linenum
    code="${rest#*:}"                            # code part
    # 从 code 中提取类型名（struct/enum 后的第一个标识符）
    type_name=$(echo "${code}" | sed -E 's/.*pub[[:space:]]+(struct|enum)[[:space:]]+([A-Za-z_][A-Za-z0-9_]*).*/\2/')
    if [[ -n "${type_name}" && "${type_name}" != "${code}" ]]; then
      echo "${type_name} ${file_loc}:${linenum}"
    fi
  done \
  | sort \
  > "${TMPFILE}"

# 按类型名分组
declare -A TYPE_FILES
declare -A TYPE_LOCS

while read -r name location; do
  [[ -z "${name}" ]] && continue
  file="${location%%:*}"
  if [[ -n "${TYPE_FILES[${name}]:-}" ]]; then
    if [[ "${TYPE_FILES[${name}]}" != *"${file}"* ]]; then
      TYPE_FILES["${name}"]="${TYPE_FILES[${name}]} ${file}"
      TYPE_LOCS["${name}"]="${TYPE_LOCS[${name}]}, ${location}"
    fi
  else
    TYPE_FILES["${name}"]="${file}"
    TYPE_LOCS["${name}"]="${location}"
  fi
done < "${TMPFILE}"

# 报告重复
FOUND=0
for name in "${!TYPE_FILES[@]}"; do
  file_count=$(echo "${TYPE_FILES[${name}]}" | tr ' ' '\n' | sort -u | wc -l | tr -d ' ')
  if [[ "${file_count}" -gt 1 ]]; then
    if [[ -n "${ALLOWLIST[${name}]:-}" ]]; then
      continue
    fi
    echo "[RS-05] Duplicate type: ${name}"
    echo "  Locations: ${TYPE_LOCS[${name}]}"
    echo ""
    ((FOUND++)) || true
  fi
done

if [[ ${FOUND} -eq 0 ]]; then
  echo "No duplicate types found."
else
  echo "Found ${FOUND} duplicate type(s)."
  if [[ "${STRICT}" == true ]]; then
    exit 1
  fi
fi
