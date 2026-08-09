#!/usr/bin/env python3
"""Quarantine untouched copies of the retired SpecRail Codex skills."""

from __future__ import annotations

import argparse
import hashlib
import os
import sys
from pathlib import Path


RETIRED_SKILL_HASHES = {
    "implx": "36df08e0784dcb71a2506f3e7197e2de0a2b846b0555b31778ad45d4bf0e4e57",
    "specrail-check-impl-against-spec": "a1e03c454474bd1117aea05e31273d54794111d2e809fee641e39c70f4a7b29e",
    "specrail-diagnose-ci": "a59df025007feafdbe922f1ad1a5d3210e4064f493c8e85a0e76f4c238786565",
    "specrail-implement-queue": "ac6b121238f73a9dc2767a8ffaf8779e0ee54d20ceb4ea054672d72943f4d769",
    "specrail-implement": "cc8bc0da7a0582b2a58d5a6161c623681fb7b514941569ae537cfef87e58d1e8",
    "specrail-install": "96986efdaa7f18527ab3303e8168ebb635b04b57a3ee73be49f30364665edea4",
    "specrail-plan-tasks": "9d8219b4d04e44c40b117847057b436b7de26a5ca90a9e7b8d2d5c9989b29c13",
    "specrail-pr-gate": "cd38a82e566b6981299a6496ead086cabcb228519c92fbc0fe59fdf31b3d540a",
    "specrail-release-note": "e341a940648f058c45be590661728f3adcd66a925343a9922e7f6434606f3e0b",
    "specrail-review-pr": "715a36929fec5bf70bfd032e744390ddbb5c5f187d07f242bcae7297b71834df",
    "specrail-triage-issue": "78b463f634434cb86ff80b3af3d174f8c78f2da0b3d3a0144888751f0a8eb437",
    "specrail-workflow": "cdb2627affb595bb23097ec67632c7ece5902f60a51ee5fd29b0ef48065d2aff",
    "specrail-write-product-spec": "ef9180215502e4c8312f613d6cc38c984b3f0d84c4910d93d6b07a5171a3dc48",
    "specrail-write-tech-spec": "e2de93cb893af5a4a17579481043edad6b1a5a1e49092ef8e3567bdf4ae395ed",
}


def _quarantine_target(root: Path, name: str) -> Path:
    candidate = root / name
    suffix = 1
    while candidate.exists() or candidate.is_symlink():
        candidate = root / f"{name}.{suffix}"
        suffix += 1
    return candidate


def retire_codex_skills(skills_dir: Path, quarantine_dir: Path) -> tuple[int, int]:
    """Move exact legacy copies out of the active Codex skill directory."""
    if not skills_dir.exists():
        return 0, 0
    if not skills_dir.is_dir() or skills_dir.is_symlink():
        raise ValueError(f"Codex skills root is not a real directory: {skills_dir}")

    skills_root = skills_dir.resolve()
    quarantine_root = quarantine_dir.resolve(strict=False)
    if skills_root == quarantine_root or skills_root in quarantine_root.parents:
        raise ValueError("retired skill quarantine must be outside the Codex skills root")

    retired = 0
    preserved = 0
    for name, expected_hash in RETIRED_SKILL_HASHES.items():
        source = skills_dir / name
        if not source.exists() and not source.is_symlink():
            continue
        if source.is_symlink() or not source.is_dir():
            print(f"SKIP modified or user-owned retired Codex skill: {source}")
            preserved += 1
            continue

        entries = list(source.iterdir())
        skill_file = source / "SKILL.md"
        exact_shape = (
            len(entries) == 1
            and entries[0].name == "SKILL.md"
            and skill_file.is_file()
            and not skill_file.is_symlink()
        )
        actual_hash = (
            hashlib.sha256(skill_file.read_bytes()).hexdigest() if exact_shape else ""
        )
        if actual_hash != expected_hash:
            print(f"SKIP modified or user-owned retired Codex skill: {source}")
            preserved += 1
            continue

        quarantine_dir.mkdir(parents=True, exist_ok=True)
        target = _quarantine_target(quarantine_dir, name)
        os.replace(source, target)
        print(f"Retired legacy Codex skill: {source} -> {target}")
        retired += 1

    return retired, preserved


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Quarantine untouched copies of retired SpecRail Codex skills."
    )
    parser.add_argument("--skills-dir", required=True, type=Path)
    parser.add_argument("--quarantine-dir", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        retire_codex_skills(args.skills_dir, args.quarantine_dir)
    except (OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
