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
#   bash tests/bench_hook_latency.sh --bench-action-output=/tmp/bench-output.json
#   bash tests/bench_hook_latency.sh --no-bench-action-output
#
# Requires: perl (for hi-res timing) or python3. Codex wrapper fixtures also
# require a built vibeguard-runtime binary.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS_DIR="${REPO_DIR}/hooks"
BENCH_SURFACE="hook_e2e_ms"
RESULTS_FILE=""
BENCH_ACTION_FILE="${VIBEGUARD_BENCH_ACTION_OUTPUT:-${REPO_DIR}/bench-output.json}"
FAIL_ON_REGRESSION=false
GLOBAL_SLA_MS=""
DEFAULT_BUDGET_MS=300
RUNS=5
INCLUDE_SLOW_FIXTURE=false
SPAWN_BASELINE_MAX_MS="${VIBEGUARD_BENCH_SPAWN_MAX_MS:-10}"
SPAWN_BASELINE_MS=""
ENVIRONMENT_DISTORTED=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) RESULTS_FILE="${REPO_DIR}/.vibeguard/benchmarks/bench-latency-$(date +%Y%m%d).json"; shift ;;
    --json-output=*) RESULTS_FILE="${1#--json-output=}"; shift ;;
    --bench-action-output=*) BENCH_ACTION_FILE="${1#--bench-action-output=}"; shift ;;
    --no-bench-action-output) BENCH_ACTION_FILE=""; shift ;;
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

measure_spawn_baseline_ms() {
  if [[ -n "${VIBEGUARD_BENCH_SPAWN_BASELINE_MS:-}" ]]; then
    printf '%s\n' "${VIBEGUARD_BENCH_SPAWN_BASELINE_MS}"
    return 0
  fi

  if command -v perl &>/dev/null; then
    perl -MTime::HiRes=time -e '
      my @samples;
      for (1..5) {
        my $start = time;
        system("/usr/bin/true");
        push @samples, (time - $start) * 1000;
      }
      @samples = sort { $a <=> $b } @samples;
      printf "%.0f\n", $samples[-1];
    '
  elif command -v python3 &>/dev/null; then
    python3 - <<'PY'
import subprocess
import time

samples = []
for _ in range(5):
    start = time.perf_counter()
    subprocess.run(["/usr/bin/true"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    samples.append((time.perf_counter() - start) * 1000)
print(f"{sorted(samples)[-1]:.0f}")
PY
  else
    printf '0\n'
  fi
}

SPAWN_BASELINE_MS="$(measure_spawn_baseline_ms)"
if [[ "$SPAWN_BASELINE_MS" =~ ^[0-9]+$ && "$SPAWN_BASELINE_MAX_MS" =~ ^[0-9]+$ \
    && "$SPAWN_BASELINE_MS" -gt "$SPAWN_BASELINE_MAX_MS" ]]; then
  ENVIRONMENT_DISTORTED=true
fi

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

POST_BUILD_BENCH_PROJECT="$TMPDIR_BENCH/post-build-rust"
POST_BUILD_FAKE_BIN="$TMPDIR_BENCH/fake-bin"
mkdir -p "$POST_BUILD_BENCH_PROJECT/src" "$POST_BUILD_FAKE_BIN"
cat > "$POST_BUILD_BENCH_PROJECT/Cargo.toml" <<'EOF'
[package]
name = "post-build-bench"
version = "0.0.0"
edition = "2021"
EOF
cat > "$POST_BUILD_BENCH_PROJECT/src/lib.rs" <<'EOF'
pub fn value() -> i32 { 1 }
EOF
cat > "$POST_BUILD_FAKE_BIN/cargo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${VIBEGUARD_POST_BUILD_FAKE_COMMAND_LOG:?}"
exit 0
EOF
chmod +x "$POST_BUILD_FAKE_BIN/cargo"
cat > "$TMPDIR_BENCH/post-build-input.json" <<EOF
{"tool_input":{"file_path":"$POST_BUILD_BENCH_PROJECT/src/lib.rs"}}
EOF

# Mock Codex wrapper inputs. These fixtures keep the hook payload shape close to
# real Codex hook events while preserving the direct-hook fields under tool_input.
cat > "$TMPDIR_BENCH/codex-pre-bash-input.json" <<'EOF'
{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cargo check"}}
EOF

cat > "$TMPDIR_BENCH/codex-post-edit-input.json" <<'EOF'
{"hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{"file_path":"src/main.rs","old_string":"fn main()","new_string":"fn main() {\n    println!(\"hello\");\n}"},"tool_response":{"output":"ok"}}
EOF

# Mock Stop input JSON
cat > "$TMPDIR_BENCH/stop-input.json" <<'EOF'
{"stop_hook_active":false}
EOF

CODEX_BENCH_HOME="$TMPDIR_BENCH/codex-home"
CODEX_BENCH_WRAPPER="$CODEX_BENCH_HOME/.vibeguard/run-hook-codex.sh"
CODEX_BENCH_RUNTIME="$CODEX_BENCH_HOME/.vibeguard/installed/bin/vibeguard-runtime"
mkdir -p "$CODEX_BENCH_HOME/.vibeguard/_lib" "$CODEX_BENCH_HOME/.vibeguard/installed/bin"
printf '%s' "$REPO_DIR" > "$CODEX_BENCH_HOME/.vibeguard/repo-path"
cp "$HOOKS_DIR/run-hook-codex.sh" "$CODEX_BENCH_WRAPPER"
cp "$HOOKS_DIR/_lib/codex_diag.sh" "$CODEX_BENCH_HOME/.vibeguard/_lib/codex_diag.sh"
cp "$HOOKS_DIR/_lib/codex_runner.sh" "$CODEX_BENCH_HOME/.vibeguard/_lib/codex_runner.sh"
cp "$HOOKS_DIR/_lib/timeout.sh" "$CODEX_BENCH_HOME/.vibeguard/_lib/timeout.sh"
chmod +x "$CODEX_BENCH_WRAPPER"
for runtime_candidate in \
  "${VIBEGUARD_RUNTIME:-}" \
  "$REPO_DIR/vibeguard-runtime/target/debug/vibeguard-runtime" \
  "$REPO_DIR/vibeguard-runtime/target/release/vibeguard-runtime"; do
  if [[ -n "$runtime_candidate" && -x "$runtime_candidate" ]]; then
    cp "$runtime_candidate" "$CODEX_BENCH_RUNTIME"
    chmod +x "$CODEX_BENCH_RUNTIME"
    break
  fi
done
if [[ ! -x "$CODEX_BENCH_RUNTIME" ]]; then
  printf '%s\n' "ERROR: Codex wrapper benchmark requires vibeguard-runtime. Run: cargo build --manifest-path vibeguard-runtime/Cargo.toml" >&2
  exit 1
fi

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
    codex-wrapper\ pre-bash-guard|codex-wrapper\ post-edit-guard\ \(100\)) printf '%s\n' 900 ;;
    post-build-check\ \(fake\ cargo\)) printf '%s\n' 900 ;;
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
  local -a extra_env=()

  if [[ $# -gt 6 ]]; then
    shift 6
    extra_env=("$@")
  fi

  for _run in $(seq 1 "$RUNS"); do
    # Keep benchmark runs isolated from the caller's ambient project log and
    # avoid measuring parent-process session discovery instead of hook work.
    local bench_log_file="${events_file:-$TMPDIR_BENCH/events-bench.jsonl}"
    local -a hook_env=(
      "VIBEGUARD_LOG_DIR=$TMPDIR_BENCH"
      "VIBEGUARD_LOG_FILE=$bench_log_file"
      "VIBEGUARD_SESSION_ID=bench"
      "VIBEGUARD_CLI=bench"
      "VIBEGUARD_PROJECT_HASH=bench000"
      "VIBEGUARD_PROJECT_LOG_DIR=$TMPDIR_BENCH"
    )
    local -a run_env=("${hook_env[@]}")
    if [[ ${#extra_env[@]} -gt 0 ]]; then
      run_env+=("${extra_env[@]}")
    fi

    local start=$(_now_ms)
    env "${run_env[@]}" bash "$hook_script" < "$input_file" > /dev/null 2>&1 || true
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
    if [[ "$ENVIRONMENT_DISTORTED" == "true" ]]; then
      status="ENV-DISTORTED"
    else
      status="FAIL"
      FAILURES=$((FAILURES + 1))
    fi
  fi

  printf "  %-35s surface=%s  P50=%4dms  P95=%4dms  P99=%4dms  max=%4dms  budget=%4dms  hotspot=%s  [%s]\n" "$name" "$BENCH_SURFACE" "$p50" "$p95" "$p99" "$max_lat" "$budget_ms" "$hotspot" "$status"

  RESULTS+=("{\"name\":\"$name\",\"surface\":\"$BENCH_SURFACE\",\"p50\":$p50,\"p95\":$p95,\"p99\":$p99,\"max\":$max_lat,\"budget_ms\":$budget_ms,\"hotspot\":\"$hotspot\",\"status\":\"$status\",\"runs\":$RUNS}")
}

bench_codex_wrapper() {
  local name="$1"
  local hook_name="$2"
  local input_file="$3"
  local events_file="${4:-}"
  local budget_ms="${5:-$(budget_for "$name")}"
  local hotspot="${6:-~/.vibeguard/run-hook-codex.sh ${hook_name}}"
  local latencies=()

  for _run in $(seq 1 "$RUNS"); do
    local bench_log_file="${events_file:-$TMPDIR_BENCH/events-bench.jsonl}"
    local -a hook_env=(
      "HOME=$CODEX_BENCH_HOME"
      "VIBEGUARD_LOG_DIR=$TMPDIR_BENCH"
      "VIBEGUARD_LOG_FILE=$bench_log_file"
      "VIBEGUARD_SESSION_ID=bench"
      "VIBEGUARD_PROJECT_HASH=bench000"
      "VIBEGUARD_PROJECT_LOG_DIR=$TMPDIR_BENCH"
      "VIBEGUARD_CODEX_DIAG_FILE=$TMPDIR_BENCH/codex-wrapper.jsonl"
      "VIBEGUARD_POLICY_DIAG_FILE=$TMPDIR_BENCH/policy.jsonl"
      "VIBEGUARD_RUNTIME="
      "VIBEGUARD_POLICY_RUNTIME="
    )

    local start=$(_now_ms)
    env "${hook_env[@]}" bash "$CODEX_BENCH_WRAPPER" "$hook_name" < "$input_file" > /dev/null 2>&1 || true
    local end=$(_now_ms)
    local elapsed=$((end - start))
    latencies+=("$elapsed")
  done

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
    if [[ "$ENVIRONMENT_DISTORTED" == "true" ]]; then
      status="ENV-DISTORTED"
    else
      status="FAIL"
      FAILURES=$((FAILURES + 1))
    fi
  fi

  printf "  %-35s surface=%s  P50=%4dms  P95=%4dms  P99=%4dms  max=%4dms  budget=%4dms  hotspot=%s  [%s]\n" "$name" "$BENCH_SURFACE" "$p50" "$p95" "$p99" "$max_lat" "$budget_ms" "$hotspot" "$status"

  RESULTS+=("{\"name\":\"$name\",\"surface\":\"$BENCH_SURFACE\",\"p50\":$p50,\"p95\":$p95,\"p99\":$p99,\"max\":$max_lat,\"budget_ms\":$budget_ms,\"hotspot\":\"$hotspot\",\"status\":\"$status\",\"runs\":$RUNS}")
}

echo "======================================"
echo "VibeGuard Hook Latency Benchmark"
echo "Surface: ${BENCH_SURFACE} (end-to-end hook process latency)"
if [[ -n "$GLOBAL_SLA_MS" ]]; then
  echo "Budget mode: global <${GLOBAL_SLA_MS}ms (P95)  Runs: ${RUNS}  Tail: P99/max reported"
else
  echo "Budget mode: per-hook P95 budgets  Runs: ${RUNS}  Tail: P99/max reported"
fi
echo "Spawn baseline: /usr/bin/true P95=${SPAWN_BASELINE_MS}ms  threshold=${SPAWN_BASELINE_MAX_MS}ms"
if [[ "$ENVIRONMENT_DISTORTED" == "true" ]]; then
  echo "Environment distorted: spawn baseline exceeds threshold; latency SLA failures will be reported but not counted."
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

echo "[Post-build hooks — fake command]"
bench_hook "post-build-check (fake cargo)" "$HOOKS_DIR/post-build-check.sh" "$TMPDIR_BENCH/post-build-input.json" "$TMPDIR_BENCH/events-100.jsonl" "$(budget_for "post-build-check (fake cargo)")" "fake cargo check" "PATH=$POST_BUILD_FAKE_BIN:$PATH" "VIBEGUARD_POST_BUILD_CACHE_TTL=0" "VIBEGUARD_POST_BUILD_FAKE_COMMAND_LOG=$TMPDIR_BENCH/post-build-fake-command.log"
echo ""

echo "[Codex wrapper hooks]"
bench_codex_wrapper "codex-wrapper pre-bash-guard" "vibeguard-pre-bash-guard.sh" "$TMPDIR_BENCH/codex-pre-bash-input.json"
bench_codex_wrapper "codex-wrapper post-edit-guard (100)" "vibeguard-post-edit-guard.sh" "$TMPDIR_BENCH/codex-post-edit-input.json" "$TMPDIR_BENCH/events-100.jsonl"
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
elif [[ "$ENVIRONMENT_DISTORTED" == "true" ]]; then
  printf "\033[33mENVIRONMENT DISTORTED: spawn baseline too high; SLA verdict suppressed\033[0m\n"
else
  printf "\033[32mPASSED: All hooks within latency budget\033[0m\n"
fi

# --- JSON output (internal format) ---
if [[ -n "$RESULTS_FILE" ]]; then
  mkdir -p "$(dirname "$RESULTS_FILE")"
  printf '{"date":"%s","surface":"%s","budget_mode":"%s","global_sla_ms":"%s","runs":%d,"spawn_baseline_ms":%d,"environment_distorted":%s,"results":[%s]}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$BENCH_SURFACE" \
    "$([[ -n "$GLOBAL_SLA_MS" ]] && printf global || printf per-hook)" \
    "${GLOBAL_SLA_MS}" \
    "$RUNS" \
    "$SPAWN_BASELINE_MS" \
    "$ENVIRONMENT_DISTORTED" \
    "$(IFS=,; echo "${RESULTS[*]}")" \
    > "$RESULTS_FILE"
  echo "Results: $RESULTS_FILE"
fi

# --- benchmark-action compatible output (customSmallerIsBetter) ---
# Defaults to bench-output.json for CI consumption. Tests and audits can override
# or disable this to avoid writing repo-root artifacts.
bench_action_name() {
  case "$1" in
    "pre-edit-guard") printf "pre-edit" ;;
    "pre-write-guard") printf "pre-write" ;;
    "pre-bash-guard") printf "pre-bash" ;;
    "post-edit-guard (100)") printf "post-edit 100" ;;
    "post-write-guard (100)") printf "post-write 100" ;;
    "post-build-check (fake cargo)") printf "post-build fake" ;;
    "codex-wrapper pre-bash-guard") printf "codex pre-bash" ;;
    "codex-wrapper post-edit-guard (100)") printf "codex post-edit 100" ;;
    "post-edit-guard (5000)") printf "post-edit 5000" ;;
    "post-write-guard (5000)") printf "post-write 5000" ;;
    "stop-guard (5000)") printf "stop 5000" ;;
    "learn-evaluator (5000)") printf "learn 5000" ;;
    *) printf "%s" "$1" ;;
  esac
}

if [[ -n "$BENCH_ACTION_FILE" ]]; then
  mkdir -p "$(dirname "$BENCH_ACTION_FILE")"
  _first=true
  {
    echo "["
    for r in "${RESULTS[@]}"; do
      _name=$(echo "$r" | python3 -c "import json,sys; print(json.load(sys.stdin)['name'])" 2>/dev/null || echo "unknown")
      _display_name=$(bench_action_name "$_name")
      _p50=$(echo "$r" | python3 -c "import json,sys; print(json.load(sys.stdin)['p50'])" 2>/dev/null || echo "0")
      _p95=$(echo "$r" | python3 -c "import json,sys; print(json.load(sys.stdin)['p95'])" 2>/dev/null || echo "0")
      _p99=$(echo "$r" | python3 -c "import json,sys; print(json.load(sys.stdin)['p99'])" 2>/dev/null || echo "0")
      if [[ "$_first" == "true" ]]; then _first=false; else echo ","; fi
      printf '  {"name": "e2e %s P50", "unit": "ms", "value": %s}' "$_display_name" "$_p50"
      echo ","
      printf '  {"name": "e2e %s P95", "unit": "ms", "value": %s}' "$_display_name" "$_p95"
      echo ","
      printf '  {"name": "e2e %s P99", "unit": "ms", "value": %s}' "$_display_name" "$_p99"
    done
    echo ""
    echo "]"
  } > "$BENCH_ACTION_FILE"
  echo "Benchmark Action output: $BENCH_ACTION_FILE"
else
  echo "Benchmark Action output: disabled"
fi

echo "======================================"

if [[ "$FAIL_ON_REGRESSION" == "true" ]] && [[ $FAILURES -gt 0 ]]; then
  exit 1
fi
