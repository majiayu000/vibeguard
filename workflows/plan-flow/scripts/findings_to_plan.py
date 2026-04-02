#!/usr/bin/env python3
"""Generate a docs/plan draft from redundancy scan findings."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import List, Sequence


SECTION_HEADER_RE = re.compile(r"^##\s+(\d+)\)")
DUP_SYMBOL_RE = re.compile(r"^- `([^`]+)`\s*$")
BULLET_RE = re.compile(r"^\s*-\s+(.+)$")
FILE_PATH_RE = re.compile(r"([A-Za-z0-9_./-]+\.rs):\d+")
PHASE_ORDER = ["P0", "P1", "P2"]
PHASE_RANK = {phase: idx for idx, phase in enumerate(PHASE_ORDER)}
LEVEL_TO_SCORE = {"low": 1, "medium": 3, "high": 5}


@dataclass
class Finding:
    finding_id: str
    step_id: str
    category: str
    title: str
    symbol: str | None
    files: List[str]
    evidence: List[str]
    impact: str
    effort: int
    risk: str
    confidence: int
    priority_score: int
    phase: str
    canonical_hint: str


def read_scan_report(
    repo_path: Path, scan_report: Path | None, target_dir: str | None
) -> str:
    if scan_report is not None:
        return scan_report.read_text(encoding="utf-8")

    if target_dir is None:
        raise ValueError("Either --scan-report or --target-dir must be provided.")

    scan_script = Path(__file__).resolve().parent / "redundancy_scan.sh"
    if not scan_script.exists():
        raise FileNotFoundError(f"Scan script not found: {scan_script}")

    result = subprocess.run(
        [str(scan_script), target_dir],
        cwd=str(repo_path),
        capture_output=True,
        text=True,
        check=True,
    )
    return result.stdout


def parse_sections(report_text: str) -> tuple[List[str], List[str], List[str]]:
    duplicate_lines: List[str] = []
    factory_lines: List[str] = []
    legacy_lines: List[str] = []
    section = ""

    for line in report_text.splitlines():
        section_match = SECTION_HEADER_RE.match(line)
        if section_match:
            section = section_match.group(1)
            continue

        if section == "1":
            duplicate_lines.append(line)
        elif section == "2":
            factory_lines.append(line)
        elif section == "3":
            legacy_lines.append(line)

    return duplicate_lines, factory_lines, legacy_lines


def extract_files(evidence_lines: Sequence[str]) -> List[str]:
    files: List[str] = []
    for line in evidence_lines:
        m = FILE_PATH_RE.search(line)
        if not m:
            continue
        path = m.group(1)
        if path not in files:
            files.append(path)
    return files


def parse_duplicate_findings(lines: Sequence[str]) -> List[Finding]:
    findings: List[Finding] = []
    current_symbol: str | None = None
    current_evidence: List[str] = []

    def flush() -> None:
        nonlocal current_symbol, current_evidence
        if current_symbol is None:
            return
        files = extract_files(current_evidence)
        count = len(files)
        impact = "high" if count >= 3 else "medium"
        risk = "medium"
        findings.append(
            Finding(
                finding_id="",
                step_id="",
                category="same-concept multi-def",
                title=f"Convergence repetition type `{current_symbol}` definition",
                symbol=current_symbol,
                files=files,
                evidence=current_evidence[:3],
                impact=impact,
                effort=0,
                risk=risk,
                confidence=0,
                priority_score=0,
                phase="P2",
                canonical_hint=f"Select one canonical `{current_symbol}` owner and adapt callers.",
            )
        )
        current_symbol = None
        current_evidence = []

    for line in lines:
        symbol_match = DUP_SYMBOL_RE.match(line.strip())
        if symbol_match:
            flush()
            current_symbol = symbol_match.group(1)
            continue

        if current_symbol is None:
            continue

        bullet_match = BULLET_RE.match(line)
        if bullet_match:
            current_evidence.append(bullet_match.group(1))

    flush()
    return findings


def parse_single_line_findings(
    lines: Sequence[str],
    category: str,
    title_prefix: str,
    impact: str,
    risk: str,
) -> List[Finding]:
    findings: List[Finding] = []
    seen_files: set[str] = set()

    for line in lines:
        bullet_match = BULLET_RE.match(line)
        if not bullet_match:
            continue
        evidence_text = bullet_match.group(1)
        file_match = FILE_PATH_RE.search(evidence_text)
        if not file_match:
            continue
        file_path = file_match.group(1)
        if file_path in seen_files:
            continue
        seen_files.add(file_path)
        short_name = Path(file_path).name
        findings.append(
            Finding(
                finding_id="",
                step_id="",
                category=category,
                title=f"{title_prefix} `{short_name}`",
                symbol=None,
                files=[file_path],
                evidence=[evidence_text],
                impact=impact,
                effort=0,
                risk=risk,
                confidence=0,
                priority_score=0,
                phase="P2",
                canonical_hint="Converge to a single path or mark deprecated with migration notes.",
            )
        )

    return findings


def pick_findings(
    duplicate_findings: List[Finding],
    factory_findings: List[Finding],
    legacy_findings: List[Finding],
    max_findings: int,
) -> List[Finding]:
    if max_findings < 1:
        return []

    dup_budget = max(1, max_findings // 2)
    remaining = max_findings - dup_budget
    factory_budget = remaining // 2
    legacy_budget = remaining - factory_budget

    selected: List[Finding] = []
    selected.extend(duplicate_findings[:dup_budget])
    selected.extend(factory_findings[:factory_budget])
    selected.extend(legacy_findings[:legacy_budget])

    overflow_sources = [
        duplicate_findings[dup_budget:],
        factory_findings[factory_budget:],
        legacy_findings[legacy_budget:],
    ]
    for source in overflow_sources:
        for finding in source:
            if len(selected) >= max_findings:
                return selected
            selected.append(finding)

    return selected[:max_findings]


def label_score(level: str) -> int:
    return LEVEL_TO_SCORE.get(level.strip().lower(), 1)


def assign_phase(priority_score: int) -> str:
    if priority_score >= 12:
        return "P0"
    if priority_score >= 4:
        return "P1"
    return "P2"


def estimate_effort(category: str, file_count: int) -> int:
    if category == "same-concept multi-def":
        if file_count <= 1:
            return 1
        if file_count == 2:
            return 3
        if file_count == 3:
            return 4
        return 5
    if category == "parallel-implementation":
        return 2 if file_count <= 1 else 3
    return 1 if file_count <= 1 else 2


def estimate_confidence(category: str, evidence_count: int, file_count: int) -> int:
    if category == "same-concept multi-def":
        if file_count >= 2 and evidence_count >= 2:
            return 5
        return 4
    if category == "parallel-implementation":
        return 3 if evidence_count >= 1 else 2
    return 3 if evidence_count >= 1 else 2


def enrich_and_sort_findings(findings: List[Finding]) -> None:
    for finding in findings:
        impact_score = label_score(finding.impact)
        risk_score = label_score(finding.risk)
        finding.effort = estimate_effort(finding.category, len(finding.files))
        finding.confidence = estimate_confidence(
            finding.category, len(finding.evidence), len(finding.files)
        )
        finding.priority_score = (impact_score * finding.confidence) - (
            finding.effort + risk_score
        )
        finding.phase = assign_phase(finding.priority_score)

    findings.sort(
        key=lambda finding: (
            PHASE_RANK.get(finding.phase, 99),
            -finding.priority_score,
            -label_score(finding.impact),
            finding.title,
        )
    )

    for idx, finding in enumerate(findings, start=1):
        finding.finding_id = f"F{idx}"
        finding.step_id = f"A{idx}"


def suggest_test_command(files: Sequence[str]) -> str:
    if not files:
        return "cargo test --lib"
    path = files[0]
    parts = path.split("/")
    if len(parts) < 3 or parts[0] != "src":
        return "cargo test --lib"
    module_parts = parts[1:-1]
    if not module_parts:
        return "cargo test --lib"
    target = "::".join(module_parts[:2])
    return f"cargo test {target} --lib"


def normalize_cell(value: str) -> str:
    return value.replace("|", "\\|").strip()


def phase_summary(findings: Sequence[Finding], phase: str) -> List[Finding]:
    return [finding for finding in findings if finding.phase == phase]


def render_plan(
    task_name: str,
    repo_path: Path,
    findings: List[Finding],
) -> str:
    now = datetime.now()
    today = now.strftime("%Y-%m-%d")
    lines: List[str] = []

    lines.append(f"# {task_name} execution plan (automatically generated draft)")
    lines.append("")
    lines.append("- planned version: v1-draft")
    lines.append(f"- Creation time: {today}")
    lines.append(f"-Applicable repositories: `{repo_path}`")
    lines.append("- Generation method: `findings_to_plan.py` from redundancy scan")
    lines.append("- Execution mode: Change each step -> Test now -> Write back plan -> Next step")
    lines.append("")
    lines.append("## 0. Execution constraints (DoR)")
    lines.append("")
    lines.append("- Goal: Convergence of duplicate/redundant designs and keeping main flow stable.")
    lines.append("-Compatibility: required (default backwards compatible unless explicitly stated in the step).")
    lines.append("- Submission strategy: per_step (submit after each step of test passes, can be adjusted according to user requirements).")
    lines.append("- Test strategy:")
    lines.append(" - step level: at least 1 directed test + 1 health check per step.")
    lines.append(" - Stage level: Runs more extensive checks after each stage is completed.")
    lines.append(" - Final: Run full or feasible maximum range regression.")
    lines.append("")
    lines.append("## 1. Analysis results (automatic extraction + scoring)")
    lines.append("")
    lines.append("| id | category | files and symbols | impact | effort | risk | confidence | score | phase | evidence | suggested convergence direction |")
    lines.append("|----|------|------------|--------|--------|------|------------|-------|-------|------|--------------|")

    if not findings:
        lines.append("| F1 | manual-review | <to-fill> | 1 | 1 | 1 | 1 | -1 | P2 | no parsed findings | add manual findings before implementation |")
    else:
        for finding in findings:
            file_and_symbol = ", ".join(finding.files[:2]) if finding.files else "<unknown>"
            if finding.symbol:
                file_and_symbol = f"{file_and_symbol}::{finding.symbol}"
            evidence = finding.evidence[0] if finding.evidence else "scan hint"
            lines.append(
                "| {fid} | {cat} | {fs} | {impact} | {effort} | {risk} | {confidence} | {score} | {phase} | {ev} | {hint} |".format(
                    fid=finding.finding_id,
                    cat=normalize_cell(finding.category),
                    fs=normalize_cell(file_and_symbol),
                    impact=label_score(finding.impact),
                    effort=finding.effort,
                    risk=label_score(finding.risk),
                    confidence=finding.confidence,
                    score=finding.priority_score,
                    phase=finding.phase,
                    ev=normalize_cell(evidence),
                    hint=normalize_cell(finding.canonical_hint),
                )
            )

    lines.append("")
    lines.append("## 2. Phased execution sequence (P0 -> P1 -> P2)")
    lines.append("")
    if not findings:
        lines.append("- P0: 0 steps")
        lines.append("- P1: 0 steps")
        lines.append("- P2: 1 step (manual evidence completion)")
    else:
        for phase in PHASE_ORDER:
            phase_items = phase_summary(findings, phase)
            lines.append(f"- {phase}: {len(phase_items)} steps")
            for finding in phase_items:
                lines.append(
                    f"  - Step {finding.step_id} <- {finding.finding_id} "
                    f"(score={finding.priority_score}): {finding.title}"
                )

    lines.append("")
    lines.append("## 3. Detailed steps (sorted by phase)")
    lines.append("")

    if not findings:
        lines.append("### Step A1 Supplement analysis evidence and generate findings")
        lines.append("")
        lines.append("- status: `in_progress`")
        lines.append("- Goal: Complete evidence before entering implementation.")
        lines.append("- Files expected to be changed:")
        lines.append("  - `plan/<this-file>.md`")
        lines.append("- Detailed changes:")
        lines.append(" - Supplement document-level evidence, risk statements, and canonical choices.")
        lines.append("- step-level test command:")
        lines.append("  - `cargo check --lib`")
        lines.append("-Complete judgment:")
        lines.append(" - At least 3 high-confidence findings map to explicit change steps.")
        lines.append("")
    else:
        first_step = True
        for phase in PHASE_ORDER:
            phase_items = phase_summary(findings, phase)
            if not phase_items:
                continue
            lines.append(f"#### Phase {phase}")
            lines.append("")
            for finding in phase_items:
                status = "in_progress" if first_step else "pending"
                first_step = False
                lines.append(f"### Step {finding.step_id} {finding.title}")
                lines.append("")
                lines.append(f"- status: `{status}`")
                lines.append(f"- association finding: `{finding.finding_id}`")
                lines.append(f"-priority phase: `{finding.phase}`")
                lines.append(
                    "- Rating: "
                    f"`impact={label_score(finding.impact)}`, "
                    f"`effort={finding.effort}`, "
                    f"`risk={label_score(finding.risk)}`, "
                    f"`confidence={finding.confidence}`, "
                    f"`score={finding.priority_score}`"
                )
                lines.append("- Goal: Convergence of duplicate/redundant paths corresponding to this finding and maintain consistent behavior.")
                lines.append("- Files expected to be changed:")
                if finding.files:
                    for path in finding.files[:4]:
                        lines.append(f"  - `{path}`")
                else:
                    lines.append("  - `<to-identify>`")
                lines.append("- Detailed changes:")
                lines.append(" - Select the canonical definition/entry and change the remaining paths to reuse or deprecate.")
                lines.append(" - Supplement guard tests for this convergence point to prevent subsequent drift again.")
                lines.append("- step-level test command:")
                lines.append(f"  - `{suggest_test_command(finding.files)}`")
                lines.append("  - `cargo check --lib`")
                lines.append("-Complete judgment:")
                lines.append(" - Only one main path remains, the old path has been migrated or the compatibility layer is clearly marked.")
                lines.append(" - Target tests and health checks passed.")
                lines.append("")

    lines.append("## 4. Regression test matrix")
    lines.append("")
    lines.append("- Phase completion check:")
    lines.append("  - `cargo check --lib`")
    lines.append("- Final check:")
    lines.append("  - `cargo test --lib`")
    lines.append("")
    lines.append("## 5. Execution log (append after each step is completed)")
    lines.append("")
    lines.append("- <YYYY-MM-DD>")
    lines.append("  - Step <ID>: `completed`")
    lines.append(" - Modify file:")
    lines.append("      - `<file>`")
    lines.append(" - Main changes:")
    lines.append("      - <summary>")
    lines.append(" - Execute test:")
    lines.append("      - `<command>` -> pass/fail")
    lines.append("")

    return "\n".join(lines)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate a docs/plan draft from scan findings.")
    parser.add_argument("--scan-report", type=Path, help="Path to markdown scan report.")
    parser.add_argument("--target-dir", help="Target dir for running redundancy scan (e.g. src).")
    parser.add_argument("--output", type=Path, required=True, help="Output plan file path.")
    parser.add_argument("--task-name", default="Redundant design convergence", help="Plan title.")
    parser.add_argument("--repo-path", type=Path, default=Path.cwd(), help="Repository root path.")
    parser.add_argument("--max-findings", type=int, default=12, help="Max findings to include.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    if args.scan_report is None and args.target_dir is None:
        print("[ERR] Provide either --scan-report or --target-dir.")
        return 1

    repo_path = args.repo_path.resolve()
    if args.scan_report is not None and not args.scan_report.exists():
        print(f"[ERR] Scan report not found: {args.scan_report}")
        return 1

    try:
        report_text = read_scan_report(repo_path, args.scan_report, args.target_dir)
    except (ValueError, FileNotFoundError, subprocess.CalledProcessError) as exc:
        print(f"[ERR] Failed to get scan report: {exc}")
        return 1

    duplicate_lines, factory_lines, legacy_lines = parse_sections(report_text)
    duplicate_findings = parse_duplicate_findings(duplicate_lines)
    factory_findings = parse_single_line_findings(
        factory_lines,
        category="parallel-implementation",
        title_prefix="Convergent parallel construction path",
        impact="medium",
        risk="medium",
    )
    legacy_findings = parse_single_line_findings(
        legacy_lines,
        category="legacy-or-dead-code",
        title_prefix="Clean up legacy/dead-code clues",
        impact="low",
        risk="low",
    )

    findings = pick_findings(
        duplicate_findings,
        factory_findings,
        legacy_findings,
        max_findings=args.max_findings,
    )
    enrich_and_sort_findings(findings)

    plan_text = render_plan(args.task_name, repo_path, findings)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(plan_text, encoding="utf-8")
    print(f"[OK] Generated plan draft: {args.output}")
    print(
        "[INFO] findings selected: "
        f"duplicates={len(duplicate_findings)}, factory={len(factory_findings)}, legacy={len(legacy_findings)}, "
        f"used={len(findings)}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
