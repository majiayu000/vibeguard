#!/usr/bin/env bash
# VibeGuard Hook 测试套件
#
# 用法：bash tests/test_hooks.sh
# 从仓库根目录运行

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

PASS=0
FAIL=0
TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }
header(){ printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

assert_contains() {
  local output="$1" expected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$output" | grep -qF "$expected"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (expected to contain: $expected)"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local output="$1" unexpected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if ! echo "$output" | grep -qF "$unexpected"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (unexpectedly contains: $unexpected)"
    FAIL=$((FAIL + 1))
  fi
}

assert_exit_zero() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (exit code: $?)"
    FAIL=$((FAIL + 1))
  fi
}

# 创建临时日志目录，避免污染真实日志
export VIBEGUARD_LOG_DIR=$(mktemp -d)
trap 'rm -rf "$VIBEGUARD_LOG_DIR"' EXIT

# =========================================================
header "log.sh — 注入防护"
# =========================================================

result=$(
  export VIBEGUARD_LOG_DIR
  source hooks/log.sh
  vg_log "test" "Tool" "pass" "reason with '''triple''' quotes" "detail \$(whoami)"
  cat "$VIBEGUARD_LOG_FILE"
)
assert_contains "$result" "'''triple'''" "三引号在 reason 中被安全记录"
assert_contains "$result" '$(whoami)' "命令替换在 detail 中不被执行"
assert_not_contains "$result" "$(whoami)" "whoami 结果不出现在日志中"

# 清空日志继续测试
> "$VIBEGUARD_LOG_DIR/events.jsonl"

result=$(
  export VIBEGUARD_LOG_DIR
  source hooks/log.sh
  vg_log "test" "Tool" "block" 'reason"; import os; os.system("id"); #' "normal"
  cat "$VIBEGUARD_LOG_FILE"
)
assert_contains "$result" '"decision": "block"' "Python 注入 payload 在 reason 中被安全记录"

# =========================================================
header "pre-bash-guard.sh — 危险命令拦截"
# =========================================================

# git push --force 应被拦截
result=$(echo '{"tool_input":{"command":"git push --force origin main"}}' | bash hooks/pre-bash-guard.sh)
assert_contains "$result" '"decision": "block"' "拦截 git push --force"

# git push --force-with-lease 应放行
result=$(echo '{"tool_input":{"command":"git push --force-with-lease origin main"}}' | bash hooks/pre-bash-guard.sh)
assert_not_contains "$result" '"decision": "block"' "放行 git push --force-with-lease"

# git reset --hard 应被拦截
result=$(echo '{"tool_input":{"command":"git reset --hard HEAD~1"}}' | bash hooks/pre-bash-guard.sh)
assert_contains "$result" '"decision": "block"' "拦截 git reset --hard"

# git checkout . 应被拦截
result=$(echo '{"tool_input":{"command":"git checkout ."}}' | bash hooks/pre-bash-guard.sh)
assert_contains "$result" '"decision": "block"' "拦截 git checkout ."

# git clean -f 应被拦截
result=$(echo '{"tool_input":{"command":"git clean -fd"}}' | bash hooks/pre-bash-guard.sh)
assert_contains "$result" '"decision": "block"' "拦截 git clean -f"

# rm -rf / 应被拦截
result=$(echo '{"tool_input":{"command":"rm -rf /"}}' | bash hooks/pre-bash-guard.sh)
assert_contains "$result" '"decision": "block"' "拦截 rm -rf /"

# rm -rf ~/  应被拦截
result=$(echo '{"tool_input":{"command":"rm -rf ~/"}}' | bash hooks/pre-bash-guard.sh)
assert_contains "$result" '"decision": "block"' "拦截 rm -rf ~/"

# rm -rf /Users/foo 应被拦截
result=$(echo '{"tool_input":{"command":"rm -rf /Users/foo"}}' | bash hooks/pre-bash-guard.sh)
assert_contains "$result" '"decision": "block"' "拦截 rm -rf /Users/foo"

# rm -rf ./node_modules 应放行（具体深层子目录）
result=$(echo '{"tool_input":{"command":"rm -rf ./node_modules"}}' | bash hooks/pre-bash-guard.sh)
assert_not_contains "$result" '"decision": "block"' "放行 rm -rf ./node_modules"

# npm run build 应放行
result=$(echo '{"tool_input":{"command":"npm run build"}}' | bash hooks/pre-bash-guard.sh)
assert_not_contains "$result" '"decision": "block"' "放行 npm run build"

# cargo build 应放行
result=$(echo '{"tool_input":{"command":"cargo build --release"}}' | bash hooks/pre-bash-guard.sh)
assert_not_contains "$result" '"decision": "block"' "放行 cargo build"

# vitest --run 应放行
result=$(echo '{"tool_input":{"command":"vitest --run"}}' | bash hooks/pre-bash-guard.sh)
assert_not_contains "$result" '"decision": "block"' "放行 vitest --run"

# commit message 含 force 不应误报
result=$(echo '{"tool_input":{"command":"git commit -m \"fix: force push guard\""}}' | bash hooks/pre-bash-guard.sh)
assert_not_contains "$result" '"decision": "block"' "commit message 含 force 不误报"

# heredoc 内容不应误报
result=$(echo '{"tool_input":{"command":"cat <<'\''EOF'\''\ngit push --force\nEOF"}}' | bash hooks/pre-bash-guard.sh)
assert_not_contains "$result" '"decision": "block"' "heredoc 内含 force push 不误报"

# =========================================================
header "pre-edit-guard.sh — 防幻觉编辑"
# =========================================================

# 不存在的文件应被拦截
result=$(echo '{"tool_input":{"file_path":"/nonexistent/file.rs","old_string":"test"}}' | bash hooks/pre-edit-guard.sh)
assert_contains "$result" '"decision": "block"' "拦截编辑不存在的文件"

# 路径含单引号应安全处理（不崩溃）
result=$(echo '{"tool_input":{"file_path":"/tmp/file'\''with'\''quotes.rs","old_string":"test"}}' | bash hooks/pre-edit-guard.sh)
assert_contains "$result" '"decision": "block"' "路径含单引号安全处理"

# 已存在文件 + 空 old_string 应放行
result=$(echo '{"tool_input":{"file_path":"hooks/log.sh","old_string":""}}' | bash hooks/pre-edit-guard.sh)
assert_not_contains "$result" '"decision": "block"' "已存在文件+空 old_string 放行"

# =========================================================
header "pre-write-guard.sh — 先搜后写"
# =========================================================

# 已存在的文件应放行
result=$(echo '{"tool_input":{"file_path":"hooks/log.sh"}}' | bash hooks/pre-write-guard.sh)
assert_not_contains "$result" "VIBEGUARD" "已存在文件直接放行"

# 新建 .md 文件应放行
result=$(echo '{"tool_input":{"file_path":"/tmp/vg_nonexist_test_README.md"}}' | bash hooks/pre-write-guard.sh)
assert_not_contains "$result" "VIBEGUARD" "新建 .md 文件放行"

# 新建 .json 文件应放行
result=$(echo '{"tool_input":{"file_path":"/tmp/vg_nonexist_test_config.json"}}' | bash hooks/pre-write-guard.sh)
assert_not_contains "$result" "VIBEGUARD" "新建 .json 文件放行"

# 新建测试文件应放行
result=$(echo '{"tool_input":{"file_path":"/tmp/vg_nonexist_test_foo.test.ts"}}' | bash hooks/pre-write-guard.sh)
assert_not_contains "$result" "VIBEGUARD" "新建测试文件放行"

# 新建源码文件应触发提醒/拦截
result=$(echo '{"tool_input":{"file_path":"/tmp/vg_nonexist_test_service.py"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" "VIBEGUARD" "新建 .py 源码文件触发 guard"

result=$(echo '{"tool_input":{"file_path":"/tmp/vg_nonexist_test_main.rs"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" "VIBEGUARD" "新建 .rs 源码文件触发 guard"

result=$(echo '{"tool_input":{"file_path":"/tmp/vg_nonexist_test_app.tsx"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" "VIBEGUARD" "新建 .tsx 源码文件触发 guard"

# tests/ 目录下的源码文件应放行
result=$(echo '{"tool_input":{"file_path":"/tmp/vg_nonexist_test/tests/helper.py"}}' | bash hooks/pre-write-guard.sh)
assert_not_contains "$result" "VIBEGUARD" "tests/ 目录下源码文件放行"

# =========================================================
header "post-edit-guard.sh — 质量警告"
# =========================================================

# Rust 文件新增 unwrap 应警告
result=$(echo '{"tool_input":{"file_path":"src/main.rs","new_string":"let val = data.unwrap();"}}' | bash hooks/post-edit-guard.sh)
assert_contains "$result" "RS-03" "检测 Rust unwrap"

# Rust 文件新增 unwrap_or_default 不应警告
result=$(echo '{"tool_input":{"file_path":"src/main.rs","new_string":"let val = data.unwrap_or_default();"}}' | bash hooks/post-edit-guard.sh)
assert_not_contains "$result" "RS-03" "不误报 unwrap_or_default"

# 测试文件中的 unwrap 不应警告
result=$(echo '{"tool_input":{"file_path":"tests/test_main.rs","new_string":"let val = data.unwrap();"}}' | bash hooks/post-edit-guard.sh)
assert_not_contains "$result" "RS-03" "测试文件 unwrap 不警告"

# TS 文件新增 console.log 应警告
result=$(echo '{"tool_input":{"file_path":"src/app.ts","new_string":"console.log(data);"}}' | bash hooks/post-edit-guard.sh)
assert_contains "$result" "DEBUG" "检测 TS console.log"

# Python 文件新增 print 应警告
result=$(echo '{"tool_input":{"file_path":"src/main.py","new_string":"  print(data)"}}' | bash hooks/post-edit-guard.sh)
assert_contains "$result" "DEBUG" "检测 Python print()"

# 硬编码 .db 路径应警告
result=$(echo '{"tool_input":{"file_path":"src/config.rs","new_string":"let db = \"app.db\";"}}' | bash hooks/post-edit-guard.sh)
assert_contains "$result" "U-11" "检测硬编码 .db 路径"

# =========================================================
header "post-write-guard.sh — 重复检测"
# =========================================================

# 非源码文件（.md）应放行
result=$(echo '{"tool_input":{"file_path":"/tmp/vg_test_readme.md","content":"# test"}}' | bash hooks/post-write-guard.sh)
assert_not_contains "$result" "VIBEGUARD" "非源码文件 (.md) 放行"

# 无 git 项目时放行（使用 /tmp 下不存在的路径）
result=$(echo '{"tool_input":{"file_path":"/tmp/vg_no_git_project/src/main.rs","content":"fn main() {}"}}' | bash hooks/post-write-guard.sh)
assert_not_contains "$result" "VIBEGUARD" "无 git 项目时放行"

# 空 content 放行
result=$(echo '{"tool_input":{"file_path":"src/lib.rs","content":""}}' | bash hooks/post-write-guard.sh)
assert_not_contains "$result" "VIBEGUARD" "空 content 放行"

# 空 file_path 放行
result=$(echo '{"tool_input":{"file_path":"","content":"fn main() {}"}}' | bash hooks/post-write-guard.sh)
assert_not_contains "$result" "VIBEGUARD" "空 file_path 放行"

# 同名源码文件应告警
tmp_repo_same_name="$(mktemp -d)"
git -C "$tmp_repo_same_name" init -q
mkdir -p "$tmp_repo_same_name/src/existing" "$tmp_repo_same_name/src/new"
cat >"$tmp_repo_same_name/src/existing/service.py" <<'EOF'
def existing_service():
    return True
EOF
json_payload=$(printf '{"tool_input":{"file_path":"%s","content":"def create_service():\\n    return True"}}' "$tmp_repo_same_name/src/new/service.py")
result=$(echo "$json_payload" | bash hooks/post-write-guard.sh)
assert_contains "$result" "L1-重复文件" "检测同名源码文件重复"
rm -rf "$tmp_repo_same_name"

# 重复定义应告警
tmp_repo_dup_def="$(mktemp -d)"
git -C "$tmp_repo_dup_def" init -q
mkdir -p "$tmp_repo_dup_def/src/existing" "$tmp_repo_dup_def/src/new"
cat >"$tmp_repo_dup_def/src/existing/handler.py" <<'EOF'
def processOrder():
    return 1
EOF
json_payload=$(printf '{"tool_input":{"file_path":"%s","content":"def processOrder():\\n    return 2"}}' "$tmp_repo_dup_def/src/new/new_handler.py")
result=$(echo "$json_payload" | bash hooks/post-write-guard.sh)
assert_contains "$result" "L1-重复定义" "检测重复定义"
rm -rf "$tmp_repo_dup_def"

# 超过扫描预算时应降级提示
tmp_repo_budget="$(mktemp -d)"
git -C "$tmp_repo_budget" init -q
mkdir -p "$tmp_repo_budget/src"
cat >"$tmp_repo_budget/src/existing.py" <<'EOF'
def keepExisting():
    return "ok"
EOF
json_payload=$(printf '{"tool_input":{"file_path":"%s","content":"def keepExisting():\\n    return \\"new\\""}}' "$tmp_repo_budget/src/new_file.py")
result=$(echo "$json_payload" | VG_SCAN_MAX_FILES=0 bash hooks/post-write-guard.sh)
assert_contains "$result" "L1-扫描降级" "超过文件预算时降级"
rm -rf "$tmp_repo_budget"

# 新源码文件有同名文件时应 warn（使用当前仓库中已有的 log.sh）
result=$(echo '{"tool_input":{"file_path":"'${REPO_DIR}'/hooks/subdir/log.sh","content":"#!/bin/bash\necho test"}}' | bash hooks/post-write-guard.sh)
# log.sh 已存在于 hooks/ 目录，如果检测到应有 VIBEGUARD 输出
# 但 .sh 不在 VG_SOURCE_EXTS 中，所以放行
assert_not_contains "$result" "VIBEGUARD" "非源码扩展名 (.sh) 放行"

# =========================================================
header "post-build-check.sh — 构建检查"
# =========================================================

# 非构建语言文件（.py）应放行
result=$(echo '{"tool_input":{"file_path":"src/main.py"}}' | bash hooks/post-build-check.sh)
assert_not_contains "$result" "VIBEGUARD" "非构建语言 (.py) 放行"

# .md 文件应放行
result=$(echo '{"tool_input":{"file_path":"README.md"}}' | bash hooks/post-build-check.sh)
assert_not_contains "$result" "VIBEGUARD" "非源码文件 (.md) 放行"

# 空 file_path 放行
result=$(echo '{"tool_input":{"file_path":""}}' | bash hooks/post-build-check.sh)
assert_not_contains "$result" "VIBEGUARD" "空 file_path 放行"

# .json 文件应放行
result=$(echo '{"tool_input":{"file_path":"package.json"}}' | bash hooks/post-build-check.sh)
assert_not_contains "$result" "VIBEGUARD" "非构建语言 (.json) 放行"

# =========================================================
# 总结
# =========================================================

echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
