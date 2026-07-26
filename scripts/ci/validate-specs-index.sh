#!/usr/bin/env bash
# VibeGuard CI: Keep docs/specs/README.md in sync with the GH<n>/ spec directories.
#
# Fails when:
#   - a docs/specs/GH<n>/ directory exists but has no row in the README index
#   - a README index row names a GH<n>/ directory that does not exist
#
# Usage:
#   bash scripts/ci/validate-specs-index.sh [specs_dir]
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SPECS_DIR="${1:-$REPO_DIR/docs/specs}"
INDEX_FILE="$SPECS_DIR/README.md"

if [[ ! -f "$INDEX_FILE" ]]; then
  echo "validate-specs-index: missing index file: $INDEX_FILE" >&2
  exit 1
fi

on_disk="$(find "$SPECS_DIR" -mindepth 1 -maxdepth 1 -type d -name 'GH*' -exec basename {} \; | sort)"
indexed="$(sed -nE 's/^\| `(GH[0-9]+)\/`.*/\1/p' "$INDEX_FILE" | sort -u)"

fail=0

missing_from_index="$(comm -23 <(printf '%s\n' "$on_disk" | grep . || true) <(printf '%s\n' "$indexed" | grep . || true))"
if [[ -n "$missing_from_index" ]]; then
  fail=1
  echo "validate-specs-index: spec directories missing from $INDEX_FILE index table:" >&2
  printf '  - docs/specs/%s/\n' $missing_from_index >&2
fi

missing_on_disk="$(comm -13 <(printf '%s\n' "$on_disk" | grep . || true) <(printf '%s\n' "$indexed" | grep . || true))"
if [[ -n "$missing_on_disk" ]]; then
  fail=1
  echo "validate-specs-index: index rows without a matching spec directory:" >&2
  printf '  - %s/\n' $missing_on_disk >&2
fi

if [[ "$fail" -ne 0 ]]; then
  echo "validate-specs-index: update the index table in docs/specs/README.md (see its 'Update this index' rule)." >&2
  exit 1
fi

echo "validate-specs-index: OK ($(printf '%s\n' "$on_disk" | grep -c . || true) spec directories indexed)"
