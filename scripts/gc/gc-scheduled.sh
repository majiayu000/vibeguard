#!/usr/bin/env bash
# VibeGuard 定期 GC — 由 launchd 调度
#
# 执行日志归档 + worktree 清理，结果写入 gc-cron.log。
# 由 com.vibeguard.gc plist 每周日凌晨 3 点触发。
#
# 手动运行：bash gc-scheduled.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}"
GC_LOG="${LOG_DIR}/gc-cron.log"

mkdir -p "${LOG_DIR}"

{
  echo "=========================================="
  echo "VibeGuard GC — $(date '+%Y-%m-%d %H:%M:%S')"
  echo "=========================================="
  echo

  echo "--- 日志归档 ---"
  bash "${SCRIPT_DIR}/gc-logs.sh" 2>&1 || echo "[ERROR] gc-logs failed"
  echo

  echo "--- Worktree 清理 ---"
  bash "${SCRIPT_DIR}/gc-worktrees.sh" 2>&1 || echo "[ERROR] gc-worktrees failed"
  echo

  echo "--- Session Metrics 清理 ---"
  # 删除 90 天前的 session-metrics 条目
  CUTOFF=$(date -v-90d '+%Y-%m-%dT' 2>/dev/null || date -d '90 days ago' '+%Y-%m-%dT' 2>/dev/null || echo "")
  if [[ -n "${CUTOFF}" ]]; then
    CLEANED=0
    for mf in "${LOG_DIR}"/projects/*/session-metrics.jsonl; do
      [[ -f "${mf}" ]] || continue
      BEFORE=$(wc -l < "${mf}" | tr -d ' ')
      python3 -c "
import sys
cutoff = '${CUTOFF}'
kept = []
with open('${mf}') as f:
    for line in f:
        if line.strip():
            if '\"ts\"' in line:
                idx = line.find('\"ts\"')
                ts_start = line.find('\"', idx + 4) + 1
                ts_val = line[ts_start:ts_start+10]
                if ts_val >= cutoff[:10]:
                    kept.append(line)
            else:
                kept.append(line)
with open('${mf}', 'w') as f:
    f.writelines(kept)
print(f'  {len(kept)} 条保留 (原 ${BEFORE} 条)')
" 2>/dev/null || true
      AFTER=$(wc -l < "${mf}" | tr -d ' ')
      DIFF=$((BEFORE - AFTER))
      [[ ${DIFF} -gt 0 ]] && CLEANED=$((CLEANED + DIFF))
    done
    echo "  清理 ${CLEANED} 条过期 metrics"
  else
    echo "  跳过（无法计算日期）"
  fi
  echo

  echo "--- 定期学习（事件日志 + 代码扫描统一信号源） ---"
  VIBEGUARD_DIR="${SCRIPT_DIR}/.."
  python3 -c "
import json, os, sys, subprocess
from collections import Counter
from datetime import datetime, timezone, timedelta

log_dir = '${LOG_DIR}'
vibeguard_dir = '${VIBEGUARD_DIR}'
projects_dir = os.path.join(log_dir, 'projects')
digest_file = os.path.join(log_dir, 'learn-digest.jsonl')

if not os.path.isdir(projects_dir):
    print('  无项目数据，跳过')
    sys.exit(0)

now = datetime.now(timezone.utc)
cutoff_7d = (now - timedelta(days=7)).strftime('%Y-%m-%dT')
signals_found = 0

# 语言检测 → 对应 guards 脚本
def detect_guards(project_root):
    '''返回 [(guard_script, rule_id_prefix)] 列表'''
    guards = []
    guards_dir = os.path.join(vibeguard_dir, 'guards')
    # 通用守卫（所有项目）
    slop = os.path.join(guards_dir, 'universal', 'check_code_slop.sh')
    if os.path.exists(slop):
        guards.append((slop, 'SLOP'))
    # 语言检测
    if os.path.exists(os.path.join(project_root, 'Cargo.toml')):
        for f in os.listdir(os.path.join(guards_dir, 'rust')):
            if f.startswith('check_') and f.endswith('.sh'):
                guards.append((os.path.join(guards_dir, 'rust', f), 'RS'))
    if os.path.exists(os.path.join(project_root, 'tsconfig.json')) or \
       os.path.exists(os.path.join(project_root, 'package.json')):
        for f in os.listdir(os.path.join(guards_dir, 'typescript')):
            if f.startswith('check_') and f.endswith('.sh'):
                guards.append((os.path.join(guards_dir, 'typescript', f), 'TS'))
    if os.path.exists(os.path.join(project_root, 'go.mod')):
        for f in os.listdir(os.path.join(guards_dir, 'go')):
            if f.startswith('check_') and f.endswith('.sh'):
                guards.append((os.path.join(guards_dir, 'go', f), 'GO'))
    return guards

def run_guard(script, project_root):
    '''运行守卫脚本，返回违规行数'''
    try:
        result = subprocess.run(
            ['bash', script, project_root],
            capture_output=True, text=True, timeout=30
        )
        output = result.stdout.strip()
        if not output:
            return 0, []
        # 计算 [XX-NN] 标记的违规行
        violations = [l for l in output.split('\\n') if l.startswith('[')]
        return len(violations), violations[:3]  # 最多保留 3 条示例
    except (subprocess.TimeoutExpired, OSError):
        return 0, []

for proj in os.listdir(projects_dir):
    proj_dir = os.path.join(projects_dir, proj)
    if not os.path.isdir(proj_dir):
        continue

    events_file = os.path.join(proj_dir, 'events.jsonl')
    project_root_file = os.path.join(proj_dir, '.project-root')

    signals = []
    session_set = set()

    # ── 信号源 A：事件日志分析 ──
    if os.path.exists(events_file):
        warn_reasons = Counter()
        block_reasons = Counter()
        edit_files = Counter()
        slow_count = 0

        with open(events_file) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    evt = json.loads(line)
                except json.JSONDecodeError:
                    continue
                ts = evt.get('ts', '')
                if ts[:10] < cutoff_7d[:10]:
                    continue
                session_set.add(evt.get('session', ''))
                decision = evt.get('decision', '')
                reason = evt.get('reason', '')
                if decision == 'warn' and reason:
                    warn_reasons[reason] += 1
                elif decision == 'block' and reason:
                    block_reasons[reason] += 1
                if evt.get('tool') == 'Edit' and evt.get('detail'):
                    edit_files[evt['detail'].split()[-1]] += 1
                if evt.get('duration_ms', 0) > 5000:
                    slow_count += 1

        for reason, count in warn_reasons.most_common(5):
            if count >= 10:
                signals.append({
                    'type': 'repeated_warn', 'source': 'events',
                    'reason': reason, 'count': count,
                    'sessions': len(session_set)
                })
        for reason, count in block_reasons.most_common(5):
            if count >= 5:
                signals.append({
                    'type': 'chronic_block', 'source': 'events',
                    'reason': reason, 'count': count,
                    'sessions': len(session_set)
                })
        for filepath, count in edit_files.most_common(5):
            if count >= 20:
                signals.append({
                    'type': 'hot_files', 'source': 'events',
                    'file': filepath, 'edits': count,
                    'sessions': len(session_set)
                })
        if slow_count >= 10:
            signals.append({
                'type': 'slow_sessions', 'source': 'events',
                'count': slow_count, 'sessions': len(session_set)
            })

        # warn 趋势
        metrics_file = os.path.join(proj_dir, 'session-metrics.jsonl')
        if os.path.exists(metrics_file):
            mid = (now - timedelta(days=3.5)).strftime('%Y-%m-%dT')
            early_warns, late_warns = 0, 0
            with open(metrics_file) as mf:
                for ml in mf:
                    ml = ml.strip()
                    if not ml:
                        continue
                    try:
                        m = json.loads(ml)
                    except json.JSONDecodeError:
                        continue
                    mts = m.get('ts', '')
                    if mts[:10] < cutoff_7d[:10]:
                        continue
                    w = m.get('decisions', {}).get('warn', 0)
                    if mts < mid:
                        early_warns += w
                    else:
                        late_warns += w
            if early_warns > 0 and late_warns > early_warns * 1.5:
                signals.append({
                    'type': 'warn_escalation', 'source': 'events',
                    'early': early_warns, 'late': late_warns,
                    'ratio': round(late_warns / max(early_warns, 1), 2)
                })

    # ── 信号源 B：代码扫描（linter 违规） ──
    if os.path.exists(project_root_file):
        project_root = open(project_root_file).read().strip()
        if os.path.isdir(project_root):
            guards = detect_guards(project_root)
            for guard_script, prefix in guards:
                vcount, examples = run_guard(guard_script, project_root)
                if vcount >= 5:
                    guard_name = os.path.basename(guard_script).replace('check_', '').replace('.sh', '')
                    signals.append({
                        'type': 'linter_violations', 'source': 'code_scan',
                        'guard': guard_name, 'count': vcount,
                        'examples': examples
                    })

    if signals:
        signals_found += len(signals)
        entry = {
            'ts': now.strftime('%Y-%m-%dT%H:%M:%SZ'),
            'project': proj,
            'signals': signals,
            'recommendation': f'consider /vibeguard:learn for project {proj}'
        }
        # 读 project-root 补充可读路径
        if os.path.exists(project_root_file):
            entry['project_root'] = open(project_root_file).read().strip()
        with open(digest_file, 'a') as df:
            df.write(json.dumps(entry, ensure_ascii=False) + '\n')
        print(f'  项目 {proj}: {len(signals)} 个学习信号')
        for s in signals:
            src = s.get('source', '')
            if s['type'] == 'linter_violations':
                print(f'    - [代码扫描] {s[\"guard\"]}: {s[\"count\"]} 个违规')
            else:
                detail = s.get('reason', s.get('file', ''))
                count = s.get('count', s.get('edits', ''))
                print(f'    - [事件日志] {s[\"type\"]}: {detail} ({count})')

if signals_found == 0:
    print('  无需学习的信号')
else:
    print(f'  共 {signals_found} 个信号，已写入 learn-digest.jsonl')
" 2>&1 || echo "[ERROR] learn-digest failed"
  echo

  echo "--- 会话质量反思（Reflection Automation） ---"
  REFLECTION_FILE="${LOG_DIR}/reflection-digest.md"
  python3 -c "
import json, os, sys
from collections import Counter
from datetime import datetime, timezone, timedelta

log_dir = '${LOG_DIR}'
projects_dir = os.path.join(log_dir, 'projects')
output_file = '${REFLECTION_FILE}'

if not os.path.isdir(projects_dir):
    print('  无项目数据，跳过')
    sys.exit(0)

now = datetime.now(timezone.utc)
cutoff_7d = (now - timedelta(days=7)).strftime('%Y-%m-%dT')

# 收集所有项目的 session-metrics
all_sessions = []
project_names = {}
for proj in os.listdir(projects_dir):
    proj_dir = os.path.join(projects_dir, proj)
    if not os.path.isdir(proj_dir):
        continue
    # 读项目名
    root_file = os.path.join(proj_dir, '.project-root')
    if os.path.exists(root_file):
        project_names[proj] = open(root_file).read().strip().split('/')[-1]
    else:
        project_names[proj] = proj

    metrics_file = os.path.join(proj_dir, 'session-metrics.jsonl')
    if not os.path.exists(metrics_file):
        continue
    with open(metrics_file) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                m = json.loads(line)
                if m.get('ts', '')[:10] >= cutoff_7d[:10]:
                    m['_project'] = proj
                    all_sessions.append(m)
            except json.JSONDecodeError:
                continue

if not all_sessions:
    print('  无近 7 天会话数据，跳过')
    sys.exit(0)

# 聚合分析
total_sessions = len(all_sessions)
total_events = sum(s.get('event_count', 0) for s in all_sessions)

# 决策分布
decision_totals = Counter()
for s in all_sessions:
    for d, c in s.get('decisions', {}).items():
        decision_totals[d] += c

# 纠正信号统计
sessions_with_corrections = 0
all_correction_signals = Counter()
for s in all_sessions:
    sigs = s.get('correction_signals', [])
    if sigs:
        sessions_with_corrections += 1
        for sig in sigs:
            # 归类信号
            if '反复修正' in sig:
                all_correction_signals['文件反复修正'] += 1
            elif '高摩擦' in sig:
                all_correction_signals['高摩擦会话'] += 1
            elif '纠正检测' in sig:
                all_correction_signals['实时纠正触发'] += 1
            elif '升级警告' in sig:
                all_correction_signals['升级警告'] += 1

# Hook 触发频率
hook_totals = Counter()
for s in all_sessions:
    for h, c in s.get('hooks', {}).items():
        hook_totals[h] += c

# 高 warn 比率会话
high_friction = [s for s in all_sessions if s.get('warn_ratio', 0) > 0.4]

# 最频繁编辑文件
file_edits = Counter()
for s in all_sessions:
    for f, c in s.get('top_edited_files', {}).items():
        if f:
            file_edits[f] += c

# 生成反思报告
report = []
report.append(f'# VibeGuard 周度反思报告')
report.append(f'')
report.append(f'> 生成时间: {now.strftime(\"%Y-%m-%d %H:%M UTC\")}')
report.append(f'> 覆盖范围: 最近 7 天')
report.append(f'')
report.append(f'## 概览')
report.append(f'')
report.append(f'- 会话数: {total_sessions}')
report.append(f'- 总事件数: {total_events}')
report.append(f'- pass: {decision_totals.get(\"pass\", 0)} | warn: {decision_totals.get(\"warn\", 0)} | block: {decision_totals.get(\"block\", 0)} | escalate: {decision_totals.get(\"escalate\", 0)}')
total_decisions = sum(decision_totals.values())
overall_warn_rate = (decision_totals.get('warn', 0) + decision_totals.get('block', 0) + decision_totals.get('escalate', 0)) / max(total_decisions, 1)
report.append(f'- 整体摩擦率: {overall_warn_rate:.0%}')
report.append(f'')

if sessions_with_corrections > 0 or high_friction:
    report.append(f'## 纠正信号')
    report.append(f'')
    report.append(f'- 含纠正信号的会话: {sessions_with_corrections}/{total_sessions}')
    report.append(f'- 高摩擦会话（>40% warn）: {len(high_friction)}')
    if all_correction_signals:
        report.append(f'- 信号类型:')
        for sig, count in all_correction_signals.most_common():
            report.append(f'  - {sig}: {count} 次')
    report.append(f'')

report.append(f'## Top 触发 Hook')
report.append(f'')
for hook, count in hook_totals.most_common(5):
    report.append(f'- {hook}: {count} 次')
report.append(f'')

if file_edits:
    report.append(f'## 热点文件（跨会话高频编辑）')
    report.append(f'')
    for f, c in file_edits.most_common(5):
        basename = os.path.basename(f)
        report.append(f'- {basename}: {c} 次编辑')
    report.append(f'')

# 改进建议
suggestions = []
if overall_warn_rate > 0.3:
    suggestions.append('整体摩擦率偏高 → 检查 top warn 原因，考虑新增规则或增强 Hook 提示')
if sessions_with_corrections > total_sessions * 0.3:
    suggestions.append('超过 30% 会话有纠正信号 → 运行 /vibeguard:learn 批量提取模式')
top_hook = hook_totals.most_common(1)
if top_hook and top_hook[0][1] > total_events * 0.3:
    suggestions.append(f'{top_hook[0][0]} 触发过于频繁 → 检查是否误报或规则过严')
if file_edits:
    top_file = file_edits.most_common(1)[0]
    if top_file[1] > 30:
        suggestions.append(f'{os.path.basename(top_file[0])} 编辑 {top_file[1]} 次 → 考虑拆分组件或审视架构')

if suggestions:
    report.append(f'## 改进建议')
    report.append(f'')
    for i, s in enumerate(suggestions, 1):
        report.append(f'{i}. {s}')
    report.append(f'')
else:
    report.append(f'## 改进建议')
    report.append(f'')
    report.append(f'本周无显著改进信号，系统运行正常。')
    report.append(f'')

# 写入文件
with open(output_file, 'w') as f:
    f.write('\n'.join(report))

print(f'  生成反思报告: {output_file}')
print(f'  会话: {total_sessions}, 事件: {total_events}, 摩擦率: {overall_warn_rate:.0%}')
if suggestions:
    for s in suggestions:
        print(f'    - {s}')
" 2>&1 || echo "[ERROR] reflection failed"
  echo

  echo "GC 完成"
} >> "${GC_LOG}" 2>&1

# 保持 gc-cron.log 不超过 1MB
if [[ -f "${GC_LOG}" ]]; then
  SIZE=$(du -k "${GC_LOG}" | cut -f1)
  if [[ ${SIZE} -gt 1024 ]]; then
    tail -500 "${GC_LOG}" > "${GC_LOG}.tmp"
    mv "${GC_LOG}.tmp" "${GC_LOG}"
  fi
fi
