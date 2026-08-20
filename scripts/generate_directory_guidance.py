#!/usr/bin/env python3
"""Generate scoped CLAUDE.md files from one canonical Markdown source."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import difflib
import os
import re
import secrets
import stat
import sys
from collections.abc import Iterator
from pathlib import Path, PurePosixPath


ROOT = Path(__file__).resolve().parents[1]
SOURCE_PATH = ROOT / "docs" / "directory-guidance.md"
EXPECTED_OUTPUTS = {
    "claude-md/CLAUDE.md",
    "guards/CLAUDE.md",
    "hooks/CLAUDE.md",
    "rules/CLAUDE.md",
    "scripts/CLAUDE.md",
}
RETIRED_OUTPUTS = {
    "guards/go/CLAUDE.md",
    "guards/rust/CLAUDE.md",
}
INVENTORY_EXCLUDED_DIRECTORIES = {
    ".git",
    ".claude/worktrees",
    ".vibeguard/worktrees",
}
GENERATED_HEADER = (
    "<!-- Generated from docs/directory-guidance.md; do not edit directly. -->\n\n"
)
START_RE = re.compile(r"^<!-- directory-guidance:([^:]+):start -->$")
END_RE = re.compile(r"^<!-- directory-guidance:([^:]+):end -->$")


def validate_output_path(raw_path: str) -> str:
    path = PurePosixPath(raw_path)
    if (
        path.is_absolute()
        or len(path.parts) < 2
        or any(part in {"", ".", ".."} for part in path.parts)
        or path.name != "CLAUDE.md"
    ):
        raise ValueError(f"unsafe directory-guidance output path: {raw_path}")
    return path.as_posix()


def parse_sections(source: str) -> dict[str, str]:
    sections: dict[str, str] = {}
    active_path: str | None = None
    active_lines: list[str] = []

    for line_number, line in enumerate(source.splitlines(keepends=True), start=1):
        stripped = line.rstrip("\r\n")
        start = START_RE.fullmatch(stripped)
        end = END_RE.fullmatch(stripped)

        if start:
            if active_path is not None:
                raise ValueError(
                    f"nested directory-guidance section at line {line_number}"
                )
            active_path = validate_output_path(start.group(1))
            if active_path in sections:
                raise ValueError(f"duplicate directory-guidance section: {active_path}")
            active_lines = []
            continue

        if end:
            end_path = validate_output_path(end.group(1))
            if active_path is None:
                raise ValueError(
                    f"directory-guidance end marker without start at line {line_number}"
                )
            if end_path != active_path:
                raise ValueError(
                    f"directory-guidance marker mismatch at line {line_number}: "
                    f"expected {active_path}, got {end_path}"
                )
            body = "".join(active_lines).strip()
            if not body:
                raise ValueError(f"empty directory-guidance section: {active_path}")
            sections[active_path] = GENERATED_HEADER + body + "\n"
            active_path = None
            active_lines = []
            continue

        if active_path is not None:
            active_lines.append(line)

    if active_path is not None:
        raise ValueError(f"unterminated directory-guidance section: {active_path}")

    actual_outputs = set(sections)
    if actual_outputs != EXPECTED_OUTPUTS:
        missing = sorted(EXPECTED_OUTPUTS - actual_outputs)
        unexpected = sorted(actual_outputs - EXPECTED_OUTPUTS)
        details = []
        if missing:
            details.append(f"missing: {', '.join(missing)}")
        if unexpected:
            details.append(f"unexpected: {', '.join(unexpected)}")
        raise ValueError("directory-guidance output inventory mismatch (" + "; ".join(details) + ")")

    return sections


DIRECTORY_OPEN_FLAGS = (
    os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
)
FILE_READ_FLAGS = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)


@contextmanager
def open_parent_directory(root: Path, relative_path: str) -> Iterator[tuple[int, str]]:
    path = PurePosixPath(validate_output_path(relative_path))
    root_descriptor = os.open(root, DIRECTORY_OPEN_FLAGS)
    opened_descriptors: list[int] = []
    try:
        parent_descriptor = root_descriptor
        for component in path.parent.parts:
            next_descriptor = os.open(
                component,
                DIRECTORY_OPEN_FLAGS,
                dir_fd=parent_descriptor,
            )
            opened_descriptors.append(next_descriptor)
            parent_descriptor = next_descriptor
        yield parent_descriptor, path.name
    finally:
        for descriptor in reversed(opened_descriptors):
            os.close(descriptor)
        os.close(root_descriptor)


def stat_entry_or_none(parent_descriptor: int, name: str) -> os.stat_result | None:
    try:
        return os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
    except FileNotFoundError:
        return None


def validate_regular_output(output_stat: os.stat_result, relative_path: str) -> None:
    if not stat.S_ISREG(output_stat.st_mode) or output_stat.st_nlink != 1:
        raise ValueError(
            "directory-guidance output must be a single-link regular file, "
            "not a symlink, hard link, or special file: "
            f"{relative_path}"
        )


def relative_entry_exists(root: Path, relative_path: str) -> bool:
    try:
        with open_parent_directory(root, relative_path) as (parent_descriptor, name):
            return stat_entry_or_none(parent_descriptor, name) is not None
    except FileNotFoundError:
        return False


def read_regular_output_at(
    parent_descriptor: int,
    name: str,
    relative_path: str,
) -> str:
    entry_stat = stat_entry_or_none(parent_descriptor, name)
    if entry_stat is None:
        raise FileNotFoundError(relative_path)
    validate_regular_output(entry_stat, relative_path)
    descriptor = os.open(name, FILE_READ_FLAGS, dir_fd=parent_descriptor)
    try:
        opened_stat = os.fstat(descriptor)
        validate_regular_output(opened_stat, relative_path)
        if (entry_stat.st_dev, entry_stat.st_ino) != (
            opened_stat.st_dev,
            opened_stat.st_ino,
        ):
            raise ValueError(
                f"directory-guidance output changed while reading: {relative_path}"
            )
        with os.fdopen(descriptor, "r", encoding="utf-8") as handle:
            descriptor = -1
            return handle.read()
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def read_regular_output(root: Path, relative_path: str, *, missing_ok: bool) -> str:
    try:
        with open_parent_directory(root, relative_path) as (parent_descriptor, name):
            return read_regular_output_at(parent_descriptor, name, relative_path)
    except FileNotFoundError:
        if missing_ok:
            return ""
        raise


def same_entry(left: os.stat_result, right: os.stat_result) -> bool:
    return (left.st_dev, left.st_ino) == (right.st_dev, right.st_ino)


def validate_inventory_directory(
    directory_descriptor: int,
    relative_directory: str,
    expected_outputs: set[str],
) -> None:
    try:
        with os.scandir(directory_descriptor) as iterator:
            entries = sorted(iterator, key=lambda entry: entry.name)
    except OSError as error:
        location = relative_directory or "."
        raise ValueError(
            f"cannot inspect directory-guidance inventory at {location}: {error}"
        ) from error

    for entry in entries:
        relative_path = (
            f"{relative_directory}/{entry.name}"
            if relative_directory
            else entry.name
        )
        if relative_path in INVENTORY_EXCLUDED_DIRECTORIES:
            continue
        try:
            entry_stat = os.stat(
                entry.name,
                dir_fd=directory_descriptor,
                follow_symlinks=False,
            )
        except OSError as error:
            raise ValueError(
                f"cannot inspect directory-guidance inventory entry {relative_path}: {error}"
            ) from error

        if stat.S_ISLNK(entry_stat.st_mode):
            try:
                target_stat = os.stat(entry.name, dir_fd=directory_descriptor)
            except FileNotFoundError:
                target_stat = None
            except OSError as error:
                raise ValueError(
                    f"cannot inspect directory-guidance symlink {relative_path}: {error}"
                ) from error
            if target_stat is not None and stat.S_ISDIR(target_stat.st_mode):
                raise ValueError(
                    "symlinked directory may hide scoped guidance outside "
                    f"canonical inventory: {relative_path}"
                )
            if entry.name == "CLAUDE.md" and relative_path not in expected_outputs:
                raise ValueError(
                    "symlinked scoped guidance outside canonical inventory: "
                    f"{relative_path}"
                )
            continue

        if stat.S_ISDIR(entry_stat.st_mode):
            try:
                child_descriptor = os.open(
                    entry.name,
                    DIRECTORY_OPEN_FLAGS,
                    dir_fd=directory_descriptor,
                )
            except OSError as error:
                raise ValueError(
                    f"cannot inspect directory-guidance inventory at {relative_path}: {error}"
                ) from error
            try:
                opened_stat = os.fstat(child_descriptor)
                if not same_entry(entry_stat, opened_stat):
                    raise ValueError(
                        "directory-guidance inventory changed while scanning: "
                        f"{relative_path}"
                    )
                validate_inventory_directory(
                    child_descriptor,
                    relative_path,
                    expected_outputs,
                )
                current_stat = os.stat(
                    entry.name,
                    dir_fd=directory_descriptor,
                    follow_symlinks=False,
                )
                if not stat.S_ISDIR(current_stat.st_mode) or not same_entry(
                    opened_stat,
                    current_stat,
                ):
                    raise ValueError(
                        "directory-guidance inventory changed while scanning: "
                        f"{relative_path}"
                    )
            except OSError as error:
                raise ValueError(
                    f"cannot inspect directory-guidance inventory at {relative_path}: {error}"
                ) from error
            finally:
                os.close(child_descriptor)
            continue

        if entry.name != "CLAUDE.md" or relative_path in expected_outputs:
            continue
        if not stat.S_ISREG(entry_stat.st_mode):
            continue
        try:
            prefix = read_regular_output_at(
                directory_descriptor,
                entry.name,
                relative_path,
            )[: len(GENERATED_HEADER)]
        except (OSError, UnicodeError, ValueError) as error:
            raise ValueError(
                f"cannot inspect potential generated guidance {relative_path}: {error}"
            ) from error
        if prefix == GENERATED_HEADER:
            raise ValueError(f"orphaned generated directory guidance: {relative_path}")


def validate_output_inventory(
    root: Path,
    expected_outputs: set[str],
    retired_outputs: set[str],
) -> None:
    for relative_path in sorted(retired_outputs):
        if relative_entry_exists(root, relative_path):
            raise ValueError(
                f"retired scoped guidance still exists: {relative_path}; "
                "remove it so parent guidance cannot be overridden"
            )

    root_descriptor = os.open(root, DIRECTORY_OPEN_FLAGS)
    try:
        validate_inventory_directory(root_descriptor, "", expected_outputs)
    finally:
        os.close(root_descriptor)


def check_outputs(sections: dict[str, str], root: Path = ROOT) -> int:
    stale = False
    for relative_path, expected in sorted(sections.items()):
        actual = read_regular_output(root, relative_path, missing_ok=True)
        if actual == expected:
            continue
        stale = True
        print(f"stale generated directory guidance: {relative_path}", file=sys.stderr)
        diff = difflib.unified_diff(
            actual.splitlines(),
            expected.splitlines(),
            fromfile=relative_path,
            tofile=f"generated:{relative_path}",
            lineterm="",
        )
        for diff_line in diff:
            print(diff_line, file=sys.stderr)
    if stale:
        print(
            "run: python3 scripts/generate_directory_guidance.py",
            file=sys.stderr,
        )
        return 1
    print(f"directory guidance is current ({len(sections)} generated files)")
    return 0


def atomic_write_at(
    parent_descriptor: int,
    name: str,
    relative_path: str,
    content: str,
) -> None:
    existing_stat = stat_entry_or_none(parent_descriptor, name)
    if existing_stat is not None:
        validate_regular_output(existing_stat, relative_path)
    mode = stat.S_IMODE(existing_stat.st_mode) if existing_stat is not None else 0o644
    temporary_name: str | None = None
    try:
        for _ in range(16):
            candidate_name = f".{name}.{secrets.token_hex(8)}.tmp"
            try:
                descriptor = os.open(
                    candidate_name,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
                    0o600,
                    dir_fd=parent_descriptor,
                )
                temporary_name = candidate_name
                break
            except FileExistsError:
                continue
        else:
            raise OSError(f"could not allocate temporary output for {relative_path}")

        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(content)
            handle.flush()
            os.fchmod(handle.fileno(), mode)
            os.fsync(handle.fileno())
        os.replace(
            temporary_name,
            name,
            src_dir_fd=parent_descriptor,
            dst_dir_fd=parent_descriptor,
        )
        temporary_name = None
    finally:
        if temporary_name is not None:
            try:
                os.unlink(temporary_name, dir_fd=parent_descriptor)
            except FileNotFoundError:
                pass


def atomic_write(root: Path, relative_path: str, content: str) -> None:
    with open_parent_directory(root, relative_path) as (parent_descriptor, name):
        atomic_write_at(parent_descriptor, name, relative_path, content)


def write_outputs(sections: dict[str, str], root: Path = ROOT) -> None:
    for relative_path, content in sorted(sections.items()):
        atomic_write(root, relative_path, content)
        print(f"generated {relative_path}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail if a generated CLAUDE.md differs from the canonical source",
    )
    args = parser.parse_args()

    try:
        source = SOURCE_PATH.read_text(encoding="utf-8")
        sections = parse_sections(source)
        validate_output_inventory(ROOT, EXPECTED_OUTPUTS, RETIRED_OUTPUTS)
        if args.check:
            return check_outputs(sections)
        write_outputs(sections)
        return 0
    except (OSError, UnicodeError, ValueError) as error:
        print(f"directory guidance generation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
