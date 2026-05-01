#!/usr/bin/env bash
# SEC-13 output-rewrite extension: hook output rewrites must explain why.
set -euo pipefail

REPO_DIR="${1:-$(cd "$(dirname "$0")/../../.." && pwd)}"

python3 - <<'PY' "${REPO_DIR}"
import sys
from pathlib import Path

repo = Path(sys.argv[1])
errors: list[str] = []
reason_marker = "SEC-13-OUTPUT-REWRITE-REASON:"
rewrite_key = "updated" + "ToolOutput"
scan_roots = [repo / "hooks", repo / "scripts"]

for root in scan_roots:
    if not root.exists():
        continue
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        if path.suffix not in {".sh", ".py", ".js", ".ts", ".json"}:
            continue
        if any(part in {"node_modules", "dist", "__pycache__"} for part in path.relative_to(repo).parts):
            continue
        lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
        for idx, line in enumerate(lines):
            if rewrite_key not in line:
                continue
            window = lines[max(0, idx - 6): idx + 1]
            if not any(reason_marker in candidate for candidate in window):
                rel = path.relative_to(repo)
                errors.append(f"{rel}:{idx + 1}: output rewrite without {reason_marker}")

if errors:
    print("FAIL: hook output rewriting lacks SEC-13 reasons")
    for error in errors:
        print(error)
    raise SystemExit(1)

print("OK: no unreasoned hook output rewriting found")
PY
