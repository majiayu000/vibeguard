#!/usr/bin/env bash
# VibeGuard Hook Latency Benchmark
#
# Measures actual execution time of each hook under different data scales.
# SLA: every hook fixture has a P95 latency budget. P99 is reported for tail-latency tracking.
#
# Usage:
#   bash tests/bench_hook_latency.sh              # normal run
#   bash tests/bench_hook_latency.sh --json       # JSON output for CI
#   bash tests/bench_hook_latency.sh --fail-on-regression  # exit 1 if a fixture exceeds its budget
#
# Requires: perl (for hi-res timing) or python3

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS_DIR="${REPO_DIR}/hooks"
RESULTS_FILE=""
FAIL_ON_REGRESSION=false
GLOBAL_SLA_MS=""
DEFAULT_BUDGET_MS=300
RUNS=5
INCLUDE_SLOW_FIXTURE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) RESULTS_FILE="${REPO_DIR}/data/bench-latency-$(date +%Y%m%d).json"; shift ;;
    --fail-on-regression) FAIL_ON_REGRESSION=true; shift ;;
    --sla=*) GLOBAL_SLA_MS="${1#--sla=}"; shift ;;
    --runs=*) RUNS="${1#--runs=}"; shift ;;
    --include-slow-fixture) INCLUDE_SLOW_FIXTURE=true; shift ;;
    *) shift ;;
  esac
done

# --- High-resolution timer (ms) ---
_now_ms() {
  if command -v perl &>/dev/null; then
    perl -MTime::HiRes=time -e 'printf "%.0f", time*1000'
  elif command -v python3 &>/dev/null; then
    python3 -c 'import time; print(int(time.time()*1000))'
  else
    echo "$(date +%s)000"
  fi
}

# --- Generate mock data ---
TMPDIR_BENCH=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BENCH"' EXIT

# Small events.jsonl (100 lines)
python3 -c "
import json
for i in range(100):
    print(json.dumps({'ts':'2026-04-13T10:00:00Z','session':'bench','hook':'post-edit-guard','tool':'Edit','decision':'pass','reason':'','detail':f'src/file{i}.rs'}))
" > "$TMPDIR_BENCH/events-100.jsonl"

# Large events.jsonl (5000 lines)
python3 -c "
import json
for i in range(5000):
    print(json.dumps({'ts':'2026-04-13T10:00:00Z','session':'bench','hook':'post-edit-guard','tool':'Edit','decision':'pass','reason':'','detail':f'src/file{i%50}.rs'}))
" > "$TMPDIR_BENCH/events-5000.jsonl"

# Mock Edit input JSON
cat > "$TMPDIR_BENCH/edit-input.json" <<'EOF'
{"tool_input":{"file_path":"src/main.rs","old_string":"fn main()","new_string":"fn main() {\n    println!(\"hello\");\n}"}}
EOF

# Mock Write input JSON
cat > "$TMPDIR_BENCH/write-input.json" <<'EOF'
{"tool_input":{"file_path":"src/new_file.rs","content":"fn main() {\n    println!(\"hello\");\n}\n"}}
EOF

# Mock Bash input JSON
cat > "$TMPDIR_BENCH/bash-input.json" <<'EOF'
{"tool_input":{"command":"cargo check"}}
EOF

# Mock Stop input JSON
cat > "$TMPDIR_BENCH/stop-input.json" <<'EOF'
{"stop_hook_active":false}
EOF

# --- Benchmark runner ---
RESULTS=()
FAILURES=0

budget_for() {
  local name="$1"
  if [[ -n "$GLOBAL_SLA_MS" ]]; then
    printf '%s\n' "$GLOBAL_SLA_MS"
    return 0
  fi

  case "$name" in
    pre-edit-guard|pre-bash-guard) printf '%s\n' 300 ;;
    pre-write-guard) printf '%s\n' 500 ;;
    post-edit-guard\ \(100\)) printf '%s\n' 500 ;;
    post-write-guard\ \(100\)) printf '%s\n' 400 ;;
    post-edit-guard\ \(5000\)|post-write-guard\ \(5000\)) printf '%s\n' 500 ;;
    stop-guard\ \(5000\)|learn-evaluator\ \(5000\)) printf '%s\n' 400 ;;
    synthetic-slow-hook) printf '%s\n' 1 ;;
    *) printf '%s\n' "$DEFAULT_BUDGET_MS" ;;
  esac
}

bench_hook() {
  local name="$1"
  local hook_script="$2"
  local input_file="$3"
  local events_file="${4:-}"
  local budget_ms="${5:-$(budget_for "$name")}"
  local hotspot="${6:-${name}}"
  local latencies=()

  for _run in $(seq 1 "$RUNS"); do
    # Keep benchmark runs isolated from the caller's ambient project log and
    # avoid measuring parent-process session discovery instead of hook work.
    local bench_log_file="${events_file:-$TMPDIR_BENCH/events-bench.jsonl}"
    local env_prefix="VIBEGUARD_LOG_DIR=$TMPDIR_BENCH VIBEGUARD_LOG_FILE=$bench_log_file VIBEGUARD_SESSION_ID=bench VIBEGUARD_CLI=bench VIBEGUARD_PROJECT_HASH=bench000 VIBEGUARD_PROJECT_LOG_DIR=$TMPDIR_BENCH"

    local start=$(_now_ms)
    env $env_prefix bash "$hook_script" < "$input_file" > /dev/null 2>&1 || true
    local end=$(_now_ms)
    local elapsed=$((end - start))
    latencies+=("$elapsed")
  done

  # Calculate P50/P95/P99/max
  local sorted
  sorted=$(printf '%s\n' "${latencies[@]}" | sort -n)
  local count=${#latencies[@]}
  local p50_idx=$(( (count * 50 / 100) ))
  local p95_idx=$(( (count * 95 / 100) ))
  local p99_idx=$(( (count * 99 / 100) ))
  [[ $p50_idx -ge $count ]] && p50_idx=$((count - 1))
  [[ $p95_idx -ge $count ]] && p95_idx=$((count - 1))
  [[ $p99_idx -ge $count ]] && p99_idx=$((count - 1))

  local p50=$(echo "$sorted" | sed -n "$((p50_idx + 1))p")
  local p95=$(echo "$sorted" | sed -n "$((p95_idx + 1))p")
  local p99=$(echo "$sorted" | sed -n "$((p99_idx + 1))p")
  local max_lat=$(echo "$sorted" | tail -1)

  local status="PASS"
  if [[ "$p95" -gt "$budget_ms" ]]; then
    status="FAIL"
    FAILURES=$((FAILURES + 1))
  fi

  printf "  %-35s P50=%4dms  P95=%4dms  P99=%4dms  max=%4dms  budget=%4dms  hotspot=%s  [%s]\n" "$name" "$p50" "$p95" "$p99" "$max_lat" "$budget_ms" "$hotspot" "$status"

  RESULTS+=("{\"name\":\"$name\",\"p50\":$p50,\"p95\":$p95,\"p99\":$p99,\"max\":$max_lat,\"budget_ms\":$budget_ms,\"hotspot\":\"$hotspot\",\"status\":\"$status\",\"runs\":$RUNS}")
}

echo "======================================"
echo "VibeGuard Hook Latency Benchmark"
if [[ -n "$GLOBAL_SLA_MS" ]]; then
  echo "Budget mode: global <${GLOBAL_SLA_MS}ms (P95)  Runs: ${RUNS}  Tail: P99/max reported"
else
  echo "Budget mode: per-hook P95 budgets  Runs: ${RUNS}  Tail: P99/max reported"
fi
echo "======================================"
echo ""

# --- Pre-hooks (lightweight, should be <50ms) ---
echo "[PreToolUse hooks]"
bench_hook "pre-edit-guard" "$HOOKS_DIR/pre-edit-guard.sh" "$TMPDIR_BENCH/edit-input.json"
bench_hook "pre-write-guard" "$HOOKS_DIR/pre-write-guard.sh" "$TMPDIR_BENCH/write-input.json"
bench_hook "pre-bash-guard" "$HOOKS_DIR/pre-bash-guard.sh" "$TMPDIR_BENCH/bash-input.json"
echo ""

# --- Post-hooks with small log (should be <100ms) ---
echo "[PostToolUse hooks — 100-line log]"
bench_hook "post-edit-guard (100)" "$HOOKS_DIR/post-edit-guard.sh" "$TMPDIR_BENCH/edit-input.json" "$TMPDIR_BENCH/events-100.jsonl"
bench_hook "post-write-guard (100)" "$HOOKS_DIR/post-write-guard.sh" "$TMPDIR_BENCH/write-input.json" "$TMPDIR_BENCH/events-100.jsonl"
echo ""

# --- Post-hooks with large log (stress test, should still be <200ms) ---
echo "[PostToolUse hooks — 5000-line log]"
bench_hook "post-edit-guard (5000)" "$HOOKS_DIR/post-edit-guard.sh" "$TMPDIR_BENCH/edit-input.json" "$TMPDIR_BENCH/events-5000.jsonl"
bench_hook "post-write-guard (5000)" "$HOOKS_DIR/post-write-guard.sh" "$TMPDIR_BENCH/write-input.json" "$TMPDIR_BENCH/events-5000.jsonl"
echo ""

# --- Stop hooks ---
echo "[Stop hooks — 5000-line log]"
bench_hook "stop-guard (5000)" "$HOOKS_DIR/stop-guard.sh" "$TMPDIR_BENCH/stop-input.json" "$TMPDIR_BENCH/events-5000.jsonl"
bench_hook "learn-evaluator (5000)" "$HOOKS_DIR/learn-evaluator.sh" "$TMPDIR_BENCH/stop-input.json" "$TMPDIR_BENCH/events-5000.jsonl"
echo ""

if [[ "$INCLUDE_SLOW_FIXTURE" == "true" ]]; then
  cat > "$TMPDIR_BENCH/synthetic-slow-hook.sh" <<'EOF'
#!/usr/bin/env bash
sleep 0.05
exit 0
EOF
  chmod +x "$TMPDIR_BENCH/synthetic-slow-hook.sh"
  echo "[Synthetic latency gate fixture]"
  bench_hook "synthetic-slow-hook" "$TMPDIR_BENCH/synthetic-slow-hook.sh" "$TMPDIR_BENCH/stop-input.json" "" 1 "synthetic sleep fixture"
  echo ""
fi

# --- Summary ---
echo "======================================"
if [[ $FAILURES -gt 0 ]]; then
  printf "\033[31mFAILED: %d hook fixture(s) exceeded latency budget\033[0m\n" "$FAILURES"
else
  printf "\033[32mPASSED: All hooks within latency budget\033[0m\n"
fi

# --- JSON output (internal format) ---
if [[ -n "$RESULTS_FILE" ]]; then
  mkdir -p "$(dirname "$RESULTS_FILE")"
  printf '{"date":"%s","budget_mode":"%s","global_sla_ms":"%s","runs":%d,"results":[%s]}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$([[ -n "$GLOBAL_SLA_MS" ]] && printf global || printf per-hook)" \
    "${GLOBAL_SLA_MS}" \
    "$RUNS" \
    "$(IFS=,; echo "${RESULTS[*]}")" \
    > "$RESULTS_FILE"
  echo "Results: $RESULTS_FILE"
fi

# --- benchmark-action compatible output (customSmallerIsBetter) ---
# Always write to bench-output.json for CI consumption
BENCH_ACTION_FILE="${REPO_DIR}/bench-output.json"
_first=true
{
  echo "["
  for r in "${RESULTS[@]}"; do
    _name=$(echo "$r" | python3 -c "import json,sys; print(json.load(sys.stdin)['name'])" 2>/dev/null || echo "unknown")
    _p50=$(echo "$r" | python3 -c "import json,sys; print(json.load(sys.stdin)['p50'])" 2>/dev/null || echo "0")
    _p95=$(echo "$r" | python3 -c "import json,sys; print(json.load(sys.stdin)['p95'])" 2>/dev/null || echo "0")
    _p99=$(echo "$r" | python3 -c "import json,sys; print(json.load(sys.stdin)['p99'])" 2>/dev/null || echo "0")
    if [[ "$_first" == "true" ]]; then _first=false; else echo ","; fi
    printf '  {"name": "%s (P50)", "unit": "ms", "value": %s}' "$_name" "$_p50"
    echo ","
    printf '  {"name": "%s (P95)", "unit": "ms", "value": %s}' "$_name" "$_p95"
    echo ","
    printf '  {"name": "%s (P99)", "unit": "ms", "value": %s}' "$_name" "$_p99"
  done
  echo ""
  echo "]"
} > "$BENCH_ACTION_FILE"
echo "Benchmark Action output: $BENCH_ACTION_FILE"

echo "======================================"

if [[ "$FAIL_ON_REGRESSION" == "true" ]] && [[ $FAILURES -gt 0 ]]; then
  exit 1
fi
