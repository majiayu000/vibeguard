#!/usr/bin/env python3
"""Shared SKILL.md format validation rules."""

from __future__ import annotations

import re
from pathlib import Path


FORMAT_PATH_PATTERNS = (
    "skills/*/SKILL.md",
    "workflows/*/SKILL.md",
    ".claude/skills/*/SKILL.md",
    "templates/skill-template.md",
)
FORMAT_REQUIRED_SECTIONS = ("## When to Activate", "## Red Flags", "## Checklist")
FORMAT_LIST_SECTIONS = ("## Red Flags", "## Checklist")
MIN_RED_FLAGS = 3
MIN_CHECKLIST_ITEMS = 3
FRONTMATTER_FIELD_PATTERN = re.compile(r"^[A-Za-z][A-Za-z0-9_-]*:\s*.*$")
FRONTMATTER_BLOCK_SCALAR_PATTERN = re.compile(
    r"^[A-Za-z][A-Za-z0-9_-]*:\s*[|>](?:(?:[1-9][+-]?)|(?:[+-][1-9]?))?\s*(?:#.*)?$",
)


def default_skill_paths(repo_dir: Path) -> list[Path]:
    paths: list[Path] = []
    for pattern in FORMAT_PATH_PATTERNS:
        paths.extend(repo_dir.glob(pattern))
    return sorted(path for path in paths if path.is_file())


def section_body(text: str, heading: str) -> str | None:
    label = heading.removeprefix("## ")
    pattern = re.compile(
        rf"(?ms)^##\s+{re.escape(label)}\s*$\n(?P<body>.*?)(?=^##\s+|\Z)",
    )
    match = pattern.search(text)
    if not match:
        return None
    return match.group("body")


def _list_item_text(line: str) -> str | None:
    match = re.match(r"^\s*(?:[-*+]|\d+[.)])\s+(?P<item>\S.*)$", line)
    if not match:
        return None
    return re.sub(r"^\[[ xX]\]\s+", "", match.group("item").strip())


def _useful_item_text(item: str) -> bool:
    lower = item.strip(" .").lower()
    if not lower or lower in {"...", "todo", "tbd", "n/a", "none", "placeholder"}:
        return False
    starts_with_markdown_link = re.match(
        r"^\[[^\]\n]+\](?:\([^)]+\)|\[[^\]\n]*\])",
        item,
    ) is not None
    if lower.startswith(("todo:", "tbd:", "<")):
        return False
    if lower.startswith("[") and not starts_with_markdown_link:
        return False
    return True


def useful_list_item(line: str) -> bool:
    item = _list_item_text(line)
    return item is not None and _useful_item_text(item)


def useful_checklist_item(line: str) -> bool:
    match = re.match(r"^\s*-\s+\[[ xX]\]\s+(?P<item>\S.*)$", line)
    return match is not None and _useful_item_text(match.group("item").strip())


def count_useful_bullets(body: str) -> int:
    return sum(1 for line in body.splitlines() if useful_list_item(line))


def count_plain_bullets(body: str) -> int:
    return sum(1 for line in body.splitlines() if re.match(r"^\s*-\s+\S", line))


def count_useful_checklist_items(body: str) -> int:
    return sum(1 for line in body.splitlines() if useful_checklist_item(line))


def validate_frontmatter(text: str) -> list[str]:
    errors: list[str] = []
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        errors.append("missing YAML frontmatter opening")
        return errors

    closing_index = next((index for index, line in enumerate(lines[1:], start=1) if line.strip() == "---"), None)
    if closing_index is None:
        errors.append("missing YAML frontmatter closing")
        return errors

    frontmatter_lines = lines[1:closing_index]
    in_block_scalar = False
    for line_number, line in enumerate(frontmatter_lines, start=2):
        if not line.strip():
            continue
        if line.startswith((" ", "\t")):
            if in_block_scalar:
                continue
            errors.append(f"invalid indented frontmatter line before closing delimiter: line {line_number}")
            return errors
        in_block_scalar = False
        if not FRONTMATTER_FIELD_PATTERN.match(line):
            errors.append(f"invalid frontmatter line before closing delimiter: line {line_number}")
            return errors
        if FRONTMATTER_BLOCK_SCALAR_PATTERN.match(line):
            in_block_scalar = True

    frontmatter = "\n".join(frontmatter_lines)
    for field in ("name", "description"):
        if not re.search(rf"(?m)^{field}:\s*\S", frontmatter):
            errors.append(f"missing frontmatter field: {field}")
    return errors


def skill_format_errors(path: Path) -> list[str]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        return [f"cannot read skill file: {exc}"]

    errors = validate_frontmatter(text)
    for heading in FORMAT_REQUIRED_SECTIONS:
        body = section_body(text, heading)
        if body is None:
            errors.append(f"missing required section: {heading}")
            continue
        if heading == "## When to Activate":
            activation_count = count_plain_bullets(body)
            if activation_count == 0:
                errors.append("## When to Activate must contain at least one bullet")
        elif heading == "## Red Flags":
            red_flag_count = count_useful_bullets(body)
            if red_flag_count == 0:
                errors.append("## Red Flags has no useful list items")
            elif red_flag_count < MIN_RED_FLAGS:
                errors.append(f"## Red Flags must contain at least {MIN_RED_FLAGS} bullets")
        elif heading == "## Checklist":
            checklist_count = count_useful_checklist_items(body)
            if checklist_count == 0:
                errors.append("## Checklist has no useful list items")
            elif checklist_count < MIN_CHECKLIST_ITEMS:
                errors.append(f"## Checklist must contain at least {MIN_CHECKLIST_ITEMS} checkbox items")
    return errors
