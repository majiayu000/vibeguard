#!/usr/bin/env bash
# Regenerate or verify hook docs derived from hooks/manifest.json.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
MODE="${1:---check}"

case "${MODE}" in
  --check|--write) ;;
  *)
    echo "usage: $0 [--check|--write]" >&2
    exit 2
    ;;
esac

python3 - <<'PY' "${REPO_DIR}" "${MODE}"
import difflib
import sys
from pathlib import Path

repo = Path(sys.argv[1])
mode = sys.argv[2]
sys.path.insert(0, str(repo / "scripts/lib"))

from hooks_manifest import load_manifest, render_doc_table  # noqa: E402

doc = repo / "hooks/CLAUDE.md"
start = "<!-- hooks-manifest-table:start -->"
end = "<!-- hooks-manifest-table:end -->"
text = doc.read_text(encoding="utf-8")
if start not in text or end not in text:
    raise SystemExit("hooks/CLAUDE.md missing hooks manifest table markers")

before, rest = text.split(start, 1)
current, after = rest.split(end, 1)
generated = "\n" + render_doc_table(load_manifest(repo / "hooks/manifest.json"))
next_text = before + start + generated + end + after

if mode == "--write":
    if next_text != text:
        doc.write_text(next_text, encoding="utf-8")
        print("CHANGED")
    else:
        print("SKIP")
    raise SystemExit(0)

if next_text == text:
    print("OK: hooks/CLAUDE.md generated table is current")
    raise SystemExit(0)

diff = difflib.unified_diff(
    text.splitlines(keepends=True),
    next_text.splitlines(keepends=True),
    fromfile=str(doc),
    tofile=str(doc),
)
sys.stdout.writelines(diff)
raise SystemExit(1)
PY
