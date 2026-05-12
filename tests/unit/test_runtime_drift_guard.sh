#!/usr/bin/env bash
# Unit tests for guards/universal/check_runtime_drift.sh (W-20).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="${REPO_DIR}/guards/universal/check_runtime_drift.sh"

PASS=0
FAIL=0
TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }

run_expect() {
  local desc="$1"
  local expected="$2"
  local pattern="$3"
  shift 3

  TOTAL=$((TOTAL + 1))
  local out rc
  set +e
  out="$("$@" 2>&1)"
  rc=$?
  set -e

  if [[ "${rc}" -ne "${expected}" ]]; then
    red "${desc} (expected exit ${expected}, got ${rc})"
    printf '%s\n' "${out}" | sed 's/^/    /'
    FAIL=$((FAIL + 1))
    return
  fi
  if [[ -n "${pattern}" ]] && ! grep -qF "${pattern}" <<< "${out}"; then
    red "${desc} (missing: ${pattern})"
    printf '%s\n' "${out}" | sed 's/^/    /'
    FAIL=$((FAIL + 1))
    return
  fi
  green "${desc}"
  PASS=$((PASS + 1))
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

PROJECT="${TMP_DIR}/project"
mkdir -p "${PROJECT}/rules/claude-rules/common" "${PROJECT}/skills/demo"
cat > "${PROJECT}/rules/claude-rules/common/workflow.md" <<'EOF'
## W-01: Demo rule (strict)
Rule text.
EOF
cat > "${PROJECT}/skills/demo/SKILL.md" <<'EOF'
---
name: demo
description: Demo skill
---
EOF
cat > "${PROJECT}/tools.txt" <<'EOF'
tool:demo
description: Demo tool
EOF

SNAPSHOT="${TMP_DIR}/runtime-pin.json"

printf '\n=== W-20 runtime drift guard ===\n'

run_expect "snapshot creation succeeds" 0 "snapshot written" \
  bash "${GUARD}" --snapshot "${SNAPSHOT}" --root "${PROJECT}" \
    --runtime-version "agent 1.0" --model "model-a" --sdk-version "sdk 1.0" \
    --tools-file "${PROJECT}/tools.txt"

run_expect "unchanged surfaces pass" 0 "OK: runtime, tool, and rule surfaces match snapshot" \
  bash "${GUARD}" --check "${SNAPSHOT}" --root "${PROJECT}" \
    --runtime-version "agent 1.0" --model "model-a" --sdk-version "sdk 1.0" \
    --tools-file "${PROJECT}/tools.txt"

run_expect "runtime version drift fails" 1 "runtime version: agent 1.0 -> agent 2.0" \
  bash "${GUARD}" --check "${SNAPSHOT}" --root "${PROJECT}" \
    --runtime-version "agent 2.0" --model "model-a" --sdk-version "sdk 1.0" \
    --tools-file "${PROJECT}/tools.txt"

printf '\nchanged tool description\n' >> "${PROJECT}/tools.txt"
run_expect "tool surface drift fails" 1 "tool surface hash" \
  bash "${GUARD}" --check "${SNAPSHOT}" --root "${PROJECT}" \
    --runtime-version "agent 1.0" --model "model-a" --sdk-version "sdk 1.0" \
    --tools-file "${PROJECT}/tools.txt"

printf '\nchanged rule text\n' >> "${PROJECT}/rules/claude-rules/common/workflow.md"
run_expect "rule surface drift fails" 1 "rule surface hash" \
  bash "${GUARD}" --check "${SNAPSHOT}" --root "${PROJECT}" \
    --runtime-version "agent 1.0" --model "model-a" --sdk-version "sdk 1.0" \
    --tools-file "${PROJECT}/tools.txt"

run_expect "accepted drift is recorded" 0 "drift accepted and recorded" \
  bash "${GUARD}" --check "${SNAPSHOT}" --root "${PROJECT}" \
    --runtime-version "agent 1.0" --model "model-a" --sdk-version "sdk 1.0" \
    --tools-file "${PROJECT}/tools.txt" \
    --accept-drift --decision-log SECURITY.md --reason "operator reviewed tool and rule changes"

run_expect "decision log contains accepted drift entry" 0 "" \
  grep -qF "W-20 runtime drift accepted" "${PROJECT}/SECURITY.md"

run_expect "accept drift requires decision log" 2 "requires --decision-log" \
  bash "${GUARD}" --check "${SNAPSHOT}" --root "${PROJECT}" \
    --runtime-version "agent 1.0" --model "model-a" --sdk-version "sdk 1.0" \
    --tools-file "${PROJECT}/tools.txt" --accept-drift

echo
printf 'Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n' "${TOTAL}" "${PASS}" "${FAIL}"
[[ "${FAIL}" -gt 0 ]] && exit 1 || exit 0
