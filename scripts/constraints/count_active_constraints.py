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


def _iter_constraints(path: Path, text: str) -> Iterable[Constraint]:
    _fields, body = _strip_frontmatter(text)
    frontmatter_offset = len(text) - len(body)

    for match in RULE_ID_RE.finditer(body):
        rule_id = match.group(1)
        yield Constraint(
            key=f"rule:{rule_id}",
            label=rule_id,
            source=path,
            line=_line_number(text, frontmatter_offset + match.start()),
        )

    in_fence = False
    body_lines = body.splitlines()
    for index, line in enumerate(body_lines, start=_line_number(text, frontmatter_offset)):
        stripped = line.strip()
        if stripped.startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence or not stripped or stripped.startswith("|"):
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


def discover_sources(
    root: Path,
    home: Path,
    task_paths: list[str],
    skills: list[str],
    explicit_sources: list[Path],
    include_canonical_rules: bool,
) -> dict[Path, str]:
    sources: dict[Path, str] = {}

    for path in explicit_sources:
        _add_source(sources, path, "explicit", root=root, task_paths=task_paths)

    global_files = [
        home / ".claude" / "CLAUDE.md",
        home / ".claude" / "AGENTS.md",
        home / ".codex" / "AGENTS.md",
    ]
    for path in global_files:
        _add_source(sources, path, "global", root=root, task_paths=task_paths)

    for base in (home / ".claude" / "rules", home / ".codex" / "rules"):
        for path in _iter_files(base, "**/*.md"):
            _add_source(sources, path, "global-rule", root=root, task_paths=task_paths)

    project_files = [
        root / "AGENTS.md",
        root / "CLAUDE.md",
        root / ".claude" / "CLAUDE.md",
    ]
    for path in project_files:
        _add_source(sources, path, "project", root=root, task_paths=task_paths)

    for path in _iter_files(root / ".claude" / "rules", "**/*.md"):
        _add_source(sources, path, "path-rule", root=root, task_paths=task_paths)

    if include_canonical_rules:
        for path in _iter_files(root / "rules" / "claude-rules", "**/*.md"):
            _add_source(sources, path, "canonical-rule", root=root, task_paths=task_paths)

    skill_roots = [
        root / "skills",
        root / "workflows",
        home / ".claude" / "skills",
        home / ".codex" / "skills",
    ]
    for skill in skills:
        for base in skill_roots:
            _add_source(sources, base / skill / "SKILL.md", "skill", root=root, task_paths=task_paths)

    return sources


def count_constraints(sources: dict[Path, str]) -> tuple[list[SourceReport], list[Constraint]]:
    seen: set[str] = set()
    reports: list[SourceReport] = []
    all_constraints: list[Constraint] = []

    for path, kind in sorted(sources.items(), key=lambda item: str(item[0])):
        text = _read_text(path)
        report = SourceReport(path=path, kind=kind)
        for constraint in _iter_constraints(path, text):
            if constraint.key in seen:
                continue
            seen.add(constraint.key)
            report.constraints.append(constraint)
            all_constraints.append(constraint)
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
        if not constraint.key.startswith("rule:"):
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
    task_paths = args.task_path or []
    skills = args.skill or []
    explicit_sources = [Path(item) for item in (args.source or [])]
    sources = discover_sources(
        root,
        home,
        task_paths,
        skills,
        explicit_sources,
        args.include_canonical_rules,
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
                "id": constraint.label if constraint.key.startswith("rule:") else "",
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
