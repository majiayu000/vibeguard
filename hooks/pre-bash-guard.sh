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

if ! COMMAND=$(printf '%s' "$INPUT" | vg_json_field_strict "tool_input.command"); then
  vg_log "pre-bash-guard" "Bash" "block" "invalid Bash hook input JSON; fail-closed" ""
  vg_json_output_kv decision block reason "VIBEGUARD interception: invalid Bash hook input JSON; fail-closed because tool_input.command could not be parsed."
  exit 0
fi

if [[ -z "$COMMAND" ]]; then
  exit 0
fi

# Prepare all derived command strings in one runtime call:
# - COMMAND_NO_HEREDOC removes heredoc bodies to avoid false positives.
# - COMMAND_STRIPPED hides quoted content before command-structure regexes.
# - COMMAND_PATH_SCAN removes quotes but keeps path content for rm -rf checks.
# - COMMAND_STRIPPED_WITH_DOT preserves quoted standalone dots for checkout/restore detection.
if ! {
  IFS= read -r -d '' COMMAND_NO_HEREDOC \
    && IFS= read -r -d '' COMMAND_STRIPPED \
    && IFS= read -r -d '' COMMAND_PATH_SCAN \
    && IFS= read -r -d '' COMMAND_STRIPPED_WITH_DOT
} < <(printf '%s' "$COMMAND" | "$_VIBEGUARD_RUNTIME" bash-preprocess 2>/dev/null); then
  vg_log "pre-bash-guard" "Bash" "block" "Bash command preprocessing failed; fail-closed." "$COMMAND"
  vg_json_output_kv decision block reason "VIBEGUARD interception: Bash command preprocessing failed; fail-closed."
  exit 0
fi

block() {
  local reason="$1"
  vg_log "pre-bash-guard" "Bash" "block" "$reason" "$COMMAND"
  vg_json_output_kv decision block reason "VIBEGUARD interception: ${reason}"
  exit 0
}

# git reset --hard — Allow execution (users need to use it in scenarios such as rebase conflicts)

# git checkout . / git restore . (discard all changes)
# Only matches pure "." endings, excluding legal path operations such as git checkout ./src/file
# COMMAND_STRIPPED_WITH_DOT converts "." / '.' to a bare dot then strips other quoted content,
# so a no-anchor regex safely detects all wrapper forms (env vars, pipes, `command`, `env`,
# and shell redirections such as heredoc openers) without false-positives from separators
# inside commit messages or string arguments.
_VG_RE_GIT_DISCARD='git[[:space:]]+(checkout|restore)[[:space:]]+\.[[:space:]]*(;|&&|\|\||[<>]|$)'
if [[ "$COMMAND_STRIPPED_WITH_DOT" =~ $_VG_RE_GIT_DISCARD ]]; then
  block "Disable git checkout/restore. (discard all changes in batches). Alternatives: git checkout -- <specific file> specifies the files to be discarded; git stash temporarily stores all changes (recoverable); git diff first checks the changes before deciding."
fi

# git clean -f (delete untracked files)
_VG_RE_GIT_CLEAN='git[[:space:]]+clean[[:space:]]+.*-f'
if [[ "$COMMAND_STRIPPED" =~ $_VG_RE_GIT_CLEAN ]]; then
  block "Disable git clean -f (untracked files are permanently deleted and cannot be recovered). Alternatives: git clean -n (dry run preview) to see what will be deleted first; git stash --include-untracked to temporarily store untracked files; manually rm to specify files."
fi

# rm -rf dangerous path detection (covers rm -rf, rm -fr, rm -Rf, rm --recursive --force and other variants)
# First identify the rm -rf command in the command structure of "remove quotation marks", and then perform dangerous path matching in the text that retains the path content.
_VG_RE_RM_RF='(^|[;&|][[:space:]]*)(sudo[[:space:]]+)?(\\?rm)[[:space:]]+((-[a-zA-Z]*([rR][a-zA-Z]*f|f[a-zA-Z]*[rR]))|(--(recursive|force)[[:space:]]+--(recursive|force)))([[:space:]]|$)'
if [[ "$COMMAND_STRIPPED" =~ $_VG_RE_RM_RF ]]; then
  DANGEROUS=false
  # Dangerous paths: root directory, home directory (including /Users/xxx, /home/xxx), system directory
  for pattern in \
    '[[:space:]]/([[:space:];|&]|$)' \
    '[[:space:]]~([[:space:];|&/]|$)' \
    '\$HOME' \
    '[[:space:]]/Users(/[^/[:space:];|&]*)?([[:space:];|&]|$)' \
    '[[:space:]]/home(/[^/[:space:];|&]*)?([[:space:];|&]|$)' \
    '[[:space:]]/(etc|var|usr|bin|sbin|opt|System|Library)([[:space:];|&/]|$)'; do
    if [[ "$COMMAND_PATH_SCAN" =~ $pattern ]]; then
      DANGEROUS=true
      break
    fi
  done
  if [[ "$DANGEROUS" == true ]]; then
    block "Prohibit rm -rf dangerous paths (the root directory, home directory, and system directory are not recoverable). Alternatives: rm -rf <specific deep subdirectory> specifies the exact path; rm -ri interactively confirms; first confirm the target with ls and then delete it."
  fi
fi


# --- git commit interception: Claude Code has no PreCommit event, and is filled in through Bash hook ---
_VG_RE_GIT_COMMIT='git[[:space:]]+commit($|[^A-Za-z0-9_])'
if [[ "$COMMAND_STRIPPED" =~ $_VG_RE_GIT_COMMIT ]]; then
  # Explicit skip
  if [[ ! "$COMMAND" =~ VIBEGUARD_SKIP_PRECOMMIT=1 ]]; then
    HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
    PRECOMMIT_SCRIPT="${HOOK_DIR}/pre-commit-guard.sh"
    if [[ -f "$PRECOMMIT_SCRIPT" ]]; then
      PRECOMMIT_EXIT=0
      PRECOMMIT_OUTPUT=$(VIBEGUARD_DIR="${VIBEGUARD_DIR:-$(cd "$HOOK_DIR/.." && pwd)}" bash "$PRECOMMIT_SCRIPT" 2>&1) || PRECOMMIT_EXIT=$?
      if [[ $PRECOMMIT_EXIT -ne 0 ]]; then
        vg_log "pre-bash-guard" "Bash" "block" "pre-commit check failed" "$COMMAND"
        # Embed detailed output into reason so Claude Code can see it
        # (stderr is not visible to the agent, only the JSON reason field is)
        # Pass via stdin to avoid execve argv+env size limit on large output.
        printf '%s' "$PRECOMMIT_OUTPUT" | python3 -c '
import json, sys
output = sys.stdin.read()
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
_VG_RE_DOC_WRITE='(cat|echo|printf|tee)[[:space:]].*>.*\.md($|[^A-Za-z0-9_])'
if [[ "$COMMAND_STRIPPED" =~ $_VG_RE_DOC_WRITE ]]; then
  # Skip if writing to a temp/system directory (not a project doc)
  _VG_RE_TEMP_DOC='>.*(/tmp/|/var/|/proc/|\$TMPDIR|\$TEMP|mktemp)'
  if [[ "$COMMAND_STRIPPED" =~ $_VG_RE_TEMP_DOC ]]; then
    true  # temp path — pass through
  elif [[ ! "$COMMAND_STRIPPED" =~ (README|CLAUDE|CONTRIBUTING|CHANGELOG|LICENSE|SKILL)\.[mM][dD] ]]; then
    # Output a warning instead of blocking (probably reasonable document creation)
    vg_log "pre-bash-guard" "Bash" "warn" "Non-standard .md file" "$COMMAND"
    vg_json_output_kv decision warn reason "VIBEGUARD Warning: Creation of non-standard .md file detected. Only README/CLAUDE/CONTRIBUTING/CHANGELOG/LICENSE/SKILL.md is allowed to be created. Please confirm the file purpose if necessary."
    exit 0
  fi
fi

# --- Package manager transparent correction (updatedInput) ---
# Mechanically predictable commands can be rewritten directly without block+retry.
# Only for simple single commands (chain commands including && and other chain commands are not corrected to avoid mistakenly modifying complex pipelines).
_PKG_CORRECTION=$(printf '%s' "$COMMAND" | "$_VIBEGUARD_RUNTIME" pkg-rewrite 2>/dev/null || echo "")

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
  # PKG-CORRECTION-JSON-CONTRACT: pass the generated command to the runtime via stdin.
  # Never interpolate _PKG_CORRECTION into code or shell eval.
  printf '%s' "$_PKG_CORRECTION" | "$_VIBEGUARD_RUNTIME" allow-command-json
  exit 0
fi

# Pass all checks → Release
vg_log "pre-bash-guard" "Bash" "pass" "" "$COMMAND"
exit 0
