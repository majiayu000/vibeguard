#!/usr/bin/env bash
# VibeGuard Install State — Track installed files and support repair/drift detection
#
#State file: ~/.vibeguard/install-state.json
# Format:
# {
#   "version": 1,
#   "installed_at": "2026-03-23T17:00:00+08:00",
#   "profile": "full",
#   "languages": ["rust", "python"],
#   "repo_dir": "/path/to/vibeguard",
#   "files": {
#     "~/.claude/rules/vibeguard/common/coding-style.md": {
#       "source": "rules/claude-rules/common/coding-style.md",
#       "checksum": "sha256:abc123...",
#       "type": "copy"
#     },
#     "~/.claude/skills/vibeguard": {
#       "source": "skills/vibeguard",
#       "type": "symlink"
#     }
#   }
# }

STATE_VERSION=1
STATE_FILE="${HOME}/.vibeguard/install-state.json"

# Initialize or load state
state_init() {
  local profile="${1:-core}" languages="${2:-}"
  python3 -c "
import json, datetime
state = {
    'version': ${STATE_VERSION},
    'installed_at': datetime.datetime.now().astimezone().isoformat(),
    'profile': '${profile}',
    'languages': '${languages}'.split(',') if '${languages}' else [],
    'repo_dir': '$(cat "${HOME}/.vibeguard/repo-path" 2>/dev/null || echo "")',
    'files': {}
}
with open('${STATE_FILE}', 'w') as f:
    json.dump(state, f, indent=2)
    f.write('\n')
"
}

# Record a file installation
state_record_file() {
  local dest="$1" source="$2" install_type="${3:-copy}"
  local checksum=""

  if [[ "$install_type" != "symlink" ]] && [[ -f "$dest" ]]; then
    if command -v shasum &>/dev/null; then
      checksum="sha256:$(shasum -a 256 "$dest" | cut -d' ' -f1)"
    elif command -v sha256sum &>/dev/null; then
      checksum="sha256:$(sha256sum "$dest" | cut -d' ' -f1)"
    fi
  fi

  python3 -c "
import json
try:
    with open('${STATE_FILE}') as f:
        state = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    state = {'version': ${STATE_VERSION}, 'files': {}}

version = state.get('version', ${STATE_VERSION})
if version != ${STATE_VERSION}:
    raise SystemExit(f'unsupported install-state version: {version} (expected ${STATE_VERSION})')

entry = {'source': '${source}', 'type': '${install_type}'}
checksum = '${checksum}'
if checksum:
    entry['checksum'] = checksum
state.setdefault('files', {})['${dest}'] = entry

with open('${STATE_FILE}', 'w') as f:
    json.dump(state, f, indent=2)
    f.write('\n')
"
}

# Record all files (regular or symlink) under a directory as installed artifacts.
# source_prefix is joined with each relative file path for traceability.
state_record_tree() {
  local dest_dir="$1" source_prefix="$2"
  [[ -d "$dest_dir" ]] || return 0

  while IFS= read -r file; do
    local rel source install_type
    rel="${file#"${dest_dir}/"}"
    source="${source_prefix%/}/${rel}"
    if [[ -L "$file" ]]; then install_type="symlink"; else install_type="copy"; fi
    state_record_file "$file" "$source" "$install_type"
  done < <(find "$dest_dir" \( -type f -o -type l \) 2>/dev/null)
}

# Check for drift — files that were installed but have been modified or removed
state_check_drift() {
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "NO_STATE"
    return 0
  fi

  python3 -c "
import json, os, subprocess

with open('${STATE_FILE}') as f:
    state = json.load(f)

version = state.get('version', 1)
if version != ${STATE_VERSION}:
    print(f'UNSUPPORTED_STATE_VERSION: {version} (expected ${STATE_VERSION})')
    raise SystemExit(0)

files = state.get('files', {})
drift_count = 0
missing_count = 0

for dest, info in files.items():
    expanded = os.path.expanduser(dest)
    if info['type'] == 'symlink':
        if not os.path.islink(expanded):
            if not os.path.exists(expanded):
                print(f'MISSING: {dest}')
                missing_count += 1
            else:
                print(f'DRIFT: {dest} (was symlink, now regular file)')
                drift_count += 1
    elif info['type'] == 'copy':
        if not os.path.exists(expanded):
            print(f'MISSING: {dest}')
            missing_count += 1
        elif 'checksum' in info:
            try:
                result = subprocess.run(
                    ['shasum', '-a', '256', expanded],
                    capture_output=True, text=True, timeout=5
                )
                if result.returncode == 0:
                    actual = 'sha256:' + result.stdout.split()[0]
                    if actual != info['checksum']:
                        print(f'DRIFT: {dest} (checksum mismatch)')
                        drift_count += 1
            except (subprocess.TimeoutExpired, FileNotFoundError):
                pass

total = len(files)
print(f'---')
print(f'Total tracked: {total}, Missing: {missing_count}, Drifted: {drift_count}')
if drift_count + missing_count == 0:
    print('STATUS: CLEAN')
else:
    print(f'STATUS: DRIFT ({drift_count} drifted, {missing_count} missing)')
" 2>/dev/null
}

# List all tracked files
state_list() {
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "No install state found. Run setup.sh first."
    return 1
  fi

  python3 -c "
import json
with open('${STATE_FILE}') as f:
    state = json.load(f)
version = state.get('version', 1)
if version != ${STATE_VERSION}:
    raise SystemExit(f'Unsupported install-state version: {version} (expected ${STATE_VERSION})')
print(f'Profile: {state.get(\"profile\", \"unknown\")}')
print(f'Installed: {state.get(\"installed_at\", \"unknown\")}')
langs = state.get('languages', [])
if langs:
    print(f'Languages: {\", \".join(langs)}')
print(f'Tracked files: {len(state.get(\"files\", {}))}')
print()
for dest, info in sorted(state.get('files', {}).items()):
    t = info.get('type', '?')
    print(f'  [{t:7s}] {dest}')
"
}

state_list_tracked_symlinks_under() {
  local dest_dir="$1"
  [[ -f "$STATE_FILE" ]] || return 0

  python3 - "$STATE_FILE" "$dest_dir" "$STATE_VERSION" <<'PY'
import json
import os
import sys

state_file, dest_dir, expected_version = sys.argv[1], sys.argv[2], int(sys.argv[3])
dest_dir = os.path.abspath(os.path.expanduser(dest_dir))

try:
    with open(state_file, encoding="utf-8") as f:
        state = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    raise SystemExit(0)

version = state.get("version", expected_version)
if version != expected_version:
    print(
        f"WARN: unsupported install-state version: {version} (expected {expected_version}); "
        "skipping tracked symlink cleanup",
        file=sys.stderr,
    )
    raise SystemExit(0)

for dest, info in sorted(state.get("files", {}).items()):
    if info.get("type") != "symlink":
        continue
    expanded = os.path.abspath(os.path.expanduser(dest))
    if expanded == dest_dir or expanded.startswith(dest_dir + os.sep):
        print(expanded)
PY
}

# Remove state file (used by clean.sh)
state_clean() {
  rm -f "$STATE_FILE"
}
