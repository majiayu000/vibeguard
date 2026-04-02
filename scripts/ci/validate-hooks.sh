#!/usr/bin/env bash
# VibeGuard CI: Verify that the hooks script is executable and has correct syntax
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
errors=0

echo "Validating hook scripts..."

for script in "${REPO_DIR}"/hooks/*.sh; do
  [[ -f "$script" ]] || continue
  name=$(basename "$script")

  if [[ ! -x "$script" ]]; then
    echo "FAIL: ${name} is not executable"
    ((errors++))
  fi

  if ! bash -n "$script" 2>/dev/null; then
    echo "FAIL: ${name} has syntax errors"
    ((errors++))
  else
    echo "OK: ${name}"
  fi
done

# Verify hooks configuration format (check that all scripts referenced by hooks in settings.json exist)
SETTINGS_FILE="${HOME}/.claude/settings.json"
if [[ -f "${SETTINGS_FILE}" ]]; then
  echo
  echo "Validating hooks configuration..."
  python3 -c "
import json, os

with open('${SETTINGS_FILE}') as f:
    data = json.load(f)

hooks = data.get('hooks', {})
errors = 0
for event, entries in hooks.items():
    for entry in entries:
        for hook in entry.get('hooks', []):
            cmd = hook.get('command', '')
            #Extract script path
            parts = cmd.split()
            if len(parts) >= 2 and parts[0] == 'bash':
                script_path = parts[1]
                if os.path.exists(script_path):
                    print(f'OK: {event} -> {os.path.basename(script_path)}')
                else:
                    print(f'FAIL: {event} -> {script_path} not found')
                    errors += 1

import sys
sys.exit(errors)
" 2>/dev/null
  hook_errors=$?
  errors=$((errors + hook_errors))
fi

echo
if [[ ${errors} -eq 0 ]]; then
  echo "All hooks valid."
else
  echo "FAILED: ${errors} errors found."
  exit 1
fi
