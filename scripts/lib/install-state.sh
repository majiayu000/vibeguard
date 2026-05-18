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
INSTALL_STATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Initialize or load state
state_init() {
  local profile="${1:-core}" languages="${2:-}"
  local repo_dir
  repo_dir="$(cat "${HOME}/.vibeguard/repo-path" 2>/dev/null || true)"

  python3 - "$INSTALL_STATE_LIB_DIR" "$STATE_FILE" "$STATE_VERSION" "$profile" "$languages" "$repo_dir" <<'PY'
import datetime
import sys
from pathlib import Path

lib_dir, state_file, state_version, profile, languages, repo_dir = sys.argv[1:7]
sys.path.insert(0, lib_dir)
from file_ops import write_json_atomic

state = {
    'version': int(state_version),
    'installed_at': datetime.datetime.now().astimezone().isoformat(),
    'profile': profile,
    'languages': languages.split(',') if languages else [],
    'repo_dir': repo_dir,
    'files': {}
}
write_json_atomic(Path(state_file), state)
PY
}

# Record a file installation
state_record_file() {
  local dest="$1" source="$2" install_type="${3:-copy}"

  python3 - "$INSTALL_STATE_LIB_DIR" "$STATE_FILE" "$STATE_VERSION" "$dest" "$source" "$install_type" <<'PY'
import json
import sys
from pathlib import Path

lib_dir, state_file, state_version, dest, source, install_type = sys.argv[1:7]
sys.path.insert(0, lib_dir)
from file_ops import sha256_file, write_json_atomic

expected_version = int(state_version)
state_path = Path(state_file)
dest_path = Path(dest)

try:
    with state_path.open(encoding='utf-8') as f:
        state = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    state = {'version': expected_version, 'files': {}}

version = state.get('version', expected_version)
if version != expected_version:
    raise SystemExit(f'unsupported install-state version: {version} (expected {expected_version})')

entry = {'source': source, 'type': install_type}
if install_type != 'symlink' and dest_path.is_file():
    entry['checksum'] = 'sha256:' + sha256_file(dest_path)
state.setdefault('files', {})[dest] = entry

write_json_atomic(state_path, state)
PY
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

  python3 - "$INSTALL_STATE_LIB_DIR" "$STATE_FILE" "$STATE_VERSION" 2>/dev/null <<'PY'
import json, os
import sys
from pathlib import Path

lib_dir, state_file, state_version = sys.argv[1], sys.argv[2], int(sys.argv[3])
sys.path.insert(0, lib_dir)
from file_ops import sha256_file

with open(state_file, encoding='utf-8') as f:
    state = json.load(f)

version = state.get('version', 1)
if version != state_version:
    print(f'UNSUPPORTED_STATE_VERSION: {version} (expected {state_version})')
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
            actual = 'sha256:' + sha256_file(Path(expanded))
            if actual != info['checksum']:
                print(f'DRIFT: {dest} (checksum mismatch)')
                drift_count += 1

total = len(files)
print(f'---')
print(f'Total tracked: {total}, Missing: {missing_count}, Drifted: {drift_count}')
if drift_count + missing_count == 0:
    print('STATUS: CLEAN')
else:
    print(f'STATUS: DRIFT ({drift_count} drifted, {missing_count} missing)')
PY
}

# List all tracked files
state_list() {
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "No install state found. Run setup.sh first."
    return 1
  fi

  python3 - "$STATE_FILE" "$STATE_VERSION" <<'PY'
import json
import sys

state_file, expected_version = sys.argv[1], int(sys.argv[2])

with open(state_file, encoding='utf-8') as f:
    state = json.load(f)
version = state.get('version', 1)
if version != expected_version:
    raise SystemExit(f'Unsupported install-state version: {version} (expected {expected_version})')
print(f'Profile: {state.get("profile", "unknown")}')
print(f'Installed: {state.get("installed_at", "unknown")}')
langs = state.get('languages', [])
if langs:
    print(f'Languages: {", ".join(langs)}')
print(f'Tracked files: {len(state.get("files", {}))}')
print()
for dest, info in sorted(state.get('files', {}).items()):
    t = info.get('type', '?')
    print(f'  [{t:7s}] {dest}')
PY
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
