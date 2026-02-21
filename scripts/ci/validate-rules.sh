#!/usr/bin/env bash
# VibeGuard CI: 验证规则文件格式正确
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
RULES_DIR="${REPO_DIR}/rules"
errors=0

echo "Validating rule files..."

# 检查所有规则文件存在且非空
for rule_file in universal.md python.md typescript.md go.md rust.md security.md; do
  path="${RULES_DIR}/${rule_file}"
  if [[ ! -f "$path" ]]; then
    echo "FAIL: ${rule_file} not found"
    ((errors++))
  elif [[ ! -s "$path" ]]; then
    echo "FAIL: ${rule_file} is empty"
    ((errors++))
  else
    echo "OK: ${rule_file}"
  fi
done

# 检查规则文件包含必要的表格结构
echo
echo "Checking rule file structure..."
for rule_file in "${RULES_DIR}"/*.md; do
  [[ -f "$rule_file" ]] || continue
  name=$(basename "$rule_file")
  [[ "$name" == "CLAUDE.md" ]] && continue

  if ! grep -q '| ID' "$rule_file" 2>/dev/null; then
    echo "WARN: ${name} missing ID column in table"
  fi

  if ! grep -q '严重度\|严重\|高\|中\|低' "$rule_file" 2>/dev/null; then
    echo "WARN: ${name} missing severity indicators"
  fi
done

# 检查 vibeguard-rules.md 索引文件
RULES_INDEX="${REPO_DIR}/claude-md/vibeguard-rules.md"
if [[ -f "$RULES_INDEX" ]]; then
  if grep -q 'vibeguard-start' "$RULES_INDEX" && grep -q 'vibeguard-end' "$RULES_INDEX"; then
    echo "OK: vibeguard-rules.md has proper markers"
  else
    echo "FAIL: vibeguard-rules.md missing start/end markers"
    ((errors++))
  fi
else
  echo "FAIL: vibeguard-rules.md not found"
  ((errors++))
fi

echo
if [[ ${errors} -eq 0 ]]; then
  echo "All rule files valid."
else
  echo "FAILED: ${errors} errors found."
  exit 1
fi
