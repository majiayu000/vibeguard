#!/usr/bin/env python3
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REFERENCE_PATH = ROOT / "docs" / "rule-reference.md"
ALL_RULE_GLOB = "rules/claude-rules/**/*.md"
CANONICAL_RULE_PATHS = [
    ROOT / "rules" / "claude-rules" / "common" / "coding-style.md",
    ROOT / "rules" / "claude-rules" / "common" / "security.md",
    ROOT / "rules" / "claude-rules" / "common" / "workflow.md",
]
TARGET_OVERLOAD_RULES = {"U-32", "SEC-13", "W-14", "W-05", "W-17"}
REQUIRED_REFERENCE_IDS = {"SEC-13", "W-14", "W-05", "U-32"}
REFERENCE_ONLY_IDS = {"U-27", "U-28"}
ABSOLUTE_WORDS = ("确保", "永远", "必须", "绝不", "100%")
DEGRADE_WORDS = ("降级", "例外", "不可行", "stale", "fallback", "hook", "guard", "verify", "skill")
RULE_HEADER_RE = re.compile(r"^##\s+((?:U|W|SEC)-\d+):", re.M)
REF_ID_RE = re.compile(r"\|\s*((?:U|W|SEC)-\d+)\s*\|")
HIGH_CONTEXT_GLOBS = [
    "**/AGENTS.md",
    "**/CLAUDE.md",
    ".claude/settings.json",
    ".claude/settings.local.json",
    ".claude/agents/**/*.md",
    ".claude/skills/**/*.md",
]
HIGH_RISK_PATTERNS = [
    re.compile(r"ignore previous(?:/system)? instructions", re.I),
    re.compile(r"ignore system instructions", re.I),
    re.compile(r"override system", re.I),
    re.compile(r"do not mention", re.I),
    re.compile(r"hide this change", re.I),
    re.compile(r"avoid mentioning", re.I),
    re.compile(r"不要提及"),
    re.compile(r"静默执行"),
    re.compile(r"忽略前述"),
]


def rel(path: Path) -> Path:
    return path.relative_to(ROOT)


def parse_rule_ids(text: str) -> list[str]:
    return RULE_HEADER_RE.findall(text)


def parse_rule_blocks(text: str) -> list[tuple[str, str]]:
    blocks = re.split(r"(?=^##\s+(?:U|W|SEC)-\d+:)", text, flags=re.M)
    out: list[tuple[str, str]] = []
    for block in blocks:
        if not block.startswith("## "):
            continue
        header = block.splitlines()[0]
        match = re.match(r"##\s+((?:U|W|SEC)-\d+):", header)
        if match:
            out.append((match.group(1), block))
    return out


def gather_high_context_files() -> list[Path]:
    files: set[Path] = set()
    for pattern in HIGH_CONTEXT_GLOBS:
        files.update(ROOT.glob(pattern))
    return sorted(path for path in files if path.is_file())


def gather_all_rule_ids() -> set[str]:
    rule_ids: set[str] = set()
    for path in ROOT.glob(ALL_RULE_GLOB):
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8")
        rule_ids.update(parse_rule_ids(text))
    return rule_ids


def check_rule_files() -> tuple[list[str], set[str]]:
    issues: list[str] = []
    rule_ids: set[str] = set()

    for path in CANONICAL_RULE_PATHS:
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8")
        ids = parse_rule_ids(text)
        rule_ids.update(ids)

        if len(ids) > 30:
            issues.append(f"U-32 {rel(path)}: rule file contains {len(ids)} active rules (>30)")

        for rule_id, block in parse_rule_blocks(text):
            if rule_id not in TARGET_OVERLOAD_RULES:
                continue
            if any(word in block for word in ABSOLUTE_WORDS) and not any(word in block for word in DEGRADE_WORDS):
                issues.append(
                    f"U-32 {rel(path)}: {rule_id} uses absolute language without degrade/verify path"
                )

    return issues, rule_ids


def check_high_context_files() -> list[str]:
    issues: list[str] = []
    for path in gather_high_context_files():
        text = path.read_text(encoding="utf-8")
        relative = rel(path)
        line_count = text.count("\n") + 1

        if relative.name in {"AGENTS.md", "CLAUDE.md"} and line_count > 100:
            issues.append(f"U-32 {relative}: high-context file has {line_count} lines (>100)")

        for pattern in HIGH_RISK_PATTERNS:
            if pattern.search(text):
                issues.append(f"SEC-13 {relative}: suspicious directive pattern `{pattern.pattern}` detected")

    return issues


def check_reference_drift(rule_ids: set[str]) -> list[str]:
    issues: list[str] = []
    if not REFERENCE_PATH.exists():
        return issues

    ref_text = REFERENCE_PATH.read_text(encoding="utf-8")
    ref_ids = set(REF_ID_RE.findall(ref_text))

    for rule_id in sorted(REQUIRED_REFERENCE_IDS):
        if rule_id not in ref_ids:
            issues.append(f"W-17 {rel(REFERENCE_PATH)}: missing {rule_id} in rule reference")

    allowed_ids = set(rule_ids) | REFERENCE_ONLY_IDS
    for rule_id in sorted(ref_ids):
        if rule_id not in allowed_ids:
            issues.append(f"W-17 {rel(REFERENCE_PATH)}: reference includes stale rule id {rule_id}")

    if "SEC-12" in ref_text and "MCP Docker container leak" in ref_text:
        issues.append(f"W-17 {rel(REFERENCE_PATH)}: SEC-12 summary is stale and does not match canonical security.md")

    return issues


def main() -> int:
    issues, rule_ids = check_rule_files()
    all_rule_ids = gather_all_rule_ids() | rule_ids
    issues.extend(check_high_context_files())
    issues.extend(check_reference_drift(all_rule_ids))

    if issues:
        for issue in issues:
            print(issue)
        return 1

    print("rule-overload-audit: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
