#!/usr/bin/env bash
# Unit tests for guards/rust/check_single_source_of_truth.sh (RS-12)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="${REPO_DIR}/guards/rust/check_single_source_of_truth.sh"

PASS=0; FAIL=0; TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }

assert_ok() {
  local desc="$1"; shift; TOTAL=$((TOTAL+1))
  if "$@" >/dev/null 2>&1; then green "$desc"; PASS=$((PASS+1))
  else red "$desc (expected exit 0)"; FAIL=$((FAIL+1)); fi
}

assert_fail() {
  local desc="$1"; shift; TOTAL=$((TOTAL+1))
  if "$@" >/dev/null 2>&1; then red "$desc (expected non-zero)"; FAIL=$((FAIL+1))
  else green "$desc"; PASS=$((PASS+1)); fi
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

printf '\n=== check_single_source_of_truth (RS-12) ===\n'

# --- FAIL: dual task systems (Todo* + Task* families) with two state stores ---
proj_dual="${tmpdir}/fail_dual_task"
mkdir -p "${proj_dual}/src"
cat > "${proj_dual}/src/tools.rs" <<'EOF'
pub struct TodoWrite;
pub struct TodoRead;
pub struct TaskDone;

static TODO_STATE: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());
static TASK_STATE: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());
EOF
assert_fail "dual task system with two state stores fails --strict" bash "$GUARD" --strict "$proj_dual"

# --- FAIL: Todo* family + multiple task-named state stores ---
# The guard detects stores only when the line contains "task" or "todo" in it.
proj_multi_state="${tmpdir}/fail_multi_state"
mkdir -p "${proj_multi_state}/src"
cat > "${proj_multi_state}/src/state.rs" <<'EOF'
pub struct TodoWrite;
pub struct TodoRead;
static TODO_PENDING: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());
static TODO_DONE: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());
static TODO_ARCHIVE: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());
EOF
assert_fail "Todo* family with multiple todo-named state stores fails --strict" bash "$GUARD" --strict "$proj_multi_state"

# --- PASS: single task system with one state store ---
proj_single="${tmpdir}/pass_single_task"
mkdir -p "${proj_single}/src"
cat > "${proj_single}/src/tools.rs" <<'EOF'
pub struct TaskWrite;
pub struct TaskRead;
pub struct TaskDone;
static TASK_STATE: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());
EOF
assert_ok "single task system passes --strict" bash "$GUARD" --strict "$proj_single"

# --- PASS: no task types at all ---
proj_no_task="${tmpdir}/pass_no_task"
mkdir -p "${proj_no_task}/src"
cat > "${proj_no_task}/src/lib.rs" <<'EOF'
pub struct User { pub id: u64 }
pub fn greet(name: &str) -> String { format!("Hello, {}!", name) }
EOF
assert_ok "no task types passes" bash "$GUARD" --strict "$proj_no_task"

# --- PASS: empty project ---
proj_empty="${tmpdir}/pass_empty"
mkdir -p "${proj_empty}/src"
assert_ok "empty project passes" bash "$GUARD" --strict "$proj_empty"

echo
printf 'Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n' "$TOTAL" "$PASS" "$FAIL"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0
