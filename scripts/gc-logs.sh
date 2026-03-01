#!/usr/bin/env bash
# VibeGuard GC — 日志归档
#
# events.jsonl 超过阈值时按月归档（gzip），保留最近 3 个月。
#
# 用法：
#   bash gc-logs.sh              # 默认 10MB 阈值
#   bash gc-logs.sh --threshold 5  # 5MB 阈值
#   bash gc-logs.sh --dry-run    # 只报告，不执行

set -euo pipefail

green() { printf '\033[32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }
red() { printf '\033[31m%s\033[0m\n' "$1"; }

LOG_DIR="${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}"
LOG_FILE="${LOG_DIR}/events.jsonl"
ARCHIVE_DIR="${LOG_DIR}/archive"
THRESHOLD_MB=10
DRY_RUN=false
RETAIN_MONTHS=3

while [[ $# -gt 0 ]]; do
  case "$1" in
    --threshold) THRESHOLD_MB="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --retain) RETAIN_MONTHS="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ ! -f "$LOG_FILE" ]]; then
  yellow "日志文件不存在: ${LOG_FILE}"
  exit 0
fi

FILE_SIZE_MB=$(du -m "$LOG_FILE" | cut -f1)
echo "当前日志大小: ${FILE_SIZE_MB}MB (阈值: ${THRESHOLD_MB}MB)"

# 归档：超过阈值时按月拆分并压缩
if [[ "$FILE_SIZE_MB" -ge "$THRESHOLD_MB" ]]; then
  mkdir -p "$ARCHIVE_DIR"

  # 按月份分组归档
  python3 -c "
import json, sys, os
from collections import defaultdict

log_file = '${LOG_FILE}'
archive_dir = '${ARCHIVE_DIR}'
dry_run = ${DRY_RUN:+True} or False

months = defaultdict(list)
kept = []
cutoff_line = 0
total = 0

with open(log_file) as f:
    for line in f:
        total += 1
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
            ts = event.get('ts', '')
            month = ts[:7]  # YYYY-MM
            if month:
                months[month].append(line)
            else:
                kept.append(line)
        except json.JSONDecodeError:
            kept.append(line)

# 保留当月数据在主文件
sorted_months = sorted(months.keys())
if sorted_months:
    current_month = sorted_months[-1]
    kept.extend(months.pop(current_month))

archived = 0
for month, lines in sorted(months.items()):
    archive_path = os.path.join(archive_dir, f'events-{month}.jsonl')
    if dry_run:
        print(f'  [DRY-RUN] 归档 {len(lines)} 条 → {archive_path}')
    else:
        with open(archive_path, 'a') as af:
            af.write('\n'.join(lines) + '\n')
    archived += len(lines)

if not dry_run and archived > 0:
    with open(log_file, 'w') as f:
        f.write('\n'.join(kept) + '\n' if kept else '')
    os.chmod(log_file, 0o600)

print(f'总计 {total} 条，归档 {archived} 条，保留 {len(kept)} 条')
"

  # 压缩归档文件
  if [[ "$DRY_RUN" == "false" ]]; then
    for f in "${ARCHIVE_DIR}"/events-*.jsonl; do
      [[ -f "$f" ]] || continue
      gzip -f "$f" 2>/dev/null && green "已压缩: $(basename "$f").gz"
    done
  fi
else
  green "日志大小未超阈值，无需归档"
fi

# 清理过期归档：删除超过 RETAIN_MONTHS 的归档
if [[ -d "$ARCHIVE_DIR" ]]; then
  CUTOFF=$(date -v-${RETAIN_MONTHS}m +%Y-%m 2>/dev/null || date -d "${RETAIN_MONTHS} months ago" +%Y-%m 2>/dev/null || echo "")
  if [[ -n "$CUTOFF" ]]; then
    for f in "${ARCHIVE_DIR}"/events-*.jsonl.gz; do
      [[ -f "$f" ]] || continue
      MONTH=$(basename "$f" | sed 's/events-\(.*\)\.jsonl\.gz/\1/')
      if [[ "$MONTH" < "$CUTOFF" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
          yellow "  [DRY-RUN] 删除过期归档: $(basename "$f")"
        else
          rm "$f"
          yellow "已删除过期归档: $(basename "$f")"
        fi
      fi
    done
  fi
fi

green "日志 GC 完成"
