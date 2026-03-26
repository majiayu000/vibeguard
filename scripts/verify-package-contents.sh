#!/usr/bin/env bash
# verify-package-contents.sh — prepublishOnly guard
# Packs a tarball, unpacks it, and asserts that every required directory/file
# is present before the real publish proceeds.
#
# Exit codes:
#   0  — all required entries found
#   1  — one or more entries missing (blocks publish)

set -euo pipefail

REQUIRED=(
  "hooks"
  "guards"
  "rules"
  "scripts/setup"
  "scripts/lib"
  "skills"
  "workflows"
  "agents"
  "context-profiles"
  "mcp-server"
  ".claude/commands/vibeguard"
)

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "🔍  Packing tarball for verification…"
npm pack --pack-destination "$WORK" --quiet
TARBALL=$(ls "$WORK"/*.tgz)

echo "📦  Unpacking $TARBALL"
tar -xzf "$TARBALL" -C "$WORK"

MISSING=()
for entry in "${REQUIRED[@]}"; do
  if [ ! -e "$WORK/package/$entry" ]; then
    MISSING+=("$entry")
  fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
  echo ""
  echo "❌  prepublish verification FAILED — missing from tarball:"
  for m in "${MISSING[@]}"; do
    echo "     MISSING: $m"
  done
  echo ""
  echo "Add the missing paths to the 'files' array in package.json and retry."
  exit 1
fi

echo "✅  All required entries present in tarball:"
for entry in "${REQUIRED[@]}"; do
  echo "     OK: $entry"
done
