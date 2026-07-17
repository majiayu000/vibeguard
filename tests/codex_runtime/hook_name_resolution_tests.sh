header "run-hook-codex resolves namespaced hook names canonically"

assert_codex_name_equal() {
  local actual="$1" expected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "${actual}" == "${expected}" ]]; then
    green "${desc}"
    PASS=$((PASS + 1))
  else
    red "${desc} (expected: ${expected}; actual: ${actual})"
    FAIL=$((FAIL + 1))
  fi
}

NAME_HOME="${TMP_DIR}/hook-name-home"
NAME_REPO="${TMP_DIR}/hook-name-repo"
NAME_DIAG="${TMP_DIR}/hook-name-diag.jsonl"
mkdir -p "${NAME_HOME}/.vibeguard" "${NAME_REPO}/hooks"
printf '%s' "${NAME_REPO}" > "${NAME_HOME}/.vibeguard/repo-path"

name_map_sync_output="$(
  { python3 - "${REPO_DIR}/hooks/manifest.json" "${REPO_DIR}/hooks/_lib/codex_diag.sh" <<'PY'
import json
import re
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
expected = {
    (item["codex"]["script"], item["script"])
    for item in manifest["hooks"]
    if item.get("codex", {}).get("enabled")
}
helper = Path(sys.argv[2]).read_text(encoding="utf-8")
function_body = helper.split("resolve_codex_hook_name() {", 1)[1].split("\n}", 1)[0]
actual_pairs = re.findall(
    r'^\s*(vibeguard-[^)]+)\) printf \'%s\\n\' "([^"]+)" ;;$',
    function_body,
    flags=re.MULTILINE,
)
actual = set(actual_pairs)
if len(actual_pairs) != len(actual) or actual != expected:
    print(f"expected={sorted(expected)} actual={sorted(actual_pairs)}")
    raise SystemExit(1)
print("hook-name-map-sync-ok")
PY
  } 2>&1 || true
)"
assert_contains "${name_map_sync_output}" "hook-name-map-sync-ok" "wrapper allowlist exactly matches manifest requested/canonical pairs"

name_mapping_count=0
while IFS=$'\t' read -r requested_name canonical_name event_name; do
  cat > "${NAME_REPO}/hooks/${canonical_name}" <<HOOK
#!/usr/bin/env bash
cat >/dev/null
printf '{"systemMessage":"resolved:${canonical_name}"}\n'
HOOK
  chmod +x "${NAME_REPO}/hooks/${canonical_name}"
  resolved_output="$(
    printf '{"hook_event_name":"%s","tool_input":{"command":"echo ok"}}' "${event_name}" \
      | HOME="${NAME_HOME}" VIBEGUARD_RUNTIME="${VIBEGUARD_RUNTIME}" \
        bash "${REPO_DIR}/hooks/run-hook-codex.sh" "${requested_name}"
  )"
  assert_contains "${resolved_output}" "resolved:${canonical_name}" "${requested_name} resolves to ${canonical_name}"
  name_mapping_count=$((name_mapping_count + 1))
done < <(
  python3 - "${REPO_DIR}/hooks/manifest.json" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
for item in manifest["hooks"]:
    codex = item.get("codex", {})
    if not codex.get("enabled"):
        continue
    entries = codex.get("entries")
    event = entries[0]["event"] if isinstance(entries, list) else codex["event"]
    print(f'{codex["script"]}\t{item["script"]}\t{event}')
PY
)
assert_codex_name_equal "${name_mapping_count}" "8" "all manifest Codex hook names are covered"

alias_count="$(find "${REPO_DIR}/hooks" -maxdepth 1 -type f -name 'vibeguard-*.sh' | wc -l | tr -d '[:space:]')"
assert_codex_name_equal "${alias_count}" "0" "canonical resolution has no physical alias shells"

INSTALLED_NAME_HOME="${TMP_DIR}/hook-name-installed-home"
mkdir -p "${INSTALLED_NAME_HOME}/.vibeguard/installed/hooks"
cat > "${INSTALLED_NAME_HOME}/.vibeguard/installed/hooks/pre-bash-guard.sh" <<'HOOK'
#!/usr/bin/env bash
cat >/dev/null
printf '{"systemMessage":"resolved:installed-pre-bash-guard.sh"}\n'
HOOK
chmod +x "${INSTALLED_NAME_HOME}/.vibeguard/installed/hooks/pre-bash-guard.sh"
installed_resolution_output="$(
  printf '{"hook_event_name":"PreToolUse","tool_input":{"command":"echo ok"}}' \
    | HOME="${INSTALLED_NAME_HOME}" VIBEGUARD_EXECUTION_MODE="installed-snapshot" \
      VIBEGUARD_RUNTIME="${VIBEGUARD_RUNTIME}" bash "${REPO_DIR}/hooks/run-hook-codex.sh" \
      vibeguard-pre-bash-guard.sh
)"
assert_contains "${installed_resolution_output}" "resolved:installed-pre-bash-guard.sh" "installed snapshot uses canonical hook file"

INVALID_TARGET_MARKER="${TMP_DIR}/invalid-hook-target-executed"
cat > "${NAME_REPO}/hooks/pre-bash-guard.sh" <<HOOK
#!/usr/bin/env bash
cat >/dev/null
touch "${INVALID_TARGET_MARKER}"
printf '{"systemMessage":"unexpected target execution"}\n'
HOOK
chmod +x "${NAME_REPO}/hooks/pre-bash-guard.sh"

run_invalid_hook_name() {
  local requested_name="$1" event_name="$2" expected_fragment="$3" desc="$4"
  local output rc
  rm -f "${INVALID_TARGET_MARKER}"
  set +e
  if [[ "${requested_name}" == "__missing__" ]]; then
    output="$(
      printf '{"hook_event_name":"%s","tool_input":{"command":"echo ok"}}' "${event_name}" \
        | HOME="${NAME_HOME}" VIBEGUARD_RUNTIME="${VIBEGUARD_RUNTIME}" \
          VIBEGUARD_CODEX_DIAG_FILE="${NAME_DIAG}" bash "${REPO_DIR}/hooks/run-hook-codex.sh" 2>/dev/null
    )"
    rc=$?
  else
    output="$(
      printf '{"hook_event_name":"%s","tool_input":{"command":"echo ok"}}' "${event_name}" \
        | HOME="${NAME_HOME}" VIBEGUARD_RUNTIME="${VIBEGUARD_RUNTIME}" \
          VIBEGUARD_CODEX_DIAG_FILE="${NAME_DIAG}" bash "${REPO_DIR}/hooks/run-hook-codex.sh" "${requested_name}" 2>/dev/null
    )"
    rc=$?
  fi
  set -e
  assert_codex_name_equal "${rc}" "0" "${desc} exits zero after protocol response"
  assert_contains "${output}" "invalid-hook-name" "${desc} exposes stable reason"
  assert_contains "${output}" "${expected_fragment}" "${desc} uses event-appropriate visible failure"
  assert_codex_name_equal "$(test -e "${INVALID_TARGET_MARKER}" && printf yes || printf no)" "no" "${desc} does not execute a target"
}

run_invalid_hook_name "__missing__" "PreToolUse" '"permissionDecision": "deny"' "missing requested name"
run_invalid_hook_name "" "PermissionRequest" '"behavior": "deny"' "empty requested name"
run_invalid_hook_name "vibeguard-unknown.sh" "Stop" '"stopReason"' "unknown requested name"
run_invalid_hook_name "vibeguard-../pre-bash-guard.sh" "PostToolUse" '"additionalContext"' "traversal requested name"
run_invalid_hook_name "vibeguard-pre-bash-guard.sh/extra" "CustomEvent" '"systemMessage"' "path-shaped requested name"
run_invalid_hook_name "vibeguard-vibeguard-pre-bash-guard.sh" "PreToolUse" '"permissionDecision": "deny"' "double-prefixed requested name"
run_invalid_hook_name "pre-bash-guard.sh" "PreToolUse" '"permissionDecision": "deny"' "non-namespaced requested name"

assert_contains "$(cat "${NAME_DIAG}" 2>/dev/null || true)" "vibeguard-unknown.sh" "invalid-name diagnostic preserves requested name"
assert_contains "$(cat "${NAME_DIAG}" 2>/dev/null || true)" "invalid-hook-name" "invalid-name diagnostic preserves stable reason"

FALLBACK_WRAPPER_DIR="${TMP_DIR}/hook-name-fallback-wrapper"
mkdir -p "${FALLBACK_WRAPPER_DIR}"
cp "${REPO_DIR}/hooks/run-hook-codex.sh" "${FALLBACK_WRAPPER_DIR}/run-hook-codex.sh"
fallback_invalid_output="$(
  printf '{"hook_event_name":"PreToolUse","tool_input":{"command":"echo ok"}}' \
    | HOME="${NAME_HOME}" bash "${FALLBACK_WRAPPER_DIR}/run-hook-codex.sh" pre-bash-guard.sh
)"
assert_contains "${fallback_invalid_output}" "invalid-hook-name" "missing diagnostic helper preserves invalid-name reason"
assert_contains "${fallback_invalid_output}" '"permissionDecision":"deny"' "missing diagnostic helper fails closed visibly"
assert_codex_pretool_output_contract "${fallback_invalid_output}" "missing diagnostic helper deny matches Codex contract"
