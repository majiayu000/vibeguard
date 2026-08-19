#!/usr/bin/env bash
# Keep closed GH<n> packets out of the current tree and their outcome index valid.

set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
specs_dir="${1:-$repo_dir/docs/specs}"
index_file="$specs_dir/README.md"
inventory_file="$specs_dir/archived-issues.txt"

if [[ ! -f "$index_file" ]]; then
  echo "validate-specs-index: missing index file: $index_file" >&2
  exit 1
fi

if [[ ! -f "$inventory_file" ]]; then
  echo "validate-specs-index: missing archive inventory: $inventory_file" >&2
  exit 1
fi

packet_dirs="$(find "$specs_dir" -mindepth 1 -maxdepth 1 -type d -name 'GH[0-9]*' -exec basename {} \; | sort)"
if [[ -n "$packet_dirs" ]]; then
  echo "validate-specs-index: closed issue packets must stay in Git history, not the current tree:" >&2
  while IFS= read -r packet_dir; do
    [[ -n "$packet_dir" ]] && printf '  - docs/specs/%s/\n' "$packet_dir" >&2
  done <<< "$packet_dirs"
  echo "validate-specs-index: add or update the archived outcome row instead of restoring the packet." >&2
  exit 1
fi

python3 - "$index_file" "$inventory_file" <<'PY'
from __future__ import annotations

import re
import sys
from collections import Counter
from pathlib import Path


index_path = Path(sys.argv[1])
inventory_path = Path(sys.argv[2])
text = index_path.read_text(encoding="utf-8")
lines = text.splitlines()


def visible_markdown_lines(source_lines: list[str]) -> list[tuple[int, str]]:
    visible: list[tuple[int, str]] = []
    fence_character: str | None = None
    fence_length = 0
    for index, line in enumerate(source_lines):
        if fence_character is not None:
            closing_fence = re.fullmatch(
                rf" {{0,3}}{re.escape(fence_character)}{{{fence_length},}}[ \t]*",
                line,
            )
            if closing_fence is not None:
                fence_character = None
                fence_length = 0
            continue
        fence = re.match(r"^ {0,3}(`{3,}|~{3,})", line)
        if fence is not None:
            marker = fence.group(1)
            fence_character = marker[0]
            fence_length = len(marker)
            continue
        visible.append((index, line))
    return visible


visible_lines = visible_markdown_lines(lines)
archive_heading_pattern = re.compile(
    r"^ {0,3}##[ \t]+Archived GitHub Packet Index(?:[ \t]+#+)?[ \t]*$"
)
archive_headings = [
    index for index, line in visible_lines if archive_heading_pattern.fullmatch(line)
]
if len(archive_headings) != 1:
    raise SystemExit(
        "validate-specs-index: expected exactly one visible 'Archived GitHub Packet Index' section"
    )

archive_start = archive_headings[0]
archive_end = len(lines)
for index, line in visible_lines:
    if index > archive_start and re.match(r"^ {0,3}#{1,2}(?:[ \t]+|$)", line):
        archive_end = index
        break
archive_lines = [
    line for index, line in visible_lines if archive_start < index < archive_end
]

legacy_rows = [line for line in archive_lines if re.fullmatch(r"\| `GH[0-9]+/` .*", line)]
if legacy_rows:
    raise SystemExit(
        "validate-specs-index: archived rows must be issue links, not live GH<n>/ paths: "
        + legacy_rows[0]
    )

row_pattern = re.compile(
    r"^\| \[GH(?P<label>[0-9]+)\]"
    r"\(https://github\.com/majiayu000/vibeguard/issues/(?P<url>[0-9]+)\) \| .+ \|$"
)
candidate_rows = [line for line in archive_lines if line.startswith("| [GH")]
if not candidate_rows:
    raise SystemExit("validate-specs-index: archived packet index has no GH issue rows")

ids: list[str] = []
for line in candidate_rows:
    match = row_pattern.fullmatch(line)
    if match is None:
        raise SystemExit(f"validate-specs-index: malformed archived packet row: {line}")
    if match.group("label") != match.group("url"):
        raise SystemExit(f"validate-specs-index: issue label/URL mismatch: {line}")
    ids.append(match.group("label"))

duplicates = sorted(issue_id for issue_id, count in Counter(ids).items() if count > 1)
if duplicates:
    raise SystemExit(
        "validate-specs-index: duplicate archived issue row(s): "
        + ", ".join(f"GH{issue_id}" for issue_id in duplicates)
    )

inventory_rows = [
    line.strip()
    for line in inventory_path.read_text(encoding="utf-8").splitlines()
    if line.strip() and not line.lstrip().startswith("#")
]
malformed_inventory = [line for line in inventory_rows if re.fullmatch(r"GH[0-9]+", line) is None]
if malformed_inventory:
    raise SystemExit(
        "validate-specs-index: malformed archive inventory row: " + malformed_inventory[0]
    )

inventory_ids = [line.removeprefix("GH") for line in inventory_rows]
inventory_duplicates = sorted(
    issue_id for issue_id, count in Counter(inventory_ids).items() if count > 1
)
if inventory_duplicates:
    raise SystemExit(
        "validate-specs-index: duplicate archive inventory row(s): "
        + ", ".join(f"GH{issue_id}" for issue_id in inventory_duplicates)
    )
if inventory_ids != sorted(inventory_ids, key=int):
    raise SystemExit("validate-specs-index: archive inventory must be sorted numerically")

indexed_set = set(ids)
inventory_set = set(inventory_ids)
missing = sorted(inventory_set - indexed_set, key=int)
unexpected = sorted(indexed_set - inventory_set, key=int)
if missing or unexpected:
    details: list[str] = []
    if missing:
        details.append("missing index rows: " + ", ".join(f"GH{issue_id}" for issue_id in missing))
    if unexpected:
        details.append(
            "index rows absent from inventory: "
            + ", ".join(f"GH{issue_id}" for issue_id in unexpected)
        )
    raise SystemExit("validate-specs-index: archive completeness mismatch (" + "; ".join(details) + ")")

print(f"validate-specs-index: OK ({len(ids)} archived issue outcomes indexed)")
PY
