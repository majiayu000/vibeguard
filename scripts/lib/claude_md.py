#!/usr/bin/env python3
"""CLAUDE.md VibeGuard rules inject/remove."""
import difflib
import re
import sys
from pathlib import Path
from typing import Optional

START = "<!-- vibeguard-start -->"
END = "<!-- vibeguard-end -->"
MANAGED_ANCHOR = "#VibeGuard"
ROUTING_CONTRACT_REF = "`workflows/references/routing-contract.md`"
RULE_COUNT_PLACEHOLDER = "__VIBEGUARD_RULE_COUNT__"
RULE_HEADING_RE = re.compile(
    r"^##\s+(?:RS|GO|TS|PY|U|SEC|W|TASTE)-[A-Za-z0-9-]+(?:\s|:|$)",
    re.MULTILINE,
)


def count_rule_headings(root: Path) -> int:
    if not root.exists():
        return 0
    total = 0
    for rule_file in root.rglob("*.md"):
        if not rule_file.is_file():
            continue
        text = rule_file.read_text(encoding="utf-8", errors="replace")
        total += len(RULE_HEADING_RE.findall(text))
    return total


def resolve_rule_count(vibeguard_dir: str, rule_count: Optional[int]) -> int:
    if rule_count is not None:
        return rule_count
    return count_rule_headings(Path(vibeguard_dir) / "rules" / "claude-rules")


def iter_managed_blocks(content: str):
    pos = 0
    while True:
        start = content.find(START, pos)
        if start < 0:
            return
        after_start = start + len(START)
        next_start = content.find(START, after_start)
        end = content.find(END, after_start)
        if end < 0:
            return
        if 0 <= next_start < end:
            pos = after_start
            continue
        end_after = end + len(END)
        if MANAGED_ANCHOR in content[start:end_after]:
            yield start, end_after
        pos = end_after


def first_managed_block_range(content: str) -> Optional[tuple[int, int]]:
    for start, end_after in iter_managed_blocks(content):
        return start, end_after
    return None


def count_managed_blocks(content: str) -> int:
    return sum(1 for _ in iter_managed_blocks(content))


def managed_span_lines(content: str) -> tuple[int, int, int]:
    blocks = list(iter_managed_blocks(content))
    if not blocks:
        return 0, 0, 0
    start, end_after = blocks[0]
    start_line = content[:start].count("\n") + 1
    end_line = content[: end_after - 1].count("\n") + 1
    return len(blocks), start_line, end_line


def render_injected(
    claude_md_path: str,
    rules_path: str,
    vibeguard_dir: str,
    rule_count: Optional[int] = None,
) -> tuple[str, str, str]:
    claude_md = Path(claude_md_path)
    rules = Path(rules_path).read_text()
    rules = rules.replace("__VIBEGUARD_DIR__", vibeguard_dir)
    rules = rules.replace(
        ROUTING_CONTRACT_REF,
        f"`{vibeguard_dir}/workflows/references/routing-contract.md`",
    )
    rules = rules.replace(RULE_COUNT_PLACEHOLDER, str(resolve_rule_count(vibeguard_dir, rule_count)))

    original = claude_md.read_text() if claude_md.exists() else ""
    managed = first_managed_block_range(original)

    if managed is not None:
        start_idx, end_after = managed
        before = original[:start_idx].rstrip()
        after = original[end_after:].lstrip("\n")
        content = before + "\n\n" + rules.strip() + "\n"
        if after:
            content += "\n" + after
        action = "UPDATED"
    else:
        content = original.rstrip() + "\n\n" + rules.strip() + "\n"
        if not original.strip():
            content = rules.strip() + "\n"
        action = "APPENDED"

    return action, original, content


def inject(claude_md_path: str, rules_path: str, vibeguard_dir: str, rule_count: Optional[int] = None) -> str:
    action, _original, content = render_injected(claude_md_path, rules_path, vibeguard_dir, rule_count)
    claude_md = Path(claude_md_path)
    claude_md.write_text(content)
    return action


def diff_inject(claude_md_path: str, rules_path: str, vibeguard_dir: str, rule_count: Optional[int] = None) -> str:
    action, original, content = render_injected(claude_md_path, rules_path, vibeguard_dir, rule_count)
    if original == content:
        return "SKIP"
    diff = "".join(
        difflib.unified_diff(
            original.splitlines(keepends=True),
            content.splitlines(keepends=True),
            fromfile=claude_md_path,
            tofile=claude_md_path,
        )
    )
    return diff + action


def remove(claude_md_path: str) -> str:
    claude_md = Path(claude_md_path)
    if not claude_md.exists():
        return "NOT_FOUND"

    content = claude_md.read_text()
    managed = first_managed_block_range(content)

    if managed is not None:
        start_idx, end_after = managed
        before = content[:start_idx].rstrip()
        after = content[end_after:].lstrip("\n")
        content = before
        if after:
            content += "\n\n" + after
        content = content.rstrip() + "\n"
        claude_md.write_text(content)
        return "REMOVED"

    return "NOT_FOUND"


def parse_rule_count(value: Optional[str]) -> Optional[int]:
    if value is None:
        return None
    try:
        count = int(value)
    except ValueError:
        print(f"Invalid rule count: {value}", file=sys.stderr)
        sys.exit(2)
    if count < 0:
        print(f"Invalid rule count: {value}", file=sys.stderr)
        sys.exit(2)
    return count


if __name__ == "__main__":
    action = sys.argv[1]
    if action == "inject":
        rule_count = parse_rule_count(sys.argv[5] if len(sys.argv) > 5 else None)
        print(inject(sys.argv[2], sys.argv[3], sys.argv[4], rule_count))
    elif action == "diff-inject":
        rule_count = parse_rule_count(sys.argv[5] if len(sys.argv) > 5 else None)
        print(diff_inject(sys.argv[2], sys.argv[3], sys.argv[4], rule_count))
    elif action == "remove":
        print(remove(sys.argv[2]))
    elif action == "managed-span":
        count, start_line, end_line = managed_span_lines(Path(sys.argv[2]).read_text())
        print(f"{count} {start_line} {end_line}")
    else:
        print(f"Unknown action: {action}", file=sys.stderr)
        sys.exit(1)
