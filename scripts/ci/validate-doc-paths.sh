#!/usr/bin/env bash
# VibeGuard CI: Verify the true existence of backtick path references in markdown documents
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
DOCS_DIR="${1:-$REPO_DIR}"
REPO_ROOT="${2:-$REPO_DIR}"

python3 - "$DOCS_DIR" "$REPO_ROOT" <<'PY'
import re
import sys
from pathlib import Path

docs_dir = Path(sys.argv[1]).resolve()
repo_root = Path(sys.argv[2]).resolve()

ALLOWLIST_FILE = repo_root / ".vibeguard-doc-paths-allowlist"

EXTENSIONS = (
    r"\.py|\.ts|\.tsx|\.js|\.jsx|\.sh|\.rs|\.go|\.toml|\.json|\.yaml|\.yml"
    r"|\.md|\.css|\.html|\.sql|\.lock|\.cfg|\.ini|\.env"
)
PATH_RE = re.compile(r"`([A-Za-z0-9_./-]+(?:" + EXTENSIONS + r"))`")

SKIP_PREFIXES = ("http://", "https://", "~/", "your/", "project/")
SKIP_CONTAINS = ("*", "<", ">", "${")


def load_allowlist() -> set[str]:
    if not ALLOWLIST_FILE.exists():
        return set()
    entries: set[str] = set()
    for line in ALLOWLIST_FILE.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped and not stripped.startswith("#"):
            entries.add(stripped)
    return entries


def should_skip(path_str: str) -> bool:
    if any(path_str.startswith(p) for p in SKIP_PREFIXES):
        return True
    if any(c in path_str for c in SKIP_CONTAINS):
        return True
    # Skip bare filenames (without / path separator) - these are filename references in directory context, not path references
    if "/" not in path_str:
        return True
    # Skip hidden file/extension lists starting with . (e.g. .py/.ts/.rs)
    if path_str.startswith("."):
        return True
    return False


def main() -> int:
    allowlist = load_allowlist()

    # Collect markdown files
    md_files = sorted(docs_dir.rglob("*.md"))
    # Exclude node_modules and .git
    md_files = [
        f for f in md_files
        if "node_modules" not in f.parts and ".git" not in f.parts
        and ".omx" not in f.parts
        and not (".claude" in f.parts and "worktrees" in f.parts)
    ]

    if not md_files:
        print("No markdown files found")
        return 0

    failures: list[str] = []
    ok_count = 0

    for md_file in md_files:
        try:
            content = md_file.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue

        file_failures: list[str] = []
        ref_count = 0

        for line_num, line in enumerate(content.splitlines(), 1):
            for match in PATH_RE.finditer(line):
                path_str = match.group(1)

                if should_skip(path_str):
                    continue
                if path_str in allowlist:
                    continue

                ref_count += 1
                full_path = repo_root / path_str
                # Also try to parse relative to the directory where the markdown file is located
                rel_path = md_file.parent / path_str
                if not full_path.exists() and not rel_path.exists():
                    rel_md = md_file.relative_to(docs_dir) if docs_dir != repo_root else md_file.relative_to(repo_root)
                    file_failures.append(
                        f"FAIL: {rel_md}:{line_num} `{path_str}` — not found"
                    )

        if file_failures:
            failures.extend(file_failures)
        elif ref_count > 0:
            rel_md = md_file.relative_to(docs_dir) if docs_dir != repo_root else md_file.relative_to(repo_root)
            print(f"OK: {rel_md} — {ref_count} references, all valid")
            ok_count += 1

    for f in failures:
        print(f)

    if failures:
        print(f"\n{len(failures)} broken path reference(s) found")
        return 1

    if ok_count == 0:
        print("No path references found in markdown files")
    else:
        print(f"\nAll {ok_count} files with path references validated successfully")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
