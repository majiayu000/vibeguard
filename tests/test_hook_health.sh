#!/usr/bin/env bash
# VibeGuard hook-health 回归测试
#
# 用法：bash tests/test_hook_health.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${REPO_DIR}/scripts/hook-health.sh"

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

assert_exit_nonzero() {
  local code="$1" desc="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$code" -ne 0 ]]; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (expected non-zero exit)"
    FAIL=$((FAIL + 1))
  fi
}

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

header "无日志文件"
no_log_out="$(VIBEGUARD_LOG_DIR="${TMP_DIR}/missing" bash "${SCRIPT}" 2>&1 || true)"
assert_contains "${no_log_out}" "没有日志数据" "缺失日志时给出提示"

header "最近 24 小时健康快照"
mkdir -p "${TMP_DIR}/log"
python3 - "${TMP_DIR}/log/events.jsonl" <<'PY'
import json
import sys
from datetime import datetime, timedelta, timezone

path = sys.argv[1]
now = datetime.now(timezone.utc)

events = [
    {
        "ts": (now - timedelta(hours=1)).isoformat().replace("+00:00", "Z"),
        "session": "s1",
        "hook": "pre-bash-guard",
        "tool": "Bash",
        "decision": "pass",
        "reason": "",
        "detail": "cargo check",
    },
    {
        "ts": (now - timedelta(hours=2)).isoformat().replace("+00:00", "Z"),
        "session": "s2",
        "hook": "stop-guard",
        "tool": "Stop",
        "decision": "gate",
        "reason": "uncommitted source changes",
        "detail": "src/main.rs",
    },
    {
        "ts": (now - timedelta(hours=3)).isoformat().replace("+00:00", "Z"),
        "session": "s3",
        "hook": "pre-bash-guard",
        "tool": "Bash",
        "decision": "warn",
        "reason": "非标准 .md 文件",
        "detail": "echo hi > notes.md",
    },
    {
        "ts": (now - timedelta(minutes=30)).isoformat().replace("+00:00", "Z"),
        "session": "s4",
        "hook": "post-edit-guard",
        "tool": "Edit",
        "decision": "correction",
        "reason": "replace any with concrete type",
        "detail": "src/lib.rs",
    },
    {
        "ts": (now - timedelta(hours=30)).isoformat().replace("+00:00", "Z"),
        "session": "old",
        "hook": "pre-commit-guard",
        "tool": "git-commit",
        "decision": "block",
        "reason": "old event out of window",
        "detail": "",
    },
]

with open(path, "w", encoding="utf-8") as f:
    for event in events:
        f.write(json.dumps(event, ensure_ascii=False) + "\n")
PY

health_out="$(VIBEGUARD_LOG_DIR="${TMP_DIR}/log" bash "${SCRIPT}" 24 2>&1)"
assert_contains "${health_out}" "VibeGuard Hook Health (最近 24 小时)" "标题正确"
assert_contains "${health_out}" "总触发: 4" "过滤出 24 小时内事件"
assert_contains "${health_out}" "通过(pass): 1" "pass 统计正确"
assert_contains "${health_out}" "风险(非 pass): 3" "风险统计正确"
assert_contains "${health_out}" "风险率: 75.0%" "风险率计算正确"
assert_contains "${health_out}" "风险 Hook Top 5:" "输出风险 hook 排名"
assert_contains "${health_out}" "最近风险事件 Top 10:" "输出最近风险事件"
assert_contains "${health_out}" "stop-guard | gate" "风险事件包含 gate"

header "非法参数"
set +e
bad_arg_out="$(VIBEGUARD_LOG_DIR="${TMP_DIR}/log" bash "${SCRIPT}" abc 2>&1)"
bad_arg_code=$?
set -e
assert_exit_nonzero "${bad_arg_code}" "非法参数返回非零"
assert_contains "${bad_arg_out}" "参数必须是正整数小时数" "非法参数错误信息"

echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
