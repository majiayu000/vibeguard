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
