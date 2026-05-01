#!/usr/bin/env bash
# SEC-14 self-application: first-party MCP tool descriptions must not contain
# authority-claim or instruction-override language.
set -euo pipefail

REPO_DIR="${1:-$(cd "$(dirname "$0")/../../.." && pwd)}"

python3 - <<'PY' "${REPO_DIR}"
import re
import sys
from pathlib import Path

repo = Path(sys.argv[1])

forbidden = [
    re.compile(r"\babsolute authority\b", re.I),
    re.compile(r"\babsolute precedence\b", re.I),
    re.compile(r"\bsupersedes\s+user\s+requests?\b", re.I),
    re.compile(r"\boverrides?\s+user\b", re.I),
    re.compile(r"\bignore\s+prior\s+instructions?\b", re.I),
    re.compile(r"\bignore\s+previous\s+(?:prompt|instructions?)\b", re.I),
    re.compile(r"\boverride\s+system\b", re.I),
    re.compile(r"\bdisregard\s+the\s+user\b", re.I),
    re.compile(r"\bact\s+as\s+(?:a\s+|an\s+|the\s+)?(?:system|developer|root|admin|administrator)\b", re.I),
]

targets: list[Path] = []
for base in (repo / "mcp-server" / "src", repo / "mcp-server" / "dist"):
    if not base.exists():
        continue
    for path in sorted(base.rglob("*")):
        if not path.is_file():
            continue
        if "node_modules" in path.parts:
            continue
        if path.suffix not in {".js", ".mjs", ".cjs", ".ts", ".d.ts"}:
            continue
        if path.name.endswith(".map"):
            continue
        targets.append(path)

def line_no(text: str, index: int) -> int:
    return text.count("\n", 0, index) + 1


def skip_ws_comments(text: str, index: int) -> int:
    while index < len(text):
        if text[index].isspace():
            index += 1
            continue
        if text.startswith("//", index):
            newline = text.find("\n", index + 2)
            index = len(text) if newline == -1 else newline + 1
            continue
        if text.startswith("/*", index):
            end = text.find("*/", index + 2)
            index = len(text) if end == -1 else end + 2
            continue
        break
    return index


def read_string_literal(text: str, index: int) -> tuple[str, int, bool] | None:
    if index >= len(text) or text[index] not in "\"'`":
        return None
    quote = text[index]
    index += 1
    out: list[str] = []
    dynamic_template = False
    while index < len(text):
        ch = text[index]
        if ch == "\\":
            if index + 1 < len(text):
                esc = text[index + 1]
                if esc in "\r\n":
                    index += 2
                    if esc == "\r" and index < len(text) and text[index] == "\n":
                        index += 1
                    continue
                if esc == "x" and index + 3 < len(text) and re.fullmatch(r"[0-9A-Fa-f]{2}", text[index + 2 : index + 4]):
                    out.append(chr(int(text[index + 2 : index + 4], 16)))
                    index += 4
                    continue
                if esc == "u":
                    if index + 2 < len(text) and text[index + 2] == "{":
                        close = text.find("}", index + 3)
                        if close != -1 and re.fullmatch(r"[0-9A-Fa-f]{1,6}", text[index + 3 : close]):
                            out.append(chr(int(text[index + 3 : close], 16)))
                            index = close + 1
                            continue
                    if index + 5 < len(text) and re.fullmatch(r"[0-9A-Fa-f]{4}", text[index + 2 : index + 6]):
                        out.append(chr(int(text[index + 2 : index + 6], 16)))
                        index += 6
                        continue
                if esc in "01234567":
                    end = index + 2
                    while end < len(text) and end < index + 4 and text[end] in "01234567":
                        end += 1
                    out.append(chr(int(text[index + 1 : end], 8)))
                    index = end
                    continue
                escapes = {
                    "n": "\n",
                    "r": "\r",
                    "t": "\t",
                    "b": "\b",
                    "f": "\f",
                    "v": "\v",
                    "0": "\0",
                }
                out.append(escapes.get(esc, esc))
                index += 2
                continue
        if quote == "`" and text.startswith("${", index):
            dynamic_template = True
            expr_end = skip_arg(text, index + 2)
            if expr_end >= len(text) or text[expr_end] != "}":
                return None
            index = expr_end + 1
            continue
        if ch == quote:
            return ("".join(out), index + 1, dynamic_template)
        out.append(ch)
        index += 1
    return None


def read_static_string_term(text: str, index: int) -> tuple[str, int] | None:
    index = skip_ws_comments(text, index)
    literal = read_string_literal(text, index)
    if literal is not None:
        value, end, dynamic_template = literal
        if dynamic_template:
            return None
        return (value, end)

    if index < len(text) and text[index] == "(":
        nested = read_static_string_expression(text, index + 1, {")"})
        if nested is None:
            return None
        value, end = nested
        end = skip_ws_comments(text, end)
        if end < len(text) and text[end] == ")":
            return (value, end + 1)

    return None


def read_static_string_expression(text: str, index: int, end_delimiters: set[str]) -> tuple[str, int] | None:
    parts: list[str] = []
    term = read_static_string_term(text, index)
    if term is None:
        return None
    value, cursor = term
    parts.append(value)

    while True:
        cursor = skip_ws_comments(text, cursor)
        if cursor < len(text) and text[cursor] in end_delimiters:
            return ("".join(parts), cursor)
        if cursor < len(text) and text[cursor] == "+":
            term = read_static_string_term(text, cursor + 1)
            if term is None:
                return None
            value, cursor = term
            parts.append(value)
            continue
        return None


def previous_significant_index(text: str, index: int) -> int:
    index -= 1
    while index >= 0 and text[index].isspace():
        index -= 1
    return index


def previous_significant_char(text: str, index: int) -> str:
    index = previous_significant_index(text, index)
    return "" if index < 0 else text[index]


def previous_word(text: str, index: int) -> str:
    index -= 1
    while index >= 0 and text[index].isspace():
        index -= 1
    end = index + 1
    while index >= 0 and is_identifier_char(text[index]):
        index -= 1
    return text[index + 1 : end]


def regex_after_control_paren(text: str, index: int) -> bool:
    close = index - 1
    while close >= 0 and text[close].isspace():
        close -= 1
    if close < 0 or text[close] != ")":
        return False

    depth = 0
    cursor = close
    while cursor >= 0:
        ch = text[cursor]
        if ch == ")":
            depth += 1
        elif ch == "(":
            depth -= 1
            if depth == 0:
                return previous_word(text, cursor) in {"if", "while", "for", "with", "switch"}
        cursor -= 1
    return False


def regex_after_postfix_operator(text: str, index: int) -> bool:
    prev = previous_significant_index(text, index)
    if prev <= 0 or text[prev] not in "+-":
        return False
    if text[prev - 1] != text[prev]:
        return False
    return previous_significant_char(text, prev - 1) != ""


def read_regex_literal(text: str, index: int) -> int | None:
    if index >= len(text) or text[index] != "/" or text.startswith(("//", "/*"), index):
        return None
    if regex_after_postfix_operator(text, index):
        return None
    prev = previous_significant_char(text, index)
    regex_prefix_words = {"return", "throw", "case", "yield", "await", "typeof", "void", "delete"}
    allowed_after_word = previous_word(text, index) in regex_prefix_words
    allowed_after_control = prev == ")" and regex_after_control_paren(text, index)
    if prev and (is_identifier_char(prev) or prev in ")]}\"'`") and not (allowed_after_word or allowed_after_control):
        return None

    index += 1
    in_class = False
    while index < len(text):
        ch = text[index]
        if ch == "\\":
            index += 2
            continue
        if ch in "\r\n":
            return None
        if ch == "[":
            in_class = True
        elif ch == "]":
            in_class = False
        elif ch == "/" and not in_class:
            index += 1
            while index < len(text) and text[index].isalpha():
                index += 1
            return index
        index += 1
    return None


def skip_arg(text: str, index: int) -> int:
    depth = 0
    while index < len(text):
        if text.startswith("//", index) or text.startswith("/*", index):
            index = skip_ws_comments(text, index)
            continue
        regex_end = read_regex_literal(text, index)
        if regex_end is not None:
            index = regex_end
            continue
        literal = read_string_literal(text, index)
        if literal is not None:
            _, index, _ = literal
            continue
        ch = text[index]
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            if depth == 0:
                return index
            depth -= 1
        elif ch == "," and depth == 0:
            return index
        index += 1
    return index


def skip_group_close(text: str, index: int, close_char: str) -> int:
    depth = 0
    while index < len(text):
        if text.startswith("//", index) or text.startswith("/*", index):
            index = skip_ws_comments(text, index)
            continue
        regex_end = read_regex_literal(text, index)
        if regex_end is not None:
            index = regex_end
            continue
        literal = read_string_literal(text, index)
        if literal is not None:
            _, index, _ = literal
            continue
        ch = text[index]
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            if depth == 0:
                return index if ch == close_char else len(text)
            depth -= 1
        index += 1
    return index


def skip_type_args(text: str, index: int) -> int:
    index = skip_ws_comments(text, index)
    if index >= len(text) or text[index] != "<":
        return index

    depth = 0
    while index < len(text):
        if text.startswith("//", index) or text.startswith("/*", index):
            index = skip_ws_comments(text, index)
            continue
        literal = read_string_literal(text, index)
        if literal is not None:
            _, index, _ = literal
            continue

        ch = text[index]
        if ch == "<":
            depth += 1
        elif ch == ">":
            depth -= 1
            if depth == 0:
                return index + 1
        index += 1
    return index


def skip_optional_call_marker(text: str, index: int) -> int:
    index = skip_ws_comments(text, index)
    if text.startswith("?.", index):
        return skip_ws_comments(text, index + 2)
    return index


def parse_static_description(
    text: str,
    index: int,
    end_delimiters: set[str],
) -> tuple[str | None, int, str | None]:
    index = skip_ws_comments(text, index)
    literal = read_string_literal(text, index)
    if literal is None:
        return (None, index, "description must be a static string literal")
    value, end, dynamic_template = literal
    after = skip_ws_comments(text, end)
    if dynamic_template or after >= len(text) or text[after] not in end_delimiters:
        return (None, index, "description must not be composed dynamically")
    return (value, index, None)


def is_identifier_char(ch: str) -> bool:
    return ch.isalnum() or ch in "_$"


def read_identifier_escape(text: str, index: int) -> tuple[str, int] | None:
    if not text.startswith("\\u", index):
        return None
    if index + 2 < len(text) and text[index + 2] == "{":
        close = text.find("}", index + 3)
        if close != -1 and re.fullmatch(r"[0-9A-Fa-f]{1,6}", text[index + 3 : close]):
            return (chr(int(text[index + 3 : close], 16)), close + 1)
    if index + 5 < len(text) and re.fullmatch(r"[0-9A-Fa-f]{4}", text[index + 2 : index + 6]):
        return (chr(int(text[index + 2 : index + 6], 16)), index + 6)
    return None


def read_identifier(text: str, index: int) -> tuple[str, int] | None:
    parts: list[str] = []
    escaped = read_identifier_escape(text, index)
    if escaped is not None:
        ch, index = escaped
        parts.append(ch)
    elif index < len(text) and (text[index].isalpha() or text[index] in "_$"):
        parts.append(text[index])
        index += 1
    else:
        return None

    start = index
    while index < len(text):
        escaped = read_identifier_escape(text, index)
        if escaped is not None:
            ch, index = escaped
            parts.append(ch)
            continue
        if is_identifier_char(text[index]):
            parts.append(text[index])
            index += 1
            continue
        break
    return ("".join(parts), index)


def tool_member_call_start(text: str, index: int) -> tuple[int, str] | None:
    cursor = skip_ws_comments(text, index)
    while cursor < len(text):
        optional_member = False
        if text.startswith("?.", cursor):
            optional_member = True
            cursor = skip_ws_comments(text, cursor + 2)
            if cursor < len(text) and text[cursor] == "[":
                optional_member = False

        tool_name_start = skip_ws_comments(text, cursor) if optional_member else None
        if not optional_member and cursor < len(text) and text[cursor] == ".":
            tool_name_start = skip_ws_comments(text, cursor + 1)
        if tool_name_start is not None:
            tool_name = read_identifier(text, tool_name_start)
            if tool_name is None:
                return None
            prop_name, after_prop = tool_name
            after_prop_ok = after_prop >= len(text) or not is_identifier_char(text[after_prop])
            if prop_name in {"tool", "registerTool"} and after_prop_ok:
                call_start = skip_optional_call_marker(text, skip_type_args(text, after_prop))
                if call_start < len(text) and text[call_start] == "(":
                    return (call_start, prop_name)
            cursor = skip_ws_comments(text, after_prop)
            continue

        if cursor < len(text) and text[cursor] == "[":
            bracket_close = skip_arg(text, cursor + 1)
            if bracket_close >= len(text) or text[bracket_close] != "]":
                return None
            prop_start = skip_ws_comments(text, cursor + 1)
            prop = read_static_string_expression(text, prop_start, {"]"})
            if prop is not None:
                prop_name, prop_end = prop
                prop_close = skip_ws_comments(text, prop_end)
                if prop_close == bracket_close and prop_name in {"tool", "registerTool"}:
                    call_start = skip_optional_call_marker(text, skip_type_args(text, bracket_close + 1))
                    if call_start < len(text) and text[call_start] == "(":
                        return (call_start, prop_name)
            else:
                call_start = skip_optional_call_marker(text, skip_type_args(text, bracket_close + 1))
                if call_start < len(text) and text[call_start] == "(":
                    return (call_start, "unsupportedToolMember")
            cursor = skip_ws_comments(text, bracket_close + 1)
            continue

        return None

    return None


def tool_call_start(text: str, index: int) -> tuple[int | None, str | None, str | None]:
    if text[index] == "(":
        receiver_end = skip_arg(text, index + 1)
        if receiver_end < len(text) and text[receiver_end] == ")":
            member_call = tool_member_call_start(text, receiver_end + 1)
            if member_call is not None:
                call_start, call_kind = member_call
                return (call_start, call_kind, None)
        return (None, None, None)

    ident = read_identifier(text, index)
    if ident is None:
        return (None, None, None)
    _, after_object = ident
    before_ok = index == 0 or not is_identifier_char(text[index - 1])
    if not before_ok:
        return (None, None, None)

    member_call = tool_member_call_start(text, after_object)
    if member_call is not None:
        call_start, call_kind = member_call
        return (call_start, call_kind, None)
    return (None, None, None)


def describe_call_start(text: str, index: int) -> tuple[int | None, str | None]:
    cursor = index
    optional_member = False
    if text.startswith("?.", cursor):
        optional_member = True
        cursor = skip_ws_comments(text, cursor + 2)

    describe_name_start: int | None = None
    if optional_member:
        describe_name_start = skip_ws_comments(text, cursor)
    elif cursor < len(text) and text[cursor] == ".":
        describe_name_start = skip_ws_comments(text, cursor + 1)

    if describe_name_start is not None:
        describe_name = read_identifier(text, describe_name_start)
        if describe_name is not None and describe_name[0] == "describe":
            after_describe = describe_name[1]
            after_ok = after_describe >= len(text) or not is_identifier_char(text[after_describe])
            call_start = skip_optional_call_marker(text, skip_type_args(text, after_describe))
            if after_ok and call_start < len(text) and text[call_start] == "(":
                return (call_start, None)

    if cursor < len(text) and text[cursor] == "[":
        bracket_close = skip_arg(text, cursor + 1)
        if bracket_close >= len(text) or text[bracket_close] != "]":
            return (None, None)
        prop_start = skip_ws_comments(text, cursor + 1)
        prop = read_static_string_expression(text, prop_start, {"]"})
        if prop is None:
            call_start = skip_optional_call_marker(text, skip_type_args(text, bracket_close + 1))
            if call_start < len(text) and text[call_start] == "(":
                arg_start = skip_ws_comments(text, call_start + 1)
                if arg_start < len(text) and text[arg_start] != ")":
                    return (call_start, "schema description member name must be static `describe`")
            return (None, None)
        prop_name, prop_end = prop
        prop_close = skip_ws_comments(text, prop_end)
        if prop_close >= len(text) or text[prop_close] != "]":
            return (None, None)
        if prop_name == "describe":
            call_start = skip_optional_call_marker(text, skip_type_args(text, prop_close + 1))
            if call_start < len(text) and text[call_start] == "(":
                return (call_start, None)

    return (None, None)


def read_property_key(text: str, index: int) -> tuple[str, int] | None:
    index = skip_ws_comments(text, index)
    if index >= len(text):
        return None

    if text[index] == "[":
        bracket_close = skip_arg(text, index + 1)
        if bracket_close >= len(text) or text[bracket_close] != "]":
            return None
        prop_start = skip_ws_comments(text, index + 1)
        prop = read_static_string_expression(text, prop_start, {"]"})
        if prop is None:
            return None
        prop_name, prop_end = prop
        prop_close = skip_ws_comments(text, prop_end)
        if prop_close != bracket_close:
            return None
        after_key = skip_ws_comments(text, bracket_close + 1)
    else:
        literal = read_string_literal(text, index)
        if literal is not None:
            prop_name, after_key, dynamic_template = literal
            if dynamic_template:
                return None
        else:
            ident = read_identifier(text, index)
            if ident is None:
                return None
            prop_name, after_key = ident
        after_key = skip_ws_comments(text, after_key)

    if after_key < len(text) and text[after_key] == ":":
        return (prop_name, after_key + 1)
    return None


def extract_register_tool_descriptions(text: str, index: int) -> list[tuple[int, str, str | None, str | None]]:
    descriptions: list[tuple[int, str, str | None, str | None]] = []
    index = skip_ws_comments(text, index)
    if index >= len(text) or text[index] != "{":
        return [(
            line_no(text, index),
            "tool description",
            None,
            "registerTool options must be an inline object literal",
        )]

    object_end = skip_group_close(text, index + 1, "}")
    if object_end >= len(text) or text[object_end] != "}":
        return [(
            line_no(text, index),
            "tool description",
            None,
            "registerTool options must be an inline object literal",
        )]

    cursor = index + 1
    while cursor < object_end:
        cursor = skip_ws_comments(text, cursor)
        if cursor >= object_end:
            break
        prop = read_property_key(text, cursor)
        if prop is None:
            descriptions.append((
                line_no(text, cursor),
                "tool description",
                None,
                "registerTool options properties must be static key: value entries",
            ))
            next_cursor = skip_arg(text, cursor)
        else:
            prop_name, value_start = prop
            if prop_name == "description":
                value, value_index, error = parse_static_description(text, value_start, {",", "}"})
                descriptions.append((line_no(text, value_index), "tool description", value, error))
            next_cursor = skip_arg(text, value_start)

        if next_cursor >= len(text) or next_cursor >= object_end:
            break
        cursor = next_cursor + 1 if text[next_cursor] == "," else next_cursor

    return descriptions


def extract_descriptions(path: Path, text: str) -> list[tuple[int, str, str | None, str | None]]:
    descriptions: list[tuple[int, str, str | None, str | None]] = []
    index = 0
    while index < len(text):
        if text.startswith("//", index) or text.startswith("/*", index):
            index = skip_ws_comments(text, index)
            continue
        regex_end = read_regex_literal(text, index)
        if regex_end is not None:
            index = regex_end
            continue
        literal = read_string_literal(text, index)
        if literal is not None:
            _, index, _ = literal
            continue

        call_start, call_kind, call_error = tool_call_start(text, index)
        if call_error is not None:
            descriptions.append((line_no(text, index), "tool description", None, call_error))
            index += len("server")
            continue
        if call_start is not None:
            handled_tool_call = True
            if call_kind == "unsupportedToolMember":
                first_arg_end = skip_arg(text, call_start + 1)
                if first_arg_end < len(text) and text[first_arg_end] == ",":
                    descriptions.append((
                        line_no(text, index),
                        "tool description",
                        None,
                        "computed tool member name must be static `tool` or `registerTool`",
                    ))
                else:
                    handled_tool_call = False
            else:
                first_arg_end = skip_arg(text, call_start + 1)
                if first_arg_end < len(text) and text[first_arg_end] == ",":
                    if call_kind == "tool":
                        value, value_index, error = parse_static_description(text, first_arg_end + 1, {",", ")"})
                        descriptions.append((line_no(text, value_index), "tool description", value, error))
                    elif call_kind == "registerTool":
                        descriptions.extend(extract_register_tool_descriptions(text, first_arg_end + 1))
            if handled_tool_call:
                index = call_start + 1
                continue

        describe_start, describe_error = describe_call_start(text, index)
        if describe_error is not None:
            descriptions.append((line_no(text, index), "schema description", None, describe_error))
            index = (describe_start + 1) if describe_start is not None else index + 1
            continue
        if describe_start is not None:
            value, value_index, error = parse_static_description(text, describe_start + 1, {",", ")"})
            descriptions.append((line_no(text, value_index), "schema description", value, error))
            index = describe_start + 1
            continue

        index += 1
    return descriptions


errors: list[str] = []
description_surfaces: list[tuple[Path, int, str, str]] = []
for path in targets:
    text = path.read_text(encoding="utf-8", errors="replace")
    for line, surface, description, error in extract_descriptions(path, text):
        if error is not None:
            rel = path.relative_to(repo)
            errors.append(f"{rel}:{line}: SEC-14 MCP {surface} {error}")
            continue
        assert description is not None
        description_surfaces.append((path, line, surface, description))

for path, line, surface, description in description_surfaces:
    for pattern in forbidden:
        for match in pattern.finditer(description):
            rel = path.relative_to(repo)
            errors.append(f"{rel}:{line}: SEC-14 forbidden phrase `{match.group(0)}` in MCP {surface}")

if errors:
    print("FAIL: MCP description surfaces contain SEC-14 authority/override language")
    for error in errors:
        print(error)
    raise SystemExit(1)

print("OK: first-party MCP description surfaces avoid SEC-14 forbidden language")
PY
