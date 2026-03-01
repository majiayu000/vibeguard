#!/usr/bin/env python3
"""CLAUDE.md VibeGuard rules inject/remove."""
import sys
from pathlib import Path

START = "<!-- vibeguard-start -->"
END = "<!-- vibeguard-end -->"


def inject(claude_md_path: str, rules_path: str, vibeguard_dir: str) -> str:
    claude_md = Path(claude_md_path)
    rules = Path(rules_path).read_text()
    rules = rules.replace("__VIBEGUARD_DIR__", vibeguard_dir)

    content = claude_md.read_text() if claude_md.exists() else ""

    start_idx = content.find(START)
    end_idx = content.find(END)

    if start_idx >= 0 and end_idx >= 0:
        before = content[:start_idx].rstrip()
        after = content[end_idx + len(END) :].lstrip("\n")
        content = before + "\n\n" + rules.strip() + "\n"
        if after:
            content += "\n" + after
        action = "UPDATED"
    else:
        legacy_marker = "\n# VibeGuard"
        legacy_idx = content.find(legacy_marker)
        if legacy_idx >= 0:
            content = content[:legacy_idx].rstrip()
        content = content.rstrip() + "\n\n" + rules.strip() + "\n"
        action = "APPENDED"

    claude_md.write_text(content)
    return action


def remove(claude_md_path: str) -> str:
    claude_md = Path(claude_md_path)
    if not claude_md.exists():
        return "NOT_FOUND"

    content = claude_md.read_text()
    start_idx = content.find(START)
    end_idx = content.find(END)

    if start_idx >= 0 and end_idx >= 0:
        before = content[:start_idx].rstrip()
        after = content[end_idx + len(END) :].lstrip("\n")
        content = before
        if after:
            content += "\n\n" + after
        content = content.rstrip() + "\n"
        claude_md.write_text(content)
        return "REMOVED"

    legacy_marker = "\n# VibeGuard"
    idx = content.find(legacy_marker)
    if idx >= 0:
        content = content[:idx].rstrip() + "\n"
        claude_md.write_text(content)
        return "REMOVED_LEGACY"

    return "NOT_FOUND"


if __name__ == "__main__":
    action = sys.argv[1]
    if action == "inject":
        print(inject(sys.argv[2], sys.argv[3], sys.argv[4]))
    elif action == "remove":
        print(remove(sys.argv[2]))
    else:
        print(f"Unknown action: {action}", file=sys.stderr)
        sys.exit(1)
