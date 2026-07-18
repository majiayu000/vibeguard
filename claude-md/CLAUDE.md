# claude-md/ directory

VibeGuard rule injection mechanism. This directory contains template files that inject VibeGuard rules into users `~/.claude/CLAUDE.md`.

## How to work

1. `vibeguard-rules.md` contains the rule content injected into CLAUDE.md
2. `setup.sh` manages the injection area through `<!-- vibeguard-start -->` / `<!-- vibeguard-end -->` tags
3. Rerunning `setup.sh` will update the content in the existing marked area and will not affect user-defined content.

## Modify rules

1. Edit the canonical rule under `rules/claude-rules/**`, including its `**Compact guidance:**` field when the rule is selected for compact injection
2. Run `python3 scripts/generate_rule_docs.py` from the repository root
3. Run `bash setup.sh` to re-inject
4. Valid in new Claude Code session
