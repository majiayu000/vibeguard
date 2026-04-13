#!/usr/bin/env bash
# VibeGuard PreToolUse(Bash) Hook
#
# Hard interception of irreversible dangerous commands:
# - git checkout . / git restore . (discard all changes)
# - git clean -f (remove untracked files)
# - rm -rf project root directory or sensitive path
#
# Transparently correct (updatedInput) mechanically predictable commands:
#   - npm install / yarn install → pnpm install
#   - npm install <pkg> / yarn add <pkg> → pnpm add <pkg>
#   - pip install / pip3 install / python -m pip install → uv pip install
#
# Note: force push detection has been moved to hooks/git/pre-push (git native hook),
# This hook is installed to each project .git/hooks/pre-push through scripts/install-hook.sh.

set -euo pipefail

source "$(dirname "$0")/log.sh"
vg_start_timer

INPUT=$(cat)

COMMAND=$(echo "$INPUT" | vg_json_field "tool_input.command")

if [[ -z "$COMMAND" ]]; then
  exit 0
fi

# Remove heredoc content to avoid false positives caused by multi-line text
# Cover variants: <<EOF, <<'EOF', <<"EOF", <<-EOF, <<-'EOF', << 'EOF' etc.
COMMAND_NO_HEREDOC=$(echo "$COMMAND" | python3 -c '
import re, sys
cmd = sys.stdin.read()
# Matches <<[-]? Optional spaces Optional quotes Terminator Optional quotes until end of line terminator
cmd = re.sub(r"<<-?\s*[\"'"'"']?(\w+)[\"'"'"']?.*?\n\1", "", cmd, flags=re.DOTALL)
print(cmd)
' 2>/dev/null || echo "$COMMAND")

# Strip quotation marks (commit message, echo string, etc.) to avoid text content triggering false alarms
# Keep the command structure and replace the quoted content with an empty string
COMMAND_STRIPPED=$(echo "$COMMAND_NO_HEREDOC" | python3 -c "
import re, sys
cmd = sys.stdin.read()
# Remove double quotes and single quotes
cmd = re.sub(r'\"[^\"]*\"', '\"\"', cmd)
cmd = re.sub(r\"'[^']*'\", \"''\", cmd)
print(cmd)
" 2>/dev/null || echo "$COMMAND_NO_HEREDOC")

# Use path scanning: remove quotation marks but retain the content to prevent rm -rf \"/Users/...\" from being bypassed
COMMAND_PATH_SCAN=$(printf '%s' "$COMMAND_NO_HEREDOC" | tr -d "\"'")

block() {
  local reason="$1"
  vg_log "pre-bash-guard" "Bash" "block" "$reason" "$COMMAND"
  vg_json_output_kv decision block reason "VIBEGUARD interception: ${reason}"
  exit 0
}

# git reset --hard — Allow execution (users need to use it in scenarios such as rebase conflicts)

# git checkout . / git restore . (discard all changes)
# Only matches pure "." endings, excluding legal path operations such as git checkout ./src/file
if echo "$COMMAND_STRIPPED" | grep -qE 'git\s+(checkout|restore)\s+\.\s*(;|&&|\|\||$)'; then
  block "Disable git checkout/restore. (discard all changes in batches). Alternatives: git checkout -- <specific file> specifies the files to be discarded; git stash temporarily stores all changes (recoverable); git diff first checks the changes before deciding."
fi

# git clean -f (delete untracked files)
if echo "$COMMAND_STRIPPED" | grep -qE 'git\s+clean\s+.*-f'; then
  block "Disable git clean -f (untracked files are permanently deleted and cannot be recovered). Alternatives: git clean -n (dry run preview) to see what will be deleted first; git stash --include-untracked to temporarily store untracked files; manually rm to specify files."
fi

# rm -rf dangerous path detection (covers rm -rf, rm -fr, rm -Rf, rm --recursive --force and other variants)
# First identify the rm -rf command in the command structure of "remove quotation marks", and then perform dangerous path matching in the text that retains the path content.
if echo "$COMMAND_STRIPPED" | grep -qE '(^|[;&|][[:space:]]*)(sudo[[:space:]]+)?(\\?rm)[[:space:]]+((-[a-zA-Z]*([rR][a-zA-Z]*f|f[a-zA-Z]*[rR]))|(--(recursive|force)[[:space:]]+--(recursive|force)))([[:space:]]|$)'; then
  DANGEROUS=false
  # Dangerous paths: root directory, home directory (including /Users/xxx, /home/xxx), system directory
  for pattern in \
    '[[:space:]]/([[:space:];|&]|$)' \
    '[[:space:]]~([[:space:];|&/]|$)' \
    '\$HOME' \
    '[[:space:]]/Users(/[^/[:space:];|&]*)?([[:space:];|&]|$)' \
    '[[:space:]]/home(/[^/[:space:];|&]*)?([[:space:];|&]|$)' \
    '[[:space:]]/(etc|var|usr|bin|sbin|opt|System|Library)([[:space:];|&/]|$)'; do
    if echo "$COMMAND_PATH_SCAN" | grep -qE "$pattern"; then
      DANGEROUS=true
      break
    fi
  done
  if [[ "$DANGEROUS" == true ]]; then
    block "Prohibit rm -rf dangerous paths (the root directory, home directory, and system directory are not recoverable). Alternatives: rm -rf <specific deep subdirectory> specifies the exact path; rm -ri interactively confirms; first confirm the target with ls and then delete it."
  fi
fi


# --- git commit interception: Claude Code has no PreCommit event, and is filled in through Bash hook ---
if echo "$COMMAND_STRIPPED" | grep -qE 'git\s+commit\b'; then
  # Explicit skip
  if ! echo "$COMMAND" | grep -qE 'VIBEGUARD_SKIP_PRECOMMIT=1'; then
    HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
    PRECOMMIT_SCRIPT="${HOOK_DIR}/pre-commit-guard.sh"
    if [[ -f "$PRECOMMIT_SCRIPT" ]]; then
      PRECOMMIT_EXIT=0
      PRECOMMIT_OUTPUT=$(VIBEGUARD_DIR="${VIBEGUARD_DIR:-$(cd "$HOOK_DIR/.." && pwd)}" bash "$PRECOMMIT_SCRIPT" 2>&1) || PRECOMMIT_EXIT=$?
      if [[ $PRECOMMIT_EXIT -ne 0 ]]; then
        vg_log "pre-bash-guard" "Bash" "block" "pre-commit check failed" "$COMMAND"
        # Embed detailed output into reason so Claude Code can see it
        # (stderr is not visible to the agent, only the JSON reason field is)
        # Use Python for JSON output to avoid double-escaping (PRECOMMIT_OUTPUT
        # may contain newlines/quotes that need exactly one round of escaping).
        VG_PRECOMMIT_OUTPUT="$PRECOMMIT_OUTPUT" python3 -c '
import json, os
output = os.environ.get("VG_PRECOMMIT_OUTPUT", "")
reason = "VIBEGUARD Pre-Commit 检查失败。请根据上方错误信息修复问题后重新提交。禁止使用环境变量绕过。\n\n" + output
print(json.dumps({"decision": "block", "reason": reason}))
'
        exit 0
      fi
    fi
  fi
fi

# --- doc-file-blocker: Detect creation of non-standard .md files ---
# Allowed .md files: README, CLAUDE, CONTRIBUTING, CHANGELOG, LICENSE, SKILL
# Fix doc-file-blocker: exclude temp file paths and paths containing numbers
# (e.g. /tmp/doc123.md, mktemp output) which are not persistent documentation.
if echo "$COMMAND_STRIPPED" | grep -qE "(cat|echo|printf|tee)\s.*>.*\.md\b" 2>/dev/null; then
  # Skip if writing to a temp/system directory (not a project doc)
  if echo "$COMMAND_STRIPPED" | grep -qE ">.*(/tmp/|/var/|/proc/|\$TMPDIR|\$TEMP|mktemp)" 2>/dev/null; then
    true  # temp path — pass through
  elif ! echo "$COMMAND_STRIPPED" | grep -qiE "(README|CLAUDE|CONTRIBUTING|CHANGELOG|LICENSE|SKILL)\.md" 2>/dev/null; then
    # Output a warning instead of blocking (probably reasonable document creation)
    vg_log "pre-bash-guard" "Bash" "warn" "Non-standard .md file" "$COMMAND"
    vg_json_output_kv decision warn reason "VIBEGUARD Warning: Creation of non-standard .md file detected. Only README/CLAUDE/CONTRIBUTING/CHANGELOG/LICENSE/SKILL.md is allowed to be created. Please confirm the file purpose if necessary."
    exit 0
  fi
fi

# --- Package manager transparent correction (updatedInput) ---
# Mechanically predictable commands can be rewritten directly without block+retry.
# Only for simple single commands (chain commands including && and other chain commands are not corrected to avoid mistakenly modifying complex pipelines).
_PKG_REWRITE_SCRIPT="$(dirname "$0")/_lib/pkg_rewrite.py"
_PKG_CORRECTION=$(printf '%s' "$COMMAND" | python3 "$_PKG_REWRITE_SCRIPT" 2>/dev/null || echo "")

if [[ -n "$_PKG_CORRECTION" ]]; then
  # Verify target tool is actually installed before rewriting — avoids turning
  # a working command into one that will always fail (e.g. no pnpm/uv on PATH).
  _target_tool="${_PKG_CORRECTION%% *}"
  if ! command -v "$_target_tool" &>/dev/null; then
    vg_log "pre-bash-guard" "Bash" "pass" "pkg-rewrite skipped (${_target_tool} not found)" "${COMMAND:0:120}"
    exit 0
  fi
  # For uv pip install, also require an active or local virtual environment;
  # without one uv pip fails immediately, making the rewrite harmful.
  if [[ "$_PKG_CORRECTION" == uv\ pip\ install* ]] \
      && [[ -z "${VIRTUAL_ENV:-}" ]] && [[ ! -d ".venv" ]]; then
    vg_log "pre-bash-guard" "Bash" "pass" "pkg-rewrite skipped (no active venv for uv pip)" "${COMMAND:0:120}"
    exit 0
  fi
  vg_log "pre-bash-guard" "Bash" "correction" "package manager auto-rewrite" "${COMMAND:0:120} → $_PKG_CORRECTION"
  python3 -c "
import json, sys
corrected = sys.argv[1]
print(json.dumps({'decision': 'allow', 'updatedInput': {'command': corrected}}))
" "$_PKG_CORRECTION"
  exit 0
fi

# Pass all checks → Release
vg_log "pre-bash-guard" "Bash" "pass" "" "$COMMAND"
exit 0
