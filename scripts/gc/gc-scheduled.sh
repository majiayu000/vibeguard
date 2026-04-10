#!/usr/bin/env bash
# VibeGuard periodic GC — scheduled by launchd
#
# Execute log archiving + worktree cleaning, and write the results to gc-cron.log.
# Triggered by com.vibeguard.gc plist every Sunday at 3am.
#
# Manually run: bash gc-scheduled.sh

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

  echo "--- Log archive ---"
  bash "${SCRIPT_DIR}/gc-logs.sh" 2>&1 || echo "[ERROR] gc-logs failed"
  echo

  echo "--- Worktree Cleanup ---"
  bash "${SCRIPT_DIR}/gc-worktrees.sh" 2>&1 || echo "[ERROR] gc-worktrees failed"
  echo

  echo "--- Session Metrics Cleanup ---"
  # Delete session-metrics entries older than 90 days
  CUTOFF=$(date -v-90d '+%Y-%m-%dT' 2>/dev/null || date -d '90 days ago' '+%Y-%m-%dT' 2>/dev/null || echo "")
  if [[ -n "${CUTOFF}" ]]; then
    CLEANED=0
    for mf in "${LOG_DIR}"/projects/*/session-metrics.jsonl; do
      [[ -f "${mf}" ]] || continue
      BEFORE=$(wc -l < "${mf}" | tr -d ' ')
      _GC_CUTOFF="${CUTOFF}" _GC_MF="${mf}" _GC_BEFORE="${BEFORE}" \
      python3 <<'PYEOF' 2>/dev/null || true
import sys, os
cutoff = os.environ['_GC_CUTOFF']
mf = os.environ['_GC_MF']
before = os.environ['_GC_BEFORE']
kept = []
with open(mf) as f:
    for line in f:
        if line.strip():
            if '"ts"' in line:
                idx = line.find('"ts"')
                ts_start = line.find('"', idx + 4) + 1
                ts_val = line[ts_start:ts_start+10]
                if ts_val >= cutoff[:10]:
                    kept.append(line)
            else:
                kept.append(line)
with open(mf, 'w') as f:
    f.writelines(kept)
print(f' {len(kept)} reserved items (original {before} items)')
PYEOF
      AFTER=$(wc -l < "${mf}" | tr -d ' ')
      DIFF=$((BEFORE - AFTER))
      [[ ${DIFF} -gt 0 ]] && CLEANED=$((CLEANED + DIFF))
    done
    echo "Clean ${CLEANED} expired metrics"
  else
    echo "Skip (cannot calculate date)"
  fi
  echo

  echo "--- Regular learning (event log + code scanning unified signal source) ---"
  VIBEGUARD_DIR="${SCRIPT_DIR}/.."
  _GC_LOG_DIR="${LOG_DIR}" _GC_VIBEGUARD_DIR="${VIBEGUARD_DIR}" \
  python3 <<'PYEOF' 2>&1 || echo "[ERROR] learn-digest failed"
import json, os, sys, subprocess
from collections import Counter
from datetime import datetime, timezone, timedelta

log_dir = os.environ['_GC_LOG_DIR']
vibeguard_dir = os.environ['_GC_VIBEGUARD_DIR']
projects_dir = os.path.join(log_dir, 'projects')
digest_file = os.path.join(log_dir, 'learn-digest.jsonl')

if not os.path.isdir(projects_dir):
    print('No project data, skip')
    sys.exit(0)

now = datetime.now(timezone.utc)
cutoff_7d = (now - timedelta(days=7)).strftime('%Y-%m-%dT')
signals_found = 0

# Language detection → corresponds to guards script
def detect_guards(project_root):
    '''Return [(guard_script, rule_id_prefix)] list'''
    guards = []
    guards_dir = os.path.join(vibeguard_dir, 'guards')
    # Universal guard (all projects)
    slop = os.path.join(guards_dir, 'universal', 'check_code_slop.sh')
    if os.path.exists(slop):
        guards.append((slop, 'SLOP'))
    # Language detection
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
    '''Run the guard script and return the number of violating lines'''
    try:
        result = subprocess.run(
            ['bash', script, project_root],
            capture_output=True, text=True, timeout=30
        )
        output = result.stdout.strip()
        if not output:
            return 0, []
        # Count the offending lines marked by [XX-NN]
        violations = [l for l in output.split('\\n') if l.startswith('[')]
        return len(violations), violations[:3] # Keep up to 3 examples
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

    # ── Signal source A: event log analysis ──
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

        # warn Trending
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

    # ── Signal source B: code scan (linter violation) ──
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
        # Read project-root to supplement the readable path
        if os.path.exists(project_root_file):
            entry['project_root'] = open(project_root_file).read().strip()
        with open(digest_file, 'a') as df:
            df.write(json.dumps(entry, ensure_ascii=False) + '\n')
        print(f' project {proj}: {len(signals)} learning signals')
        for s in signals:
            src = s.get('source', '')
            if s['type'] == 'linter_violations':
                print(f' - [code scan] {s["guard"]}: {s["count"]} violations')
            else:
                detail = s.get('reason', s.get('file', ''))
                count = s.get('count', s.get('edits', ''))
                print(f' - [Event Log] {s["type"]}: {detail} ({count})')

if signals_found == 0:
    print('No need to learn signals')
else:
    print(f' A total of {signals_found} signals have been written to learn-digest.jsonl')
PYEOF
  echo

  echo "---Session Quality Reflection (Reflection Automation) ---"
  REFLECTION_FILE="${LOG_DIR}/reflection-digest.md"
  _GC_LOG_DIR="${LOG_DIR}" _GC_REFLECTION_FILE="${REFLECTION_FILE}" \
  python3 <<'PYEOF' 2>&1 || echo "[ERROR] reflection failed"
import json, os, sys
from collections import Counter
from datetime import datetime, timezone, timedelta

log_dir = os.environ['_GC_LOG_DIR']
projects_dir = os.path.join(log_dir, 'projects')
output_file = os.environ['_GC_REFLECTION_FILE']

if not os.path.isdir(projects_dir):
    print('No project data, skip')
    sys.exit(0)

now = datetime.now(timezone.utc)
cutoff_7d = (now - timedelta(days=7)).strftime('%Y-%m-%dT')

# Collect session-metrics of all projects
all_sessions = []
project_names = {}
for proj in os.listdir(projects_dir):
    proj_dir = os.path.join(projects_dir, proj)
    if not os.path.isdir(proj_dir):
        continue
    # Read project name
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
    print('No session data in the past 7 days, skip')
    sys.exit(0)

# Aggregation analysis
total_sessions = len(all_sessions)
total_events = sum(s.get('event_count', 0) for s in all_sessions)

# Decision distribution
decision_totals = Counter()
for s in all_sessions:
    for d, c in s.get('decisions', {}).items():
        decision_totals[d] += c

# Correct signal statistics
sessions_with_corrections = 0
all_correction_signals = Counter()
for s in all_sessions:
    sigs = s.get('correction_signals', [])
    if sigs:
        sessions_with_corrections += 1
        for sig in sigs:
            # Classify signals
            if 'repeated revision' in sig:
                all_correction_signals['File repeatedly corrected'] += 1
            elif 'high friction' in sig:
                all_correction_signals['High Friction Session'] += 1
            elif 'correction detection' in sig:
                all_correction_signals['Real-time correction trigger'] += 1
            elif 'upgrade warning' in sig:
                all_correction_signals['Upgrade warning'] += 1

# Hook trigger frequency
hook_totals = Counter()
for s in all_sessions:
    for h, c in s.get('hooks', {}).items():
        hook_totals[h] += c

# High warn rate sessions
high_friction = [s for s in all_sessions if s.get('warn_ratio', 0) > 0.4]

# Most frequently edited files
file_edits = Counter()
for s in all_sessions:
    for f, c in s.get('top_edited_files', {}).items():
        if f:
            file_edits[f] += c

# Generate reflection report
report = []
report.append(f'# VibeGuard Weekly Reflection Report')
report.append(f'')
report.append(f'> Generation time: {now.strftime("%Y-%m-%d %H:%M UTC")}')
report.append(f'>Coverage: Last 7 days')
report.append(f'')
report.append(f'## overview')
report.append(f'')
report.append(f'- Number of sessions: {total_sessions}')
report.append(f'-Total number of events: {total_events}')
report.append(f'- pass: {decision_totals.get("pass", 0)} | warn: {decision_totals.get("warn", 0)} | block: {decision_totals.get("block", 0)} | escalate: {decision_totals.get("escalate", 0)}')
total_decisions = sum(decision_totals.values())
overall_warn_rate = (decision_totals.get('warn', 0) + decision_totals.get('block', 0) + decision_totals.get('escalate', 0)) / max(total_decisions, 1)
report.append(f'- overall friction rate: {overall_warn_rate:.0%}')
report.append(f'')

if sessions_with_corrections > 0 or high_friction:
    report.append(f'##Correction signal')
    report.append(f'')
    report.append(f'- Sessions with correction signals: {sessions_with_corrections}/{total_sessions}')
    report.append(f'- High friction session (>40% warn): {len(high_friction)}')
    if all_correction_signals:
        report.append(f'- signal type:')
        for sig, count in all_correction_signals.most_common():
            report.append(f' - {sig}: {count} times')
    report.append(f'')

report.append(f'## Top trigger Hook')
report.append(f'')
for hook, count in hook_totals.most_common(5):
    report.append(f'- {hook}: {count} times')
report.append(f'')

if file_edits:
    report.append(f'## Hotspot files (high-frequency editing across sessions)')
    report.append(f'')
    for f, c in file_edits.most_common(5):
        basename = os.path.basename(f)
        report.append(f'- {basename}: {c} edits')
    report.append(f'')

# Improvement suggestions
suggestions = []
if overall_warn_rate > 0.3:
    suggestions.append('The overall friction rate is high → Check the reason for top warn and consider adding new rules or enhancing Hook prompts')
if sessions_with_corrections > total_sessions * 0.3:
    suggestions.append('More than 30% of sessions have correction signals → run /vibeguard:learn batch extraction mode')
top_hook = hook_totals.most_common(1)
if top_hook and top_hook[0][1] > total_events * 0.3:
    suggestions.append(f'{top_hook[0][0]} is triggered too frequently → check whether there are false positives or the rules are too strict')
if file_edits:
    top_file = file_edits.most_common(1)[0]
    if top_file[1] > 30:
        suggestions.append(f'{os.path.basename(top_file[0])} Edited {top_file[1]} times → Consider splitting components or reviewing the architecture')

if suggestions:
    report.append(f'## Improvement suggestions')
    report.append(f'')
    for i, s in enumerate(suggestions, 1):
        report.append(f'{i}. {s}')
    report.append(f'')
else:
    report.append(f'## Improvement suggestions')
    report.append(f'')
    report.append(f'There is no significant improvement signal this week, the system is running normally.')
    report.append(f'')

#Write to file
with open(output_file, 'w') as f:
    f.write('\n'.join(report))

print(f' Generate reflection report: {output_file}')
print(f' Sessions: {total_sessions}, Events: {total_events}, Friction rate: {overall_warn_rate:.0%}')
if suggestions:
    for s in suggestions:
        print(f'    - {s}')
PYEOF
  echo

  echo "GC completed"
} >> "${GC_LOG}" 2>&1

# Keep gc-cron.log no larger than 1MB
if [[ -f "${GC_LOG}" ]]; then
  SIZE=$(du -k "${GC_LOG}" | cut -f1)
  if [[ ${SIZE} -gt 1024 ]]; then
    tail -500 "${GC_LOG}" > "${GC_LOG}.tmp"
    mv "${GC_LOG}.tmp" "${GC_LOG}"
  fi
fi
