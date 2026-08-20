#!/usr/bin/env bash
# Focused generator safety and freshness regression tests.

set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"

python3 tests/test_generate_directory_guidance.py
python3 scripts/generate_directory_guidance.py --check
