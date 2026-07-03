#!/usr/bin/env bash
# VibeGuard weekly health report regression testing
#
# Usage: bash tests/test_weekly_health_report.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${REPO_DIR}/scripts/weekly-health-report.sh"
PY_SCRIPT="${REPO_DIR}/scripts/weekly-health-report.py"

PASS=0
FAIL=0
TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }
header(){ printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

assert_contains() {
  local output="$1" expected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qF -- "$expected" <<< "$output"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (expected to contain: $expected)"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local output="$1" forbidden="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qF -- "$forbidden" <<< "$output"; then
    red "$desc (must not contain: $forbidden)"
    FAIL=$((FAIL + 1))
  else
    green "$desc"
    PASS=$((PASS + 1))
  fi
}

assert_cmd() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc"
    FAIL=$((FAIL + 1))
  fi
}

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

header "syntax"
assert_cmd "weekly health Python compiles" python3 -m py_compile "${PY_SCRIPT}"
assert_cmd "weekly health wrapper syntax is valid" bash -n "${SCRIPT}"

header "build"
assert_cmd "vibeguard-runtime builds for weekly health report" \
  cargo build --manifest-path "${REPO_DIR}/vibeguard-runtime/Cargo.toml" --quiet

header "fixtures"
rules_dir="${TMP_DIR}/rules"
skills_dir="${TMP_DIR}/skills"
mkdir -p "${rules_dir}" "${skills_dir}/used-skill" "${skills_dir}/unused-skill"
cat > "${rules_dir}/rules.md" <<'MD'
# Test Rules

## U-01: Used rule
Triggered in the fixture log.

## U-02: Pass rule
Triggered by a pass event.

## U-03: Zero trigger rule
Not triggered in the fixture log.
MD

cat > "${skills_dir}/used-skill/SKILL.md" <<'MD'
---
name: used-skill
description: Use when testing used skill detection.
---
MD

cat > "${skills_dir}/unused-skill/SKILL.md" <<'MD'
---
name: unused-skill
description: Use when testing zero skill detection.
---
MD

test_now="$(python3 - <<'PY'
from datetime import datetime, timezone
print(datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"))
PY
)"

events_file="${TMP_DIR}/events.jsonl"
triage_file="${TMP_DIR}/triage.jsonl"
scorecard_file="${TMP_DIR}/scorecard.json"
python3 - "${events_file}" "${triage_file}" "${scorecard_file}" "${test_now}" <<'PY'
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

events_path, triage_path, scorecard_path, now_raw = sys.argv[1:5]
now = datetime.fromisoformat(now_raw.replace("Z", "+00:00"))

events = [
    {
        "ts": (now - timedelta(days=1)).isoformat().replace("+00:00", "Z"),
        "session": "s1",
        "hook": "pre-bash-guard",
        "tool": "Bash",
        "decision": "warn",
        "reason": "U-01 warning",
        "detail": "echo hi",
        "skill": "used-skill",
    },
    {
        "ts": (now - timedelta(days=1, minutes=1)).isoformat().replace("+00:00", "Z"),
        "session": "s1",
        "hook": "post-edit-guard",
        "tool": "Edit",
        "decision": "block",
        "reason": "U-01 blocked",
        "detail": "src/lib.rs",
    },
    {
        "ts": (now - timedelta(hours=2)).isoformat().replace("+00:00", "Z"),
        "session": "s2",
        "hook": "pre-bash-guard",
        "tool": "Bash",
        "decision": "pass",
        "reason": "U-02 accepted",
        "detail": "cargo check",
    },
    {
        "ts": (now - timedelta(days=45)).isoformat().replace("+00:00", "Z"),
        "session": "old",
        "hook": "pre-bash-guard",
        "tool": "Bash",
        "decision": "warn",
        "reason": "U-03 old event outside window",
        "detail": "old",
    },
]
with Path(events_path).open("w", encoding="utf-8") as handle:
    for event in events:
        handle.write(json.dumps(event) + "\n")
    handle.write("{broken-json\n")
    handle.write("[]\n")

triage = [
    {"ts": now_raw, "rule": "U-01", "verdict": "tp"},
    {"ts": now_raw, "rule": "U-01", "verdict": "fp"},
    {"ts": now_raw, "rule": "U-02", "verdict": "unclassified"},
]
with Path(triage_path).open("w", encoding="utf-8") as handle:
    for record in triage:
        handle.write(json.dumps(record) + "\n")

scorecard = {
    "rules": {
        "U-01": {"stage": "warn", "precision": 0.5, "samples": 2, "tp": 1, "fp": 1, "acceptable": 0},
        "U-02": {"stage": "experimental", "precision": None, "samples": 0, "tp": 0, "fp": 0, "acceptable": 0},
    }
}
Path(scorecard_path).write_text(json.dumps(scorecard), encoding="utf-8")
PY

json_report="${TMP_DIR}/weekly-health.json"
_VIBEGUARD_TEST_NOW="${test_now}" bash "${SCRIPT}" \
  --log-file "${events_file}" \
  --triage-file "${triage_file}" \
  --scorecard-file "${scorecard_file}" \
  --rules-dir "${rules_dir}" \
  --skills-dir "${skills_dir}" \
  --json 30 > "${json_report}"

assert_cmd "weekly health JSON contract is populated" python3 - "${json_report}" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert data["schema_version"] == 1, data
assert data["report"] == "weekly_health", data
source = data["source"]
assert source["event_parse_errors"] == 1, source
assert source["event_non_object_lines"] == 1, source
assert source["events_loaded_for_window"] == 3, source

rules = {row["rule"]: row for row in data["rule_triggers"]}
assert rules["U-01"]["total"] == 2, rules
assert rules["U-01"]["warn"] == 1, rules
assert rules["U-01"]["block"] == 1, rules
assert rules["U-02"]["pass"] == 1, rules

precision = {row["rule"]: row for row in data["precision_attention"]}
assert precision["U-01"]["fp"] == 1, precision
assert precision["U-01"]["fp_rate"] == 0.5, precision
assert precision["U-02"]["unclassified"] == 1, precision

zero_rules = data["zero_usage"]["rules"]["items"]
assert zero_rules == ["U-03"], zero_rules
zero_skills = {item["name"] for item in data["zero_usage"]["skills"]["items"]}
assert "unused-skill" in zero_skills, zero_skills
assert "used-skill" not in zero_skills, zero_skills
PY

human_out="$(_VIBEGUARD_TEST_NOW="${test_now}" bash "${SCRIPT}" \
  --log-file "${events_file}" \
  --triage-file "${triage_file}" \
  --scorecard-file "${scorecard_file}" \
  --rules-dir "${rules_dir}" \
  --skills-dir "${skills_dir}" \
  30 2>&1)"
assert_contains "${human_out}" "VibeGuard Weekly Health Report (last 30 days)" "human report has title"
assert_contains "${human_out}" "Rule trigger counts" "human report includes rule trigger section"
assert_contains "${human_out}" "Precision attention" "human report includes precision section"
assert_contains "${human_out}" "Zero-usage rule candidates (1)" "human report includes zero-rule section"
assert_contains "${human_out}" "- U-03" "human report lists zero-trigger rule"
assert_contains "${human_out}" "Zero-usage skill candidates (1)" "human report includes zero-skill section"
assert_contains "${human_out}" "- unused-skill" "human report lists zero-use skill"
assert_not_contains "${human_out}" "- used-skill" "human report does not list used skill as zero-use"

if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi

printf "\n==============================\n"
printf "Total: %d  Pass: %d  Fail: %d\n" "$TOTAL" "$PASS" "$FAIL"
printf "==============================\n"
