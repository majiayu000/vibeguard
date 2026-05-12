#!/usr/bin/env bash
# VibeGuard Guard - W-20 runtime drift detector.
#
# Creates and checks execution pinning snapshots for long-running tasks.

set -euo pipefail

MODE=""
SNAPSHOT_FILE=""
ROOT_DIR="$(pwd)"
RUNTIME_VERSION=""
MODEL_ID=""
SDK_VERSION=""
TOOLS_FILE=""
DECISION_LOG=""
REASON=""
ACCEPT_DRIFT=0

usage() {
  cat <<'EOF'
Usage:
  bash check_runtime_drift.sh --snapshot FILE [options]
  bash check_runtime_drift.sh --check FILE [options]

Options:
  --root DIR              Project root to scan (default: current directory)
  --runtime-version TEXT  Agent CLI/runtime version to pin
  --model TEXT            Model ID to pin
  --sdk-version TEXT      Key SDK/runtime version to pin
  --tools-file FILE       Optional pre-rendered tool/MCP/skill list to hash
  --accept-drift          Record drift as accepted and exit 0
  --decision-log FILE     SECURITY.md-style decision log for --accept-drift
  --reason TEXT           Reason recorded with accepted drift

Exit codes:
  0  Snapshot written, no drift, or drift accepted and logged
  1  Runtime drift detected
  2  Usage or snapshot input error
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --snapshot)
      MODE="snapshot"; SNAPSHOT_FILE="${2:-}"; shift 2 ;;
    --check)
      MODE="check"; SNAPSHOT_FILE="${2:-}"; shift 2 ;;
    --root)
      ROOT_DIR="${2:-}"; shift 2 ;;
    --runtime-version)
      RUNTIME_VERSION="${2:-}"; shift 2 ;;
    --model)
      MODEL_ID="${2:-}"; shift 2 ;;
    --sdk-version)
      SDK_VERSION="${2:-}"; shift 2 ;;
    --tools-file)
      TOOLS_FILE="${2:-}"; shift 2 ;;
    --accept-drift)
      ACCEPT_DRIFT=1; shift ;;
    --decision-log)
      DECISION_LOG="${2:-}"; shift 2 ;;
    --reason)
      REASON="${2:-}"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "[W-20] unknown argument: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

if [[ -z "${MODE}" || -z "${SNAPSHOT_FILE}" ]]; then
  echo "[W-20] --snapshot FILE or --check FILE is required" >&2
  usage >&2
  exit 2
fi

if [[ ! -d "${ROOT_DIR}" ]]; then
  echo "[W-20] root directory not found: ${ROOT_DIR}" >&2
  exit 2
fi

if [[ -n "${TOOLS_FILE}" && ! -f "${TOOLS_FILE}" ]]; then
  echo "[W-20] tools file not found: ${TOOLS_FILE}" >&2
  exit 2
fi

if [[ "${ACCEPT_DRIFT}" -eq 1 && -z "${DECISION_LOG}" ]]; then
  echo "[W-20] --accept-drift requires --decision-log FILE" >&2
  exit 2
fi

export VG_W20_MODE="${MODE}"
export VG_W20_SNAPSHOT_FILE="${SNAPSHOT_FILE}"
export VG_W20_ROOT_DIR="${ROOT_DIR}"
export VG_W20_RUNTIME_VERSION="${RUNTIME_VERSION}"
export VG_W20_MODEL_ID="${MODEL_ID}"
export VG_W20_SDK_VERSION="${SDK_VERSION}"
export VG_W20_TOOLS_FILE="${TOOLS_FILE}"
export VG_W20_ACCEPT_DRIFT="${ACCEPT_DRIFT}"
export VG_W20_DECISION_LOG="${DECISION_LOG}"
export VG_W20_REASON="${REASON}"

python3 - <<'PY'
from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from typing import Any


MODE = os.environ["VG_W20_MODE"]
ROOT = Path(os.environ["VG_W20_ROOT_DIR"]).resolve()
SNAPSHOT_FILE = Path(os.environ["VG_W20_SNAPSHOT_FILE"])
TOOLS_FILE = os.environ.get("VG_W20_TOOLS_FILE", "")
ACCEPT_DRIFT = os.environ.get("VG_W20_ACCEPT_DRIFT") == "1"
DECISION_LOG = os.environ.get("VG_W20_DECISION_LOG", "")
REASON = os.environ.get("VG_W20_REASON", "").strip() or "not provided"


def fail_usage(message: str) -> int:
    print(f"[W-20] {message}", file=sys.stderr)
    return 2


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def aggregate(entries: list[dict[str, str]]) -> str:
    digest = hashlib.sha256()
    for entry in sorted(entries, key=lambda item: item["path"]):
        digest.update(entry["path"].encode("utf-8", errors="surrogateescape"))
        digest.update(b"\0")
        digest.update(entry["sha256"].encode("ascii"))
        digest.update(b"\0")
    return digest.hexdigest()


def rel(path: Path) -> str:
    try:
        return path.resolve().relative_to(ROOT).as_posix()
    except ValueError:
        return str(path.resolve())


def run_version(command: list[str]) -> str | None:
    if shutil.which(command[0]) is None:
        return None
    try:
        completed = subprocess.run(command, check=False, text=True, capture_output=True, timeout=2)
    except Exception:
        return None
    output = (completed.stdout or completed.stderr).strip().splitlines()
    if completed.returncode == 0 and output:
        return output[0][:200]
    return None


def first_nonempty(*values: str | None) -> str:
    for value in values:
        if value:
            stripped = value.strip()
            if stripped:
                return stripped
    return "unknown"


def runtime_surface() -> dict[str, str]:
    runtime_version = first_nonempty(
        os.environ.get("VG_W20_RUNTIME_VERSION"),
        os.environ.get("CODEX_VERSION"),
        os.environ.get("CLAUDE_CODE_VERSION"),
        run_version(["codex", "--version"]),
        run_version(["claude", "--version"]),
    )
    model_id = first_nonempty(
        os.environ.get("VG_W20_MODEL_ID"),
        os.environ.get("OPENAI_MODEL"),
        os.environ.get("CODEX_MODEL"),
        os.environ.get("ANTHROPIC_MODEL"),
        os.environ.get("CLAUDE_MODEL"),
    )
    sdk_version = first_nonempty(
        os.environ.get("VG_W20_SDK_VERSION"),
        os.environ.get("OPENAI_SDK_VERSION"),
        os.environ.get("ANTHROPIC_SDK_VERSION"),
        run_version(["node", "--version"]),
        run_version(["python3", "--version"]),
    )
    return {
        "runtime_version": runtime_version,
        "model_id": model_id,
        "sdk_version": sdk_version,
    }


def existing_files(paths: list[Path]) -> list[Path]:
    seen: set[Path] = set()
    out: list[Path] = []
    for path in paths:
        resolved = path.resolve()
        if resolved in seen or not resolved.is_file():
            continue
        seen.add(resolved)
        out.append(resolved)
    return out


def tool_source_files() -> list[Path]:
    if TOOLS_FILE:
        return existing_files([Path(TOOLS_FILE)])

    candidates: list[Path] = [
        ROOT / ".mcp.json",
        ROOT / ".codex" / "config.toml",
        ROOT / ".claude" / "settings.json",
        ROOT / ".claude" / "settings.local.json",
    ]
    candidates.extend(ROOT.glob(".claude/settings*.json"))
    candidates.extend(ROOT.glob(".claude/commands/**/*.md"))
    candidates.extend(ROOT.glob("skills/**/SKILL.md"))
    candidates.extend(ROOT.glob("workflows/**/SKILL.md"))
    return existing_files(candidates)


def rule_source_files() -> list[Path]:
    rule_root = ROOT / "rules" / "claude-rules"
    if not rule_root.exists():
        return []
    return existing_files(list(rule_root.rglob("*.md")))


def surface(name: str, paths: list[Path]) -> dict[str, Any]:
    entries = [{"path": rel(path), "sha256": sha256_file(path)} for path in sorted(paths)]
    return {
        "name": name,
        "count": len(entries),
        "aggregate_hash": aggregate(entries),
        "files": entries,
    }


def snapshot() -> dict[str, Any]:
    return {
        "schema_version": 1,
        "rule": "W-20",
        "created_at_utc": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "root": str(ROOT),
        "runtime": runtime_surface(),
        "tools": surface("tool_surface", tool_source_files()),
        "rules": surface("rule_surface", rule_source_files()),
    }


def files_by_path(surface_data: dict[str, Any]) -> dict[str, str]:
    return {
        str(entry.get("path", "")): str(entry.get("sha256", ""))
        for entry in surface_data.get("files", [])
    }


def file_delta(label: str, before: dict[str, Any], after: dict[str, Any]) -> list[str]:
    old_files = files_by_path(before)
    new_files = files_by_path(after)
    details: list[str] = []
    for path in sorted(set(old_files) - set(new_files)):
        details.append(f"{label} removed: {path}")
    for path in sorted(set(new_files) - set(old_files)):
        details.append(f"{label} added: {path}")
    for path in sorted(set(old_files) & set(new_files)):
        if old_files[path] != new_files[path]:
            details.append(f"{label} changed: {path}")
    return details


def drift_findings(before: dict[str, Any], after: dict[str, Any]) -> list[str]:
    findings: list[str] = []
    for key, label in (
        ("runtime_version", "runtime version"),
        ("model_id", "model ID"),
        ("sdk_version", "key SDK/runtime version"),
    ):
        old = str(before.get("runtime", {}).get(key, "unknown"))
        new = str(after.get("runtime", {}).get(key, "unknown"))
        if old != new:
            findings.append(f"{label}: {old} -> {new}")

    for section, label in (("tools", "tool surface hash"), ("rules", "rule surface hash")):
        old_surface = before.get(section, {})
        new_surface = after.get(section, {})
        old_hash = str(old_surface.get("aggregate_hash", ""))
        new_hash = str(new_surface.get("aggregate_hash", ""))
        if old_hash != new_hash:
            findings.append(f"{label}: {old_hash[:12]} -> {new_hash[:12]}")
            findings.extend(file_delta(section, old_surface, new_surface))
    return findings


def append_decision_log(path_text: str, findings: list[str]) -> None:
    path = Path(path_text)
    if not path.is_absolute():
        path = ROOT / path
    path.parent.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    lines = [
        "",
        f"## W-20 runtime drift accepted - {timestamp}",
        "",
        f"- Snapshot: `{SNAPSHOT_FILE}`",
        f"- Root: `{ROOT}`",
        f"- Reason: {REASON}",
        "- Drift:",
    ]
    lines.extend(f"  - {finding}" for finding in findings)
    lines.append("")
    with path.open("a", encoding="utf-8") as handle:
        handle.write("\n".join(lines))


def main() -> int:
    current = snapshot()

    if MODE == "snapshot":
        SNAPSHOT_FILE.parent.mkdir(parents=True, exist_ok=True)
        SNAPSHOT_FILE.write_text(json.dumps(current, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(f"[W-20] snapshot written: {SNAPSHOT_FILE}")
        print(f"[W-20] tool files: {current['tools']['count']}  rule files: {current['rules']['count']}")
        return 0

    if MODE != "check":
        return fail_usage(f"unknown mode: {MODE}")

    if not SNAPSHOT_FILE.is_file():
        return fail_usage(f"snapshot file not found: {SNAPSHOT_FILE}")

    try:
        before = json.loads(SNAPSHOT_FILE.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        return fail_usage(f"invalid snapshot JSON: {exc}")

    if before.get("schema_version") != 1 or before.get("rule") != "W-20":
        return fail_usage("snapshot is not a W-20 schema_version=1 snapshot")

    findings = drift_findings(before, current)
    if not findings:
        print("[W-20] OK: runtime, tool, and rule surfaces match snapshot")
        return 0

    print("[W-20] runtime drift detected")
    for finding in findings:
        print(f"- {finding}")

    if ACCEPT_DRIFT:
        append_decision_log(DECISION_LOG, findings)
        print(f"[W-20] drift accepted and recorded in {DECISION_LOG}")
        return 0

    print("")
    print("Stop execution until the environment is restored or the user accepts the drift.")
    print("To accept drift, rerun with --accept-drift --decision-log SECURITY.md --reason TEXT.")
    return 1


raise SystemExit(main())
PY
