#!/usr/bin/env bash
# Layered config (env > ~/.vibeguard/config.json > default 800) for U-16 file-size guard.
# Verifies the wiring across pre-write-guard, pre-edit-guard, post-write-guard, and
# the post_edit_quality U-16 detector.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/hook_test_lib.sh"
hook_test_init

# --- Fixture setup ---------------------------------------------------------
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR" "$VIBEGUARD_LOG_DIR"' EXIT
export VG_CB_THRESHOLD=999

# 850-line python source (over default 800)
big_py_content=$(python3 -c 'print("\n".join(f"x = {i}" for i in range(850)))')
medium_py_content=$(python3 -c 'print("\n".join(f"x = {i}" for i in range(450)))')

# tool_input.content envelope for Write hooks
write_input_file="$WORK_DIR/write_input.json"
python3 > "$write_input_file" <<PY
import json
content = "\n".join(f"x = {i}" for i in range(850))
print(json.dumps({"tool_input": {"file_path": "$REPO_DIR/__vg_u16_cfg_subj.py", "content": content}}))
PY

medium_write_input_file="$WORK_DIR/medium_write_input.json"
python3 > "$medium_write_input_file" <<PY
import json
content = "\n".join(f"x = {i}" for i in range(450))
print(json.dumps({"tool_input": {"file_path": "$REPO_DIR/__vg_u16_typical_subj.py", "content": content}}))
PY

# Real on-disk file for Edit hook (needs to actually exist)
edit_target="$WORK_DIR/edit_target.py"
printf '%s\n' "$big_py_content" > "$edit_target"
edit_input_file="$WORK_DIR/edit_input.json"
python3 > "$edit_input_file" <<PY
import json
print(json.dumps({"tool_input": {
    "file_path": "$edit_target",
    "old_string": "x = 849",
    "new_string": "x = 849\nx = 850"
}}))
PY

medium_edit_target="$WORK_DIR/medium_edit_target.py"
printf '%s\n' "$medium_py_content" > "$medium_edit_target"
medium_edit_input_file="$WORK_DIR/medium_edit_input.json"
python3 > "$medium_edit_input_file" <<PY
import json
print(json.dumps({"tool_input": {
    "file_path": "$medium_edit_target",
    "old_string": "x = 449",
    "new_string": "x = 449\nx = 450"
}}))
PY

# --- Helpers ---------------------------------------------------------------
run_pre_write() {
  bash hooks/pre-write-guard.sh < "$write_input_file"
}
run_pre_write_medium() {
  bash hooks/pre-write-guard.sh < "$medium_write_input_file"
}
run_pre_edit() {
  bash hooks/pre-edit-guard.sh < "$edit_input_file"
}
run_pre_edit_medium() {
  bash hooks/pre-edit-guard.sh < "$medium_edit_input_file"
}
run_post_write() {
  bash hooks/post-write-guard.sh < "$write_input_file" 2>/dev/null
}
run_post_write_medium() {
  bash hooks/post-write-guard.sh < "$medium_write_input_file" 2>/dev/null
}
run_post_edit_medium() {
  bash hooks/post-edit-guard.sh < "$medium_edit_input_file" 2>/dev/null
}

# --- pre-write-guard -------------------------------------------------------
header "U-16 layered config — pre-write-guard"

unset VG_U16_LIMIT
unset VG_U16_WARN_LIMIT
unset VIBEGUARD_CONFIG_FILE
result=$(run_pre_write)
assert_contains "$result" '"decision": "block"' "default 800: 850-line write blocks"
assert_contains "$result" "850 lines" "block reason cites actual line count"
assert_contains "$result" "800-line" "block reason cites resolved limit"

result=$(run_pre_write_medium)
assert_not_contains "$result" '"decision": "block"' "default 400/800: 450-line write is advisory only"
assert_contains "$result" "[U-16]" "default 400/800: 450-line write emits U-16 advisory"
assert_contains "$result" "400-line typical range" "write advisory cites typical threshold"
assert_contains "$result" "[L1]" "450-line new source write still includes search-first advisory"

export VIBEGUARD_WRITE_MODE=block
result=$(run_pre_write_medium)
assert_contains "$result" '"decision": "block"' "write_mode=block still blocks 450-line new source writes"
assert_contains "$result" "[L1] [block]" "write_mode=block block reason stays L1 search-first"
unset VIBEGUARD_WRITE_MODE

export VG_U16_WARN_LIMIT=600
result=$(run_pre_write_medium)
assert_not_contains "$result" "[U-16]" "VG_U16_WARN_LIMIT=600: 450-line write has no U-16 advisory"
unset VG_U16_WARN_LIMIT

export VG_U16_LIMIT=1000
result=$(run_pre_write)
assert_not_contains "$result" '"decision": "block"' "VG_U16_LIMIT=1000 raises limit, no block"
assert_contains "$result" "[U-16]" "VG_U16_LIMIT=1000 still emits typical-range advisory"
unset VG_U16_LIMIT

cfg_file="$WORK_DIR/cfg.json"
echo '{"u16":{"limit":1500}}' > "$cfg_file"
export VIBEGUARD_CONFIG_FILE="$cfg_file"
result=$(run_pre_write)
assert_not_contains "$result" '"decision": "block"' "JSON u16.limit=1500 raises limit, no block"
assert_contains "$result" "[U-16]" "JSON u16.limit=1500 still emits typical-range advisory"

echo '{"u16":{"limit":1500,"warn_limit":900}}' > "$cfg_file"
result=$(run_pre_write)
assert_not_contains "$result" "[U-16]" "JSON u16.warn_limit=900 suppresses advisory for 850-line write"

export VG_U16_LIMIT=500
result=$(run_pre_write)
assert_contains "$result" '"decision": "block"' "env=500 beats JSON=1500, blocks"
assert_contains "$result" "500-line" "env-overridden limit appears in reason"
unset VG_U16_LIMIT

echo '{not-json' > "$cfg_file"
result=$(run_pre_write)
assert_contains "$result" '"decision": "block"' "malformed JSON falls back to default 800 (blocks)"

unset VIBEGUARD_CONFIG_FILE

# --- pre-edit-guard --------------------------------------------------------
header "U-16 layered config — pre-edit-guard"

unset VG_U16_LIMIT VG_U16_WARN_LIMIT VIBEGUARD_CONFIG_FILE
result=$(run_pre_edit)
assert_contains "$result" '"decision": "block"' "default 800: edit pushing to 851 blocks"
assert_contains "$result" "limit: 800" "block reason cites resolved limit"

result=$(run_pre_edit_medium)
assert_not_contains "$result" '"decision": "block"' "default 400/800: edit to 451 lines is advisory only"
assert_contains "$result" "[U-16]" "default 400/800: edit to 451 lines emits U-16 advisory"
assert_contains "$result" "400-line typical range" "edit advisory cites typical threshold"

export VG_U16_WARN_LIMIT=600
result=$(run_pre_edit_medium)
assert_not_contains "$result" "[U-16]" "VG_U16_WARN_LIMIT=600: edit to 451 lines has no U-16 advisory"
unset VG_U16_WARN_LIMIT

export VG_U16_LIMIT=2000
result=$(run_pre_edit)
assert_not_contains "$result" '"decision": "block"' "VG_U16_LIMIT=2000: edit allowed"
unset VG_U16_LIMIT

echo '{"u16":{"limit":2000}}' > "$cfg_file"
export VIBEGUARD_CONFIG_FILE="$cfg_file"
result=$(run_pre_edit)
assert_not_contains "$result" '"decision": "block"' "JSON u16.limit=2000: edit allowed"

export VG_U16_LIMIT=600
result=$(run_pre_edit)
assert_contains "$result" '"decision": "block"' "env=600 beats JSON=2000, blocks"
assert_contains "$result" "limit: 600" "block reason reflects env override"
unset VG_U16_LIMIT VG_U16_WARN_LIMIT VIBEGUARD_CONFIG_FILE

# --- post-write-guard ------------------------------------------------------
header "U-16 layered config — post-write-guard"

unset VG_U16_LIMIT VG_U16_WARN_LIMIT VIBEGUARD_CONFIG_FILE
result=$(run_post_write)
assert_contains "$result" "[U-16]" "default 800: 850-line write emits U-16 warn"
assert_contains "$result" "exceeding 800-line limit" "warn cites resolved limit"

result=$(run_post_write_medium)
assert_contains "$result" "[U-16]" "default 400/800: 450-line post-write emits U-16 advisory"
assert_contains "$result" "400-line typical range" "post-write advisory cites typical threshold"

export VG_U16_LIMIT=1000
result=$(run_post_write)
assert_contains "$result" "400-line typical range" "VG_U16_LIMIT=1000: 850-line write emits advisory, not hard-limit warning"
assert_not_contains "$result" "exceeding 1000-line limit" "VG_U16_LIMIT=1000: no hard-limit warning"
unset VG_U16_LIMIT

echo '{"u16":{"limit":1500}}' > "$cfg_file"
export VIBEGUARD_CONFIG_FILE="$cfg_file"
result=$(run_post_write)
assert_contains "$result" "400-line typical range" "JSON u16.limit=1500: 850-line write emits advisory"

echo '{"u16":{"limit":1500,"warn_limit":900}}' > "$cfg_file"
result=$(run_post_write)
assert_not_contains "$result" "[U-16]" "JSON u16.warn_limit=900: 850-line post-write is silent"

export VG_U16_LIMIT=600
result=$(run_post_write)
assert_contains "$result" "exceeding 600-line limit" "env=600 wins, warn at 600"
unset VG_U16_LIMIT VG_U16_WARN_LIMIT VIBEGUARD_CONFIG_FILE

# --- post-edit-guard -------------------------------------------------------
header "U-16 layered config — post-edit-guard"

unset VG_U16_LIMIT VG_U16_WARN_LIMIT VIBEGUARD_CONFIG_FILE
result=$(run_post_edit_medium)
assert_contains "$result" "[U-16]" "default 400/800: 450-line post-edit emits U-16 advisory"
assert_contains "$result" "400-line typical range" "post-edit advisory cites typical threshold"

export VG_U16_WARN_LIMIT=600
result=$(run_post_edit_medium)
assert_not_contains "$result" "[U-16]" "VG_U16_WARN_LIMIT=600: 450-line post-edit is silent"
unset VG_U16_WARN_LIMIT

# --- config.sh helper unit checks -----------------------------------------
header "vg_config_get_int — unit"

source hooks/_lib/config.sh

VIBEGUARD_CONFIG_FILE_SAVED="${VIBEGUARD_CONFIG_FILE:-}"
unset VG_TEST_X
_VG_CONFIG_FILE="$WORK_DIR/missing.json"
got=$(vg_config_get_int VG_TEST_X u16.limit 800)
[[ "$got" == "800" ]] && green "missing config falls back to default" || { red "missing config (got: $got)"; FAIL=$((FAIL+1)); }
TOTAL=$((TOTAL+1)); PASS=$((PASS+1))

echo '{"u16":{"limit":1234,"warn_limit":456}}' > "$WORK_DIR/cfg.json"
_VG_CONFIG_FILE="$WORK_DIR/cfg.json"
got=$(vg_config_get_int VG_TEST_X u16.limit 800)
[[ "$got" == "1234" ]] && green "JSON read returns int" || { red "JSON int (got: $got)"; FAIL=$((FAIL+1)); }
TOTAL=$((TOTAL+1)); PASS=$((PASS+1))

got=$(vg_config_get_int VG_TEST_WARN u16.warn_limit 400)
[[ "$got" == "456" ]] && green "JSON read returns U-16 warn_limit" || { red "JSON warn_limit (got: $got)"; FAIL=$((FAIL+1)); }
TOTAL=$((TOTAL+1)); PASS=$((PASS+1))

VG_TEST_X=999
got=$(vg_config_get_int VG_TEST_X u16.limit 800)
[[ "$got" == "999" ]] && green "env beats JSON" || { red "env vs JSON (got: $got)"; FAIL=$((FAIL+1)); }
TOTAL=$((TOTAL+1)); PASS=$((PASS+1))

VG_TEST_X="abc"
got=$(vg_config_get_int VG_TEST_X u16.limit 800)
[[ "$got" == "1234" ]] && green "non-numeric env falls through to JSON" || { red "bad env (got: $got)"; FAIL=$((FAIL+1)); }
TOTAL=$((TOTAL+1)); PASS=$((PASS+1))

echo '{"u16":{"limit":"oops"}}' > "$WORK_DIR/cfg.json"
unset VG_TEST_X
got=$(vg_config_get_int VG_TEST_X u16.limit 800)
[[ "$got" == "800" ]] && green "wrong-typed JSON falls through to default" || { red "wrong type (got: $got)"; FAIL=$((FAIL+1)); }
TOTAL=$((TOTAL+1)); PASS=$((PASS+1))

[[ -n "$VIBEGUARD_CONFIG_FILE_SAVED" ]] && export VIBEGUARD_CONFIG_FILE="$VIBEGUARD_CONFIG_FILE_SAVED"

hook_test_finish
