# claude-md/ directory

VibeGuard rule injection mechanism. This directory contains template files that inject VibeGuard rules into users `~/.claude/CLAUDE.md`.

## How to work

1. `vibeguard-rules.md` contains the rule content injected into CLAUDE.md
2. `setup.sh` manages the injection area through `<!-- vibeguard-start -->` / `<!-- vibeguard-end -->` tags
3. Rerunning `setup.sh` will update the content in the existing marked area and will not affect user-defined content.

## Modify rules

1. Edit `vibeguard-rules.md`
2. Run `bash setup.sh` to re-inject
3. Valid in new Claude Code session
