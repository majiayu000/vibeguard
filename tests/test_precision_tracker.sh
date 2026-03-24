#!/usr/bin/env bash
# VibeGuard Precision Tracker 测试套件
#
# 用法：bash tests/test_precision_tracker.sh
# 从仓库根目录运行

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TRACKER="${REPO_DIR}/scripts/precision-tracker.py"

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
    echo "  output: $(echo "$output" | head -5)"
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

assert_cmd_ok() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (exit code non-zero)"
    FAIL=$((FAIL + 1))
  fi
}

# ── 独立临时目录，不污染真实数据 ────────────────────────────────────────────
TMPDIR_TEST=$(mktemp -d)
TRIAGE_FILE="${TMPDIR_TEST}/triage.jsonl"
SCORECARD_FILE="${TMPDIR_TEST}/rule-scorecard.json"
cleanup() { rm -rf "$TMPDIR_TEST"; }
trap cleanup EXIT

# Seed scorecard with a known initial state
python3 -c "
import json
scorecard = {
  'rules': {
    'RS-03': {'stage': 'experimental', 'precision': None, 'samples': 0,
              'tp': 0, 'fp': 0, 'acceptable': 0, 'last_fp_ts': None,
              'stage_entered_ts': '2026-01-01T00:00:00Z', 'notes': 'unwrap'},
    'RS-99': {'stage': 'warn', 'precision': None, 'samples': 0,
              'tp': 0, 'fp': 0, 'acceptable': 0, 'last_fp_ts': None,
              'stage_entered_ts': '2026-01-01T00:00:00Z', 'notes': 'test rule'}
  }
}
print(json.dumps(scorecard, indent=2))
" > "$SCORECARD_FILE"

# Empty triage file
touch "$TRIAGE_FILE"

header "precision-tracker.py — 语法检查"
assert_cmd_ok "Python 语法正确" python3 -m py_compile "$TRACKER"

header "精度报告输出"
report=$(python3 "$TRACKER" \
  --triage-file "$TRIAGE_FILE" \
  --scorecard-file "$SCORECARD_FILE")
assert_contains "$report" "VibeGuard Rule Precision Scorecard" "报告标题存在"
assert_contains "$report" "RS-03" "报告包含 RS-03"
assert_contains "$report" "RS-99" "报告包含 RS-99"
assert_contains "$report" "experimental" "报告显示 experimental 阶段"
assert_contains "$report" "warn" "报告显示 warn 阶段"
assert_contains "$report" "N/A" "无样本时精度显示 N/A"

header "--rule 过滤"
report_single=$(python3 "$TRACKER" \
  --triage-file "$TRIAGE_FILE" \
  --scorecard-file "$SCORECARD_FILE" \
  --rule RS-03)
assert_contains "$report_single" "RS-03" "--rule RS-03 包含 RS-03"
assert_not_contains "$report_single" "RS-99" "--rule RS-03 排除 RS-99"

header "--record 记录 triage 反馈"
python3 "$TRACKER" \
  --triage-file "$TRIAGE_FILE" \
  --scorecard-file "$SCORECARD_FILE" \
  --record tp RS-03 >/dev/null
assert_contains "$(cat "$TRIAGE_FILE")" '"verdict": "tp"' "--record tp 写入 triage.jsonl"
assert_contains "$(cat "$TRIAGE_FILE")" '"rule": "RS-03"' "--record tp 写入正确 rule"

python3 "$TRACKER" \
  --triage-file "$TRIAGE_FILE" \
  --scorecard-file "$SCORECARD_FILE" \
  --record fp RS-03 --context "false alarm in tests" >/dev/null
assert_contains "$(cat "$TRIAGE_FILE")" '"verdict": "fp"' "--record fp 写入 triage.jsonl"
assert_contains "$(cat "$TRIAGE_FILE")" "false alarm in tests" "--context 写入 triage.jsonl"

header "精度计算正确性"
# 1 tp + 1 fp → precision = 50%
updated_scorecard=$(cat "$SCORECARD_FILE")
echo "$updated_scorecard" | python3 -c "
import json, sys
sc = json.load(sys.stdin)
rs03 = sc['rules']['RS-03']
assert rs03['tp'] == 1, f'tp should be 1, got {rs03[\"tp\"]}'
assert rs03['fp'] == 1, f'fp should be 1, got {rs03[\"fp\"]}'
assert rs03['samples'] == 2, f'samples should be 2, got {rs03[\"samples\"]}'
assert abs(rs03['precision'] - 0.5) < 0.001, f'precision should be ~0.5, got {rs03[\"precision\"]}'
print('OK')
" > /dev/null && {
  PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1))
  green "1 TP + 1 FP 时精度为 50%"
} || {
  FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1))
  red "精度计算错误（期望 50%）"
}

header "生命周期晋升 — experimental → warn"
# 添加 20 个 tp（precision ≥ 70% AND samples ≥ 20）到一个新的测试规则
TRIAGE2="${TMPDIR_TEST}/triage2.jsonl"
SCORECARD2="${TMPDIR_TEST}/scorecard2.json"
python3 -c "
import json
scorecard = {
  'rules': {
    'TEST-01': {
      'stage': 'experimental', 'precision': None, 'samples': 0,
      'tp': 0, 'fp': 0, 'acceptable': 0, 'last_fp_ts': None,
      'stage_entered_ts': '2026-01-01T00:00:00Z', 'notes': 'test'
    }
  }
}
print(json.dumps(scorecard, indent=2))
" > "$SCORECARD2"
# 21 tp, 1 fp → precision = 21/22 ≈ 95% ≥ 70%; samples = 22 ≥ 20
python3 -c "
import json
lines = []
for _ in range(21):
    lines.append(json.dumps({'ts': '2026-03-01T00:00:00Z', 'rule': 'TEST-01', 'verdict': 'tp'}))
lines.append(json.dumps({'ts': '2026-03-02T00:00:00Z', 'rule': 'TEST-01', 'verdict': 'fp'}))
print('\n'.join(lines))
" > "$TRIAGE2"

transition_out=$(python3 "$TRACKER" \
  --triage-file "$TRIAGE2" \
  --scorecard-file "$SCORECARD2" \
  --update-scorecard 2>&1)
assert_contains "$transition_out" "TEST-01" "晋升输出包含规则名"
assert_contains "$transition_out" "experimental → warn" "experimental 晋升到 warn"

new_stage=$(python3 -c "
import json
sc = json.load(open('$SCORECARD2'))
print(sc['rules']['TEST-01']['stage'])
")
TOTAL=$((TOTAL + 1))
if [[ "$new_stage" == "warn" ]]; then
  green "晋升后 stage 为 warn"
  PASS=$((PASS + 1))
else
  red "晋升后 stage 应为 warn，实际: $new_stage"
  FAIL=$((FAIL + 1))
fi

header "生命周期降级 — warn → demoted（精度 < 80%）"
TRIAGE3="${TMPDIR_TEST}/triage3.jsonl"
SCORECARD3="${TMPDIR_TEST}/scorecard3.json"
python3 -c "
import json
scorecard = {
  'rules': {
    'TEST-02': {
      'stage': 'warn', 'precision': None, 'samples': 0,
      'tp': 0, 'fp': 0, 'acceptable': 0, 'last_fp_ts': None,
      'stage_entered_ts': '2026-01-01T00:00:00Z', 'notes': 'test'
    }
  }
}
print(json.dumps(scorecard, indent=2))
" > "$SCORECARD3"
# 10 tp, 15 fp → precision = 10/25 = 40% < 80%; samples = 25 ≥ 20
python3 -c "
import json
lines = []
for _ in range(10):
    lines.append(json.dumps({'ts': '2026-03-01T00:00:00Z', 'rule': 'TEST-02', 'verdict': 'tp'}))
for _ in range(15):
    lines.append(json.dumps({'ts': '2026-03-02T00:00:00Z', 'rule': 'TEST-02', 'verdict': 'fp'}))
print('\n'.join(lines))
" > "$TRIAGE3"

transition_out3=$(python3 "$TRACKER" \
  --triage-file "$TRIAGE3" \
  --scorecard-file "$SCORECARD3" \
  --update-scorecard 2>&1)
assert_contains "$transition_out3" "warn → demoted" "精度不足时降级到 demoted"

demoted_stage=$(python3 -c "
import json
sc = json.load(open('$SCORECARD3'))
print(sc['rules']['TEST-02']['stage'])
")
TOTAL=$((TOTAL + 1))
if [[ "$demoted_stage" == "demoted" ]]; then
  green "降级后 stage 为 demoted"
  PASS=$((PASS + 1))
else
  red "降级后 stage 应为 demoted，实际: $demoted_stage"
  FAIL=$((FAIL + 1))
fi

# =========================================================
echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
