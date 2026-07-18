#!/usr/bin/env python3
"""Generate the checked vibeguard-runtime release manifest."""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path


EXPECTED_TARGETS = (
    "aarch64-apple-darwin",
    "x86_64-apple-darwin",
    "x86_64-unknown-linux-musl",
    "aarch64-unknown-linux-musl",
)
ALLOWED_EXTRA_RUNTIME_ASSETS = {
    "vibeguard-runtime-dependency-metadata.json",
}
CHECKSUM_LINE = re.compile(r"^([0-9a-fA-F]{64})[ \t]+\*?([^ \t\r\n]+)$")


def die(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def parse_sha256sums(path: Path) -> dict[str, str]:
    checksums: dict[str, str] = {}
    for line_number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw_line.strip()
        if not line:
            continue
        match = CHECKSUM_LINE.match(line)
        if not match:
            die(f"{path} line {line_number} is not a valid SHA256SUMS entry")
        checksum, filename = match.groups()
        filename = Path(filename).name
        if filename in checksums:
            die(f"{path} has duplicate checksum entry for {filename}")
        checksums[filename] = checksum.lower()
    return checksums


def main(argv: list[str]) -> int:
    if len(argv) not in {4, 5}:
        print(
            "Usage: generate_runtime_release_manifest.py <version> <artifacts-dir> <output-json> [release-repo]",
            file=sys.stderr,
        )
        return 2

    version = argv[1].strip()
    artifacts_dir = Path(argv[2])
    output_path = Path(argv[3])
    release_repo = argv[4].strip() if len(argv) == 5 else os.environ.get("GITHUB_REPOSITORY", "majiayu000/vibeguard")

    if not version or version.startswith("v"):
        die("version must be a bare runtime version such as 1.2.3")
    if "/" not in release_repo or release_repo.startswith("/") or release_repo.endswith("/"):
        die("release repo must be owner/repo")
    if not artifacts_dir.is_dir():
        die(f"artifacts directory not found: {artifacts_dir}")

    checksum_path = artifacts_dir / "SHA256SUMS"
    if not checksum_path.is_file():
        die(f"checksum manifest not found: {checksum_path}")

    checksums = parse_sha256sums(checksum_path)
    assets: dict[str, dict[str, int | str]] = {}
    expected_filenames = {f"vibeguard-runtime-{target}" for target in EXPECTED_TARGETS}

    for filename in checksums:
        if (
            filename.startswith("vibeguard-runtime-")
            and filename not in expected_filenames
            and filename not in ALLOWED_EXTRA_RUNTIME_ASSETS
        ):
            die(f"unexpected runtime release asset in SHA256SUMS: {filename}")

    for target in EXPECTED_TARGETS:
        filename = f"vibeguard-runtime-{target}"
        asset_path = artifacts_dir / filename
        if filename not in checksums:
            die(f"SHA256SUMS missing entry for {filename}")
        if not asset_path.is_file():
            die(f"runtime artifact not found: {asset_path}")
        assets[target] = {
            "name": filename,
            "sha256": checksums[filename],
            "size": asset_path.stat().st_size,
        }

    manifest = {
        "assets": assets,
        "package": "vibeguard-runtime",
        "release_repo": release_repo,
        "schema_version": 1,
        "tag": f"v{version}",
        "version": version,
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
