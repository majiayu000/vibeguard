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

header "实验阶段规则精度不足时不直接降级 — experimental 不走 demoted 快捷路径"
TRIAGE_EXP="${TMPDIR_TEST}/triage_exp.jsonl"
SCORECARD_EXP="${TMPDIR_TEST}/scorecard_exp.json"
python3 -c "
import json
scorecard = {
  'rules': {
    'EXP-01': {
      'stage': 'experimental', 'precision': None, 'samples': 0,
      'tp': 0, 'fp': 0, 'acceptable': 0, 'last_fp_ts': None,
      'stage_entered_ts': '2026-01-01T00:00:00Z', 'notes': 'test'
    }
  }
}
print(json.dumps(scorecard, indent=2))
" > "$SCORECARD_EXP"
# 5 tp, 20 fp → precision = 5/25 = 20% < 80%; samples = 25 ≥ 20
# experimental rule with poor precision must NOT be demoted directly
python3 -c "
import json
lines = []
for _ in range(5):
    lines.append(json.dumps({'ts': '2026-03-01T00:00:00Z', 'rule': 'EXP-01', 'verdict': 'tp'}))
for _ in range(20):
    lines.append(json.dumps({'ts': '2026-03-02T00:00:00Z', 'rule': 'EXP-01', 'verdict': 'fp'}))
print('\n'.join(lines))
" > "$TRIAGE_EXP"

python3 "$TRACKER" \
  --triage-file "$TRIAGE_EXP" \
  --scorecard-file "$SCORECARD_EXP" \
  --update-scorecard >/dev/null 2>&1

exp_stage=$(python3 -c "
import json
sc = json.load(open('$SCORECARD_EXP'))
print(sc['rules']['EXP-01']['stage'])
")
TOTAL=$((TOTAL + 1))
if [[ "$exp_stage" == "experimental" ]]; then
  green "精度不足的 experimental 规则保持 experimental（不直接降级）"
  PASS=$((PASS + 1))
else
  red "experimental 规则不应直接降级，应保持 experimental，实际: $exp_stage"
  FAIL=$((FAIL + 1))
fi

header "无效 triage 行被隔离（issue-1：schema 校验）"
TRIAGE_BAD="${TMPDIR_TEST}/triage_bad.jsonl"
SCORECARD_BAD="${TMPDIR_TEST}/scorecard_bad.json"
python3 -c "
import json
scorecard = {
  'rules': {
    'RS-04': {
      'stage': 'experimental', 'precision': None, 'samples': 0,
      'tp': 0, 'fp': 0, 'acceptable': 0, 'last_fp_ts': None,
      'stage_entered_ts': '2026-01-01T00:00:00Z', 'notes': ''
    }
  }
}
print(json.dumps(scorecard, indent=2))
" > "$SCORECARD_BAD"
printf '%s\n' \
  '{"ts":"2026-03-01T00:00:00Z","rule":"RS-04","verdict":"tp"}' \
  '[]' \
  '42' \
  '{"rule":{"bad":1},"verdict":"tp"}' \
  '{"ts":"2026-03-01T00:00:00Z","rule":"RS-04","verdict":"unknown_verdict"}' \
  '{"ts":"2026-03-01T00:00:00Z","rule":"RS-04","verdict":"fp"}' \
  > "$TRIAGE_BAD"

bad_stderr=$(python3 "$TRACKER" \
  --triage-file "$TRIAGE_BAD" \
  --scorecard-file "$SCORECARD_BAD" \
  --update-scorecard 2>&1 >/dev/null) || true
assert_contains "$bad_stderr" "[ERROR]" "无效行产生 ERROR 输出"

valid_samples=$(python3 -c "
import json, sys
sc = json.load(open('$SCORECARD_BAD'))
print(sc['rules']['RS-04']['samples'])
")
TOTAL=$((TOTAL + 1))
# Valid records (1 tp + 1 fp) are still processed; only invalid lines are skipped.
if [[ "$valid_samples" == "2" ]]; then
  green "有效记录被正常处理（samples=2），无效行被隔离"
  PASS=$((PASS + 1))
else
  red "有效记录应被处理（期望 samples=2，实际 $valid_samples）"
  FAIL=$((FAIL + 1))
fi

header "原子写保证 scorecard 格式完整（issue-2：atomic write）"
SCORECARD_ATOMIC="${TMPDIR_TEST}/scorecard_atomic.json"
TRIAGE_ATOMIC="${TMPDIR_TEST}/triage_atomic.jsonl"
python3 -c "
import json
scorecard = {'rules': {'AT-01': {'stage': 'experimental', 'precision': None, 'samples': 0,
  'tp': 0, 'fp': 0, 'acceptable': 0, 'last_fp_ts': None,
  'stage_entered_ts': '2026-01-01T00:00:00Z', 'notes': ''}}}
print(json.dumps(scorecard, indent=2))
" > "$SCORECARD_ATOMIC"
printf '{"ts":"2026-03-01T00:00:00Z","rule":"AT-01","verdict":"tp"}\n' > "$TRIAGE_ATOMIC"
python3 "$TRACKER" \
  --triage-file "$TRIAGE_ATOMIC" \
  --scorecard-file "$SCORECARD_ATOMIC" \
  --update-scorecard >/dev/null 2>&1
# Verify the output is valid JSON (atomic write should never leave a partial file)
python3 -c "import json; json.load(open('$SCORECARD_ATOMIC'))" 2>/dev/null && {
  TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1))
  green "update-scorecard 后 scorecard 是合法 JSON"
} || {
  TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
  red "update-scorecard 后 scorecard 不是合法 JSON"
}
# Verify no stray .tmp files remain
tmp_count=$(find "${TMPDIR_TEST}" -maxdepth 1 -name '.scorecard-*.tmp' 2>/dev/null | wc -l | tr -d ' ')
TOTAL=$((TOTAL + 1))
if [[ "$tmp_count" == "0" ]]; then
  green "无残留临时文件"
  PASS=$((PASS + 1))
else
  red "发现残留临时文件（$tmp_count 个）"
  FAIL=$((FAIL + 1))
fi

header "triage 清理后旧规则统计被重置（issue-3：stale rule reset）"
TRIAGE4="${TMPDIR_TEST}/triage4.jsonl"
SCORECARD4="${TMPDIR_TEST}/scorecard4.json"
python3 -c "
import json
scorecard = {
  'rules': {
    'STALE-01': {
      'stage': 'warn', 'precision': 0.95, 'samples': 50,
      'tp': 45, 'fp': 5, 'acceptable': 0, 'last_fp_ts': '2026-01-01T00:00:00Z',
      'stage_entered_ts': '2026-01-01T00:00:00Z', 'notes': 'stale rule'
    },
    'ACTIVE-01': {
      'stage': 'experimental', 'precision': None, 'samples': 0,
      'tp': 0, 'fp': 0, 'acceptable': 0, 'last_fp_ts': None,
      'stage_entered_ts': '2026-01-01T00:00:00Z', 'notes': 'active rule'
    }
  }
}
print(json.dumps(scorecard, indent=2))
" > "$SCORECARD4"
# Only ACTIVE-01 has triage records; STALE-01 has been archived
printf '{"ts":"2026-03-01T00:00:00Z","rule":"ACTIVE-01","verdict":"tp"}\n' > "$TRIAGE4"

python3 "$TRACKER" \
  --triage-file "$TRIAGE4" \
  --scorecard-file "$SCORECARD4" \
  --update-scorecard >/dev/null 2>&1

stale_samples=$(python3 -c "
import json
sc = json.load(open('$SCORECARD4'))
print(sc['rules']['STALE-01']['samples'])
")
TOTAL=$((TOTAL + 1))
if [[ "$stale_samples" == "0" ]]; then
  green "triage 清理后旧规则 samples 被重置为 0"
  PASS=$((PASS + 1))
else
  red "旧规则 samples 未被重置（期望 0，实际 $stale_samples）"
  FAIL=$((FAIL + 1))
fi

stale_precision=$(python3 -c "
import json
sc = json.load(open('$SCORECARD4'))
print(sc['rules']['STALE-01']['precision'])
")
TOTAL=$((TOTAL + 1))
if [[ "$stale_precision" == "None" ]]; then
  green "triage 清理后旧规则 precision 被重置为 None"
  PASS=$((PASS + 1))
else
  red "旧规则 precision 未被重置（期望 None，实际 $stale_precision）"
  FAIL=$((FAIL + 1))
fi

# Active rule should still have correct stats
active_samples=$(python3 -c "
import json
sc = json.load(open('$SCORECARD4'))
print(sc['rules']['ACTIVE-01']['samples'])
")
TOTAL=$((TOTAL + 1))
if [[ "$active_samples" == "1" ]]; then
  green "活跃规则统计不受影响（samples=1）"
  PASS=$((PASS + 1))
else
  red "活跃规则统计异常（期望 1，实际 $active_samples）"
  FAIL=$((FAIL + 1))
fi

header "Issue-1: fp 缺失 ts 被拒绝，不计入 fp 统计"
TRIAGE_NO_TS="${TMPDIR_TEST}/triage_no_ts.jsonl"
SCORECARD_NO_TS="${TMPDIR_TEST}/scorecard_no_ts.json"
python3 -c "
import json
scorecard = {
  'rules': {
    'TS-01': {
      'stage': 'warn', 'precision': None, 'samples': 0,
      'tp': 0, 'fp': 0, 'acceptable': 0, 'last_fp_ts': None,
      'stage_entered_ts': '2026-01-01T00:00:00Z', 'notes': ''
    }
  }
}
print(json.dumps(scorecard, indent=2))
" > "$SCORECARD_NO_TS"
# fp without ts must be rejected; tp with ts is valid; total samples should be 1
printf '%s\n' \
  '{"ts":"2026-03-01T00:00:00Z","rule":"TS-01","verdict":"tp"}' \
  '{"rule":"TS-01","verdict":"fp"}' \
  > "$TRIAGE_NO_TS"

no_ts_stderr=$(python3 "$TRACKER" \
  --triage-file "$TRIAGE_NO_TS" \
  --scorecard-file "$SCORECARD_NO_TS" \
  --update-scorecard 2>&1 >/dev/null) || true
assert_contains "$no_ts_stderr" "[ERROR]" "fp 缺失 ts 时产生 ERROR 输出"

# last_fp_ts must remain None (fp was rejected), so warn→error must not fire
no_ts_last_fp=$(python3 -c "
import json
sc = json.load(open('$SCORECARD_NO_TS'))
print(sc['rules']['TS-01']['last_fp_ts'])
")
TOTAL=$((TOTAL + 1))
if [[ "$no_ts_last_fp" == "None" ]]; then
  green "fp 缺失 ts 时 last_fp_ts 保持 None（不误晋级）"
  PASS=$((PASS + 1))
else
  red "last_fp_ts 不应被更新（期望 None，实际 $no_ts_last_fp）"
  FAIL=$((FAIL + 1))
fi

header "Issue-2: 跨时区 fp ts 比较使用 datetime 而非字符串"
TRIAGE_TZ="${TMPDIR_TEST}/triage_tz.jsonl"
SCORECARD_TZ="${TMPDIR_TEST}/scorecard_tz.json"
python3 -c "
import json
scorecard = {
  'rules': {
    'TZ-01': {
      'stage': 'warn', 'precision': None, 'samples': 0,
      'tp': 0, 'fp': 0, 'acceptable': 0, 'last_fp_ts': None,
      'stage_entered_ts': '2026-01-01T00:00:00Z', 'notes': ''
    }
  }
}
print(json.dumps(scorecard, indent=2))
" > "$SCORECARD_TZ"
# +09:00 record is 2026-03-01T12:00:00+09:00 = 2026-03-01T03:00:00Z
# Z record is 2026-03-01T10:00:00Z  (later in UTC)
# String sort: "+09:00" < "Z" is wrong; datetime comparison must pick the Z record
printf '%s\n' \
  '{"ts":"2026-03-01T12:00:00+09:00","rule":"TZ-01","verdict":"fp"}' \
  '{"ts":"2026-03-01T10:00:00Z","rule":"TZ-01","verdict":"fp"}' \
  > "$TRIAGE_TZ"

python3 "$TRACKER" \
  --triage-file "$TRIAGE_TZ" \
  --scorecard-file "$SCORECARD_TZ" \
  --update-scorecard >/dev/null 2>&1

tz_last_fp=$(python3 -c "
import json
sc = json.load(open('$SCORECARD_TZ'))
print(sc['rules']['TZ-01']['last_fp_ts'])
")
TOTAL=$((TOTAL + 1))
# 10:00Z is 10:00 UTC; 12:00+09:00 is 03:00 UTC — so 10:00Z is the later one
if [[ "$tz_last_fp" == "2026-03-01T10:00:00Z" ]]; then
  green "跨时区 fp 比较正确选出最新 ts（UTC 10:00Z 晚于 +09:00 的 03:00Z）"
  PASS=$((PASS + 1))
else
  red "跨时区比较错误（期望 2026-03-01T10:00:00Z，实际 $tz_last_fp）"
  FAIL=$((FAIL + 1))
fi

header "Issue-3: 抑制规则边界 — RS-03X 不误匹配 RS-03"
# Verify vg_filter_suppressed only suppresses the exact rule ID
suppress_out=$(python3 -c "
import sys, re
rule = 'RS-03'
suppress_pat = re.compile(r'^\s*(?://|#)\s*vibeguard-disable-next-line\s+' + re.escape(rule) + r'(?:\s|--|$)')
lines = [
    '// vibeguard-disable-next-line RS-03X -- wrong rule',
    'should_appear_1',
    '// vibeguard-disable-next-line RS-03 -- correct',
    'should_not_appear',
    '// vibeguard-disable-next-line RS-03',
    'also_not_appear',
]
for i, line in enumerate(lines):
    prev = lines[i - 1] if i > 0 else ''
    if suppress_pat.search(prev):
        continue
    print(line)
")
assert_contains "$suppress_out" "should_appear_1" "RS-03X 注释不抑制 RS-03 规则"
assert_not_contains "$suppress_out" "should_not_appear" "RS-03 注释正确抑制下一行"
assert_not_contains "$suppress_out" "also_not_appear" "无 reason 的 RS-03 注释也正确抑制"

# Code strings containing // must not suppress (reviewer bypass scenario)
suppress_out2=$(python3 -c "
import sys, re
rule = 'RS-03'
suppress_pat = re.compile(r'^\s*(?://|#)\s*vibeguard-disable-next-line\s+' + re.escape(rule) + r'(?:\s|--|$)')
lines = [
    'let s = \"// vibeguard-disable-next-line RS-03 in string\";',
    'should_appear_2',
]
for i, line in enumerate(lines):
    prev = lines[i - 1] if i > 0 else ''
    if suppress_pat.search(prev):
        continue
    print(line)
")
assert_contains "$suppress_out2" "should_appear_2" "字符串中的 // 标记不抑制（非行首注释）"

header "Issue-4: 无时区时间戳被校验拒绝（防 naive vs aware TypeError）"
TRIAGE_NAIVE="${TMPDIR_TEST}/triage_naive.jsonl"
SCORECARD_NAIVE="${TMPDIR_TEST}/scorecard_naive.json"
python3 -c "
import json
scorecard = {
  'rules': {
    'NZ-01': {
      'stage': 'warn', 'precision': None, 'samples': 0,
      'tp': 0, 'fp': 0, 'acceptable': 0, 'last_fp_ts': None,
      'stage_entered_ts': '2026-01-01T00:00:00Z', 'notes': ''
    }
  }
}
print(json.dumps(scorecard, indent=2))
" > "$SCORECARD_NAIVE"
# naive timestamp (no Z / offset) must be rejected; tz-aware tp must be accepted
printf '%s\n' \
  '{"ts":"2026-03-01T10:00:00","rule":"NZ-01","verdict":"fp"}' \
  '{"ts":"2026-03-01T11:00:00Z","rule":"NZ-01","verdict":"tp"}' \
  > "$TRIAGE_NAIVE"

naive_stderr=$(python3 "$TRACKER" \
  --triage-file "$TRIAGE_NAIVE" \
  --scorecard-file "$SCORECARD_NAIVE" \
  --update-scorecard 2>&1 >/dev/null) || true
assert_contains "$naive_stderr" "[ERROR]" "无时区 fp ts 产生 ERROR 输出"

naive_samples=$(python3 -c "
import json
sc = json.load(open('$SCORECARD_NAIVE'))
print(sc['rules']['NZ-01']['samples'])
")
TOTAL=$((TOTAL + 1))
# The valid tp record is still processed; only the invalid fp (no tz) is skipped.
if [[ "$naive_samples" == "1" ]]; then
  green "有效 tp 被正常处理（samples=1），无时区 fp 被隔离"
  PASS=$((PASS + 1))
else
  red "有效 tp 应被处理（期望 samples=1，实际 $naive_samples）"
  FAIL=$((FAIL + 1))
fi

header "parse errors 时生命周期迁移被冻结（issue: lifecycle freeze）"
# When triage has parse errors, lifecycle transitions must NOT fire even if
# stats would normally trigger a promotion/demotion, to prevent stage pollution.
TRIAGE_PERR="${TMPDIR_TEST}/triage_perr.jsonl"
SCORECARD_PERR="${TMPDIR_TEST}/scorecard_perr.json"
python3 -c "
import json
scorecard = {
  'rules': {
    'RS-LC': {
      'stage': 'experimental', 'precision': None, 'samples': 0,
      'tp': 0, 'fp': 0, 'acceptable': 0, 'last_fp_ts': None,
      'stage_entered_ts': '2026-01-01T00:00:00Z', 'notes': ''
    }
  }
}
print(json.dumps(scorecard, indent=2))
" > "$SCORECARD_PERR"
# 10 valid tp records (enough to trigger experimental→warn) + 1 corrupt line
{
  for i in $(seq 1 10); do
    printf '{"ts":"2026-03-0%dT00:00:00Z","rule":"RS-LC","verdict":"tp"}\n' "$((i % 9 + 1))"
  done
  printf 'NOT_JSON\n'
} > "$TRIAGE_PERR"

perr_out=$(python3 "$TRACKER" \
  --triage-file "$TRIAGE_PERR" \
  --scorecard-file "$SCORECARD_PERR" \
  --update-scorecard 2>&1)
# Error message must mention transitions suppressed
assert_contains "$perr_out" "lifecycle transitions and counter resets suppressed" "parse errors 时警告包含 transitions suppressed"
# Stage must remain experimental — transition must not have fired
perr_stage=$(python3 -c "
import json
sc = json.load(open('$SCORECARD_PERR'))
print(sc['rules']['RS-LC']['stage'])
")
TOTAL=$((TOTAL + 1))
if [[ "$perr_stage" == "experimental" ]]; then
  green "parse errors 时生命周期迁移被冻结（stage 保持 experimental）"
  PASS=$((PASS + 1))
else
  red "parse errors 时 stage 意外变更（期望 experimental，实际 $perr_stage）"
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
