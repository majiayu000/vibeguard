#!/usr/bin/env bash
# Ensure public docs do not overstate hook blocking behavior.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_DIR"

failures=0

require_absent() {
  local file="$1"
  local pattern="$2"
  local message="$3"
  if grep -Fq "$pattern" "$file"; then
    echo "FAIL: ${message}" >&2
    failures=$((failures + 1))
  fi
}

require_present() {
  local file="$1"
  local pattern="$2"
  local message="$3"
  if ! grep -Fq "$pattern" "$file"; then
    echo "FAIL: ${message}" >&2
    failures=$((failures + 1))
  fi
}

require_absent "README.md" '| AI tries to finish with unverified changes | `stop-guard` | **Gate**' \
  "README.md must not describe stop-guard as a blocking Gate"
require_present "README.md" '| AI tries to finish with unverified changes | `stop-guard` | **Signal**' \
  "README.md must describe stop-guard as a non-blocking Signal"
require_present "README.md" '| `Stop` | `stop-guard.sh` | Uncommitted changes signal (logs a `gate` event, non-blocking Stop) |' \
  "README.md Codex hook table must explain stop-guard logs gate events without blocking Stop"
require_absent "README.md" 'Stop Gate' \
  "README.md must not use the old Stop Gate wording"
require_present "README.md" 'Full: adds Stop signal + Build Check + learning' \
  "README.md installation example must describe Stop signal"
require_absent "README.md" 'Dangerous shell/git commands (`rm -rf`, `push --force`, `reset --hard`)' \
  "README.md summary must not advertise reset/force-push as one pre-bash command bucket"
require_present "README.md" 'Dangerous shell/git operations (`rm -rf` dangerous paths, `git clean -f`, non-fast-forward pushes)' \
  "README.md summary must describe current local-cleanup/pre-push split"
require_present "README.md" 'VibeGuard git pre-push hook denies' \
  "README.md example must attribute force-push denial to git pre-push"
require_present "README.md" '| AI creates new `.py/.ts/.rs/.go/.js` file | `pre-write-guard` | **Warn by default**' \
  "README.md must describe L1 new-source behavior as warn-by-default"
require_absent "README.md" '| AI runs `git push --force`, `rm -rf`, `reset --hard` | `pre-bash-guard` | **Block**' \
  "README.md must not assign force-push protection to pre-bash-guard"
require_present "README.md" '| AI pushes a non-fast-forward update or branch deletion | git `pre-push` | **Block**' \
  "README.md must assign force-push protection to git pre-push"
require_present "README.md" '`pre-bash-guard` does not regex-match `git push --force`' \
  "README.md must make the pre-bash/pre-push boundary explicit"
require_present "README.md" '| `PreToolUse(Bash)` | `pre-bash-guard.sh` | Destructive local cleanup interception + package manager correction |' \
  "README.md Codex hook table must not imply force-push lives in pre-bash"

require_absent "docs/README_CN.md" '| AI 想结束但还没有验证改动 | `stop-guard` | **闸门**' \
  "docs/README_CN.md must not describe stop-guard as a blocking gate"
require_present "docs/README_CN.md" '| AI 想结束但还没有验证改动 | `stop-guard` | **信号**' \
  "docs/README_CN.md must describe stop-guard as a signal"
require_present "docs/README_CN.md" '| `Stop` | `stop-guard.sh` | 未验证改动信号（记录 `gate` 事件，但 Stop 不阻塞） |' \
  "docs/README_CN.md Codex hook table must explain non-blocking Stop behavior"
require_absent "docs/README_CN.md" 'Stop Gate' \
  "docs/README_CN.md must not use the old Stop Gate wording"
require_present "docs/README_CN.md" '增加 Stop 信号、Build Check、学习闭环' \
  "docs/README_CN.md installation example must describe Stop signal"
require_present "docs/README_CN.md" '| AI 创建新的 `.py/.ts/.rs/.go/.js` 文件 | `pre-write-guard` | 默认 **告警**' \
  "docs/README_CN.md must describe L1 new-source behavior as warn-by-default"
require_absent "docs/README_CN.md" '| AI 执行 `git push --force`、`rm -rf`、`git clean -fd`、批量 `git checkout/restore .` | `pre-bash-guard`' \
  "docs/README_CN.md must not assign force-push protection to pre-bash-guard"
require_present "docs/README_CN.md" '| AI 推送非快进更新或删除远端分支 | git `pre-push` | **拦截**' \
  "docs/README_CN.md must assign force-push protection to git pre-push"
require_present "docs/README_CN.md" 'git `pre-push` hook 负责非快进推送/删除远端分支保护；`pre-bash-guard` 不用正则匹配 `git push --force`' \
  "docs/README_CN.md setup prose must make the pre-bash/pre-push boundary explicit"
require_present "docs/README_CN.md" '| `PreToolUse(Bash)` | `pre-bash-guard.sh` | 危险本地清理拦截 + 包管理器纠偏 |' \
  "docs/README_CN.md Codex hook table must not imply force-push lives in pre-bash"

require_absent "docs/CLAUDE.md.example" '| `Stop` has unverified source code changes | **Gate**' \
  "docs/CLAUDE.md.example must not describe stop-guard as a blocking Gate"
require_absent "docs/CLAUDE.md.example" 'Stop Gate' \
  "docs/CLAUDE.md.example must not use the old Stop Gate wording"
require_present "docs/CLAUDE.md.example" '| `Stop` has unverified source code changes | **Signal**' \
  "docs/CLAUDE.md.example must describe stop-guard as a signal"
require_present "docs/CLAUDE.md.example" 'additionally enable Stop signal / Learn evaluator' \
  "docs/CLAUDE.md.example setup snippet must describe Stop signal"
require_present "docs/CLAUDE.md.example" 'the `full` profile additionally enables the Stop signal' \
  "docs/CLAUDE.md.example setup prose must describe Stop signal"
require_absent "docs/CLAUDE.md.example" '| `Write` creates a new source code file | **Block**' \
  "docs/CLAUDE.md.example must not describe L1 new-source behavior as default block"
require_present "docs/CLAUDE.md.example" '| `Write` creates a new source code file | **Warn by default**' \
  "docs/CLAUDE.md.example must describe L1 new-source behavior as warn-by-default"
require_absent "docs/CLAUDE.md.example" '| `Bash` force push / rm -rf / reset --hard | **Block**' \
  "docs/CLAUDE.md.example must not assign force-push protection to pre-bash"
require_present "docs/CLAUDE.md.example" '| git `pre-push` detects non-fast-forward push / branch deletion | **Block**' \
  "docs/CLAUDE.md.example must assign force-push protection to git pre-push"

require_absent "scripts/setup/install.sh" 'Stop Gate' \
  "scripts/setup/install.sh usage comments must not use the old Stop Gate wording"
require_present "scripts/setup/install.sh" 'Install full (including Stop signal/Build Check)' \
  "scripts/setup/install.sh usage comments must describe Stop signal"

require_present "hooks/manifest.json" 'Record uncommitted source code changes as a non-blocking Stop signal.' \
  "hooks manifest must describe stop-guard as a non-blocking Stop signal"
require_absent "hooks/manifest.json" 'Intercept dangerous commands: force push, rm -rf /, reset --hard, etc.' \
  "hooks manifest must not assign force-push protection to pre-bash-guard"
require_present "hooks/manifest.json" 'force-push protection lives in the git pre-push hook' \
  "hooks manifest must describe force-push as git pre-push owned"
require_present "hooks/CLAUDE.md" '| `stop-guard.sh` | Stop | Record uncommitted source code changes as a non-blocking Stop signal. | native |' \
  "generated hook docs must describe stop-guard as a non-blocking Stop signal"
require_present "hooks/CLAUDE.md" '| `pre-bash-guard.sh` | PreToolUse(Bash) | Intercept destructive local cleanup commands:' \
  "generated hook docs must describe pre-bash local cleanup scope"

require_absent "docs/assets/demo-scenario.sh" 'pre-bash-guard: blocked `git push --force`' \
  "demo script must not show force-push as pre-bash behavior"
require_present "docs/assets/demo-scenario.sh" 'git pre-push hook: blocked non-fast-forward push' \
  "demo script must show force-push as git pre-push behavior"

require_present "scripts/setup/targets/claude-home.sh" 'Stop signal + Build check + Learn evaluator' \
  "setup status must avoid the old Stop gate wording"

if [[ "$failures" -gt 0 ]]; then
  exit 1
fi

echo "OK: hook behavior docs match current hook semantics"
