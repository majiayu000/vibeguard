#!/bin/bash
# 预填充 7 次连续 Read 事件（达到阈值 7）
# 必须写到与 log.sh 一致的项目日志路径
SID="test-session-$$"
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "global")
HASH=$(printf '%s' "$REPO_ROOT" | shasum -a 256 2>/dev/null | cut -c1-8)
PROJECT_LOG="${VIBEGUARD_LOG_DIR}/projects/${HASH}"
mkdir -p "$PROJECT_LOG"
for i in $(seq 1 7); do
  printf '{"ts":"2026-03-24T00:00:%02dZ","session":"%s","hook":"analysis-paralysis-guard","tool":"Read","decision":"pass","reason":"consecutive_reads=%d","detail":""}\n' "$i" "$SID" "$i"
done > "$PROJECT_LOG/events.jsonl"
echo "ENV=VIBEGUARD_SESSION_ID=$SID"