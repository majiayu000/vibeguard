#!/usr/bin/env bash
# VibeGuard TypeScript Guard — [TS-03] console 残留检测
#
# 检测非测试文件中的 console.log、console.warn、console.error 残留。
# 与 post-edit-guard 的实时检测互补，这个脚本做项目级全量扫描。
#
# 用法：
#   bash check_console_residual.sh [--strict] [target_dir]
#
# --strict 模式：任何违规都以非零退出码退出

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
parse_guard_args "$@"

RESULTS=$(create_tmpfile)
COUNT=0

# CLI 项目允许使用 console，跳过整个检查。
# 仅当检测到显式 CLI 入口时才跳过，避免把仅带 bin 字段的库项目误判为 CLI。
_IS_CLI=false
if [[ -f "${TARGET_DIR}/package.json" ]]; then
  grep -qE '"[^"]*":\s*"[^"]*cli[^"]*"' "${TARGET_DIR}/package.json" 2>/dev/null && _IS_CLI=true
fi
ls "${TARGET_DIR}/src/cli."* "${TARGET_DIR}/cli."* 2>/dev/null | grep -q . && _IS_CLI=true
if [[ "$_IS_CLI" == true ]]; then
  echo "[TS-03] SKIP: CLI 项目，console 为正常输出方式"
  exit 0
fi

# Pre-commit diff-only mode: only check lines added in staged diff
if [[ -n "${VIBEGUARD_STAGED_FILES:-}" ]] && [[ -f "${VIBEGUARD_STAGED_FILES}" ]]; then
  STAGED_TS=$(grep -E '\.(ts|tsx|js|jsx)$' "${VIBEGUARD_STAGED_FILES}" \
    | grep -vE '(\.(test|spec)\.(ts|tsx|js|jsx)$|/__tests__/|/test/)' || true)
  if [[ -n "${STAGED_TS}" ]]; then
    while IFS= read -r f; do
      [[ -z "$f" || ! -f "$f" ]] && continue
      REL_PATH="${f#${TARGET_DIR}/}"

      # 排除合理使用 console 的文件
      case "$REL_PATH" in
        *logger*|*logging*|*log.config*) continue ;;
        */debug.*|*/debug/*) continue ;;
      esac

      # MCP 入口文件用 console.error 输出到 stderr 是协议标准做法，跳过
      if grep -qE '(StdioServerTransport|new Server\(|McpServer)' "$f" 2>/dev/null; then
        continue
      fi

      DIFF_LINES=$(git diff --cached -U0 -- "${f}" 2>/dev/null | grep '^+' | grep -v '^+++' || true)
      [[ -z "${DIFF_LINES}" ]] && continue

      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # 跳过注释行
        TRIMMED=$(echo "$line" | sed 's/^[+[:space:]]*//')
        case "$TRIMMED" in
          //*|'*'*) continue ;;
        esac
        echo "[TS-03] ${REL_PATH}: console 残留。修复：使用项目 logger 替代，或删除调试代码" >> "$RESULTS"
        COUNT=$((COUNT + 1))
      done < <(echo "${DIFF_LINES}" | grep -E '\bconsole\.(log|warn|error|debug|info)\(' || true)

    done <<< "${STAGED_TS}"
  fi
else
  # Full-file scan mode (post-edit or explicit check)
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    [[ ! -f "$file" ]] && continue

    REL_PATH="${file#${TARGET_DIR}/}"

    # 排除合理使用 console 的文件
    case "$REL_PATH" in
      *logger*|*logging*|*log.config*) continue ;;
      */debug.*|*/debug/*) continue ;;
    esac

    # MCP 入口文件用 console.error 输出到 stderr 是协议标准做法，跳过
    if grep -qE '(StdioServerTransport|new Server\(|McpServer)' "$file" 2>/dev/null; then
      continue
    fi

    while IFS= read -r line_info; do
      [[ -z "$line_info" ]] && continue
      LINE_NUM=$(echo "$line_info" | cut -d: -f1)
      LINE_CONTENT=$(echo "$line_info" | cut -d: -f2-)
      # 跳过注释行
      TRIMMED=$(echo "$LINE_CONTENT" | sed 's/^[[:space:]]*//')
      case "$TRIMMED" in
        //*|'*'*) continue ;;
      esac
      echo "[TS-03] ${REL_PATH}:${LINE_NUM} console 残留。修复：使用项目 logger 替代，或删除调试代码" >> "$RESULTS"
      COUNT=$((COUNT + 1))
    done < <(grep -nE '\bconsole\.(log|warn|error|debug|info)\(' "$file" 2>/dev/null || true)

  done < <(list_ts_files "$TARGET_DIR" | filter_non_test)
fi

# Apply suppression filter before counting
FILTERED=$(create_tmpfile)
filter_suppressed < "$RESULTS" > "$FILTERED" || true
COUNT=$(wc -l < "$FILTERED" | tr -d ' ')

if [[ $COUNT -eq 0 ]]; then
  echo "[TS-03] PASS: 未检测到 console 残留"
  exit 0
fi

echo "[TS-03] 检测到 ${COUNT} 处 console 残留:"
echo
cat "$FILTERED"

if [[ "$STRICT" == "true" ]]; then
  exit 1
fi
