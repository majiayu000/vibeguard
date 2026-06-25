#!/usr/bin/env bash
# VibeGuard scheduled GC integration tests.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

PASS=0
FAIL=0
TOTAL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }
header(){ printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

assert_contains() {
  local output="$1" expected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if printf '%s' "$output" | grep -qF -- "$expected"; then
    green "$desc"; PASS=$((PASS + 1))
  else
    red "$desc (expected to contain: $expected)"; FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local output="$1" unexpected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if ! printf '%s' "$output" | grep -qF -- "$unexpected"; then
    green "$desc"; PASS=$((PASS + 1))
  else
    red "$desc (unexpectedly contains: $unexpected)"; FAIL=$((FAIL + 1))
  fi
}

assert_cmd() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    green "$desc"; PASS=$((PASS + 1))
  else
    red "$desc"; FAIL=$((FAIL + 1))
  fi
}

header "gc-scheduled.py helpers compile"
assert_cmd "scheduled GC Python helpers compile" python3 -m py_compile \
  scripts/gc/session_metrics_cleanup.py \
  scripts/gc/learn_digest.py \
  scripts/learn/analyze.py \
  scripts/learn/adoption.py \
  scripts/learn/trajectory.py \
  scripts/gc/reflection_digest.py

header "gc-scheduled.sh orchestrates helpers"

log_dir="${TMP_ROOT}/logs"
project_dir="${log_dir}/projects/abc123"
mkdir -p "$project_dir"
today="$(date -u '+%Y-%m-%dT00:00:00Z')"

cat > "${project_dir}/session-metrics.jsonl" <<EOF
{"ts":"2020-01-01T00:00:00Z","event_count":1,"decisions":{"warn":1},"hooks":{"old":1},"top_edited_files":{"old.py":1}}
{"ts":"${today}","event_count":5,"decisions":{"pass":3,"warn":2},"hooks":{"post-edit-guard":2},"top_edited_files":{"src/app.py":2},"warn_ratio":0.4}
EOF
printf '%s\n' "$TMP_ROOT/project" > "${project_dir}/.project-root"
mkdir -p "$TMP_ROOT/project"

cfg="${TMP_ROOT}/.vibeguard.json"
cat > "$cfg" <<'JSON'
{
  "gc": {
    "session_metrics_retain_days": 30,
    "learning_window_days": 7,
    "gc_log_max_kb": 1024
  }
}
JSON

VIBEGUARD_LOG_DIR="$log_dir" VIBEGUARD_PROJECT_CONFIG="$cfg" bash scripts/gc/gc-scheduled.sh

gc_log="$(cat "${log_dir}/gc-cron.log")"
metrics_after="$(cat "${project_dir}/session-metrics.jsonl")"
reflection="$(cat "${log_dir}/reflection-digest.md")"

assert_contains "$gc_log" "--- Session Metrics Cleanup ---" "scheduled GC runs metrics cleanup section"
assert_contains "$gc_log" "Clean 1 expired metrics" "scheduled GC prunes expired metrics"
assert_contains "$gc_log" "--- Regular learning" "scheduled GC runs learning digest section"
assert_contains "$gc_log" "---Session Quality Reflection" "scheduled GC runs reflection section"
assert_contains "$metrics_after" "$today" "current session metric remains"
assert_not_contains "$metrics_after" "2020-01-01" "expired session metric is removed"
assert_contains "$reflection" "VibeGuard Weekly Reflection Report" "reflection report is generated"

header "learn_digest.py tolerates malformed UTF-8"

learn_log_dir="${TMP_ROOT}/learn-logs"
learn_project_dir="${learn_log_dir}/projects/badutf8"
learn_root="${TMP_ROOT}/learn-project"
stale_project_dir="${learn_log_dir}/projects/stale-code-scan"
stale_root="${TMP_ROOT}/stale-code-project"
mkdir -p "$learn_project_dir" "$learn_root" "$stale_project_dir" "${stale_root}/src"
printf '%s\n' "$learn_root" > "${learn_project_dir}/.project-root"
printf '%s\n' "$stale_root" > "${stale_project_dir}/.project-root"
printf '{"scripts":{}}\n' > "${stale_root}/package.json"
cat > "${stale_root}/src/stale.ts" <<'EOF'
export function stale(value: any): any {
  const one: any = value;
  const two: any = one;
  const three: any = two;
  const four: any = three;
  const five: any = four;
  return five;
}
EOF
printf '%s\n' '{"ts":"2020-01-01T00:00:00Z","session":"stale","decision":"warn","reason":"old-only"}' > "${stale_project_dir}/events.jsonl"
python3 - "${learn_project_dir}/events.jsonl" "$today" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
today = sys.argv[2]
with path.open("wb") as f:
    f.write(
        b'{"ts":"'
        + today.encode("utf-8")
        + b'","session":"bad-utf8","decision":"warn","reason":"recoverable-utf8-\xff"}\n'
    )
    for index in range(10):
        f.write(
            (
                json.dumps(
                    {
                        "ts": today,
                        "session": f"learn-{index}",
                        "decision": "warn",
                        "reason": "repeat-gc-warning",
                    }
                )
                + "\n"
            ).encode("utf-8")
        )
PY
learn_out="$(_GC_LOG_DIR="$learn_log_dir" _GC_VIBEGUARD_DIR="$REPO_DIR" _GC_LEARNING_WINDOW_DAYS=7 python3 scripts/gc/learn_digest.py 2>&1)"
learn_digest="$(cat "${learn_log_dir}/learn-digest.jsonl" 2>/dev/null || true)"

assert_not_contains "$learn_out" "UnicodeDecodeError" "learning digest tolerates malformed UTF-8 event bytes"
assert_cmd "learning digest writes output after malformed UTF-8" test -f "${learn_log_dir}/learn-digest.jsonl"
assert_contains "$learn_digest" "repeat-gc-warning" "learning digest keeps valid rows after malformed UTF-8"
assert_not_contains "$learn_digest" "$stale_root" "learning digest skips code scan for stale project activity"

header "learn_digest.py current-project preview"

preview_log_dir="${TMP_ROOT}/preview-logs"
preview_root="${TMP_ROOT}/preview-project"
preview_external_root="${TMP_ROOT}/external-project"
preview_hash="$(python3 - "$preview_root" <<'PY'
import hashlib
import sys

print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest()[:8])
PY
)"
preview_project_dir="${preview_log_dir}/projects/${preview_hash}"
preview_other_project_dir="${preview_log_dir}/projects/ffff0000"
mkdir -p "${preview_project_dir}" "${preview_root}/src" "${preview_external_root}" "${preview_other_project_dir}"
printf '%s\n' "$preview_root" > "${preview_project_dir}/.project-root"
printf '%s\n' "${TMP_ROOT}/other-project" > "${preview_other_project_dir}/.project-root"
git -C "$preview_root" init -q

python3 - "${preview_project_dir}/events.jsonl" "$today" "${preview_external_root}/outside.py" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
today = sys.argv[2]
external_path = sys.argv[3]
with path.open("w", encoding="utf-8") as f:
    for index in range(10):
        f.write(json.dumps({
            "ts": today,
            "session": f"warn-{index % 2}",
            "decision": "warn",
            "reason": "repeat-preview-warning",
        }) + "\n")
    for index in range(5):
        f.write(json.dumps({
            "ts": today,
            "session": f"block-{index}",
            "decision": "block",
            "reason": "repeat-preview-block",
        }) + "\n")
    for index in range(20):
        f.write(json.dumps({
            "ts": today,
            "session": f"edit-{index % 3}",
            "tool": "Edit",
            "decision": "pass",
            "detail": f"src/hot.py||delta={index}",
        }) + "\n")
    for index in range(25):
        f.write(json.dumps({
            "ts": today,
            "session": f"external-{index % 4}",
            "tool": "Edit",
            "decision": "pass",
            "detail": f"{external_path}||delta={index}",
        }) + "\n")
PY

python3 - "${preview_other_project_dir}/events.jsonl" "$today" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
today = sys.argv[2]
with path.open("w", encoding="utf-8") as f:
    for index in range(10):
        f.write(json.dumps({
            "ts": today,
            "session": f"other-{index}",
            "decision": "warn",
            "reason": "other-project-warning",
        }) + "\n")
PY

preview_json="${TMP_ROOT}/learn-preview.json"
VIBEGUARD_LOG_DIR="$preview_log_dir" python3 scripts/gc/learn_digest.py \
  --scope current \
  --project-root "$preview_root" \
  --dry-run \
  --format json \
  --output "$preview_json" \
  --no-code-scan

assert_cmd "current preview does not append learn digest" test ! -e "${preview_log_dir}/learn-digest.jsonl"
assert_cmd "current preview does not write learn watermark" test ! -e "${preview_log_dir}/.learn-watermark"
assert_cmd "current preview resolves one project and attributes paths" python3 - "$preview_json" "$preview_root" "${preview_external_root}/outside.py" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
project_root = str(Path(sys.argv[2]).resolve())
external_path = str(Path(sys.argv[3]).resolve())
assert data["scope"] == "current", data
assert data["partial"] is False, data
assert len(data["projects"]) == 1, data["projects"]
project = data["projects"][0]
assert project["project_root"] == project_root, project
signals = project["signals"]
assert not any(signal.get("reason") == "other-project-warning" for signal in signals), signals
warn = next(signal for signal in signals if signal["type"] == "repeated_warn")
assert warn["reason"] == "repeat-preview-warning", warn
assert warn["affected_sessions"] == 2, warn
block = next(signal for signal in signals if signal["type"] == "chronic_block")
assert block["reason"] == "repeat-preview-block", block
assert block["affected_sessions"] == 5, block
hot_files = [signal for signal in signals if signal["type"] == "hot_files"]
assert len(hot_files) == 1, hot_files
assert hot_files[0]["file"] == "src/hot.py", hot_files
assert hot_files[0]["path_relation"] == "in_project", hot_files
assert hot_files[0]["affected_sessions"] == 3, hot_files
assert external_path not in json.dumps(hot_files), hot_files
diagnostic = next(item for item in project["diagnostics"] if item["path_relation"] == "external")
assert diagnostic["path"] == external_path, diagnostic
assert diagnostic["classification"] == "noise", diagnostic
assert diagnostic["affected_sessions"] == 4, diagnostic
assert all(signal.get("signal_id", "").startswith("learn:") for signal in signals), signals
PY

preview_hash_json="${TMP_ROOT}/learn-preview-hash.json"
VIBEGUARD_LOG_DIR="$preview_log_dir" python3 scripts/gc/learn_digest.py \
  --scope current \
  --project-hash "$preview_hash" \
  --format json \
  --output "$preview_hash_json" \
  --no-code-scan
assert_cmd "current preview supports project hash resolution" python3 - "$preview_hash_json" "$preview_hash" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert len(data["projects"]) == 1, data
assert data["projects"][0]["project"] == sys.argv[2], data
PY

preview_subdir_json="${TMP_ROOT}/learn-preview-subdir.json"
VIBEGUARD_LOG_DIR="$preview_log_dir" python3 scripts/gc/learn_digest.py \
  --scope current \
  --project-root "$preview_root/src" \
  --format json \
  --output "$preview_subdir_json" \
  --no-code-scan
assert_cmd "current preview resolves project root subdirectories through git" python3 - "$preview_subdir_json" "$preview_hash" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert len(data["projects"]) == 1, data
assert data["projects"][0]["project"] == sys.argv[2], data
PY

unknown_hash="unknown1"
unknown_project_dir="${preview_log_dir}/projects/${unknown_hash}"
mkdir -p "$unknown_project_dir"
python3 - "${unknown_project_dir}/events.jsonl" "$today" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
today = sys.argv[2]
with path.open("w", encoding="utf-8") as f:
    for index in range(20):
        f.write(json.dumps({
            "ts": today,
            "session": f"unknown-{index % 2}",
            "tool": "Edit",
            "decision": "pass",
            "detail": "legacy/hot.py",
        }) + "\n")
PY
preview_unknown_json="${TMP_ROOT}/learn-preview-unknown.json"
VIBEGUARD_LOG_DIR="$preview_log_dir" python3 scripts/gc/learn_digest.py \
  --scope current \
  --project-hash "$unknown_hash" \
  --format json \
  --output "$preview_unknown_json" \
  --no-code-scan
assert_cmd "hash preview keeps hot files when project root is unknown" python3 - "$preview_unknown_json" "$unknown_hash" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
project = data["projects"][0]
assert project["project"] == sys.argv[2], project
hot = next(signal for signal in project["signals"] if signal["type"] == "hot_files")
assert hot["file"] == "legacy/hot.py", hot
assert hot["path_relation"] == "unknown", hot
assert hot["affected_sessions"] == 2, hot
PY

preview_json_again="${TMP_ROOT}/learn-preview-again.json"
VIBEGUARD_LOG_DIR="$preview_log_dir" python3 scripts/gc/learn_digest.py \
  --scope current \
  --project-root "$preview_root" \
  --format json \
  --output "$preview_json_again" \
  --no-code-scan
assert_cmd "current preview signal IDs are stable" python3 - "$preview_json" "$preview_json_again" <<'PY'
import json
import sys
from pathlib import Path

def stable_ids(path):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    signals = data["projects"][0]["signals"]
    return sorted((signal["type"], signal.get("reason") or signal.get("file"), signal["signal_id"]) for signal in signals)

assert stable_ids(sys.argv[1]) == stable_ids(sys.argv[2])
PY

preview_budget_json="${TMP_ROOT}/learn-preview-budget.json"
VIBEGUARD_LOG_DIR="$preview_log_dir" python3 scripts/gc/learn_digest.py \
  --scope current \
  --project-root "$preview_root" \
  --format json \
  --output "$preview_budget_json" \
  --budget-ms 0 \
  --no-code-scan
assert_cmd "current preview reports budget truncation" python3 - "$preview_budget_json" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert data["partial"] is True, data
assert data["truncated_reason"] == "budget_ms", data
PY

preview_guard_dir="${TMP_ROOT}/preview-guard-vibeguard"
mkdir -p "${preview_guard_dir}/guards/universal"
cat > "${preview_guard_dir}/guards/universal/check_code_slop.sh" <<'SH'
#!/usr/bin/env bash
for i in 1 2 3 4 5; do
  echo "[SLOP] finding ${i}"
done
exit 1
SH
chmod +x "${preview_guard_dir}/guards/universal/check_code_slop.sh"

preview_guard_violation_json="${TMP_ROOT}/learn-preview-guard-violation.json"
VIBEGUARD_LOG_DIR="$preview_log_dir" VIBEGUARD_REPO_DIR="$preview_guard_dir" python3 scripts/gc/learn_digest.py \
  --scope current \
  --project-root "$preview_root" \
  --format json \
  --output "$preview_guard_violation_json" \
  --guard-timeout 1 \
  --code-scan
assert_cmd "current preview treats guard findings as scan results" python3 - "$preview_guard_violation_json" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
project = data["projects"][0]
signal = next(item for item in project["signals"] if item.get("source") == "code_scan")
assert signal["type"] == "linter_violations", signal
assert signal["guard"] == "code_slop", signal
assert signal["count"] == 5, signal
assert not any(item.get("error") == "guard_exit:1" for item in project["diagnostics"]), project
PY

fresh_scan_root="${TMP_ROOT}/fresh-code-scan"
mkdir -p "$fresh_scan_root"
fresh_scan_json="${TMP_ROOT}/learn-preview-fresh-code-scan.json"
VIBEGUARD_LOG_DIR="$preview_log_dir" VIBEGUARD_REPO_DIR="$preview_guard_dir" python3 scripts/gc/learn_digest.py \
  --scope current \
  --project-root "$fresh_scan_root" \
  --format json \
  --output "$fresh_scan_json" \
  --guard-timeout 1 \
  --code-scan
assert_cmd "explicit current code scan runs without log activity" python3 - "$fresh_scan_json" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
project = data["projects"][0]
assert project["has_recent_activity"] is False, project
signal = next(item for item in project["signals"] if item.get("source") == "code_scan")
assert signal["type"] == "linter_violations", signal
assert signal["count"] == 5, signal
PY

cat > "${preview_guard_dir}/guards/universal/check_code_slop.sh" <<'SH'
#!/usr/bin/env bash
echo "guard crashed" >&2
exit 2
SH

preview_guard_json="${TMP_ROOT}/learn-preview-guard.json"
VIBEGUARD_LOG_DIR="$preview_log_dir" VIBEGUARD_REPO_DIR="$preview_guard_dir" python3 scripts/gc/learn_digest.py \
  --scope current \
  --project-root "$preview_root" \
  --format json \
  --output "$preview_guard_json" \
  --guard-timeout 1 \
  --code-scan
assert_cmd "current preview reports guard subprocess failures" python3 - "$preview_guard_json" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
diagnostics = data["projects"][0]["diagnostics"]
runtime = next(item for item in diagnostics if item.get("classification") == "runtime_health")
assert runtime["error"] == "guard_exit:2", runtime
assert runtime["examples"] == ["guard crashed"], runtime
PY

header "gc-scheduled.sh catch-up mode"

skip_log_before="$(wc -l < "${log_dir}/gc-cron.log" | tr -d ' ')"
VIBEGUARD_LOG_DIR="$log_dir" VIBEGUARD_PROJECT_CONFIG="$cfg" bash scripts/gc/gc-scheduled.sh --scheduled
skip_log_after="$(wc -l < "${log_dir}/gc-cron.log" | tr -d ' ')"
assert_cmd "scheduled mode skips when last success is fresh and logs are below threshold" test "$skip_log_before" = "$skip_log_after"

python3 - "${log_dir}/events.jsonl" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
path.parent.mkdir(parents=True, exist_ok=True)
with path.open("w", encoding="utf-8") as f:
    for index in range(20000):
        f.write(json.dumps({
            "ts": "2024-01-01T00:00:00Z",
            "session": "oversized",
            "hook": "pre-bash-guard",
            "tool": "Bash",
            "decision": "pass",
            "detail": "x" * 80,
            "index": index,
        }) + "\n")
    f.write(json.dumps({
        "ts": "2099-01-01T00:00:00Z",
        "session": "current",
        "hook": "pre-bash-guard",
        "tool": "Bash",
        "decision": "pass",
        "detail": "current",
    }) + "\n")
PY

VIBEGUARD_LOG_DIR="$log_dir" VIBEGUARD_PROJECT_CONFIG="$cfg" VIBEGUARD_GC_LOG_THRESHOLD_MB=1 \
  VIBEGUARD_GC_ARCHIVE_RETAIN_MONTHS=1200 \
  bash scripts/gc/gc-scheduled.sh --scheduled

assert_cmd "scheduled mode catches up when global log exceeds threshold" test -f "${log_dir}/archive/events-2024-01.jsonl.gz"
assert_contains "$(cat "${log_dir}/events.jsonl")" "current" "catch-up retains current log events"
assert_contains "$(cat "${log_dir}/gc-cron.log")" "--- Log archive ---" "catch-up records archive section"

printf '%s\n' "123" > "${log_dir}/gc-last-success"
python3 - "${log_dir}/events.jsonl" "$(date -u '+%Y-%m-01T00:00:00Z')" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
ts = sys.argv[2]
with path.open("w", encoding="utf-8") as f:
    for index in range(20000):
        f.write(json.dumps({
            "ts": ts,
            "session": "current-oversized",
            "hook": "pre-bash-guard",
            "tool": "Bash",
            "decision": "pass",
            "detail": "y" * 80,
            "index": index,
        }) + "\n")
PY

VIBEGUARD_LOG_DIR="$log_dir" VIBEGUARD_PROJECT_CONFIG="$cfg" VIBEGUARD_GC_LOG_THRESHOLD_MB=1 \
  bash scripts/gc/gc-scheduled.sh --scheduled

assert_cmd "failed scheduled GC records an attempt" test -f "${log_dir}/gc-last-attempt"
assert_contains "$(cat "${log_dir}/gc-last-success")" "123" "failed scheduled GC does not update last-success"
assert_contains "$(cat "${log_dir}/gc-cron.log")" "GC completed with errors" "failed scheduled GC is visible in cron log"

header "learn adoption and trajectory regressions"
assert_cmd "learn adoption regression suite passes" bash tests/test_learn_adoption.sh
assert_cmd "learn trajectory regression suite passes" bash tests/test_learn_trajectory.sh

printf '\n==============================\n'
printf 'Total: %s  Pass: \033[32m%s\033[0m  Fail: \033[31m%s\033[0m\n' "$TOTAL" "$PASS" "$FAIL"
printf '==============================\n'

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
