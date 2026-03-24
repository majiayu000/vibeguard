#!/usr/bin/env bash
# VibeGuard CI: 检测源码中泄露的个人路径
# 防止 /Users/<username>/ 或 /home/<username>/ 硬编码进入仓库
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
errors=0
checked=0

echo "Scanning for hardcoded personal paths..."

# Patterns to detect (case-insensitive home directory references)
# Excludes: .git/, node_modules/, dist/, .benchmarks/, *.jsonl, *.lock
EXCLUDE_DIRS="--exclude-dir=.git --exclude-dir=node_modules --exclude-dir=dist --exclude-dir=.benchmarks --exclude-dir=.vibeguard --exclude-dir=.pytest_cache --exclude-dir=worktrees --exclude-dir=target --exclude-dir=.claude --exclude-dir=__pycache__"
EXCLUDE_FILES="--exclude=*.jsonl --exclude=*.lock --exclude=bun.lock --exclude=package-lock.json"

# Pattern: /Users/<anything>/ or /home/<anything>/ (common home dir patterns)
# But NOT in comments explaining the pattern (like this file does)
while IFS= read -r match; do
  file="${match%%:*}"
  rest="${match#*:}"
  lineno="${rest%%:*}"
  content="${rest#*:}"

  # Skip this validator script itself
  [[ "$file" == *"validate-no-personal-paths.sh" ]] && continue

  # Skip test files that may legitimately test path patterns
  [[ "$file" == *"/tests/"* ]] && continue

  # Skip documentation that explains the concept
  [[ "$file" == *".md" ]] && continue

  # Skip changelog
  [[ "$file" == *"CHANGELOG"* ]] && continue

  # Skip .npmignore / .gitignore
  [[ "$file" == *"ignore" ]] && continue

  echo "FAIL: ${file}:${lineno}: hardcoded personal path detected"
  echo "  ${content}"
  ((errors++))
done < <(grep -rnH ${EXCLUDE_DIRS} ${EXCLUDE_FILES} \
  -E '(/Users/[a-zA-Z0-9._-]+/|/home/[a-zA-Z0-9._-]+/)' \
  "${REPO_DIR}" 2>/dev/null || true)

# Also check for ~ expansion in shell scripts that should use $HOME
while IFS= read -r match; do
  file="${match%%:*}"
  rest="${match#*:}"
  lineno="${rest%%:*}"
  content="${rest#*:}"

  # Skip this script, tests, docs
  [[ "$file" == *"validate-no-personal-paths.sh" ]] && continue
  [[ "$file" == *"/tests/"* ]] && continue
  [[ "$file" == *".md" ]] && continue

  # Only flag shell scripts that hardcode ~ in variable assignments (not in comments)
  [[ "$file" != *.sh ]] && continue

  # Skip comments
  trimmed="${content#"${content%%[![:space:]]*}"}"
  [[ "$trimmed" == "#"* ]] && continue

  # Skip echo/printf (display only)
  [[ "$trimmed" == *"echo "* ]] && continue
  [[ "$trimmed" == *"printf "* ]] && continue

  echo "WARN: ${file}:${lineno}: consider using \$HOME instead of ~"
  echo "  ${content}"
done < <(grep -rnH ${EXCLUDE_DIRS} ${EXCLUDE_FILES} \
  -E '=[[:space:]]*~/[a-zA-Z]' \
  "${REPO_DIR}"/*.sh "${REPO_DIR}"/hooks/*.sh "${REPO_DIR}"/scripts/**/*.sh 2>/dev/null || true)

echo
if [[ ${errors} -eq 0 ]]; then
  echo "No hardcoded personal paths found."
else
  echo "FAILED: ${errors} hardcoded personal paths detected."
  echo "Fix: Replace with \$HOME, \${REPO_DIR}, or relative paths."
  exit 1
fi
