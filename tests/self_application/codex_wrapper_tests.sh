header "Codex wrapper thinness sentinel"
good_codex_wrapper="${TMP_DIR}/good-codex-wrapper"
mkdir -p "${good_codex_wrapper}/hooks/_lib"
cat > "${good_codex_wrapper}/hooks/run-hook-codex.sh" <<'EOF'
#!/usr/bin/env bash
WRAPPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER_PATH="${WRAPPER_DIR}/_lib/codex_adapter.sh"
source "${ADAPTER_PATH}"
EVENT_NAME=$(codex_event_name "$INPUT")
codex_pretool_deny "blocked"
codex_adapt_pretool "$HOOK_OUTPUT"
codex_adapt_posttool "$HOOK_OUTPUT"
EOF
cat > "${good_codex_wrapper}/hooks/_lib/codex_adapter.sh" <<'EOF'
codex_event_name() { :; }
codex_pretool_deny() { :; }
codex_adapt_pretool() { :; }
codex_adapt_posttool() { :; }
EOF
cat > "${good_codex_wrapper}/hooks/_lib/codex_runner.sh" <<'EOF'
codex_run_hook() { :; }
EOF
cat > "${good_codex_wrapper}/hooks/_lib/codex_diag.sh" <<'EOF'
codex_diag() { :; }
EOF
assert_cmd "thin Codex wrapper passes" bash "${SELF_DIR}/check-codex-wrapper-thin.sh" "${good_codex_wrapper}"

bad_codex_wrapper="${TMP_DIR}/bad-codex-wrapper"
mkdir -p "${bad_codex_wrapper}/hooks/_lib"
cat > "${bad_codex_wrapper}/hooks/run-hook-codex.sh" <<'EOF'
#!/usr/bin/env bash
WRAPPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER_PATH="${WRAPPER_DIR}/_lib/codex_adapter.sh"
source "${ADAPTER_PATH}"
EVENT_NAME=$(codex_event_name "$INPUT")
codex_pretool_deny "blocked"
codex_adapt_pretool "$HOOK_OUTPUT"
codex_adapt_posttool "$HOOK_OUTPUT"
python3 - <<'PY'
print("inline adapter logic")
PY
EOF
cat > "${bad_codex_wrapper}/hooks/_lib/codex_adapter.sh" <<'EOF'
codex_event_name() { :; }
codex_pretool_deny() { :; }
codex_adapt_pretool() { :; }
codex_adapt_posttool() { :; }
EOF
cat > "${bad_codex_wrapper}/hooks/_lib/codex_runner.sh" <<'EOF'
codex_run_hook() { :; }
EOF
cat > "${bad_codex_wrapper}/hooks/_lib/codex_diag.sh" <<'EOF'
codex_diag() { :; }
EOF
assert_fails "inline Python in run-hook-codex fails thinness check" bash "${SELF_DIR}/check-codex-wrapper-thin.sh" "${bad_codex_wrapper}"
