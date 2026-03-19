#!/usr/bin/env bash
# VibeGuard Pre-Commit Guard — git commit 前自动守卫（Verifier 模式）
#
# 安装到 .git/hooks/pre-commit 后，每次 git commit 自动运行。
# 自动检测项目语言 → 调用 guards/ 下对应的守卫脚本 → 运行构建检查。
#
# exit 0 = 放行
# exit 1 = 阻止提交
#
# 跳过方式: VIBEGUARD_SKIP_PRECOMMIT=1 git commit -m "msg"

set -euo pipefail

if [[ "${VIBEGUARD_SKIP_PRECOMMIT:-0}" == "1" ]]; then
  exit 0
fi

# --- 定位资源 ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "${SCRIPT_DIR}/log.sh" ]]; then
  source "${SCRIPT_DIR}/log.sh"
elif [[ -n "${VIBEGUARD_DIR:-}" ]] && [[ -f "${VIBEGUARD_DIR}/hooks/log.sh" ]]; then
  source "${VIBEGUARD_DIR}/hooks/log.sh"
else
  vg_log() { :; }
  VG_SOURCE_EXTS="rs py ts js tsx jsx go java kt swift rb"
fi

# 定位 guards 目录
if [[ -n "${VIBEGUARD_DIR:-}" ]] && [[ -d "${VIBEGUARD_DIR}/guards" ]]; then
  GUARDS_DIR="${VIBEGUARD_DIR}/guards"
elif [[ -d "${SCRIPT_DIR}/../guards" ]]; then
  GUARDS_DIR="$(cd "${SCRIPT_DIR}/../guards" && pwd)"
else
  GUARDS_DIR=""
fi
# Shell-quote GUARDS_DIR for safe embedding in "bash -c" strings (handles spaces in path)
GUARDS_DIR_Q="$(printf '%q' "${GUARDS_DIR}")"

TIMEOUT="${VIBEGUARD_PRECOMMIT_TIMEOUT:-10}"
TIMEOUT_CMD=""
HAS_PYTHON3=0
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_CMD="gtimeout"
fi
command -v python3 >/dev/null 2>&1 && HAS_PYTHON3=1

# --- 收集 staged 源码文件（单次 git diff，按扩展名过滤） ---
_ALL_STAGED=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null || true)
STAGED_FILES=""
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  ext="${file##*.}"
  for e in $VG_SOURCE_EXTS; do
    if [[ "$ext" == "$e" ]]; then
      STAGED_FILES="${STAGED_FILES}${file}"$'\n'
      break
    fi
  done
done <<< "$_ALL_STAGED"
STAGED_FILES=$(echo "$STAGED_FILES" | sed '/^$/d')

if [[ -z "$STAGED_FILES" ]]; then
  exit 0
fi

FILE_COUNT=$(echo "$STAGED_FILES" | wc -l | tr -d ' ')

# --- 导出 staged 文件列表供守卫脚本使用（只扫 staged 文件，不扫全量） ---
_STAGED_TMPFILE=$(mktemp)
_cleanup_staged() { rm -f "$_STAGED_TMPFILE" 2>/dev/null; }
trap '_cleanup_staged' EXIT
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
while IFS= read -r f; do
  [[ -n "$f" ]] && echo "${REPO_ROOT}/${f}"
done <<< "$STAGED_FILES" > "$_STAGED_TMPFILE"
export VIBEGUARD_STAGED_FILES="$_STAGED_TMPFILE"

# --- 语言自动检测（Verifier 模式核心） ---
# 使用 REPO_ROOT 绝对路径，避免子目录 commit 时检测失败
DETECTED_LANGS=""
[[ -f "${REPO_ROOT}/Cargo.toml" ]]                                                      && DETECTED_LANGS="${DETECTED_LANGS} rust"
[[ -f "${REPO_ROOT}/tsconfig.json" ]]                                                   && DETECTED_LANGS="${DETECTED_LANGS} typescript"
[[ -f "${REPO_ROOT}/package.json" && ! -f "${REPO_ROOT}/tsconfig.json" ]]               && DETECTED_LANGS="${DETECTED_LANGS} javascript"
[[ -f "${REPO_ROOT}/pyproject.toml" || -f "${REPO_ROOT}/setup.py" || -f "${REPO_ROOT}/setup.cfg" ]]  && DETECTED_LANGS="${DETECTED_LANGS} python"
[[ -f "${REPO_ROOT}/go.mod" ]]                                                          && DETECTED_LANGS="${DETECTED_LANGS} go"
DETECTED_LANGS=$(echo "$DETECTED_LANGS" | xargs)

# --- 超时执行器 ---
run_with_timeout() {
  local cmd="$1"
  local code=0

  if [[ -n "${TIMEOUT_CMD}" ]]; then
    "${TIMEOUT_CMD}" "${TIMEOUT}" bash -c "$cmd" 2>&1 && return 0
    code=$?
    [[ $code -eq 124 ]] && return 124
    [[ $code -ne 127 ]] && return "$code"
  fi

  if [[ "${HAS_PYTHON3}" -eq 1 ]]; then
    python3 - "${TIMEOUT}" "$cmd" <<'PY' && return 0
import subprocess, sys
try:
    proc = subprocess.run(["bash", "-c", sys.argv[2]], timeout=int(sys.argv[1]))
    sys.exit(proc.returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)
except Exception:
    sys.exit(1)
PY
    return $?
  fi

  bash -c "$cmd" 2>&1 && return 0
  return $?
}

# --- 质量守卫：调用 guards/ 脚本（取代内联 grep） ---
GUARD_OUTPUT=""
GUARD_FAIL=0

run_guard() {
  local label="$1"
  local cmd="$2"
  local output code=0

  output=$(run_with_timeout "$cmd" 2>&1) || code=$?
  [[ $code -eq 124 ]] && return 0  # 超时跳过

  if [[ $code -ne 0 ]]; then
    GUARD_FAIL=1
    GUARD_OUTPUT="${GUARD_OUTPUT}\n[${label}]\n${output}\n"
  fi
}

if [[ -n "$GUARDS_DIR" ]]; then
  # Quote GUARDS_DIR for safe use inside bash -c strings (handles paths with spaces)
  GUARDS_DIR_Q=$(printf '%q' "${GUARDS_DIR}")
  for lang in $DETECTED_LANGS; do
    case "$lang" in
      rust)
        [[ -f "${GUARDS_DIR}/rust/check_unwrap_in_prod.sh" ]] && \
          run_guard "rust/unwrap" "bash ${GUARDS_DIR_Q}/rust/check_unwrap_in_prod.sh --strict ."
        ;;
      typescript|javascript)
        [[ -f "${GUARDS_DIR}/typescript/check_console_residual.sh" ]] && \
          run_guard "ts/console" "bash ${GUARDS_DIR_Q}/typescript/check_console_residual.sh --strict ."
        [[ -f "${GUARDS_DIR}/typescript/check_any_abuse.sh" ]] && \
          run_guard "ts/any" "bash ${GUARDS_DIR_Q}/typescript/check_any_abuse.sh --strict ."
        ;;
      python)
        [[ -f "${GUARDS_DIR}/python/check_naming_convention.py" ]] && \
          run_guard "py/naming" "python3 ${GUARDS_DIR_Q}/python/check_naming_convention.py ."
        [[ -f "${GUARDS_DIR}/python/check_dead_shims.py" ]] && \
          run_guard "py/dead_shims" "python3 ${GUARDS_DIR_Q}/python/check_dead_shims.py --strict ."
        ;;
      go)
        [[ -f "${GUARDS_DIR}/go/check_error_handling.sh" ]] && \
          run_guard "go/error_handling" "bash ${GUARDS_DIR_Q}/go/check_error_handling.sh --strict ."
        [[ -f "${GUARDS_DIR}/go/check_goroutine_leak.sh" ]] && \
          run_guard "go/goroutine_leak" "bash ${GUARDS_DIR_Q}/go/check_goroutine_leak.sh --strict ."
        [[ -f "${GUARDS_DIR}/go/check_defer_in_loop.sh" ]] && \
          run_guard "go/defer_in_loop" "bash ${GUARDS_DIR_Q}/go/check_defer_in_loop.sh --strict ."
        ;;
    esac
  done
fi

# --- 构建检查：所有检测到的语言都跑（不是 elif） ---
BUILD_FAILS=""

run_build_check() {
  local cmd="$1"
  local fail_msg="$2"
  local code=0

  run_with_timeout "$cmd" >/dev/null 2>&1 || code=$?
  if [[ $code -ne 0 && $code -ne 124 ]]; then
    BUILD_FAILS="${BUILD_FAILS}  ${fail_msg}\n"
  fi
}

for lang in $DETECTED_LANGS; do
  case "$lang" in
    rust)
      run_build_check "cargo check --quiet"  "cargo check 失败"
      ;;
    typescript)       run_build_check "npx tsc --noEmit"     "tsc --noEmit 失败" ;;
    javascript)       run_build_check 'if ! command -v node >/dev/null 2>&1; then exit 0; fi; FILES=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null | grep -E "\.(js|mjs|cjs)$" || true); [[ -z "$FILES" ]] && exit 0; while IFS= read -r f; do [[ -z "$f" || ! -f "$f" ]] && continue; node --check "$f" >/dev/null 2>&1 || exit 1; done <<< "$FILES"' "JavaScript 语法检查失败（node --check）" ;;
    go)               run_build_check "go build ./..."       "go build 失败" ;;
  esac
done

# --- 汇总 ---
if [[ $GUARD_FAIL -eq 0 ]] && [[ -z "$BUILD_FAILS" ]]; then
  vg_log "pre-commit-guard" "git-commit" "pass" "staged ${FILE_COUNT} files, all clean [${DETECTED_LANGS}]" ""
  exit 0
fi

echo "VibeGuard Pre-Commit Guard: 检测到问题"
echo "======================================="
echo "检测语言: ${DETECTED_LANGS:-none}"

if [[ $GUARD_FAIL -ne 0 ]]; then
  echo ""
  echo "质量守卫："
  echo -e "$GUARD_OUTPUT"
fi

if [[ -n "$BUILD_FAILS" ]]; then
  echo ""
  echo "构建失败："
  echo -e "$BUILD_FAILS"
fi

echo ""
echo "修复后重新 git add && git commit"
echo "紧急跳过（仅限人工操作）：VIBEGUARD_SKIP_PRECOMMIT=1 git commit -m \"msg\"" >&2

REASON="${GUARD_FAIL:+guard fail}${BUILD_FAILS:+${GUARD_FAIL:+, }build fail}"
DETAIL=$(echo "$STAGED_FILES" | head -5 | tr '\n' ' ')
# 把守卫输出摘要写入日志（截断前 500 字符避免日志膨胀）
LOG_DETAIL="${DETAIL}"
if [[ -n "$GUARD_OUTPUT" ]]; then
  GUARD_SUMMARY=$(echo -e "$GUARD_OUTPUT" | head -20 | cut -c1-200 | tr '\n' '|')
  LOG_DETAIL="${DETAIL}||guards: ${GUARD_SUMMARY}"
fi
if [[ -n "$BUILD_FAILS" ]]; then
  BUILD_SUMMARY=$(echo -e "$BUILD_FAILS" | head -5 | tr '\n' '|')
  LOG_DETAIL="${LOG_DETAIL}||build: ${BUILD_SUMMARY}"
fi
vg_log "pre-commit-guard" "git-commit" "block" "$REASON" "$LOG_DETAIL"

exit 1
