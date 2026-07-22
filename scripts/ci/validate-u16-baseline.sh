#!/usr/bin/env bash
# Validate baseline-aware U-16 file-size policy for changed source files.
set -euo pipefail

SCRIPT_REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
REPO_DIR="${VIBEGUARD_U16_REPO_DIR:-$SCRIPT_REPO_DIR}"
cd "$REPO_DIR"

base_ref="${1:-}"
if [[ -z "$base_ref" && -n "${GITHUB_BASE_REF:-}" ]]; then
  base_ref="origin/${GITHUB_BASE_REF}"
fi
if [[ -z "$base_ref" && -n "${GITHUB_EVENT_PATH:-}" && -f "${GITHUB_EVENT_PATH}" ]]; then
  base_ref="$(python3 - "$GITHUB_EVENT_PATH" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    event = json.load(handle)
print(event.get("before") or "")
PY
)"
fi
base_ref="${base_ref:-origin/main}"
head_ref="${2:-HEAD}"

runtime="${VIBEGUARD_RUNTIME:-}"
if [[ -z "$runtime" || ! -x "$runtime" ]]; then
  for candidate in \
    "$SCRIPT_REPO_DIR/vibeguard-runtime/target/release/vibeguard-runtime" \
    "$SCRIPT_REPO_DIR/vibeguard-runtime/target/debug/vibeguard-runtime" \
    "${HOME:-}/.vibeguard/installed/bin/vibeguard-runtime"; do
    if [[ -x "$candidate" ]]; then
      runtime="$candidate"
      break
    fi
  done
fi
if [[ -z "$runtime" || ! -x "$runtime" ]]; then
  echo "vibeguard-runtime not found; run cargo build --manifest-path vibeguard-runtime/Cargo.toml" >&2
  exit 2
fi

"$runtime" u16-baseline-check --base "$base_ref" --head "$head_ref"
