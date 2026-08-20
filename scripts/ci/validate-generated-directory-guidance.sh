#!/usr/bin/env bash
# Keep scoped CLAUDE.md files synchronized with docs/directory-guidance.md.

set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_dir"

python3 scripts/generate_directory_guidance.py --check
