#!/usr/bin/env bash
# Ensure canonical rules stay English-only and machine-parseable.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

python3 - "$REPO_DIR" <<'PY'
from __future__ import annotations

import re
import sys
from pathlib import Path

repo_dir = Path(sys.argv[1]).resolve()
rules_dir = repo_dir / "rules" / "claude-rules"

cjk_re = re.compile(r"[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]")
rule_prefix_re = re.compile(r"^##\s+(?:RS|GO|TS|PY|U|SEC|W|TASTE)-")
heading_re = re.compile(r"^##\s+((?:RS|GO|TS|PY|U|SEC|W|TASTE)-[A-Za-z0-9-]+):\s+(.+?)\s+\(([^)]+)\)\s*$")

errors: list[str] = []

for path in sorted(rules_dir.rglob("*.md")):
    text = path.read_text(encoding="utf-8")
    rel = path.relative_to(repo_dir)
    for lineno, line in enumerate(text.splitlines(), start=1):
        if cjk_re.search(line):
            errors.append(f"{rel}:{lineno}: canonical rules must not contain CJK text")
        if rule_prefix_re.match(line):
            if not heading_re.match(line):
                errors.append(f"{rel}:{lineno}: rule heading must include id, title, and severity in the form '## ID: Title (severity)'")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)

print("Canonical rule language and heading structure are valid.")
PY
