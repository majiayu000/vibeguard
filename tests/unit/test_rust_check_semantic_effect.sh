#!/usr/bin/env bash
# Unit tests for guards/rust/check_semantic_effect.sh (RS-13)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="${REPO_DIR}/guards/rust/check_semantic_effect.sh"

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

printf '\n=== check_semantic_effect (RS-13) ===\n'

# --- FAIL: mark_done action with no side-effects ---
proj_no_effect="${tmpdir}/fail_no_effect"
mkdir -p "${proj_no_effect}/src/task"
cat > "${proj_no_effect}/src/task/task_done.rs" <<'EOF'
pub fn mark_done(task_id: &str) -> Result<String, String> {
    Ok(format!("task {} done", task_id))
}
EOF
assert_fail "action fn without side-effects fails --strict" bash "$GUARD" --strict "$proj_no_effect"

# --- FAIL: update_ fn without writes, in task/ path (guard only checks task/todo/tool/command paths) ---
proj_update="${tmpdir}/fail_update"
mkdir -p "${proj_update}/src/task"
cat > "${proj_update}/src/task/manager.rs" <<'EOF'
pub fn update_status(id: u64) -> Result<String, String> {
    let label = format!("updated-{}", id);
    Ok(label)
}
EOF
assert_fail "update_ fn without writes in task/ path fails --strict" bash "$GUARD" --strict "$proj_update"

# --- PASS: mark_done with state mutation (insert/push) ---
proj_with_effect="${tmpdir}/pass_with_effect"
mkdir -p "${proj_with_effect}/src/task"
cat > "${proj_with_effect}/src/task/task_done.rs" <<'EOF'
use std::collections::HashMap;
pub fn mark_done(task_id: &str, state: &mut HashMap<String, String>) -> Result<String, String> {
    state.insert(task_id.to_string(), "done".to_string());
    Ok(format!("task {} done", task_id))
}
EOF
assert_ok "action fn with state mutation passes" bash "$GUARD" --strict "$proj_with_effect"

# --- PASS: delete_item that actually calls a method with side-effects ---
proj_delete="${tmpdir}/pass_delete"
mkdir -p "${proj_delete}/src"
cat > "${proj_delete}/src/store.rs" <<'EOF'
pub fn delete_item(id: u64, store: &mut Vec<u64>) -> Result<(), String> {
    store.retain(|&x| x != id);
    Ok(())
}
EOF
assert_ok "delete_ fn with retain (side-effect) passes" bash "$GUARD" --strict "$proj_delete"

# --- PASS: functions that don't have action-style names are ignored ---
proj_no_action="${tmpdir}/pass_no_action"
mkdir -p "${proj_no_action}/src"
cat > "${proj_no_action}/src/compute.rs" <<'EOF'
pub fn calculate_total(items: &[f64]) -> f64 {
    items.iter().sum()
}
pub fn format_result(val: f64) -> String {
    format!("{:.2}", val)
}
EOF
assert_ok "non-action functions are ignored" bash "$GUARD" --strict "$proj_no_action"

# --- PASS: empty project ---
proj_empty="${tmpdir}/pass_empty"
mkdir -p "${proj_empty}/src"
assert_ok "empty project passes" bash "$GUARD" --strict "$proj_empty"

echo
printf 'Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n' "$TOTAL" "$PASS" "$FAIL"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0
