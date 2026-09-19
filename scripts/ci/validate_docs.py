#!/usr/bin/env python3
"""Check local Markdown links and documented source command paths."""
import argparse
import re
from pathlib import Path
from urllib.parse import unquote, urlsplit
ROOT = Path(__file__).resolve().parents[2]

def errors(mode):
    failures = []
    paths = list(ROOT.glob("*.md"))
    for folder in ("docs", "plan", "plugins", "rules", "eval", "claude-md"):
        paths.extend((ROOT / folder).rglob("*.md"))
    for path in sorted(paths):
        text = path.read_text(encoding="utf-8")
        if mode == "links":
            for target in re.findall(r"\[[^\]\n]*\]\(([^)\n]+)\)", text):
                target = target.strip("<>")
                parsed = urlsplit(target)
                if parsed.scheme or not parsed.path:
                    continue
                if not (path.parent / unquote(parsed.path)).resolve().exists():
                    failures.append(f"{path.relative_to(ROOT)}: missing {target}")
        elif "plan" not in path.relative_to(ROOT).parts:
            for target in re.findall(r"(?:bash|python3)\s+((?:scripts|eval)/[A-Za-z0-9_./-]+\.(?:sh|py))", text):
                if not (ROOT / target).is_file():
                    failures.append(f"{path.relative_to(ROOT)}: missing command {target}")
    return failures

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("links", "commands"))
    args = parser.parse_args()
    failures = errors(args.mode)
    if failures:
        parser.exit(1, "\n".join(failures) + "\n")
    print(f"OK: documentation {args.mode}")

if __name__ == "__main__":
    main()
