#!/usr/bin/env bash
# VibeGuard CI: keep Rust event-log readers on the canonical event schema.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

python3 - <<'PY' "${REPO_DIR}"
import sys
from pathlib import Path

repo = Path(sys.argv[1])
targets = [repo / "vibeguard-runtime/src/log_query.rs"]
session_metrics_dir = repo / "vibeguard-runtime/src/session_metrics"
if session_metrics_dir.exists():
    targets.extend(
        path
        for path in sorted(session_metrics_dir.rglob("*.rs"))
        if "tests" not in path.relative_to(session_metrics_dir).parts
    )
else:
    targets.append(repo / "vibeguard-runtime/src/session_metrics.rs")
forbidden = [
    '"ts"',
    '"session"',
    '"hook"',
    '"tool"',
    '"decision"',
    '"reason"',
    '"detail"',
    '"duration_ms"',
    '"warn_ratio"',
    '"pass"',
    '"warn"',
    '"block"',
    '"escalate"',
    '"correction"',
    '"unknown"',
    '"Read"',
    '"Glob"',
    '"Grep"',
    '"Write"',
    '"Edit"',
    '"Bash"',
    '"post-edit-guard"',
    '"post-build-check"',
    '"analysis-paralysis-guard"',
    '"stop-guard"',
    '"learn-evaluator"',
]

errors = []
for path in targets:
    if not path.exists():
        errors.append(f"{path.relative_to(repo)}: missing event reader")
        continue
    in_test_module = False
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if line.strip() == "#[cfg(test)]":
            in_test_module = True
        if in_test_module:
            continue
        for token in forbidden:
            if token in line:
                rel = path.relative_to(repo)
                errors.append(f"{rel}:{lineno}: raw event literal {token}; use event_schema constants")

if errors:
    print("FAIL: Rust event readers contain raw event-schema literals")
    for error in errors:
        print(error)
    raise SystemExit(1)

print("OK: Rust event readers use event_schema constants")
PY
