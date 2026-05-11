#!/usr/bin/env bash
# VibeGuard Guard — SEC-11 / W-12 test-evolution review gate.
#
# Flags PR diffs where source and tests changed together while tests appear to
# lose assertion strength, gain skip markers, or add AI-authored test files.

set -euo pipefail

BASE=""
HEAD="HEAD"
DIFF_FILE=""
COMMIT_MESSAGE=""
COMMIT_MESSAGE_FILE=""
WARN_ONLY=0

usage() {
  cat <<'EOF'
Usage:
  bash check_test_weakening.sh [--base BASE] [--head HEAD]
  bash check_test_weakening.sh --diff diff.patch [--commit-message-file msg.txt]

Options:
  --base BASE              Base ref for git diff/log, usually origin/main
  --head HEAD              Head ref for git diff/log (default: HEAD)
  --diff FILE              Read a unified diff from FILE instead of running git diff
  --commit-message TEXT    Commit/PR message text used for AI co-author detection
  --commit-message-file F  Read commit/PR message text from F
  --warn-only              Always exit 0 after printing the report

Exit codes:
  0  No SEC-11 test-evolution review triggers found
  1  Human review is required for test evolution
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
    --commit-message)
      COMMIT_MESSAGE="${2:-}"; shift 2 ;;
    --commit-message-file)
      COMMIT_MESSAGE_FILE="${2:-}"; shift 2 ;;
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

if [[ -n "${COMMIT_MESSAGE_FILE}" ]]; then
  if [[ ! -f "${COMMIT_MESSAGE_FILE}" ]]; then
    echo "[SEC-11] commit message file not found: ${COMMIT_MESSAGE_FILE}" >&2
    exit 2
  fi
  COMMIT_MESSAGE="$(cat "${COMMIT_MESSAGE_FILE}")"
fi

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
    DIFF_TEXT="$(git diff --unified=3 --no-ext-diff "${BASE}...${HEAD}")"
    if [[ -z "${COMMIT_MESSAGE}" ]]; then
      COMMIT_MESSAGE="$(git log --format=%B "${BASE}..${HEAD}" 2>/dev/null || true)"
    fi
  else
    DIFF_TEXT="$(git diff --unified=3 --no-ext-diff)"
    if [[ -z "${COMMIT_MESSAGE}" ]]; then
      COMMIT_MESSAGE="$(git log -1 --format=%B 2>/dev/null || true)"
    fi
  fi
fi

DIFF_TMP="$(mktemp)"
printf '%s\n' "${DIFF_TEXT}" > "${DIFF_TMP}"

set +e
REPORT="$(
VIBEGUARD_SEC11_COMMIT_MESSAGE="${COMMIT_MESSAGE}" python3 - "${DIFF_TMP}" <<'PY'
from __future__ import annotations

import os
from pathlib import Path
import re
import sys
from dataclasses import dataclass, field

diff = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").splitlines()
commit_message = os.environ.get("VIBEGUARD_SEC11_COMMIT_MESSAGE", "")

SOURCE_EXTENSIONS = {
    ".py", ".js", ".jsx", ".ts", ".tsx", ".go", ".rs", ".java", ".kt",
    ".rb", ".php", ".cs", ".swift", ".mjs", ".cjs",
}
TEST_DIR_PARTS = {"test", "tests", "__tests__", "spec", "specs"}
ASSERTION_RE = re.compile(
    r"\b(assert(?:Equal|Equals|True|False|That|DeepEqual)?|expect|should|require\.Equal|assert_eq!|assert_ne!)\b"
)
SKIP_RE = re.compile(
    r"(@pytest\.mark\.skip|pytest\.skip|unittest\.skip|\.skip\s*\(|\btest\.skip\b|\bit\.skip\b|describe\.skip|#\s*\[ignore\]|//.*\bskip\b|#.*\bskip\b)",
    re.IGNORECASE,
)
AI_MARKER_RE = re.compile(
    r"(Co-authored-by:.*(Claude|Codex|ChatGPT|OpenAI|Anthropic|Copilot|AI|bot)|"
    r"Generated-by:.*(Claude|Codex|ChatGPT|OpenAI|Anthropic|Copilot|AI|bot)|"
    r"AI-assisted|AI generated)",
    re.IGNORECASE,
)


@dataclass
class FileChange:
    removed: list[tuple[int, str]] = field(default_factory=list)
    added: list[tuple[int, str]] = field(default_factory=list)
    is_new: bool = False


def clean_path(raw: str) -> str:
    if raw.startswith("a/") or raw.startswith("b/"):
        raw = raw[2:]
    return raw


def extension(path: str) -> str:
    name = path.rsplit("/", 1)[-1]
    if "." not in name:
        return ""
    return "." + name.split(".")[-1]


def is_test_file(path: str) -> bool:
    parts = set(path.split("/")[:-1])
    base = path.rsplit("/", 1)[-1]
    if parts & TEST_DIR_PARTS:
        return extension(path) in SOURCE_EXTENSIONS
    return (
        base.startswith("test_")
        or base.endswith("_test.py")
        or ".test." in base
        or ".spec." in base
        or base.endswith("_test.go")
        or base.endswith("_test.rs")
    )


def is_source_file(path: str) -> bool:
    return extension(path) in SOURCE_EXTENSIONS and not is_test_file(path)


changes: dict[str, FileChange] = {}
current_file = ""
old_line = 0
new_line = 0

for line in diff:
    if line.startswith("diff --git "):
        parts = line.split()
        current_file = clean_path(parts[-1]) if len(parts) >= 4 else ""
        changes.setdefault(current_file, FileChange())
        continue
    if not current_file:
        continue
    change = changes.setdefault(current_file, FileChange())
    if line.startswith("new file mode"):
        change.is_new = True
        continue
    if line.startswith("+++ "):
        target = line[4:].strip()
        if target != "/dev/null":
            current_file = clean_path(target)
            change = changes.setdefault(current_file, FileChange())
        continue
    if line.startswith("--- /dev/null"):
        change.is_new = True
        continue
    hunk = re.match(r"@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@", line)
    if hunk:
        old_line = int(hunk.group(1))
        new_line = int(hunk.group(2))
        continue
    if line.startswith(("+++", "---")):
        continue
    if line.startswith("-"):
        change.removed.append((old_line, line[1:]))
        old_line += 1
    elif line.startswith("+"):
        change.added.append((new_line, line[1:]))
        new_line += 1
    elif line.startswith(" "):
        old_line += 1
        new_line += 1

changed_source = sorted(path for path, change in changes.items() if is_source_file(path) and (change.added or change.removed))
changed_tests = sorted(path for path, change in changes.items() if is_test_file(path) and (change.added or change.removed))

findings: list[str] = []
if changed_source and changed_tests:
    for path in changed_tests:
        change = changes[path]
        removed_assertions = [(line, text) for line, text in change.removed if ASSERTION_RE.search(text)]
        added_assert_true = [(line, text) for line, text in change.added if "assertTrue" in text]
        removed_assert_equal = [(line, text) for line, text in change.removed if "assertEqual" in text or "assertEquals" in text]
        added_skips = [(line, text) for line, text in change.added if SKIP_RE.search(text)]

        if removed_assert_equal and added_assert_true:
            old_line, _ = removed_assert_equal[0]
            new_line_no, _ = added_assert_true[0]
            findings.append(f"{path}:{old_line}->{new_line_no}: assertion weakened assertEqual/assertEquals -> assertTrue")
        if removed_assertions:
            for line_no, text in removed_assertions[:3]:
                findings.append(f"{path}:{line_no}: assertion removed: {text.strip()[:120]}")
        if added_skips:
            for line_no, text in added_skips[:3]:
                findings.append(f"{path}:{line_no}: skip marker added: {text.strip()[:120]}")

new_test_files = sorted(path for path, change in changes.items() if is_test_file(path) and change.is_new)
if new_test_files and AI_MARKER_RE.search(commit_message):
    for path in new_test_files:
        findings.append(f"{path}: new test file in AI co-authored change; human must restate the test intent")

if not findings:
    print("[SEC-11] OK: no test-evolution review triggers found")
    raise SystemExit(0)

print("[SEC-11] test evolution review required")
print("")
print("Mandatory actions:")
print("- Require human review before merging the source+test change.")
print("- Check whether test changes weaken assertions, add skips, or bypass W-12 test-integrity rules.")
print("- For AI-authored new tests, ask the human reviewer to restate the test intent in plain language.")
print("")
print("Changed source files:")
for path in changed_source[:12]:
    print(f"- {path}")
if len(changed_source) > 12:
    print(f"- ... and {len(changed_source) - 12} more")
print("")
print("Changed test files:")
for path in changed_tests[:12]:
    print(f"- {path}")
if len(changed_tests) > 12:
    print(f"- ... and {len(changed_tests) - 12} more")
print("")
print("Findings:")
for finding in findings:
    print(f"- {finding}")
raise SystemExit(1)
PY
)"
RC=$?
set -e
rm -f "${DIFF_TMP}"

printf '%s\n' "${REPORT}"

if [[ "${WARN_ONLY}" -eq 1 ]]; then
  exit 0
fi
exit "${RC}"
