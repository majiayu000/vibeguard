#!/usr/bin/env python3
"""Generate the embedded rule catalog, reference and compact core from Markdown."""
from __future__ import annotations
import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CANONICAL = ROOT / "rules" / "claude-rules"
HEADING = re.compile(r"^## ([A-Z]+-[A-Za-z0-9-]+): (.+) \(([^)]+)\)$")
CORE_IDS = ("U-04", "W-11", "U-29", "W-03", "SEC-02", "SEC-18")

def parse_rules():
    rules = []
    seen = set()
    for source in sorted(CANONICAL.rglob("*.md")):
        current = None
        body = []
        fence = False
        def flush():
            if current is not None:
                current["body"] = "\n".join(body).strip()
                if not current["body"]:
                    raise ValueError(f"{source}: empty body for {current['id']}")
                rules.append(current.copy())
        for number, line in enumerate(source.read_text(encoding="utf-8").splitlines(), 1):
            if line.startswith("```"):
                fence = not fence
            match = None if fence else HEADING.fullmatch(line)
            if match:
                flush()
                rule_id, title, severity = match.groups()
                if rule_id in seen:
                    raise ValueError(f"{source}:{number}: duplicate ID {rule_id}")
                seen.add(rule_id)
                current = dict(id=rule_id, title=title, severity=severity,
                               source=source.relative_to(CANONICAL).as_posix())
                body = []
            elif not fence and line.startswith("## "):
                raise ValueError(f"{source}:{number}: malformed rule heading")
            elif current is not None:
                body.append(line)
        flush()
    if not rules:
        raise ValueError("canonical rule library is empty")
    return rules

def first_sentence(body):
    paragraph = body.split("\n", 1)[0]
    return re.split(r"(?<=[.!?])\s+", paragraph, maxsplit=1)[0]

def generated_files(rules):
    by_id = {r["id"]: r for r in rules}
    core = "# VibeGuard core\n\n" + "\n".join(
        f"- {rule_id}: {first_sentence(by_id[rule_id]['body'])}" for rule_id in CORE_IDS
    ) + "\n"
    lines = ["# Rule reference", "",
             "Generated from the canonical Markdown. These are review topics, not claims of automatic enforcement.",
             f"The library contains {len(rules)} topics; read only those relevant to the task.", "",
             "| ID | Topic | Scope |", "|---|---|---|"]
    for r in rules:
        link = "../rules/claude-rules/" + r["source"]
        lines.append(f"| [{r['id']}]({link}) | {r['title']} | {r['severity']} |")
    return {
        ROOT / "rules/rule-descriptions.json": json.dumps(rules, ensure_ascii=False, indent=2) + "\n",
        ROOT / "claude-md/vibeguard-rules.md": core,
        ROOT / "docs/rule-reference.md": "\n".join(lines) + "\n",
    }

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        rules = parse_rules()
        stale = []
        for path, content in generated_files(rules).items():
            if args.check:
                if not path.is_file() or path.read_text(encoding="utf-8") != content:
                    stale.append(str(path.relative_to(ROOT)))
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content, encoding="utf-8")
        if stale:
            raise ValueError("stale generated files: " + ", ".join(stale))
        print(f"OK: {len(rules)} canonical topics; generated outputs {'checked' if args.check else 'written'}")
    except (OSError, UnicodeError, ValueError, KeyError) as error:
        parser.exit(1, f"rule generation failed: {error}\n")

if __name__ == "__main__":
    main()
