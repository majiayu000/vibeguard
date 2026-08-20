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

packet_entries="$(python3 - "$specs_dir" <<'PY'
import re
import sys
from pathlib import Path

specs_dir = Path(sys.argv[1])
for entry in sorted(specs_dir.iterdir(), key=lambda path: path.name):
    if re.fullmatch(r"GH[0-9]+", entry.name):
        print(entry.name)
PY
)"
if [[ -n "$packet_entries" ]]; then
  echo "validate-specs-index: closed issue packet paths must stay in Git history, not the current tree:" >&2
  while IFS= read -r packet_entry; do
    [[ -n "$packet_entry" ]] && printf '  - docs/specs/%s\n' "$packet_entry" >&2
  done <<< "$packet_entries"
  echo "validate-specs-index: add or update the archived outcome row instead of restoring the packet." >&2
  exit 1
fi

python3 - "$index_file" "$inventory_file" <<'PY'
from __future__ import annotations

import re
import subprocess
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
    in_html_comment = False
    raw_html_end: re.Pattern[str] | None = None
    raw_html_until_blank = False

    block_tags = (
        "address|article|aside|base|basefont|blockquote|body|caption|center|col|"
        "colgroup|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|figure|"
        "footer|form|frame|frameset|h1|h2|h3|h4|h5|h6|head|header|hr|html|"
        "iframe|legend|li|link|main|menu|menuitem|nav|noframes|ol|optgroup|"
        "option|p|param|search|section|summary|table|tbody|td|tfoot|th|thead|"
        "title|tr|track|ul"
    )
    html_attribute = (
        r"[A-Za-z_:][A-Za-z0-9_.:-]*"
        r"(?:[ \t]*=[ \t]*(?:[^ \"'=<>`]+|'[^']*'|\"[^\"]*\"))?"
    )
    generic_html_tag = re.compile(
        rf"^ {{0,3}}(?:"
        rf"<[A-Za-z][A-Za-z0-9-]*(?:[ \t]+{html_attribute})*[ \t]*/?>|"
        r"</[A-Za-z][A-Za-z0-9-]*[ \t]*>"
        r")[ \t]*$"
    )

    def strip_html_comments(line: str) -> str:
        nonlocal in_html_comment
        fragments: list[str] = []
        remaining = line
        while remaining:
            if in_html_comment:
                comment_end = remaining.find("-->")
                if comment_end == -1:
                    return "".join(fragments)
                remaining = remaining[comment_end + 3 :]
                in_html_comment = False
                continue

            comment_start = remaining.find("<!--")
            if comment_start == -1:
                fragments.append(remaining)
                break
            fragments.append(remaining[:comment_start])
            remaining = remaining[comment_start + 4 :]
            in_html_comment = True
        return "".join(fragments)

    for index, line in enumerate(source_lines):
        if raw_html_end is not None:
            if raw_html_end.search(line):
                raw_html_end = None
            continue
        if raw_html_until_blank:
            if line.strip():
                continue
            raw_html_until_blank = False
        if fence_character is not None:
            closing_fence = re.fullmatch(
                rf" {{0,3}}{re.escape(fence_character)}{{{fence_length},}}[ \t]*",
                line,
            )
            if closing_fence is not None:
                fence_character = None
                fence_length = 0
            continue
        raw_html_start = re.match(r"^ {0,3}<", line)
        if raw_html_start is not None:
            end_pattern: re.Pattern[str] | None = None
            tag_match = re.match(
                r"^ {0,3}<(script|pre|style|textarea)(?:[ \t]|>|$)",
                line,
                re.IGNORECASE,
            )
            if tag_match is not None:
                end_pattern = re.compile(
                    rf"</{re.escape(tag_match.group(1))}[ \t]*>", re.IGNORECASE
                )
            elif re.match(r"^ {0,3}<!--", line):
                end_pattern = re.compile(r"-->")
            elif re.match(r"^ {0,3}<\?", line):
                end_pattern = re.compile(r"\?>")
            elif re.match(r"^ {0,3}<![A-Z]", line):
                end_pattern = re.compile(r">")
            elif re.match(r"^ {0,3}<!\[CDATA\[", line):
                end_pattern = re.compile(r"\]\]>")

            if end_pattern is not None:
                if end_pattern.search(line) is None:
                    raw_html_end = end_pattern
                continue

            if re.match(
                rf"^ {{0,3}}</?(?:{block_tags})(?:[ \t]|/?>|$)",
                line,
                re.IGNORECASE,
            ):
                raw_html_until_blank = True
                continue
            if generic_html_tag.fullmatch(line):
                raw_html_until_blank = True
                continue

        visible_line = strip_html_comments(line)
        if not visible_line and line:
            continue
        fence = re.match(r"^ {0,3}(`{3,}|~{3,})", visible_line)
        if fence is not None:
            marker = fence.group(1)
            fence_character = marker[0]
            fence_length = len(marker)
            continue
        visible.append((index, visible_line))
    return visible


def table_cells(line: str) -> list[str] | None:
    stripped = line.strip()
    if "|" not in stripped:
        return None
    cells: list[str] = []
    cell: list[str] = []
    backslash_count = 0
    for character in stripped:
        if character == "\\":
            cell.append(character)
            backslash_count += 1
            continue
        if character == "|" and backslash_count % 2 == 0:
            cells.append("".join(cell).strip())
            cell = []
        else:
            cell.append(character)
        backslash_count = 0
    cells.append("".join(cell).strip())
    if cells and not cells[0]:
        cells.pop(0)
    if cells and not cells[-1]:
        cells.pop()
    return cells


def gfm_table_line_indexes(markdown_lines: list[tuple[int, str]]) -> set[int]:
    table_indexes: set[int] = set()
    position = 1
    while position < len(markdown_lines):
        header_index, header = markdown_lines[position - 1]
        delimiter_index, delimiter = markdown_lines[position]
        header_cells = table_cells(header)
        delimiter_cells = table_cells(delimiter)
        is_delimiter = (
            header_index + 1 == delimiter_index
            and re.match(r"^ {0,3}\S", header) is not None
            and re.match(r"^ {0,3}\S", delimiter) is not None
            and header_cells is not None
            and delimiter_cells is not None
            and len(header_cells) == len(delimiter_cells)
            and all(
                re.fullmatch(r":?-{3,}:?", cell) is not None
                for cell in delimiter_cells
            )
        )
        if not is_delimiter:
            position += 1
            continue

        table_indexes.update({header_index, delimiter_index})
        position += 1
        previous_index = delimiter_index
        while position < len(markdown_lines):
            body_index, body = markdown_lines[position]
            if (
                body_index != previous_index + 1
                or not body.strip()
                or "|" not in body
            ):
                break
            table_indexes.add(body_index)
            previous_index = body_index
            position += 1
        continue
    return table_indexes


def is_thematic_break(line: str) -> bool:
    stripped = line.strip()
    return any(
        re.fullmatch(rf"(?:{re.escape(marker)}[ \t]*){{3,}}", stripped) is not None
        for marker in "*-_"
    )


def is_paragraph_line(line_index: int, line: str, table_indexes: set[int]) -> bool:
    if line_index in table_indexes or re.match(r"^ {0,3}\S", line) is None:
        return False
    stripped = line.strip()
    if re.match(r"^#{1,6}(?:[ \t]+|$)", stripped):
        return False
    if stripped.startswith((">", "<")):
        return False
    if re.match(r"^(?:[-+*]|[0-9]+[.)])(?:[ \t]+|$)", stripped):
        return False
    if re.match(r"^\[[^]\n]+\]:[ \t]*", stripped):
        return False
    return not is_thematic_break(line)


visible_lines = visible_markdown_lines(lines)
table_indexes = gfm_table_line_indexes(visible_lines)
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
for position, (index, line) in enumerate(visible_lines):
    if index > archive_start and re.match(r"^ {0,3}#{1,2}(?:[ \t]+|$)", line):
        archive_end = index
        break
    if index <= archive_start or re.fullmatch(
        r" {0,3}(?:=+|-+)[ \t]*",
        line,
    ) is None:
        continue
    if position == 0:
        continue
    heading_position = position - 1
    heading_index, heading_line = visible_lines[heading_position]
    if heading_index + 1 != index or not is_paragraph_line(
        heading_index,
        heading_line,
        table_indexes,
    ):
        continue
    while heading_position > 0:
        previous_index, previous_line = visible_lines[heading_position - 1]
        if (
            previous_index <= archive_start
            or previous_index + 1 != heading_index
            or not is_paragraph_line(previous_index, previous_line, table_indexes)
        ):
            break
        heading_position -= 1
        heading_index = previous_index
    archive_end = heading_index
    break
archive_lines = [
    (index, line)
    for index, line in visible_lines
    if archive_start < index < archive_end
]

legacy_rows = [
    line
    for _, line in archive_lines
    if re.fullmatch(r"\| `GH[0-9]+/` .*", line)
]
if legacy_rows:
    raise SystemExit(
        "validate-specs-index: archived rows must be issue links, not live GH<n>/ paths: "
        + legacy_rows[0]
    )

row_pattern = re.compile(
    r"^\| \[GH(?P<label>[1-9][0-9]*)\]"
    r"\(https://github\.com/majiayu000/vibeguard/issues/(?P<url>[1-9][0-9]*)\) "
    r"\| (?P<outcome>.*\S.*) \|$"
)
issue_url_pattern = re.compile(
    r"https://github\.com/majiayu000/vibeguard/issues/[0-9]+"
)
candidate_rows: list[tuple[int, str]] = []
for index, line in archive_lines:
    cells = table_cells(line)
    first_cell = cells[0] if cells else ""
    if re.search(r"GH[0-9]+", first_cell) or issue_url_pattern.search(line):
        candidate_rows.append((index, line))
if not candidate_rows:
    raise SystemExit("validate-specs-index: archived packet index has no GH issue rows")

ids: list[str] = []
for index, line in candidate_rows:
    if index not in table_indexes:
        raise SystemExit(
            "validate-specs-index: archived packet row must be inside a GFM table: "
            + line
        )
    cells = table_cells(line)
    if cells is None or len(cells) != 2:
        raise SystemExit(f"validate-specs-index: malformed archived packet row: {line}")
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
malformed_inventory = [
    line
    for line in inventory_rows
    if re.fullmatch(r"GH[1-9][0-9]*", line) is None
]
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

git_root_result = subprocess.run(
    ["git", "-C", str(index_path.parent), "rev-parse", "--show-toplevel"],
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
    text=True,
    check=False,
)
if git_root_result.returncode == 0:
    git_root = Path(git_root_result.stdout.strip()).resolve()
    specs_path = index_path.parent.resolve()
    try:
        relative_specs = specs_path.relative_to(git_root).as_posix()
    except ValueError as error:
        raise SystemExit(
            "validate-specs-index: specs directory is outside its Git worktree"
        ) from error
    shallow = subprocess.run(
        ["git", "-C", str(git_root), "rev-parse", "--is-shallow-repository"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=True,
    ).stdout.strip()
    if shallow == "true":
        raise SystemExit(
            "validate-specs-index: full Git history is required to prove archive completeness"
        )
    historical_paths = subprocess.run(
        [
            "git",
            "-C",
            str(git_root),
            "log",
            "--format=",
            "--name-only",
            "-z",
            "HEAD",
            "--",
            relative_specs,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    ).stdout.decode("utf-8").split("\0")
    historical_pattern = re.compile(
        rf"{re.escape(relative_specs)}/GH([1-9][0-9]*)(?:/.*)?"
    )
    historical_ids = {
        match.group(1)
        for path in historical_paths
        if (match := historical_pattern.fullmatch(path)) is not None
    }
    erased = sorted(historical_ids - inventory_set, key=int)
    if erased:
        raise SystemExit(
            "validate-specs-index: archived issue IDs are append-only relative to Git history: "
            + ", ".join(f"GH{issue_id}" for issue_id in erased)
        )

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
