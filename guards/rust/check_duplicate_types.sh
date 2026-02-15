#!/usr/bin/env bash
# VibeGuard Rust Guard: 检测跨文件重复类型定义 (RS-05)
#
# 扫描 pub struct/enum 的名称，报告同名类型出现在多个文件中的情况。
# 用法:
#   bash check_duplicate_types.sh [target_dir]
#   bash check_duplicate_types.sh --strict [target_dir]  # 有重复则退出码 1
#
# 排除: tests/ 目录

source "$(dirname "$0")/common.sh"
eval "$(parse_guard_args "$@")"

# 允许列表
ALLOWLIST_FILE="${TARGET_DIR}/.vibeguard-duplicate-types-allowlist"

declare -A ALLOWLIST
if [[ -f "${ALLOWLIST_FILE}" ]]; then
  while IFS= read -r name; do
    [[ -z "${name}" || "${name}" == \#* ]] && continue
    ALLOWLIST["${name}"]=1
  done < "${ALLOWLIST_FILE}"
fi

TMPFILE=$(create_tmpfile)

# 提取：类型名 文件路径:行号（逐文件处理，兼容空格路径和空输入）
list_rs_files "${TARGET_DIR}" \
  | { grep -vE '(/tests/|/test_)' || true; } \
  | while IFS= read -r f; do
      if [[ -f "${f}" ]]; then
        grep -nE '^[[:space:]]*pub[[:space:]]+(struct|enum)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' "${f}" 2>/dev/null \
          | sed -E "s@^([0-9]+):.*pub[[:space:]]+(struct|enum)[[:space:]]+([A-Za-z_][A-Za-z0-9_]*).*@\3 ${f}:\1@" || true
      fi
    done \
  | sort \
  > "${TMPFILE}"

# 构建允许列表参数给 awk
ALLOWLIST_AWK=""
for name in "${!ALLOWLIST[@]}"; do
  ALLOWLIST_AWK="${ALLOWLIST_AWK}${name}\n"
done

# 用 awk 单进程完成分组、去重、报告
RESULT=$(awk -v allowlist="${ALLOWLIST_AWK}" '
BEGIN {
  n = split(allowlist, arr, "\n")
  for (i = 1; i <= n; i++) if (arr[i] != "") skip[arr[i]] = 1
}
{
  name = $1; loc = $2
  split(loc, parts, ":")
  file = parts[1]
  if (!(name in first_file)) {
    first_file[name] = file
    seen[name, file] = 1
    locs[name] = loc
    file_count[name] = 1
  } else if (!((name, file) in seen)) {
    seen[name, file] = 1
    locs[name] = locs[name] ", " loc
    file_count[name]++
  }
}
END {
  found = 0
  for (name in file_count) {
    if (file_count[name] > 1 && !(name in skip)) {
      printf "[RS-05] Duplicate type: %s\n  Locations: %s\n\n", name, locs[name]
      found++
    }
  }
  if (found == 0)
    print "No duplicate types found."
  else
    printf "Found %d duplicate type(s).\n", found
  if (found > 0) {
    print ""
    print "修复方法："
    print "  1. 提取到共享模块：将类型定义移到 core/ 或 shared/，各入口 pub use 引入"
    print "  2. 如果同名但不同义：重命名以区分语义（如 ServerConfig vs DesktopConfig）"
    print "  3. 如果是 re-export 导致的假阳性：添加到 .vibeguard-duplicate-types-allowlist"
  }
  print "EXIT_CODE=" (found > 0 ? "1" : "0")
}
' "${TMPFILE}")

# 输出结果（去掉最后的 EXIT_CODE 行）
echo "${RESULT}" | grep -v '^EXIT_CODE='

# 提取退出码
SHOULD_FAIL=$(echo "${RESULT}" | grep '^EXIT_CODE=' | cut -d= -f2)
if [[ "${STRICT}" == true && "${SHOULD_FAIL}" == "1" ]]; then
  exit 1
fi
