# claude-md/ directory

VibeGuard rule injection mechanism. This directory contains the shared global
contract and the host-specific additions injected into Claude Code and Codex.

## How to work

1. `vibeguard-rules.md` contains the cross-host shared core and managed markers.
2. `vibeguard-claude.md` contains Claude Code-only guidance.
3. `vibeguard-codex.md` contains Codex-only guidance.
4. `python3 scripts/generate_rule_docs.py` composes the shared core with each
   host addition into `vibeguard-claude-rules.md` and
   `vibeguard-codex-rules.md`.
5. `setup.sh` injects the matching generated block inside
   `<!-- vibeguard-start -->` / `<!-- vibeguard-end -->`.
6. Rerunning `setup.sh` updates only the marked area and preserves user content.

## Modify rules

1. Edit the canonical rule under `rules/claude-rules/**`, including its `**Compact guidance:**` field when the rule is selected for compact injection
2. Run `python3 scripts/generate_rule_docs.py` from the repository root
3. Run `bash setup.sh` to re-inject
4. Validate both Claude and Codex rendered blocks.
5. The change becomes active in a new host session after setup is rerun.
