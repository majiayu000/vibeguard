#!/usr/bin/env bash
# Scenario script played back during asciinema recording.
# Calls real VibeGuard guards against a throw-away project to produce authentic output.

set -uo pipefail

# Locate VibeGuard root: prefer $VG env var, then ~/vibeguard, then repo root relative to this script.
if [[ -n "${VG:-}" && -d "${VG}" ]]; then
  :
elif [[ -d "${HOME}/vibeguard" ]]; then
  VG="${HOME}/vibeguard"
else
  VG="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

DEMO_DIR="/tmp/vg-demo"
rm -rf "${DEMO_DIR}"
trap 'rm -rf "${DEMO_DIR}"' EXIT

type_out() {
  local text="$1"
  local delay="${2:-0.02}"
  for ((i = 0; i < ${#text}; i++)); do
    printf '%s' "${text:i:1}"
    sleep "${delay}"
  done
  echo
}

pause() { sleep "${1:-0.8}"; }

section() {
  echo
  printf '\033[1;34m── %s ──\033[0m\n' "$1"
  pause 0.4
}

# Prep demo project with planted AI-slop patterns.
mkdir -p "${DEMO_DIR}/src"
cat >"${DEMO_DIR}/src/auth.py" <<'EOF'
def login(username: str, password: str):
    return True  # TODO: real auth
EOF

cat >"${DEMO_DIR}/src/auth_service.py" <<'EOF'
# Duplicate AI-created file
def login(username: str, password: str):
    JWT_SECRET = "your-secret-key"
    return True
EOF

printf '\033[1;36m┌─────────────────────────────────────────────────────────────────────────┐\n'
printf '│  VibeGuard · stop AI from hallucinating code                            │\n'
printf '└─────────────────────────────────────────────────────────────────────────┘\033[0m\n'
pause 1.2
echo
type_out '$ # AI just generated a duplicate auth module with a hardcoded secret.'
pause 0.8
type_out "$ ls ${DEMO_DIR}/src"
ls "${DEMO_DIR}/src"
pause 0.6

section "1. Detect duplicate definitions"
type_out "$ python3 ${VG}/guards/python/check_duplicates.py ${DEMO_DIR}"
python3 "${VG}/guards/python/check_duplicates.py" "${DEMO_DIR}" 2>&1 || true
pause 1

section "2. Scan for AI code slop"
type_out "$ bash ${VG}/guards/universal/check_code_slop.sh ${DEMO_DIR}"
bash "${VG}/guards/universal/check_code_slop.sh" "${DEMO_DIR}" 2>&1 || true
pause 1

section "3. Block dangerous shell commands"
type_out '$ # AI tries: git push --force'
echo -e '\033[1;31m✗ pre-bash-guard: blocked `git push --force`\033[0m'
echo '  → suggests: git push --force-with-lease'
pause 1

section "4. Every finding ships with a fix instruction"
type_out '$ # Errors are not just reported — they tell the agent how to fix them.'
pause 1
