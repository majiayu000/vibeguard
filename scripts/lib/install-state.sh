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

STATE_FILE="${HOME}/.vibeguard/install-state.json"

# Initialize or load state
state_init() {
  local profile="${1:-core}" languages="${2:-}"
  python3 -c "
import json, datetime
state = {
    'version': 1,
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
    state = {'version': 1, 'files': {}}

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

# Record all regular files under a directory as copy-installed artifacts.
# source_prefix is joined with each relative file path for traceability.
state_record_tree() {
  local dest_dir="$1" source_prefix="$2"
  [[ -d "$dest_dir" ]] || return 0

  while IFS= read -r file; do
    local rel source
    rel="${file#"${dest_dir}/"}"
    source="${source_prefix%/}/${rel}"
    state_record_file "$file" "$source" "copy"
  done < <(find "$dest_dir" -type f 2>/dev/null)
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

# Remove state file (used by clean.sh)
state_clean() {
  rm -f "$STATE_FILE"
}
