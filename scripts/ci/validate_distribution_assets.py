#!/usr/bin/env python3
"""Fail when a tracked distribution asset has no verifiable lifecycle owner."""

from __future__ import annotations

import ast
import json
import shutil
import subprocess
import sys
import tomllib
from pathlib import Path, PurePosixPath


VALIDATOR_PATH = "scripts/ci/validate_distribution_assets.py"
FORMAL_EVIDENCE_PATHS = {
    "schemas/install-modules.json",
    "skills-lock.json",
}
EXCLUDED_CONSUMER_PREFIXES = (
    "docs/specs/",
    "plan/",
    "tests/",
)
EXECUTABLE_CONSUMER_PREFIXES = (
    ".github/workflows/",
    "checks/",
    "guards/",
    "hooks/",
    "scripts/",
    "tools/",
    "vibeguard-runtime/",
)
EXECUTABLE_CONSUMER_SUFFIXES = {
    ".json",
    ".py",
    ".sh",
    ".toml",
}
ROOT_CONFIG_SUFFIXES = {".json", ".toml", ".yaml", ".yml"}
TOKEN_BYTES = frozenset(
    b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./*-"
)


class ValidationError(RuntimeError):
    """Raised when repository evidence cannot be collected safely."""


def collect_git_lines(repo: Path, *args: str) -> list[str]:
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "unknown git error"
        raise ValidationError(f"git {' '.join(args)} failed: {detail}")
    return [line for line in result.stdout.splitlines() if line]


def collect_assets(tracked_paths: list[str]) -> list[str]:
    assets: set[str] = set()
    for raw_path in tracked_paths:
        path = PurePosixPath(raw_path)
        parts = path.parts
        if len(parts) == 3 and parts[0] == "skills" and parts[2] == "SKILL.md":
            assets.add(raw_path)
        elif len(parts) >= 2 and parts[0] == "templates":
            assets.add(raw_path)
        elif len(parts) == 1 and path.suffix in ROOT_CONFIG_SUFFIXES:
            assets.add(raw_path)
    return sorted(assets)


def iter_json_strings(value: object):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for key, item in value.items():
            if isinstance(key, str):
                yield key
            yield from iter_json_strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from iter_json_strings(item)


def load_json_strings(path: Path) -> set[str]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise ValidationError(f"cannot read {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise ValidationError(f"invalid JSON in {path}: {exc.msg}") from exc
    return set(iter_json_strings(data))


def manifest_installs(asset: str, manifest_strings: set[str]) -> bool:
    if asset in manifest_strings:
        return True
    if not asset.startswith("skills/"):
        return False
    return any(
        asset == f"{entry.rstrip('/')}/SKILL.md"
        for entry in manifest_strings
        if entry.startswith("skills/")
    )


def contains_exact_path(content: bytes, asset: str) -> bool:
    needle = asset.encode("utf-8")
    start = 0
    while True:
        index = content.find(needle, start)
        if index < 0:
            return False
        before = content[index - 1] if index > 0 else None
        after_index = index + len(needle)
        after = content[after_index] if after_index < len(content) else None
        repo_prefix = before == ord("/") and index >= 2 and content[index - 2] == ord("}")
        if (before is None or before not in TOKEN_BYTES or repo_prefix) and (
            after is None or after not in TOKEN_BYTES
        ):
            return True
        start = index + 1


def read_tracked_file(repo: Path, relative_path: str) -> bytes:
    try:
        return (repo / relative_path).read_bytes()
    except OSError as exc:
        raise ValidationError(f"cannot read tracked file {relative_path}: {exc}") from exc


def python_contains_executable_reference(content: bytes, asset: str) -> bool:
    try:
        tree = ast.parse(content.decode("utf-8"))
    except (SyntaxError, UnicodeDecodeError) as exc:
        raise ValidationError(f"cannot parse Python consumer candidate: {exc}") from exc

    parents = {
        id(child): parent
        for parent in ast.walk(tree)
        for child in ast.iter_child_nodes(parent)
    }

    def is_executable_string(node: ast.Constant) -> bool:
        current: ast.AST = node
        has_effectful_ancestor = False
        while id(current) in parents:
            current = parents[id(current)]
            if isinstance(current, (ast.Call, ast.Yield, ast.YieldFrom, ast.NamedExpr)):
                has_effectful_ancestor = True
            if isinstance(current, ast.Expr):
                return has_effectful_ancestor
            if isinstance(current, ast.stmt):
                return True
        return True

    return any(
        isinstance(node, ast.Constant)
        and isinstance(node.value, str)
        and is_executable_string(node)
        and contains_exact_path(node.value.encode("utf-8"), asset)
        for node in ast.walk(tree)
    )


def structured_strings(content: bytes, suffix: str) -> set[str]:
    try:
        text = content.decode("utf-8")
        data = json.loads(text) if suffix == ".json" else tomllib.loads(text)
    except (UnicodeDecodeError, json.JSONDecodeError, tomllib.TOMLDecodeError) as exc:
        raise ValidationError(f"cannot parse {suffix} consumer candidate: {exc}") from exc
    return set(iter_json_strings(data))


def validate_shell_syntax(content: bytes) -> None:
    bash_path = shutil.which("bash")
    if bash_path is None:
        raise ValidationError("cannot run bash syntax validation: bash was not found")
    try:
        result = subprocess.run(
            [bash_path, "--noprofile", "--norc", "-n", "-s"],
            input=content,
            check=False,
            capture_output=True,
        )
    except OSError as exc:
        raise ValidationError(f"cannot run bash syntax validation: {exc}") from exc
    if result.returncode != 0:
        detail = (
            result.stderr.decode("utf-8", errors="replace").strip()
            or result.stdout.decode("utf-8", errors="replace").strip()
            or "no diagnostic output"
        )
        raise ValidationError(
            "cannot parse shell consumer candidate with "
            f"{bash_path} (exit {result.returncode}): {detail}"
        )


SHELL_WORD_SEPARATORS = frozenset(b" \t\r\n;|&()<>")


def parse_heredoc_delimiter(
    line: bytes,
    operator_index: int,
) -> tuple[int, bytes, bool]:
    index = operator_index + 2
    strip_tabs = index < len(line) and line[index] == ord("-")
    if strip_tabs:
        index += 1
    while index < len(line) and line[index] in b" \t":
        index += 1

    delimiter = bytearray()
    quote: int | None = None
    while index < len(line):
        byte = line[index]
        if quote is not None:
            if byte == quote:
                quote = None
            elif byte == ord("\\") and quote == ord('"') and index + 1 < len(line):
                index += 1
                delimiter.append(line[index])
            else:
                delimiter.append(byte)
            index += 1
            continue
        if byte in {ord("'"), ord('"')}:
            quote = byte
            index += 1
            continue
        if byte == ord("\\") and index + 1 < len(line):
            index += 1
            delimiter.append(line[index])
            index += 1
            continue
        if byte in SHELL_WORD_SEPARATORS:
            break
        delimiter.append(byte)
        index += 1

    if quote is not None or not delimiter:
        raise ValidationError("cannot parse shell heredoc delimiter")
    return index, bytes(delimiter), strip_tabs


def shell_code_without_comments(content: bytes) -> bytes:
    code = bytearray()
    quote: int | None = None
    at_word_start = True
    contexts: list[str] = []
    command_depths: list[int] = []
    command_outer_quotes: list[int | None] = []
    arithmetic_depths: list[int] = []
    arithmetic_outer_quotes: list[int | None] = []
    queued_heredocs: list[tuple[bytes, bool]] = []
    active_heredocs: list[tuple[bytes, bool]] = []

    for line in content.splitlines(keepends=True):
        if active_heredocs:
            delimiter, strip_tabs = active_heredocs[0]
            candidate = line.rstrip(b"\r\n")
            if strip_tabs:
                candidate = candidate.lstrip(b"\t")
            if candidate == delimiter:
                active_heredocs.pop(0)
            continue

        index = 0
        continued = False
        while index < len(line):
            byte = line[index]
            if line[index : index + 3] == b"$((" and quote != ord("'"):
                code.extend(b"$((")
                contexts.append("arithmetic")
                arithmetic_depths.append(2)
                arithmetic_outer_quotes.append(quote)
                quote = None
                at_word_start = False
                index += 3
                continue
            if line[index : index + 2] == b"$(" and quote != ord("'"):
                code.extend(b"$(")
                contexts.append("command")
                command_depths.append(1)
                command_outer_quotes.append(quote)
                quote = None
                at_word_start = False
                index += 2
                continue
            if quote is not None:
                code.append(byte)
                if (
                    byte == ord("\\")
                    and quote == ord('"')
                    and index + 1 < len(line)
                ):
                    index += 1
                    code.append(line[index])
                elif byte == quote:
                    quote = None
                at_word_start = False
                index += 1
                continue
            if line[index : index + 2] == b"((" and not arithmetic_depths:
                code.extend(b"((")
                contexts.append("arithmetic")
                arithmetic_depths.append(2)
                arithmetic_outer_quotes.append(None)
                at_word_start = False
                index += 2
                continue
            if contexts and contexts[-1] == "arithmetic":
                if byte == ord("("):
                    arithmetic_depths[-1] += 1
                elif byte == ord(")"):
                    arithmetic_depths[-1] -= 1
                    if arithmetic_depths[-1] == 0:
                        arithmetic_depths.pop()
                        contexts.pop()
                        quote = arithmetic_outer_quotes.pop()
                code.append(byte)
                at_word_start = False
                index += 1
                continue
            if line[index : index + 3] == b"<<<":
                code.extend(b"<<<")
                at_word_start = False
                index += 3
                continue
            if (
                byte == ord("<")
                and index + 1 < len(line)
                and line[index + 1] == ord("<")
            ):
                index, delimiter, strip_tabs = parse_heredoc_delimiter(line, index)
                queued_heredocs.append((delimiter, strip_tabs))
                code.extend(b"<<HEREDOC")
                at_word_start = False
                continue
            if contexts and contexts[-1] == "command" and byte == ord("("):
                command_depths[-1] += 1
            elif contexts and contexts[-1] == "command" and byte == ord(")"):
                command_depths[-1] -= 1
                if command_depths[-1] == 0:
                    command_depths.pop()
                    contexts.pop()
                    quote = command_outer_quotes.pop()
            if byte == ord("\\") and index + 1 < len(line):
                if line[index + 1] in b"\r\n":
                    continued = True
                    index += 2
                    if index < len(line) and line[index - 1] == ord("\r") and line[index] == ord("\n"):
                        index += 1
                    continue
                code.append(byte)
                index += 1
                code.append(line[index])
                at_word_start = False
                index += 1
                continue
            if byte in {ord("'"), ord('"')}:
                quote = byte
                code.append(byte)
                at_word_start = False
                index += 1
                continue
            if byte == ord("#") and at_word_start:
                newline_index = line.find(b"\n", index)
                if newline_index >= 0:
                    code.append(ord("\n"))
                    at_word_start = True
                index = len(line)
                continue
            code.append(byte)
            at_word_start = byte in SHELL_WORD_SEPARATORS
            index += 1

        if queued_heredocs and not continued:
            active_heredocs.extend(queued_heredocs)
            queued_heredocs.clear()

    if quote is not None:
        raise ValidationError("unterminated shell quote")
    if command_depths:
        raise ValidationError("unterminated shell command substitution")
    if arithmetic_depths:
        raise ValidationError("unterminated shell arithmetic expression")
    if active_heredocs or queued_heredocs:
        raise ValidationError("unterminated shell heredoc")
    return bytes(code)


def contains_executable_reference(content: bytes, asset: str, suffix: str) -> bool:
    if suffix == ".py":
        return python_contains_executable_reference(content, asset)
    if suffix in {".json", ".toml"}:
        return any(
            contains_exact_path(value.encode("utf-8"), asset)
            for value in structured_strings(content, suffix)
        )

    if suffix == ".sh":
        validate_shell_syntax(content)
        return contains_exact_path(shell_code_without_comments(content), asset)
    return False


def find_consumer(
    repo: Path,
    asset: str,
    tracked_paths: list[str],
) -> str | None:
    for relative_path in tracked_paths:
        if relative_path in {
            asset,
            "CONTRIBUTING.md",
            VALIDATOR_PATH,
            *FORMAL_EVIDENCE_PATHS,
        }:
            continue
        if relative_path.startswith(EXCLUDED_CONSUMER_PREFIXES):
            continue
        if not relative_path.startswith(EXECUTABLE_CONSUMER_PREFIXES):
            continue
        suffix = PurePosixPath(relative_path).suffix
        if suffix not in EXECUTABLE_CONSUMER_SUFFIXES:
            continue
        try:
            is_consumer = contains_executable_reference(
                read_tracked_file(repo, relative_path),
                asset,
                suffix,
            )
        except ValidationError as exc:
            raise ValidationError(f"{relative_path}: {exc}") from exc
        if is_consumer:
            return relative_path
    return None


def manual_declaration(contributing: bytes, asset: str) -> bool:
    return f"`{asset}`".encode("utf-8") in contributing


def validate_distribution_assets(repo: Path) -> int:
    tracked_paths = collect_git_lines(repo, "ls-files")
    assets = collect_assets(tracked_paths)
    manifest_strings = load_json_strings(repo / "schemas/install-modules.json")
    skill_lock_strings = load_json_strings(repo / "skills-lock.json")
    contributing = read_tracked_file(repo, "CONTRIBUTING.md")

    failures: list[str] = []
    for asset in assets:
        evidence: str | None = None
        if manifest_installs(asset, manifest_strings):
            evidence = "install_module"
        elif asset in skill_lock_strings:
            evidence = "skills_lock"
        else:
            consumer = find_consumer(repo, asset, tracked_paths)
            if consumer is not None:
                evidence = f"consumer:{consumer}"
            elif manual_declaration(contributing, asset):
                evidence = "manual:CONTRIBUTING.md"

        if evidence is None:
            failures.append(asset)
            print(f"FAIL: unowned distribution asset: {asset}", file=sys.stderr)
        else:
            print(f"OK: {asset} <- {evidence}")

    if failures:
        print(
            f"Distribution asset validation failed: {len(failures)} unowned asset(s)",
            file=sys.stderr,
        )
        return 1
    print(f"All {len(assets)} tracked distribution assets have lifecycle evidence")
    return 0


def main() -> int:
    repo = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    if len(sys.argv) > 2:
        print("usage: validate_distribution_assets.py [repo]", file=sys.stderr)
        return 2
    try:
        return validate_distribution_assets(repo)
    except ValidationError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
