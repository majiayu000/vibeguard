#!/usr/bin/env bash
# U-22 self-application: report coverage-tool availability and optional strict gate.
set -euo pipefail

REPO_DIR="${1:-$(cd "$(dirname "$0")/../../.." && pwd)}"
STRICT="${VIBEGUARD_U22_STRICT:-0}"

python3 - <<'PY' "${REPO_DIR}" "${STRICT}"
import sys
from pathlib import Path

repo = Path(sys.argv[1])
strict = sys.argv[2] == "1"
src_dir = repo / "vg-helper/src"
reports: list[str] = []
errors: list[str] = []

if src_dir.exists():
    for path in sorted(src_dir.rglob("*.rs")):
        if path.name == "main.rs":
            continue
        text = path.read_text(encoding="utf-8")
        loc = sum(1 for line in text.splitlines() if line.strip())
        has_module_tests = "#[cfg(test)]" in text
        reports.append(f"{path.relative_to(repo)}: {loc} nonblank lines, module_tests={has_module_tests}")
        if strict and loc >= 100 and not has_module_tests:
            errors.append(f"{path.relative_to(repo)}: >=100 lines but no module tests")

print("U-22 coverage inventory:")
for report in reports:
    print(f"  {report}")

if errors:
    print("FAIL: U-22 strict coverage inventory failed")
    for error in errors:
        print(error)
    raise SystemExit(1)

if strict:
    print("OK: U-22 strict coverage inventory passed")
else:
    print("OK: U-22 inventory recorded (report-only until llvm-cov baseline is adopted)")
PY
