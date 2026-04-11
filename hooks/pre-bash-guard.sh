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
  cat <<BLOCK_EOF
{
  "decision": "block",
  "reason": "VIBEGUARD interception: ${reason}"
}
BLOCK_EOF
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
        ESCAPED_OUTPUT=$(printf '%s' "$PRECOMMIT_OUTPUT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read())[1:-1])')
        cat <<BLOCK_EOF
{
  "decision": "block",
  "reason": "VIBEGUARD Pre-Commit 检查失败。请根据上方错误信息修复问题后重新提交。禁止使用环境变量绕过。\n\n${ESCAPED_OUTPUT}"
}
BLOCK_EOF
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
    cat <<WARN_EOF
{
  "decision": "warn",
  "reason": "VIBEGUARD Warning: Creation of non-standard .md file detected. Only README/CLAUDE/CONTRIBUTING/CHANGELOG/LICENSE/SKILL.md is allowed to be created. Please confirm the file purpose if necessary."
}
WARN_EOF
    exit 0
  fi
fi

# --- Package manager transparent correction (updatedInput) ---
# Mechanically predictable commands can be rewritten directly without block+retry.
# Only for simple single commands (chain commands including && and other chain commands are not corrected to avoid mistakenly modifying complex pipelines).
_PKG_CORRECTION=$(printf '%s' "$COMMAND" | python3 -c '
import sys, re

cmd = sys.stdin.read().strip()
corrected = None

# Skip complex commands (&&, &, ||, ;, pipe, redirection, newline, $() expansion, backtick) - complex pipelines do not automatically rewrite
if not re.search(r"&&|&|\|\||;|[|<>\n\r]|\$\(|`", cmd):

    # npm install (no parameters) → pnpm install
    if re.match(r"^npm\s+(?:install|i)\s*$", cmd):
        corrected = "pnpm install"

    # npm install/add <packages>
    # Only correct when there is an actual package name and all flags are translatable, excluding global installation and incompatible flags
    elif re.match(r"^npm\s+(?:install|i|add)\s+", cmd):
        rest = re.sub(r"^npm\s+(?:install|i|add)\s+", "", cmd).strip()
        tokens = rest.split()

        # Known translatable npm flags
        KNOWN_FLAGS = {"--save-dev", "-D", "--save", "-S", "--save-optional", "-O", "--save-exact", "-E"}

        is_global = any(t in ("-g", "--global") or t.startswith("--location=global") for t in tokens)
        unknown_flags = [t for t in tokens if t.startswith("-") and t not in KNOWN_FLAGS]
        packages = [t for t in tokens if not t.startswith("-")]

        if packages and not is_global and not unknown_flags:
            pnpm_flags = []
            for t in tokens:
                if t in ("--save-dev", "-D"):
                    pnpm_flags.append("-D")
                elif t in ("--save-optional", "-O"):
                    pnpm_flags.append("-O")
                elif t in ("--save-exact", "-E"):
                    pnpm_flags.append("--save-exact")
                # --save/-S is pnpm default, skip
            corrected = "pnpm add " + " ".join(pnpm_flags + packages).strip()

    # yarn install (no parameters) → pnpm install
    elif re.match(r"^yarn\s+install\s*$", cmd):
        corrected = "pnpm install"

    # yarn add <packages> → pnpm add <packages>
    # Only rewrite when all flags are known pnpm-compatible; unknown flags fall through.
    elif re.match(r"^yarn\s+add\s+", cmd):
        rest = re.sub(r"^yarn\s+add\s+", "", cmd)
        tokens = rest.split()
        YARN_KNOWN_FLAGS = {"-D", "--dev", "--save-dev", "-O", "--optional",
                            "-E", "--exact", "-P", "--save-peer",
                            "-W", "--ignore-workspace-root-check"}
        packages = [t for t in tokens if not t.startswith("-")]
        unknown_flags = [t for t in tokens if t.startswith("-") and t not in YARN_KNOWN_FLAGS]
        if packages and not unknown_flags:
            pnpm_flags = []
            for t in tokens:
                if t in ("-D", "--dev", "--save-dev"):
                    pnpm_flags.append("-D")
                elif t in ("-O", "--optional"):
                    pnpm_flags.append("-O")
                elif t in ("-E", "--exact"):
                    pnpm_flags.append("--save-exact")
                elif t in ("-P", "--save-peer"):
                    pnpm_flags.append("--save-peer")
                elif t in ("-W", "--ignore-workspace-root-check"):
                    pnpm_flags.append("-w")
            corrected = "pnpm add " + " ".join(pnpm_flags + packages).strip()

    # pip install / pip3 install → uv pip install
    # Only rewrite when all flags are known uv-pip-compatible; unknown flags fall through.
    elif re.match(r"^pip3?\s+install\s+", cmd):
        rest = re.sub(r"^pip3?\s+install\s+", "", cmd)
        tokens = rest.split()
        PIP_KNOWN_FLAGS = {"-r", "--requirement", "-e", "--editable",
                           "-U", "--upgrade", "--pre", "--no-deps",
                           "-i", "--index-url", "--extra-index-url", "--no-index",
                           "-f", "--find-links", "-c", "--constraint",
                           "-v", "--verbose", "-q", "--quiet", "-t", "--target"}
        unknown_flags = [t for t in tokens if t.startswith("-") and t not in PIP_KNOWN_FLAGS]
        if not unknown_flags:
            corrected = "uv pip install " + rest

    # python -m pip install / python3 -m pip install → uv pip install
    elif re.match(r"^python3?\s+-m\s+pip\s+install\s+", cmd):
        rest = re.sub(r"^python3?\s+-m\s+pip\s+install\s+", "", cmd)
        tokens = rest.split()
        PIP_KNOWN_FLAGS = {"-r", "--requirement", "-e", "--editable",
                           "-U", "--upgrade", "--pre", "--no-deps",
                           "-i", "--index-url", "--extra-index-url", "--no-index",
                           "-f", "--find-links", "-c", "--constraint",
                           "-v", "--verbose", "-q", "--quiet", "-t", "--target"}
        unknown_flags = [t for t in tokens if t.startswith("-") and t not in PIP_KNOWN_FLAGS]
        if not unknown_flags:
            corrected = "uv pip install " + rest

print(corrected or "")
' 2>/dev/null || echo "")

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
