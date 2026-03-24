#!/bin/bash
# 预填充 3 次 Read + 1 次 Edit + 2 次 Read（不超过连续阈值）
SID="test-session-$$"
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "global")
HASH=$(printf '%s' "$REPO_ROOT" | shasum -a 256 2>/dev/null | cut -c1-8)
PROJECT_LOG="${VIBEGUARD_LOG_DIR}/projects/${HASH}"
mkdir -p "$PROJECT_LOG"
{
  printf '{"ts":"2026-03-24T00:00:01Z","session":"%s","hook":"analysis-paralysis-guard","tool":"Read","decision":"pass","reason":"","detail":""}\n' "$SID"
  printf '{"ts":"2026-03-24T00:00:02Z","session":"%s","hook":"analysis-paralysis-guard","tool":"Read","decision":"pass","reason":"","detail":""}\n' "$SID"
  printf '{"ts":"2026-03-24T00:00:03Z","session":"%s","hook":"analysis-paralysis-guard","tool":"Read","decision":"pass","reason":"","detail":""}\n' "$SID"
  printf '{"ts":"2026-03-24T00:00:04Z","session":"%s","hook":"post-edit-guard","tool":"Edit","decision":"pass","reason":"","detail":""}\n' "$SID"
  printf '{"ts":"2026-03-24T00:00:05Z","session":"%s","hook":"analysis-paralysis-guard","tool":"Read","decision":"pass","reason":"","detail":""}\n' "$SID"
  printf '{"ts":"2026-03-24T00:00:06Z","session":"%s","hook":"analysis-paralysis-guard","tool":"Read","decision":"pass","reason":"","detail":""}\n' "$SID"
} > "$PROJECT_LOG/events.jsonl"
echo "ENV=VIBEGUARD_SESSION_ID=$SID"