<!-- Generated from docs/directory-guidance.md; do not edit directly. -->

# claude-md/ directory

This directory contains the shared global contract and host-specific additions
injected into Claude Code and Codex.

1. `vibeguard-rules.md` contains the shared core and managed markers.
2. `vibeguard-claude.md` and `vibeguard-codex.md` contain host-only guidance.
3. `python3 scripts/generate_rule_docs.py` composes the generated host blocks.
4. `setup.sh` injects the matching block between `<!-- vibeguard-start -->` and
   `<!-- vibeguard-end -->`, preserving content outside the managed region.

To change injected rules, edit `rules/claude-rules/**` first, including the
`**Compact guidance:**` field when selected for compact injection. Regenerate
the rule docs, rerun setup, and validate both Claude and Codex rendered blocks.
The updated contract becomes active in a new host session after setup reruns.
