#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/hook_test_lib.sh"
hook_test_init

header "skills-loader — learn display is read-only"

loader_home="$(mktemp -d)"
loader_project="$(mktemp -d)"
mkdir -p "${loader_home}/.claude/skills/demo" "${loader_home}/.vibeguard"
hook_test_install_runtime_stub "$loader_home"
cat > "${loader_home}/.claude/skills/demo/SKILL.md" <<'SKILL'
---
name: demo
description: Rust demo skill
---
SKILL

python3 - "${loader_home}/.vibeguard/learn-digest.jsonl" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
with path.open("w", encoding="utf-8") as handle:
    signals = []
    for index in range(1, 7):
        signals.append({
            "type": "repeated_warn",
            "source": "events",
            "reason": f"pending-signal-{index}",
            "count": index + 10,
            "signal_id": f"lrn_pending_{index:02d}",
        })
    handle.write(json.dumps({"ts": "2026-06-24T00:00:00Z", "project": "abc12345", "signals": signals}) + "\n")
PY

first_out="$(
  cd "$loader_project"
  touch Cargo.toml
  HOME="$loader_home" VIBEGUARD_SESSION_ID="skills-loader-1" bash "$REPO_DIR/hooks/skills-loader.sh"
)"
second_out="$(
  cd "$loader_project"
  HOME="$loader_home" VIBEGUARD_SESSION_ID="skills-loader-2" bash "$REPO_DIR/hooks/skills-loader.sh"
)"

assert_contains "$first_out" "pending-signal-1" "loader displays first pending signal"
assert_contains "$first_out" "pending-signal-5" "loader displays fifth pending signal"
assert_not_contains "$first_out" "pending-signal-6" "loader display remains bounded to five signals"
assert_contains "$second_out" "pending-signal-1" "repeated display is stable without state transition"
assert_exit_nonzero "loader display does not create learn watermark" test -e "${loader_home}/.vibeguard/.learn-watermark"
assert_exit_nonzero "loader display does not create triage state" test -e "${loader_home}/.vibeguard/learn-state.jsonl"

for index in 1 2 3 4 5; do
  case "$index" in
    1|2)
      HOME="$loader_home" python3 "$REPO_DIR/scripts/learn/triage_state.py" adopt "lrn_pending_0${index}" --reason "accepted" >/dev/null
      ;;
    3|4)
      HOME="$loader_home" python3 "$REPO_DIR/scripts/learn/triage_state.py" skip "lrn_pending_0${index}" --reason "not useful" >/dev/null
      ;;
    5)
      HOME="$loader_home" _VIBEGUARD_TEST_NOW="2026-06-24T00:00:00Z" \
        python3 "$REPO_DIR/scripts/learn/triage_state.py" snooze "lrn_pending_05" --days 14 --reason "later" >/dev/null
      ;;
  esac
done

state_lines="$(wc -l < "${loader_home}/.vibeguard/learn-state.jsonl" | tr -d ' ')"
assert_exit_zero "triage transitions are append-only records" test "$state_lines" = "5"
third_out="$(
  cd "$loader_project"
  HOME="$loader_home" VIBEGUARD_SESSION_ID="skills-loader-3" bash "$REPO_DIR/hooks/skills-loader.sh"
)"
assert_contains "$third_out" "pending-signal-6" "undisplayed signal remains pending after visible signals are triaged"
assert_not_contains "$third_out" "pending-signal-1" "adopted signal is hidden from loader"
assert_not_contains "$third_out" "pending-signal-3" "skipped signal is hidden from loader"
assert_not_contains "$third_out" "pending-signal-5" "snoozed signal is hidden from loader"

cat >> "${loader_home}/.vibeguard/learn-state.jsonl" <<'JSON'
{"schema_version":1,"signal_id":"lrn_pending_01","from":"adopted","to":"regressed","reason":"recurred","ts":"2026-06-24T00:00:01Z"}
{"schema_version":1,"signal_id":"lrn_pending_06","from":"new","to":"snoozed","reason":"missing until","ts":"2026-06-24T00:00:02Z"}
JSON
fourth_out="$(
  cd "$loader_project"
  HOME="$loader_home" VIBEGUARD_SESSION_ID="skills-loader-4" bash "$REPO_DIR/hooks/skills-loader.sh"
)"
assert_contains "$fourth_out" "pending-signal-1" "regressed signal returns to loader"
assert_contains "$fourth_out" "pending-signal-6" "malformed snooze does not hide pending signal"

rm -rf "$loader_home" "$loader_project"

if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi

printf "\n==============================\n"
printf "Total: %d  Pass: %d  Fail: %d\n" "$TOTAL" "$PASS" "$FAIL"
printf "==============================\n"
