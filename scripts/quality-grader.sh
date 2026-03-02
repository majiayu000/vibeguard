#!/usr/bin/env bash
# VibeGuard 质量等级自动评分
#
# 从 events.jsonl 计算质量等级（A/B/C/D），输出分数和推荐 GC 频率。
#
# 评分公式：
#   grade = security × 0.4 + stability × 0.3 + coverage × 0.2 + performance × 0.1
#   等级: A(≥90) B(70-89) C(50-69) D(<50)
#   GC 频率: A=7天 B=3天 C=1天 D=实时
#
# 用法：
#   bash quality-grader.sh           # 分析最近 30 天
#   bash quality-grader.sh 7         # 分析最近 7 天
#   bash quality-grader.sh all       # 全部历史
#   bash quality-grader.sh --json    # JSON 格式输出

set -euo pipefail

DAYS="30"
JSON_OUTPUT=false
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

for arg in "$@"; do
  case "$arg" in
    --json) JSON_OUTPUT=true ;;
    all|[0-9]*) DAYS="$arg" ;;
  esac
done

LOG_FILE="${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}/events.jsonl"

if [[ ! -f "$LOG_FILE" ]]; then
  echo "没有日志数据。hooks 触发后会自动记录到 $LOG_FILE"
  exit 0
fi

GUARDS_DIR="${REPO_DIR}/guards"
RULES_DIR="${REPO_DIR}/rules"
NATIVE_RULES_DIR="${HOME}/.claude/rules/vibeguard"

VG_DAYS="$DAYS" VG_LOG_FILE="$LOG_FILE" VG_GUARDS_DIR="$GUARDS_DIR" \
  VG_RULES_DIR="$RULES_DIR" VG_NATIVE_RULES_DIR="$NATIVE_RULES_DIR" \
  VG_JSON="$JSON_OUTPUT" python3 -c '
import json, sys, os, glob
from datetime import datetime, timezone, timedelta
from collections import Counter

days = os.environ.get("VG_DAYS", "30")
log_file = os.environ.get("VG_LOG_FILE", "")
guards_dir = os.environ.get("VG_GUARDS_DIR", "")
rules_dir = os.environ.get("VG_RULES_DIR", "")
native_rules_dir = os.environ.get("VG_NATIVE_RULES_DIR", "")
json_output = os.environ.get("VG_JSON", "false") == "true"

# 读取事件
events = []
with open(log_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue

if not events:
    print("没有日志数据。")
    sys.exit(0)

# 时间过滤
if days != "all":
    cutoff = datetime.now(timezone.utc) - timedelta(days=int(days))
    cutoff_str = cutoff.strftime("%Y-%m-%dT%H:%M:%SZ")
    events = [e for e in events if e.get("ts", "") >= cutoff_str]

if not events:
    print(f"最近 {days} 天没有日志数据。")
    sys.exit(0)

total = len(events)
by_decision = Counter(e.get("decision", "unknown") for e in events)

blocks = by_decision.get("block", 0)
warns = by_decision.get("warn", 0)
passes = by_decision.get("pass", 0)

# --- 指标计算 ---

# security: block 拦截率越低越好（说明代码质量高，很少触发严重拦截）
# 计算方式：100 - (block / total * 100)
security = max(0, 100 - (blocks / total * 100)) if total > 0 else 100

# stability: pass 率越高越好
stability = (passes / total * 100) if total > 0 else 100

# coverage: 守卫脚本覆盖的规则占比
rule_ids = set()
for md_file in glob.glob(os.path.join(rules_dir, "*.md")):
    with open(md_file) as f:
        for line in f:
            # 提取 RS-XX, GO-XX, TS-XX, PY-XX, U-XX, SEC-XX 格式
            import re
            for m in re.finditer(r"\b(RS|GO|TS|PY|U|SEC)-\d+\b", line):
                rule_ids.add(m.group())

guard_ids = set()
for guard_file in glob.glob(os.path.join(guards_dir, "**/*"), recursive=True):
    if not os.path.isfile(guard_file):
        continue
    try:
        with open(guard_file) as f:
            content = f.read()
            import re
            for m in re.finditer(r"\b(RS|GO|TS|PY|U|SEC)-\d+\b", content):
                guard_ids.add(m.group())
    except (UnicodeDecodeError, PermissionError):
        continue

implemented = rule_ids & guard_ids
coverage_mechanical = (len(implemented) / len(rule_ids) * 100) if rule_ids else 0

# AI 可见覆盖率: 规则 ID 出现在 ~/.claude/rules/vibeguard/
ai_visible_ids = set()
if native_rules_dir and os.path.isdir(native_rules_dir):
    for nr_file in glob.glob(os.path.join(native_rules_dir, "**/*.md"), recursive=True):
        try:
            with open(nr_file) as f:
                for line in f:
                    import re
                    for m in re.finditer(r"\b(RS|GO|TS|PY|U|SEC|TASTE)-[\w]+\b", line):
                        ai_visible_ids.add(m.group())
        except (UnicodeDecodeError, PermissionError):
            continue

ai_visible = rule_ids & ai_visible_ids
coverage_ai = (len(ai_visible) / len(rule_ids) * 100) if rule_ids else 0
dual_covered = implemented & ai_visible

# 综合覆盖率: AI 可见 + 机械强制 (union)
all_covered = implemented | ai_visible
coverage = (len(all_covered) / len(rule_ids) * 100) if rule_ids else 0

# performance: 慢操作占比越低越好（duration_ms > 5000）
events_with_duration = [e for e in events if "duration_ms" in e]
if events_with_duration:
    slow_ops = sum(1 for e in events_with_duration if e.get("duration_ms", 0) > 5000)
    performance = max(0, 100 - (slow_ops / len(events_with_duration) * 100))
else:
    performance = 100  # 无耗时数据，默认满分

# --- 加权评分 ---
grade_score = security * 0.4 + stability * 0.3 + coverage * 0.2 + performance * 0.1
grade_score = round(grade_score, 1)

if grade_score >= 90:
    grade = "A"
    gc_days = 7
elif grade_score >= 70:
    grade = "B"
    gc_days = 3
elif grade_score >= 50:
    grade = "C"
    gc_days = 1
else:
    grade = "D"
    gc_days = 0  # 实时

gc_freq = f"{gc_days}天" if gc_days > 0 else "实时"

if json_output:
    result = {
        "grade": grade,
        "score": grade_score,
        "gc_frequency_days": gc_days,
        "metrics": {
            "security": round(security, 1),
            "stability": round(stability, 1),
            "coverage": round(coverage, 1),
            "coverage_mechanical": round(coverage_mechanical, 1),
            "coverage_ai_visible": round(coverage_ai, 1),
            "performance": round(performance, 1),
        },
        "events_analyzed": total,
        "rules_total": len(rule_ids),
        "rules_implemented": len(implemented),
        "rules_ai_visible": len(ai_visible),
        "rules_dual_covered": len(dual_covered),
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))
else:
    period = "全部历史" if days == "all" else f"最近 {days} 天"
    print(f"""
VibeGuard 质量评分 ({period})
{"=" * 40}
等级: {grade} ({grade_score} 分)
推荐 GC 频率: {gc_freq}

分项指标:
  安全性 (×0.4):  {security:.1f}  (block {blocks}/{total})
  稳定性 (×0.3):  {stability:.1f}  (pass {passes}/{total})
  覆盖率 (×0.2):  {coverage:.1f}  (综合 {len(all_covered)}/{len(rule_ids)} 条规则)
    机械强制:      {coverage_mechanical:.1f}  (守卫/hooks {len(implemented)} 条)
    AI 可见:       {coverage_ai:.1f}  (~/.claude/rules/ {len(ai_visible)} 条)
    双重覆盖:      {len(dual_covered)} 条
  性能   (×0.1):  {performance:.1f}  (慢操作 {slow_ops if events_with_duration else "N/A"}/{len(events_with_duration)} 次)

事件总数: {total}
规则总数: {len(rule_ids)} (综合覆盖: {len(all_covered)}, 未覆盖: {len(rule_ids - all_covered)})""")

    if rule_ids - all_covered:
        uncovered = sorted(rule_ids - all_covered)
        uncovered_str = ", ".join(uncovered[:10])
        extra = f" (+{len(uncovered)-10} 条)" if len(uncovered) > 10 else ""
        print(f"未覆盖规则: {uncovered_str}{extra}")
    print()
'
