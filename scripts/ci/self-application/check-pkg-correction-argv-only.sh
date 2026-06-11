#!/usr/bin/env bash
# Ensure package-manager correction strings are passed as data, never inlined.
set -euo pipefail

REPO_DIR="${1:-$(cd "$(dirname "$0")/../../.." && pwd)}"
HOOK="${REPO_DIR}/hooks/pre-bash-guard.sh"

python3 - <<'PY' "${HOOK}"
import re
import shlex
import sys
from pathlib import Path

path = Path(sys.argv[1])
errors: list[str] = []


def shell_var_ref(name: str) -> re.Pattern[str]:
    escaped = re.escape(name)
    return re.compile(rf"\${escaped}(?![A-Za-z0-9_])|\$\{{{escaped}[^}}]*\}}")


pkg_correction_ref = shell_var_ref("_PKG_CORRECTION")


def shell_word_plain(raw: str) -> str:
    try:
        parts = shlex.split(raw, posix=True)
    except ValueError:
        return raw
    return parts[0] if len(parts) == 1 else raw


def iter_shell_words(text: str):
    i = 0
    n = len(text)
    separators = set(";|&()<>")
    while i < n:
        if text[i].isspace():
            i += 1
            continue
        if text[i] == "#":
            newline = text.find("\n", i)
            i = n if newline == -1 else newline + 1
            continue
        if text[i] in separators:
            i += 1
            continue

        start = i
        while i < n and not text[i].isspace() and text[i] not in separators:
            if text[i] == "\\":
                i += 2
                continue
            if text[i] == "'":
                i += 1
                while i < n and text[i] != "'":
                    i += 1
                if i < n:
                    i += 1
                continue
            if text[i] == '"':
                i += 1
                while i < n:
                    if text[i] == "\\" and i + 1 < n:
                        i += 2
                        continue
                    if text[i] == '"':
                        i += 1
                        break
                    i += 1
                continue
            i += 1
        yield text[start:i], start, i


def iter_python_c_sources(text: str):
    """Yield (source_word, source_start, source_end) for python3 -c snippets."""
    words = list(iter_shell_words(text))
    for idx, (word, _start, _end) in enumerate(words):
        if shell_word_plain(word) != "python3":
            continue
        if idx + 2 >= len(words) or shell_word_plain(words[idx + 1][0]) != "-c":
            continue
        yield words[idx + 2]


def iter_python_stdin_sources(text: str):
    """Yield (source, source_start_line) for python3 - heredoc snippets."""
    lines = text.splitlines()
    heredoc_re = re.compile(
        r"\bpython3\s+-\s*<<(?P<tabs>-?)\s*(?P<quote>['\"]?)(?P<tag>[A-Za-z_][A-Za-z0-9_]*)"
    )
    line_no = 0
    while line_no < len(lines):
        match = heredoc_re.search(lines[line_no])
        if not match:
            line_no += 1
            continue

        delimiter = match.group("tag")
        allow_tab_strip = match.group("tabs") == "-"
        body_start = line_no + 2
        body_lines: list[str] = []
        line_no += 1
        while line_no < len(lines):
            candidate = lines[line_no].lstrip("\t") if allow_tab_strip else lines[line_no]
            if candidate == delimiter:
                break
            body_lines.append(lines[line_no])
            line_no += 1
        yield "\n".join(body_lines), body_start
        line_no += 1


def iter_shell_logical_lines(text: str):
    buffer = ""
    start_line = 1
    for line_no, raw_line in enumerate(text.splitlines(), start=1):
        if not buffer:
            start_line = line_no
        stripped = raw_line.rstrip()
        if stripped.endswith("\\"):
            buffer += stripped[:-1] + " "
            continue
        buffer += raw_line
        yield start_line, buffer
        buffer = ""
    if buffer:
        yield start_line, buffer

if not path.exists():
    errors.append("missing hooks/pre-bash-guard.sh")
else:
    text = path.read_text(encoding="utf-8")

    python_sources = list(iter_python_c_sources(text))
    argv_ref_pattern = re.compile(
        r'\s+"(?:\$_PKG_CORRECTION|\$\{_PKG_CORRECTION\})"'
    )
    trusted_python_emitter = any(
        "sys.argv[1]" in src and argv_ref_pattern.match(text[quote_end:])
        for src, _start, quote_end in python_sources
    )
    trusted_runtime_emitter = bool(
        re.search(
            r"printf\s+'%s'\s+\"\$_PKG_CORRECTION\"\s*\|\s*\"\$_VIBEGUARD_RUNTIME\"\s+allow-command-json",
            text,
        )
    )

    if "PKG-CORRECTION-ARGV-CONTRACT" not in text and "PKG-CORRECTION-JSON-CONTRACT" not in text:
        errors.append("missing package correction data-passing contract comment")

    if not trusted_python_emitter and not trusted_runtime_emitter:
        errors.append("_PKG_CORRECTION is not passed through a trusted data channel")

    for src, start, _quote_end in python_sources:
        if pkg_correction_ref.search(src):
            line = text[:start].count("\n") + 1
            errors.append(
                f"line {line}: _PKG_CORRECTION is interpolated into inline Python source"
            )

    for src, line in iter_python_stdin_sources(text):
        if pkg_correction_ref.search(src):
            errors.append(
                f"line {line}: _PKG_CORRECTION is interpolated into stdin Python source"
            )

    shell_eval_pattern = re.compile(r"\b(?:eval|bash\s+-c|sh\s+-c)\b")
    assignment_pattern = re.compile(
        r"(?<![A-Za-z0-9_$])"
        r"(?:(?:local|readonly|export)\s+|declare(?:\s+-[A-Za-z]+)*\s+)?"
        r"([A-Za-z_][A-Za-z0-9_]*)=([^;#]*)"
    )
    set_positional_pattern = re.compile(r"(?:^|[;&|])\s*set\s+--\s+([^;#]*)")
    tainted_vars = {"_PKG_CORRECTION"}
    for line_no, line in iter_shell_logical_lines(text):
        if line.lstrip().startswith("#"):
            continue
        for match in assignment_pattern.finditer(line):
            var_name, value = match.groups()
            if any(shell_var_ref(tainted).search(value) for tainted in tainted_vars):
                tainted_vars.add(var_name)
        for match in set_positional_pattern.finditer(line):
            value = match.group(1)
            if any(shell_var_ref(tainted).search(value) for tainted in tainted_vars):
                tainted_vars.update({"1", "@", "*"})
        if shell_eval_pattern.search(line) and any(
            shell_var_ref(tainted).search(line) for tainted in tainted_vars
        ):
            errors.append(f"line {line_no}: _PKG_CORRECTION flows through shell evaluation")

if errors:
    print("FAIL: package correction data-channel contract failed")
    for error in errors:
        print(error)
    raise SystemExit(1)

print("OK: package correction is passed through a trusted data channel")
PY
