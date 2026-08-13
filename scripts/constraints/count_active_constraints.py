#!/usr/bin/env python3
"""Count effective constraints loaded into an agent context.

U-32 is about the live context budget, not a single file's line count. This
script scans high-context instruction surfaces, deduplicates rule IDs and
normative bullet constraints, and reports whether the current task exceeds the
warn/block budget.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable


WARN_THRESHOLD = 15
BLOCK_THRESHOLD = 30
RULE_ID_RE = re.compile(r"^##\s+((?:U|W|SEC|RS|PY|TS|GO|TASTE)-\d+):", re.M)
TABLE_RULE_ID_RE = re.compile(r"(?:U|W|SEC|RS|PY|TS|GO|TASTE)-\d+")
COMPACT_RULES_START = "<!-- vibeguard-generated-compact-rules:start -->"
COMPACT_RULES_END = "<!-- vibeguard-generated-compact-rules:end -->"
BULLET_RE = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s+(.+)")
NORMATIVE_RE = re.compile(
    r"\b(must|must not|should|should not|never|always|require|requires|required|"
    r"avoid|do not|don't|prohibit|forbid|block|verify)\b|"
    r"(必须|禁止|不要|不得|需要|要求|阻断|验证)",
    re.I,
)
FRONTMATTER_RE = re.compile(r"\A---\n(?P<body>.*?)\n---\n", re.S)


@dataclass(frozen=True)
class Constraint:
    key: str
    label: str
    source: Path
    line: int


@dataclass
class SourceReport:
    path: Path
    kind: str
    count: int = 0
    constraints: list[Constraint] = field(default_factory=list)


def _safe_resolve(path: Path) -> Path:
    try:
        return path.resolve()
    except OSError:
        return path


def _read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return path.read_text(encoding="utf-8", errors="replace")


def _strip_frontmatter(text: str) -> tuple[dict[str, str], str]:
    match = FRONTMATTER_RE.match(text)
    if not match:
        return {}, text
    fields: dict[str, str] = {}
    for line in match.group("body").splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        fields[key.strip()] = value.strip()
    return fields, text[match.end() :]


def _line_number(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def _normalize_constraint(value: str) -> str:
    value = re.sub(r"`[^`]+`", "`x`", value)
    value = re.sub(r"\s+", " ", value.strip().lower())
    return value[:240]


# Core rows may summarize one detailed rule, but detailed rule IDs remain
# independent constraints even when they share a broad topic.
CORE_EQUIVALENT_KEYS = {
    (
        _normalize_constraint("Errors"),
        _normalize_constraint(
            "User-visible missing data, malformed input, or wrong output must fail clearly."
        ),
    ): "rule:U-29",
    (
        _normalize_constraint("Scope"),
        _normalize_constraint(
            "Make the smallest requested change; do not add adjacent improvements."
        ),
    ): "rule:U-04",
    (
        _normalize_constraint("Verification"),
        _normalize_constraint(
            "Run a fresh, focused project command before claiming completion."
        ),
    ): "rule:W-03",
}


def _rule_constraint_key(rule_id: str) -> str:
    return f"rule:{rule_id}"


def _core_constraint_key(area: str, requirement: str) -> str:
    normalized_area = _normalize_constraint(area)
    normalized_requirement = _normalize_constraint(requirement)
    return CORE_EQUIVALENT_KEYS.get(
        (normalized_area, normalized_requirement),
        f"core:{normalized_area}:{normalized_requirement}",
    )


def _is_rule_constraint(constraint: Constraint) -> bool:
    return TABLE_RULE_ID_RE.fullmatch(constraint.label) is not None


def _iter_constraints(path: Path, text: str) -> Iterable[Constraint]:
    _fields, body = _strip_frontmatter(text)
    frontmatter_offset = len(text) - len(body)

    for match in RULE_ID_RE.finditer(body):
        rule_id = match.group(1)
        yield Constraint(
            key=_rule_constraint_key(rule_id),
            label=rule_id,
            source=path,
            line=_line_number(text, frontmatter_offset + match.start()),
        )

    in_fence = False
    in_core_contract = False
    in_compact_rules = False
    body_lines = body.splitlines()
    for index, line in enumerate(body_lines, start=_line_number(text, frontmatter_offset)):
        stripped = line.strip()
        if stripped.startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence or not stripped:
            continue
        if stripped == COMPACT_RULES_START:
            in_compact_rules = True
            continue
        if stripped == COMPACT_RULES_END:
            in_compact_rules = False
            continue
        if stripped.startswith("## "):
            in_core_contract = stripped == "## Core contract"
        if stripped.startswith("|"):
            cells = [cell.strip() for cell in stripped.strip("|").split("|")]
            first_cell = cells[0] if cells else ""
            if in_compact_rules and TABLE_RULE_ID_RE.fullmatch(first_cell):
                yield Constraint(
                    key=_rule_constraint_key(first_cell),
                    label=first_cell,
                    source=path,
                    line=index,
                )
            elif (
                in_core_contract
                and len(cells) >= 2
                and first_cell not in {"Area", ""}
                and not set(first_cell) <= {"-", ":"}
            ):
                yield Constraint(
                    key=_core_constraint_key(first_cell, cells[1]),
                    label=f"Core contract: {first_cell}",
                    source=path,
                    line=index,
                )
            continue
        bullet = BULLET_RE.match(line)
        if not bullet:
            continue
        payload = bullet.group(1).strip()
        if not NORMATIVE_RE.search(payload):
            continue
        key = "text:" + _normalize_constraint(payload)
        yield Constraint(key=key, label=payload[:120], source=path, line=index)


def _split_frontmatter_paths(value: str) -> list[str]:
    if not value:
        return []
    value = value.strip()
    if value.startswith("[") and value.endswith("]"):
        try:
            parsed = json.loads(value)
        except json.JSONDecodeError:
            parsed = []
        return [str(item).strip() for item in parsed if str(item).strip()]
    return [part.strip() for part in value.split(",") if part.strip()]


def _matches_task_path(path: Path, text: str, root: Path, task_paths: list[str]) -> bool:
    fields, _body = _strip_frontmatter(text)
    patterns = _split_frontmatter_paths(fields.get("paths", ""))
    if not patterns:
        return True
    if not task_paths:
        return False
    normalized = [item.replace(os.sep, "/").lstrip("./") for item in task_paths]
    for task_path in normalized:
        for pattern in patterns:
            if fnmatch.fnmatch(task_path, pattern) or fnmatch.fnmatch(str(root / task_path), pattern):
                return True
    return False


def _iter_files(root: Path, pattern: str) -> Iterable[Path]:
    if not root.exists():
        return []
    return (path for path in root.glob(pattern) if path.is_file())


def _add_source(
    sources: dict[Path, str],
    path: Path,
    kind: str,
    *,
    root: Path,
    task_paths: list[str],
) -> None:
    if not path.is_file():
        return
    resolved = _safe_resolve(path)
    if resolved in sources:
        return
    text = _read_text(path)
    if not _matches_task_path(path, text, root, task_paths):
        return
    sources[resolved] = kind


def _host_includes_claude(host: str) -> bool:
    return host in {"all", "claude"}


def _host_includes_codex(host: str) -> bool:
    return host in {"all", "codex"}


def discover_sources(
    root: Path,
    home: Path,
    codex_home: Path,
    task_paths: list[str],
    skills: list[str],
    explicit_sources: list[Path],
    include_canonical_rules: bool,
    host: str,
) -> dict[Path, str]:
    sources: dict[Path, str] = {}

    for path in explicit_sources:
        _add_source(sources, path, "explicit", root=root, task_paths=task_paths)

    global_files = []
    if _host_includes_claude(host):
        global_files.extend(
            [
                home / ".claude" / "CLAUDE.md",
                home / ".claude" / "AGENTS.md",
            ]
        )
    if _host_includes_codex(host):
        global_files.append(codex_home / "AGENTS.md")
    for path in global_files:
        _add_source(sources, path, "global", root=root, task_paths=task_paths)

    global_rule_roots = []
    if _host_includes_claude(host):
        global_rule_roots.append(home / ".claude" / "rules")
    for base in global_rule_roots:
        for path in _iter_files(base, "**/*.md"):
            _add_source(sources, path, "global-rule", root=root, task_paths=task_paths)

    project_files = []
    if _host_includes_codex(host):
        project_files.extend(_codex_project_instruction_files(root, task_paths))
    if _host_includes_claude(host):
        project_files.extend(
            [root / "AGENTS.md", root / "CLAUDE.md", root / ".claude" / "CLAUDE.md"]
        )
    for path in project_files:
        _add_source(sources, path, "project", root=root, task_paths=task_paths)

    if _host_includes_claude(host):
        for path in _iter_files(root / ".claude" / "rules", "**/*.md"):
            _add_source(sources, path, "path-rule", root=root, task_paths=task_paths)

    if include_canonical_rules:
        for path in _iter_files(root / "rules" / "claude-rules", "**/*.md"):
            _add_source(sources, path, "canonical-rule", root=root, task_paths=task_paths)

    skill_roots = [
        root / "skills",
        root / "workflows",
    ]
    if _host_includes_claude(host):
        skill_roots.append(home / ".claude" / "skills")
    if _host_includes_codex(host):
        skill_roots.append(codex_home / "skills")
    for skill in skills:
        for base in skill_roots:
            _add_source(sources, base / skill / "SKILL.md", "skill", root=root, task_paths=task_paths)

    return sources


def _codex_project_instruction_files(root: Path, task_paths: list[str]) -> list[Path]:
    resolved_root = root.resolve()
    instruction_files = {_codex_instruction_file(resolved_root)}
    for task_path in task_paths:
        candidate = Path(task_path)
        if not candidate.is_absolute():
            candidate = resolved_root / candidate
        candidate = candidate.resolve()
        try:
            candidate.relative_to(resolved_root)
        except ValueError:
            continue
        directory = candidate if candidate.is_dir() else candidate.parent
        while directory != resolved_root:
            instruction_files.add(_codex_instruction_file(directory))
            parent = directory.parent
            if parent == directory:
                break
            directory = parent
    return sorted(instruction_files)


def _codex_instruction_file(directory: Path) -> Path:
    override_path = directory / "AGENTS.override.md"
    return override_path if override_path.is_file() else directory / "AGENTS.md"


def count_constraints(sources: dict[Path, str]) -> tuple[list[SourceReport], list[Constraint]]:
    seen: set[str] = set()
    parsed_sources: list[tuple[SourceReport, list[Constraint]]] = []
    all_constraints: list[Constraint] = []

    for path, kind in sorted(sources.items(), key=lambda item: str(item[0])):
        text = _read_text(path)
        report = SourceReport(path=path, kind=kind)
        parsed_sources.append((report, list(_iter_constraints(path, text))))

    # Rule IDs win over equivalent shared-core rows so reports retain a useful
    # canonical ID while still counting the semantic requirement only once.
    for rule_pass in (True, False):
        for report, constraints in parsed_sources:
            for constraint in constraints:
                if _is_rule_constraint(constraint) != rule_pass:
                    continue
                if constraint.key in seen:
                    continue
                seen.add(constraint.key)
                report.constraints.append(constraint)
                all_constraints.append(constraint)

    reports: list[SourceReport] = []
    for report, _constraints in parsed_sources:
        report.count = len(report.constraints)
        if report.count:
            reports.append(report)

    return reports, all_constraints


def load_recent_event_text(log_paths: list[Path], max_lines: int) -> str:
    chunks: list[str] = []
    for path in log_paths:
        if not path.is_file():
            continue
        try:
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        chunks.extend(lines[-max_lines:])
    return "\n".join(chunks)


def low_frequency_candidates(constraints: list[Constraint], event_text: str, limit: int) -> list[dict[str, Any]]:
    candidates: list[dict[str, Any]] = []
    for constraint in constraints:
        if not _is_rule_constraint(constraint):
            continue
        rule_id = constraint.label
        if rule_id in event_text:
            continue
        candidates.append(
            {
                "id": rule_id,
                "source": str(constraint.source),
                "line": constraint.line,
                "reason": "no recent event-log hit",
                "downgrade_to": "skill/hook/path-scoped rule",
            }
        )
        if len(candidates) >= limit:
            break
    return candidates


def status_for(total: int, warn_threshold: int, block_threshold: int) -> str:
    if total > block_threshold:
        return "block"
    if total > warn_threshold:
        return "warn"
    return "ok"


def build_report(args: argparse.Namespace) -> dict[str, Any]:
    root = _safe_resolve(Path(args.root))
    home = _safe_resolve(Path(args.home).expanduser())
    codex_home = _safe_resolve(
        Path(args.codex_home).expanduser()
        if args.codex_home
        else Path(os.environ.get("CODEX_HOME", home / ".codex")).expanduser()
    )
    task_paths = args.task_path or []
    skills = args.skill or []
    explicit_sources = [Path(item) for item in (args.source or [])]
    sources = discover_sources(
        root,
        home,
        codex_home,
        task_paths,
        skills,
        explicit_sources,
        args.include_canonical_rules,
        args.host,
    )
    reports, constraints = count_constraints(sources)
    total = len(constraints)
    status = status_for(total, args.warn_threshold, args.block_threshold)

    event_logs = [Path(item).expanduser() for item in (args.events_log or [])]
    if not event_logs:
        event_logs = [home / ".vibeguard" / "events.jsonl"]
    event_text = load_recent_event_text(event_logs, args.event_lines)

    return {
        "status": status,
        "total": total,
        "warn_threshold": args.warn_threshold,
        "block_threshold": args.block_threshold,
        "sources": [
            {
                "path": str(report.path),
                "kind": report.kind,
                "count": report.count,
            }
            for report in reports
        ],
        "constraints": [
            {
                "id": constraint.label if _is_rule_constraint(constraint) else "",
                "label": constraint.label,
                "source": str(constraint.source),
                "line": constraint.line,
            }
            for constraint in constraints
        ],
        "low_frequency_candidates": low_frequency_candidates(
            constraints,
            event_text,
            args.low_frequency_limit,
        )
        if args.gc_report
        else [],
    }


def print_text(report: dict[str, Any], gc_report: bool) -> None:
    total = report["total"]
    status = report["status"]
    print(
        f"U-32 effective constraint budget: {total} "
        f"(warn>{report['warn_threshold']}, block>{report['block_threshold']})"
    )
    print(f"Status: {status.upper()}")
    if report["sources"]:
        print("Sources:")
        for source in report["sources"]:
            print(f"  - {source['kind']}: {source['count']}  {source['path']}")
    else:
        print("Sources: none")

    if status == "warn":
        print("Recommendation: split lower-frequency material into path-scoped rules, skills, or hooks.")
    elif status == "block":
        print("Required: reduce the live task context before continuing; keep effective constraints <=30.")

    if gc_report:
        print("Low-frequency rule downgrade candidates:")
        candidates = report["low_frequency_candidates"]
        if not candidates:
            print("  - none")
        for item in candidates:
            print(
                "  - {id} ({source}:{line}) -> {downgrade_to}; {reason}".format(
                    **item
                )
            )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Count effective VibeGuard constraints")
    parser.add_argument("--root", default=".", help="Project root to scan")
    parser.add_argument("--home", default=str(Path.home()), help="Home directory for global agent surfaces")
    parser.add_argument(
        "--codex-home",
        help="Codex home directory (default: $CODEX_HOME or <home>/.codex)",
    )
    parser.add_argument(
        "--host",
        choices=("all", "claude", "codex"),
        default="all",
        help="Agent host whose global surfaces are active",
    )
    parser.add_argument("--task-path", action="append", help="Task path used to activate path-scoped rules")
    parser.add_argument("--skill", action="append", help="Active skill name whose SKILL.md is loaded")
    parser.add_argument("--source", action="append", help="Explicit markdown source to include")
    parser.add_argument(
        "--include-canonical-rules",
        action="store_true",
        help="Include repository rule source files under rules/claude-rules/ for GC analysis",
    )
    parser.add_argument("--warn-threshold", type=int, default=WARN_THRESHOLD)
    parser.add_argument("--block-threshold", type=int, default=BLOCK_THRESHOLD)
    parser.add_argument("--json", action="store_true", help="Emit JSON")
    parser.add_argument("--fail-on-block", action="store_true", help="Exit non-zero when status is block")
    parser.add_argument("--gc-report", action="store_true", help="Include low-frequency downgrade candidates")
    parser.add_argument("--events-log", action="append", help="Event log path for GC frequency analysis")
    parser.add_argument("--event-lines", type=int, default=5000)
    parser.add_argument("--low-frequency-limit", type=int, default=10)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    report = build_report(args)
    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        print_text(report, args.gc_report)
    if args.fail_on_block and report["status"] == "block":
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
