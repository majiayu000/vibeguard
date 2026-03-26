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

assert_exit_nonzero() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    red "$desc (unexpected success)"
    FAIL=$((FAIL + 1))
  else
    green "$desc"
    PASS=$((PASS + 1))
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

# git push --force は pre-bash-guard では拦截しない (hooks/git/pre-push が担当)
result=$(echo '{"tool_input":{"command":"git push --force origin main"}}' | bash hooks/pre-bash-guard.sh)
assert_not_contains "$result" '"decision": "block"' "git push --force 不由 pre-bash-guard 拦截（已移至 pre-push hook）"

# git push --force-with-lease 应放行
result=$(echo '{"tool_input":{"command":"git push --force-with-lease origin main"}}' | bash hooks/pre-bash-guard.sh)
assert_not_contains "$result" '"decision": "block"' "放行 git push --force-with-lease"

# git reset --hard 应放行（用户需要在 rebase 冲突等场景中使用）
result=$(echo '{"tool_input":{"command":"git reset --hard HEAD~1"}}' | bash hooks/pre-bash-guard.sh)
assert_not_contains "$result" '"decision": "block"' "放行 git reset --hard（pre-bash-guard 不拦截）"

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
header "hooks/git/pre-push — force push 拦截"
# =========================================================

PREPUSH_SCRIPT="${REPO_DIR}/hooks/git/pre-push"

# helper: run pre-push with fake stdin refs
run_prepush() {
  echo "$1" | bash "$PREPUSH_SCRIPT"
}

ZEROS="0000000000000000000000000000000000000000"

# 新建分支（remote_sha 全零）应放行
if run_prepush "refs/heads/feature abc123 refs/heads/feature $ZEROS" 2>/dev/null; then
  green "新建远端分支放行（remote_sha=0000）"
  PASS=$((PASS + 1))
else
  red "新建远端分支放行（remote_sha=0000）"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))

# 删除远端分支（local_sha 全零）应被拦截
# 格式: <local-ref> <local-sha> <remote-ref> <remote-sha>
# 删除时 local-sha 为全零，local-ref 用 (delete) 标记
if ! run_prepush "refs/heads/feature $ZEROS refs/heads/feature abc123" 2>/dev/null; then
  green "拦截删除远端分支（local_sha=0000）"
  PASS=$((PASS + 1))
else
  red "拦截删除远端分支（local_sha=0000）"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))

# 临时 git 仓库：验证非快进推送被拦截
# stdin 格式: <local-ref> <local-sha> <remote-ref> <remote-sha>
tmp_repo_push="$(mktemp -d)"
git -C "$tmp_repo_push" init -q
git -C "$tmp_repo_push" config user.email "test@example.com"
git -C "$tmp_repo_push" config user.name "Test User"
git -C "$tmp_repo_push" commit --allow-empty -m "base"
BASE_SHA=$(git -C "$tmp_repo_push" rev-parse HEAD)
git -C "$tmp_repo_push" commit --allow-empty -m "local"
LOCAL_SHA=$(git -C "$tmp_repo_push" rev-parse HEAD)
git -C "$tmp_repo_push" reset --hard "$BASE_SHA" -q
git -C "$tmp_repo_push" commit --allow-empty -m "diverged"
REMOTE_SHA=$(git -C "$tmp_repo_push" rev-parse HEAD)

# LOCAL_SHA 和 REMOTE_SHA 从 BASE_SHA 分叉 → 非快进 → 拦截
if ! (cd "$tmp_repo_push" && echo "refs/heads/main $LOCAL_SHA refs/heads/main $REMOTE_SHA" | bash "$PREPUSH_SCRIPT") 2>/dev/null; then
  green "拦截非快进推送（force push）"
  PASS=$((PASS + 1))
else
  red "拦截非快进推送（force push）"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))

# 正常快进推送应放行：FF_SHA 是 REMOTE_SHA 的直接后继
git -C "$tmp_repo_push" checkout -q "$REMOTE_SHA"
git -C "$tmp_repo_push" commit --allow-empty -m "fast-forward"
FF_SHA=$(git -C "$tmp_repo_push" rev-parse HEAD)

if (cd "$tmp_repo_push" && echo "refs/heads/main $FF_SHA refs/heads/main $REMOTE_SHA" | bash "$PREPUSH_SCRIPT") 2>/dev/null; then
  green "快进推送放行"
  PASS=$((PASS + 1))
else
  red "快进推送放行"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))

rm -rf "$tmp_repo_push"

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

# W-12: 测试基础设施文件应被拦截（conftest.py）
result=$(echo '{"tool_input":{"file_path":"/any/path/conftest.py","old_string":""}}' | bash hooks/pre-edit-guard.sh)
assert_contains "$result" '"decision": "block"' "W-12: 拦截编辑 conftest.py"
assert_contains "$result" "W-12" "W-12: 错误消息包含规则编号"

# W-12: jest.config.ts 应被拦截
result=$(echo '{"tool_input":{"file_path":"/project/jest.config.ts","old_string":""}}' | bash hooks/pre-edit-guard.sh)
assert_contains "$result" '"decision": "block"' "W-12: 拦截编辑 jest.config.ts"

# W-12: jest.config.js 应被拦截
result=$(echo '{"tool_input":{"file_path":"/project/jest.config.js","old_string":""}}' | bash hooks/pre-edit-guard.sh)
assert_contains "$result" '"decision": "block"' "W-12: 拦截编辑 jest.config.js"

# W-12: pytest.ini 应被拦截
result=$(echo '{"tool_input":{"file_path":"/project/pytest.ini","old_string":""}}' | bash hooks/pre-edit-guard.sh)
assert_contains "$result" '"decision": "block"' "W-12: 拦截编辑 pytest.ini"

# W-12: .coveragerc 应被拦截
result=$(echo '{"tool_input":{"file_path":"/project/.coveragerc","old_string":""}}' | bash hooks/pre-edit-guard.sh)
assert_contains "$result" '"decision": "block"' "W-12: 拦截编辑 .coveragerc"

# W-12: 普通源码文件不应被测试基础设施规则拦截
result=$(echo '{"tool_input":{"file_path":"hooks/log.sh","old_string":""}}' | bash hooks/pre-edit-guard.sh)
assert_not_contains "$result" "W-12" "W-12: 普通文件不触发测试基础设施保护"

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

# W-12: 写入 conftest.py 应被拦截（新文件，正确 basename）
result=$(echo '{"tool_input":{"file_path":"/tmp/vg_nonexist_dir/conftest.py"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" '"decision": "block"' "W-12: 拦截写入新 conftest.py"
assert_contains "$result" "W-12" "W-12: write guard 错误消息包含规则编号"

# W-12: 写入已有 conftest.py 路径（含目录）也应被拦截
result=$(echo '{"tool_input":{"file_path":"/project/tests/conftest.py"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" '"decision": "block"' "W-12: 拦截写入已有 conftest.py 路径（含目录）"

# W-12: jest.config.ts 写入应被拦截
result=$(echo '{"tool_input":{"file_path":"/project/jest.config.ts"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" '"decision": "block"' "W-12: 拦截写入 jest.config.ts"

# W-12: vitest.config.ts 写入应被拦截
result=$(echo '{"tool_input":{"file_path":"/project/vitest.config.ts"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" '"decision": "block"' "W-12: 拦截写入 vitest.config.ts"

# W-12: babel.config.js 写入应被拦截
result=$(echo '{"tool_input":{"file_path":"/project/babel.config.js"}}' | bash hooks/pre-write-guard.sh)
assert_contains "$result" '"decision": "block"' "W-12: 拦截写入 babel.config.js"

# W-12: 普通 config.json 不应被测试基础设施规则拦截
result=$(echo '{"tool_input":{"file_path":"/tmp/vg_nonexist_myconfig.json"}}' | bash hooks/pre-write-guard.sh)
assert_not_contains "$result" "W-12" "W-12: 普通 config.json 不触发测试基础设施保护"

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

# TS 文件新增 console.log 应警告（使用绝对路径避免误判 CLI 项目）
result=$(echo '{"tool_input":{"file_path":"/tmp/vg_test_app.ts","new_string":"console.log(data);"}}' | bash hooks/post-edit-guard.sh)
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

# JavaScript 语法错误应警告
tmp_js_bad="$(mktemp -d)"
cat >"$tmp_js_bad/bad.js" <<'EOF'
const value = ;
EOF
result=$(echo "{\"tool_input\":{\"file_path\":\"$tmp_js_bad/bad.js\"}}" | bash hooks/post-build-check.sh)
assert_contains "$result" "VIBEGUARD" "JavaScript 语法错误触发构建检查警告"
rm -rf "$tmp_js_bad"

# JavaScript 语法正确应放行
tmp_js_ok="$(mktemp -d)"
cat >"$tmp_js_ok/good.js" <<'EOF'
const value = 1;
EOF
result=$(echo "{\"tool_input\":{\"file_path\":\"$tmp_js_ok/good.js\"}}" | bash hooks/post-build-check.sh)
assert_not_contains "$result" "VIBEGUARD" "JavaScript 语法正确放行"
rm -rf "$tmp_js_ok"

# =========================================================
header "pre-commit-guard.sh — timeout 回退"
# =========================================================

tmp_repo_precommit="$(mktemp -d)"
git -C "$tmp_repo_precommit" init -q
mkdir -p "$tmp_repo_precommit/bin" "$tmp_repo_precommit/src"

cat >"$tmp_repo_precommit/Cargo.toml" <<'EOF'
[package]
name = "vg-precommit-test"
version = "0.1.0"
edition = "2021"
EOF

cat >"$tmp_repo_precommit/src/lib.rs" <<'EOF'
pub fn add(a: i32, b: i32) -> i32 {
    a + b
}
EOF

cat >"$tmp_repo_precommit/bin/timeout" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF

cat >"$tmp_repo_precommit/bin/gtimeout" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF

cat >"$tmp_repo_precommit/bin/cargo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "check" || "${1:-}" == "fmt" ]]; then
  exit 0
fi
exit 1
EOF

chmod +x "$tmp_repo_precommit/bin/timeout" "$tmp_repo_precommit/bin/gtimeout" "$tmp_repo_precommit/bin/cargo"
git -C "$tmp_repo_precommit" add Cargo.toml src/lib.rs

assert_exit_zero "timeout/gtimeout 不可用时回退执行，不误报构建失败" bash -c "cd '$tmp_repo_precommit' && PATH='$tmp_repo_precommit/bin:/usr/bin:/bin:$PATH' bash '$REPO_DIR/hooks/pre-commit-guard.sh'"
rm -rf "$tmp_repo_precommit"

# Go 项目应运行 Go 守卫（新增 _ = 丢弃 error 时阻止提交）
tmp_repo_precommit_go="$(mktemp -d)"
git -C "$tmp_repo_precommit_go" init -q
mkdir -p "$tmp_repo_precommit_go/bin" "$tmp_repo_precommit_go/cmd"

cat >"$tmp_repo_precommit_go/go.mod" <<'EOF'
module vg-precommit-go-test

go 1.22
EOF

cat >"$tmp_repo_precommit_go/cmd/main.go" <<'EOF'
package main

func doThing() error { return nil }

func main() {
	_ = doThing()
}
EOF

cat >"$tmp_repo_precommit_go/bin/go" <<'EOF'
#!/usr/bin/env bash
# pre-commit 中 go build 只作为构建门禁，这里返回成功避免依赖本机 Go
exit 0
EOF

chmod +x "$tmp_repo_precommit_go/bin/go"
git -C "$tmp_repo_precommit_go" add go.mod cmd/main.go

assert_exit_nonzero "Go 守卫可阻止 _= 丢弃 error 的提交" bash -c "cd '$tmp_repo_precommit_go' && PATH='$tmp_repo_precommit_go/bin:/usr/bin:/bin:$PATH' bash '$REPO_DIR/hooks/pre-commit-guard.sh'"
rm -rf "$tmp_repo_precommit_go"

# =========================================================
header "log.sh — session_id: start-time anchor + 30-min TTL"
# =========================================================

# The session block in log.sh uses three conditions to decide whether to reuse a session file:
# 1. File exists
# 2. Within 30-minute inactivity window (mtime < 30 min ago)
# 3. Stored start time (line 1) matches current process start time
#
# The start time is captured with TZ=UTC so it is timezone-independent (same PID always
# produces the same string regardless of user TZ, DST transitions, or inherited TZ differences).
#
# The session file is written atomically (mktemp + mv) so concurrent hook invocations
# sharing the same Claude parent PID never observe a partially-written file.
#
# These tests verify:
# A. Start time mismatch (PID recycling) triggers a fresh session.
# B. TTL expiry (>30 min idle) triggers a fresh session even with matching start time.
# C. Atomic write: session file always has exactly 2 complete lines after writing.

_test_log_dir=$(mktemp -d)
_stale_session_id="deadbeef"

# Shared helper: atomic write matching the production implementation in log.sh.
# Usage: _vg_atomic_write <file> <line1> <line2>
_vg_atomic_write() {
  local dest="$1" line1="$2" line2="$3"
  local tmp
  tmp=$(mktemp "${_test_log_dir}/.session_tmp_XXXXXX" 2>/dev/null) || tmp="${dest}.tmp.$$"
  printf '%s\n%s\n' "$line1" "$line2" > "$tmp" \
    && mv "$tmp" "$dest" 2>/dev/null \
    || { rm -f "$tmp" 2>/dev/null; printf '%s\n%s\n' "$line1" "$line2" > "$dest"; }
}

# --- Test A: start time mismatch (PID recycling detection) ---
# File format: line 1 = start time anchor (UTC), line 2 = session_id.
# Simulate a recycled PID: the session file records a start time that does NOT match
# the current process start time, so the start time check should fail → fresh session.
# UTC-formatted lstart strings are used (as produced by TZ=UTC ps -o lstart=).
_fake_pid="99998"
_vg_sf_a="${_test_log_dir}/.session_pid_${_fake_pid}"
_vg_atomic_write "$_vg_sf_a" "Thu Jan  1 00:00:00 1970" "$_stale_session_id"

_result_a=$(
  _vg_sf="$_vg_sf_a"
  _vg_proc_start="Mon Mar 24 02:00:00 2026"  # UTC; different from stored anchor
  _vg_stored_start=$(head -1 "$_vg_sf" 2>/dev/null)
  _vg_reuse=false
  # TTL check passes (file is fresh); start time check must fail
  if [[ -f "$_vg_sf" ]] && [[ -n "$(find "$_vg_sf" -mmin -30 2>/dev/null)" ]]; then
    if [[ "$_vg_stored_start" == "$_vg_proc_start" ]]; then
      _vg_reuse=true
    fi
  fi
  if [[ "$_vg_reuse" == "true" ]]; then
    echo "reused:$(tail -1 "$_vg_sf")"
  else
    new_id=$(printf '%04x%04x' $RANDOM $RANDOM)
    _vg_atomic_write "$_vg_sf" "$_vg_proc_start" "$new_id"
    echo "fresh:$new_id"
  fi
)
assert_not_contains "$_result_a" "reused" "start time 不匹配（PID 回收）时不应复用旧 session_id"
assert_contains "$_result_a" "fresh:" "start time 不匹配时应生成新 session_id"

# Verify file was overwritten with new two-line format (line 2 = new session_id, not old one).
_file_line2=$(tail -1 "$_vg_sf_a" 2>/dev/null)
TOTAL=$((TOTAL + 1))
if [[ "$_file_line2" != "$_stale_session_id" ]]; then
  green "PID 回收场景：session 文件已用新 session_id 覆盖"
  PASS=$((PASS + 1))
else
  red "PID 回收场景：session 文件未更新，仍为旧 session_id"
  FAIL=$((FAIL + 1))
fi

# --- Test B: 30-min TTL expiry (long-lived process, new task) ---
# When the session file's mtime is older than 30 minutes, a fresh session must be created
# even if the start time matches — this prevents cross-task pollution in long-lived processes.
_fake_pid2="99999"
_vg_sf_b="${_test_log_dir}/.session_pid_${_fake_pid2}"
_current_start="Mon Mar 24 02:00:00 2026"  # UTC
_vg_atomic_write "$_vg_sf_b" "$_current_start" "$_stale_session_id"
# Make the file appear older than 30 minutes.
touch -t "$(date -v -40M '+%Y%m%d%H%M' 2>/dev/null || date --date='40 minutes ago' '+%Y%m%d%H%M' 2>/dev/null || echo '200001010000')" "$_vg_sf_b" 2>/dev/null || \
  touch -d "40 minutes ago" "$_vg_sf_b" 2>/dev/null || true

_result_b=$(
  _vg_sf="$_vg_sf_b"
  _vg_proc_start="$_current_start"  # start time would match, but TTL has expired
  _vg_stored_start=$(head -1 "$_vg_sf" 2>/dev/null)
  _vg_reuse=false
  if [[ -f "$_vg_sf" ]] && [[ -n "$(find "$_vg_sf" -mmin -30 2>/dev/null)" ]]; then
    if [[ "$_vg_stored_start" == "$_vg_proc_start" ]]; then
      _vg_reuse=true
    fi
  fi
  if [[ "$_vg_reuse" == "true" ]]; then
    echo "reused:$(tail -1 "$_vg_sf")"
  else
    new_id=$(printf '%04x%04x' $RANDOM $RANDOM)
    _vg_atomic_write "$_vg_sf" "$_vg_proc_start" "$new_id"
    echo "fresh:$new_id"
  fi
)
assert_not_contains "$_result_b" "reused" "TTL 过期（>30min）时不应复用旧 session_id"
assert_contains "$_result_b" "fresh:" "TTL 过期时应生成新 session_id（防止长进程跨任务污染）"

# --- Test C: atomic write — session file must always have exactly 2 complete lines ---
# This guards against the race where a concurrent reader sees a truncated file (open O_TRUNC
# before the second line is written).  With mktemp+mv the file is either absent or complete.
_vg_sf_c="${_test_log_dir}/.session_pid_atomic_test"
_atomic_start="Mon Mar 24 02:00:00 2026"
_atomic_id=$(printf '%04x%04x' $RANDOM $RANDOM)
_vg_atomic_write "$_vg_sf_c" "$_atomic_start" "$_atomic_id"
_line_count=$(wc -l < "$_vg_sf_c" 2>/dev/null | tr -d ' ')
_line1=$(head -1 "$_vg_sf_c" 2>/dev/null)
_line2=$(tail -1 "$_vg_sf_c" 2>/dev/null)
TOTAL=$((TOTAL + 1))
if [[ "$_line_count" == "2" && "$_line1" == "$_atomic_start" && "$_line2" == "$_atomic_id" ]]; then
  green "原子写入：session 文件恰好有 2 行且内容完整"
  PASS=$((PASS + 1))
else
  red "原子写入：session 文件行数或内容不符（lines=$_line_count line1='$_line1' line2='$_line2'）"
  FAIL=$((FAIL + 1))
fi

rm -rf "$_test_log_dir"
header "post-edit-guard — vibeguard-disable-next-line 抑制"
# =========================================================

# RS-03 不带抑制注释 → 应产生警告
result=$(python3 -c "
import json
content = 'let x = foo.unwrap();'
print(json.dumps({'tool_input': {'file_path': 'src/main.rs', 'new_string': content}}))
" | VIBEGUARD_LOG_DIR="$VIBEGUARD_LOG_DIR" bash hooks/post-edit-guard.sh 2>/dev/null || true)
assert_contains "$result" "RS-03" "RS-03: unwrap() 无抑制注释时产生警告"

# RS-03 带抑制注释 → 应抑制该行警告
result=$(python3 -c "
import json
content = '// vibeguard-disable-next-line RS-03 -- signal handler\nlet x = foo.unwrap();'
print(json.dumps({'tool_input': {'file_path': 'src/main.rs', 'new_string': content}}))
" | VIBEGUARD_LOG_DIR="$VIBEGUARD_LOG_DIR" bash hooks/post-edit-guard.sh 2>/dev/null || true)
assert_not_contains "$result" "RS-03" "RS-03: vibeguard-disable-next-line 抑制 unwrap() 警告"

# RS-10 带抑制注释 → 应抑制
result=$(python3 -c "
import json
content = '// vibeguard-disable-next-line RS-10 -- intentional drop\nlet _ = sender.send(msg);'
print(json.dumps({'tool_input': {'file_path': 'src/main.rs', 'new_string': content}}))
" | VIBEGUARD_LOG_DIR="$VIBEGUARD_LOG_DIR" bash hooks/post-edit-guard.sh 2>/dev/null || true)
assert_not_contains "$result" "RS-10" "RS-10: vibeguard-disable-next-line 抑制 let _ = 警告"

# DEBUG 带抑制注释 → 应抑制 console 警告
result=$(python3 -c "
import json
content = '// vibeguard-disable-next-line DEBUG -- intentional stderr\nconsole.log(\"debug info\");'
print(json.dumps({'tool_input': {'file_path': 'src/service.ts', 'new_string': content}}))
" | VIBEGUARD_LOG_DIR="$VIBEGUARD_LOG_DIR" bash hooks/post-edit-guard.sh 2>/dev/null || true)
assert_not_contains "$result" "DEBUG" "DEBUG: vibeguard-disable-next-line 抑制 console.log 警告"

# U-11 带抑制注释 → 应抑制硬编码路径警告
result=$(python3 -c "
import json
content = '// vibeguard-disable-next-line U-11 -- test fixture\nconst DB = \"test.db\";'
print(json.dumps({'tool_input': {'file_path': 'src/config.ts', 'new_string': content}}))
" | VIBEGUARD_LOG_DIR="$VIBEGUARD_LOG_DIR" bash hooks/post-edit-guard.sh 2>/dev/null || true)
assert_not_contains "$result" "U-11" "U-11: vibeguard-disable-next-line 抑制硬编码路径警告"

# 抑制注释只作用于紧接下一行（第三行的 unwrap 仍应报警）
result=$(python3 -c "
import json
content = '// vibeguard-disable-next-line RS-03 -- ok\nlet a = safe.unwrap();\nlet b = other.unwrap();'
print(json.dumps({'tool_input': {'file_path': 'src/main.rs', 'new_string': content}}))
" | VIBEGUARD_LOG_DIR="$VIBEGUARD_LOG_DIR" bash hooks/post-edit-guard.sh 2>/dev/null || true)
assert_contains "$result" "RS-03" "RS-03: 抑制注释仅作用于紧接的下一行，第三行 unwrap 仍报警"

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
