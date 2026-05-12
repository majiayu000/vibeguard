#!/usr/bin/env bash
# VibeGuard Guard — SEC-11 dependency version review gate.
#
# Flags dependency version changes in PR diffs and requires OSV/Snyk plus
# human review before trusting AI-generated dependency edits.

set -euo pipefail

BASE=""
HEAD="HEAD"
DIFF_FILE=""
COMMENT_PR=""
WARN_ONLY=0

usage() {
  cat <<'EOF'
Usage:
  bash check_dependency_changes.sh [--base BASE] [--head HEAD]
  bash check_dependency_changes.sh --diff diff.patch

Options:
  --base BASE       Base ref for git diff, usually origin/main
  --head HEAD       Head ref for git diff (default: HEAD)
  --diff FILE       Read a unified diff from FILE instead of running git diff
  --comment-pr N    Post the finding summary to PR N with gh pr comment
  --warn-only       Always exit 0 after printing the report

Exit codes:
  0  No dependency version review triggers found
  1  SEC-11 dependency review is required
  2  Usage or git/diff input error
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)
      BASE="${2:-}"; shift 2 ;;
    --head)
      HEAD="${2:-}"; shift 2 ;;
    --diff)
      DIFF_FILE="${2:-}"; shift 2 ;;
    --comment-pr)
      COMMENT_PR="${2:-}"; shift 2 ;;
    --warn-only)
      WARN_ONLY=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "[SEC-11] unknown argument: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

if [[ -n "${DIFF_FILE}" ]]; then
  if [[ ! -f "${DIFF_FILE}" ]]; then
    echo "[SEC-11] diff file not found: ${DIFF_FILE}" >&2
    exit 2
  fi
  DIFF_TEXT="$(cat "${DIFF_FILE}")"
else
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "[SEC-11] not in a git repository; pass --diff FILE" >&2
    exit 2
  fi
  if [[ -n "${BASE}" ]]; then
    DIFF_TEXT="$(git diff --unified=3 --no-ext-diff "${BASE}...${HEAD}" -- \
      '**/requirements.txt' '**/package.json' '**/Cargo.toml' '**/go.mod')"
  else
    DIFF_TEXT="$(git diff --unified=3 --no-ext-diff -- \
      '**/requirements.txt' '**/package.json' '**/Cargo.toml' '**/go.mod')"
  fi
fi

DIFF_TMP="$(mktemp)"
printf '%s\n' "${DIFF_TEXT}" > "${DIFF_TMP}"

set +e
REPORT="$(
python3 - "${DIFF_TMP}" <<'PY'
from __future__ import annotations

from pathlib import Path
import re
import sys
from collections import defaultdict

diff = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").splitlines()

TARGET_NAMES = {"requirements.txt", "package.json", "Cargo.toml", "go.mod"}
PACKAGE_JSON_EXCLUDE = {
    "version",
    "name",
    "description",
    "main",
    "type",
    "license",
    "packageManager",
    "engines",
}
CARGO_EXCLUDE = {"version", "edition", "rust-version", "name", "authors", "license"}


def clean_path(raw: str) -> str:
    if raw.startswith("a/") or raw.startswith("b/"):
        raw = raw[2:]
    return raw


def is_target(path: str) -> bool:
    return path.rsplit("/", 1)[-1] in TARGET_NAMES


def dep_from_line(path: str, line: str) -> tuple[str, str] | None:
    stripped = line.strip()
    if not stripped or stripped.startswith(("#", "//")):
        return None
    name = path.rsplit("/", 1)[-1]

    if name == "requirements.txt":
        match = re.match(r"([A-Za-z0-9_.-]+)(?:\[[^\]]+\])?\s*(===|==|~=|>=|<=|>|<)\s*([^\s;#]+)", stripped)
        if match:
            return match.group(1), match.group(3)
        return None

    if name == "package.json":
        match = re.match(r'"([^"]+)"\s*:\s*"([^"]+)"', stripped.rstrip(","))
        if match and match.group(1) not in PACKAGE_JSON_EXCLUDE:
            version = match.group(2)
            if re.search(r"\d", version) or version.startswith(("^", "~", "workspace:", "npm:")):
                return match.group(1), version
        return None

    if name == "Cargo.toml":
        inline = re.match(r"([A-Za-z0-9_.-]+)\s*=\s*\{[^}]*\bversion\s*=\s*\"([^\"]+)\"", stripped)
        if inline and inline.group(1) not in CARGO_EXCLUDE:
            return inline.group(1), inline.group(2)
        simple = re.match(r"([A-Za-z0-9_.-]+)\s*=\s*\"([^\"]+)\"", stripped)
        if simple and simple.group(1) not in CARGO_EXCLUDE:
            return simple.group(1), simple.group(2)
        return None

    if name == "go.mod":
        if stripped.startswith(("module ", "go ", "toolchain ")):
            return None
        match = re.match(r"([A-Za-z0-9_.\-/]+)\s+(v[0-9][^\s]+)", stripped)
        if match:
            return match.group(1), match.group(2)
        return None

    return None


changes: dict[tuple[str, str], dict[str, set[str]]] = defaultdict(lambda: {"-": set(), "+": set()})
current_file = ""

for line in diff:
    if line.startswith("diff --git "):
        parts = line.split()
        current_file = clean_path(parts[-1]) if len(parts) >= 4 else ""
        continue
    if line.startswith("+++ "):
        target = line[4:].strip()
        if target != "/dev/null":
            current_file = clean_path(target)
        continue
    if not current_file or not is_target(current_file):
        continue
    if line.startswith(("+++", "---", "@@")):
        continue
    if not line.startswith(("+", "-")):
        continue
    sign = line[0]
    parsed = dep_from_line(current_file, line[1:])
    if parsed is None:
        continue
    dep, version = parsed
    changes[(current_file, dep)][sign].add(version)

findings: list[str] = []
for (path, dep), sides in sorted(changes.items()):
    old_versions = sorted(sides["-"])
    new_versions = sorted(sides["+"])
    if not old_versions and not new_versions:
        continue
    if old_versions == new_versions:
        continue
    old = ", ".join(old_versions) if old_versions else "<new dependency>"
    new = ", ".join(new_versions) if new_versions else "<removed dependency>"
    findings.append(f"{path}: {dep} {old} -> {new}")

if not findings:
    print("[SEC-11] OK: no dependency version review triggers found")
    raise SystemExit(0)

print("[SEC-11] dependency version change review required")
print("")
print("Mandatory actions:")
print("- Run OSV/Snyk or equivalent vulnerability checks for the changed dependency set.")
print("- Require human review before merging AI-authored dependency updates.")
print("- Mention the security-tool result in the PR review or PR body.")
print("")
print("Findings:")
for finding in findings:
    print(f"- {finding}")
print("")
print("Suggested commands:")
print("- osv-scanner --lockfile <lockfile>  # when a supported lockfile exists")
print("- npm audit / pip audit / govulncheck ./... / cargo audit, matching the ecosystem")
raise SystemExit(1)
PY
)"
RC=$?
set -e
rm -f "${DIFF_TMP}"

printf '%s\n' "${REPORT}"

if [[ "${RC}" -eq 1 && -n "${COMMENT_PR}" && -n "${REPORT}" ]]; then
  if command -v gh >/dev/null 2>&1; then
    printf '%s\n' "${REPORT}" | gh pr comment "${COMMENT_PR}" --body-file - >/dev/null || {
      echo "[SEC-11] warning: failed to post PR comment" >&2
    }
  else
    echo "[SEC-11] warning: gh not found; cannot post PR comment" >&2
  fi
fi

if [[ "${WARN_ONLY}" -eq 1 ]]; then
  exit 0
fi
exit "${RC}"
