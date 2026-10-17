#!/usr/bin/env bash
# Download a prebuilt vibeguard-runtime release, verify its checksum, and run `install`.
# Requires only curl, tar and shasum or sha256sum. No Rust toolchain or source checkout.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: install.sh <claude|codex|grok|git> [install options]

  curl -fsSL https://raw.githubusercontent.com/majiayu000/vibeguard/main/install.sh | bash -s -- claude --dry-run

Arguments are forwarded to `vibeguard-runtime install`.
Set VIBEGUARD_VERSION to a release tag (for example v2.1.0) to pin a version; the default is the latest release.
EOF
}

fail() {
  echo "VibeGuard install: $*" >&2
  exit 1
}

if (($# == 0)); then
  usage
  exit 2
fi
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit 0
fi

case "$(uname -s)/$(uname -m)" in
  Darwin/arm64) target=aarch64-apple-darwin ;;
  Darwin/x86_64) target=x86_64-apple-darwin ;;
  Linux/x86_64) target=x86_64-unknown-linux-musl ;;
  Linux/aarch64 | Linux/arm64) target=aarch64-unknown-linux-musl ;;
  *) fail "no prebuilt release for $(uname -s) $(uname -m); build from source with the Rust toolchain (bash setup.sh)" ;;
esac

command -v curl >/dev/null 2>&1 || fail "curl is required to download the release"
command -v tar >/dev/null 2>&1 || fail "tar is required to extract the release"
if command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
  fail "sha256sum or shasum is required to verify the release"
fi

releases="${VIBEGUARD_RELEASES_URL:-https://github.com/majiayu000/vibeguard/releases}"
if [[ -n "${VIBEGUARD_VERSION:-}" ]]; then
  download="$releases/download/$VIBEGUARD_VERSION"
else
  download="$releases/latest/download"
fi
asset="vibeguard-$target.tar.gz"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Downloading $asset (${VIBEGUARD_VERSION:-latest})..." >&2
curl -fsSL -o "$tmp/$asset" "$download/$asset" || fail "download failed: $download/$asset"
curl -fsSL -o "$tmp/SHA256SUMS" "$download/SHA256SUMS" || fail "download failed: $download/SHA256SUMS"

expected="$(awk -v name="$asset" '$2 == name || $2 == "*" name { print $1 }' "$tmp/SHA256SUMS")"
[[ -n "$expected" ]] || fail "SHA256SUMS has no entry for $asset"
actual="$(sha256 "$tmp/$asset")"
[[ "$actual" == "$expected" ]] || fail "checksum mismatch for $asset (expected $expected, got $actual)"

mkdir "$tmp/extract"
tar -xzf "$tmp/$asset" -C "$tmp/extract"
[[ -x "$tmp/extract/vibeguard-runtime" ]] || fail "archive does not contain an executable vibeguard-runtime"

# Keep stdin away from the runtime so `curl ... | bash` does not lose the rest of this script.
"$tmp/extract/vibeguard-runtime" install "$@" </dev/null
