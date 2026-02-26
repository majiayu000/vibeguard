#!/usr/bin/env bash
# VibeGuard Rust guards 回归测试
#
# 用法：bash tests/test_rust_guards.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SSOT_GUARD="${REPO_DIR}/guards/rust/check_single_source_of_truth.sh"
SEM_GUARD="${REPO_DIR}/guards/rust/check_semantic_effect.sh"

PASS=0
FAIL=0
TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }
header(){ printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

assert_cmd_ok() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    green "${desc}"
    PASS=$((PASS + 1))
  else
    red "${desc} (expected success)"
    FAIL=$((FAIL + 1))
  fi
}

assert_cmd_fail() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    red "${desc} (expected failure)"
    FAIL=$((FAIL + 1))
  else
    green "${desc}"
    PASS=$((PASS + 1))
  fi
}

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "${tmpdir}"
}
trap cleanup EXIT

header "check_single_source_of_truth"

proj_ssot="${tmpdir}/ssot"
mkdir -p "${proj_ssot}/src"
cat > "${proj_ssot}/src/tools.rs" <<'EOF'
pub struct TodoWrite;
pub struct TodoRead;
pub struct TaskDone;

static TODO_STATE: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());
static TASK_STATE: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());
EOF
assert_cmd_fail "双轨任务系统在 strict 下失败" bash "${SSOT_GUARD}" --strict "${proj_ssot}"

proj_ssot_ok="${tmpdir}/ssot_ok"
mkdir -p "${proj_ssot_ok}/src"
cat > "${proj_ssot_ok}/src/tools.rs" <<'EOF'
pub struct TaskWrite;
pub struct TaskRead;
static TASK_STATE: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());
EOF
assert_cmd_ok "单任务系统在 strict 下通过" bash "${SSOT_GUARD}" --strict "${proj_ssot_ok}"

header "check_semantic_effect"

proj_sem_bad="${tmpdir}/sem_bad"
mkdir -p "${proj_sem_bad}/src/task"
cat > "${proj_sem_bad}/src/task/task_done.rs" <<'EOF'
pub fn mark_done(task_id: &str) -> Result<String, String> {
    Ok(format!("task {} done", task_id))
}
EOF
assert_cmd_fail "动作语义无副作用在 strict 下失败" bash "${SEM_GUARD}" --strict "${proj_sem_bad}"

proj_sem_ok="${tmpdir}/sem_ok"
mkdir -p "${proj_sem_ok}/src/task"
cat > "${proj_sem_ok}/src/task/task_done.rs" <<'EOF'
use std::collections::HashMap;

pub fn mark_done(task_id: &str, state: &mut HashMap<String, String>) -> Result<String, String> {
    state.insert(task_id.to_string(), "done".to_string());
    Ok(format!("task {} done", task_id))
}
EOF
assert_cmd_ok "动作语义有副作用在 strict 下通过" bash "${SEM_GUARD}" --strict "${proj_sem_ok}"

echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
