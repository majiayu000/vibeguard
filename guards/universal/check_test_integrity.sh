#!/usr/bin/env bash
# VibeGuard Guard — 测试完整性检测 (W-12)
#
# 检测 AI 代理可能用于伪造测试通过的攻击向量：
#   1. 库影子文件 (Library Shadowing) — 本地文件覆盖标准库模块
#   2. 空断言测试函数 (Empty Stub Detection) — 无断言的测试函数
#
# 用法：
#   bash check_test_integrity.sh [target_dir]    # 扫描指定目录
#   bash check_test_integrity.sh                 # 扫描当前目录
#
# 退出码：
#   0 — 无问题
#   1 — 发现问题

set -euo pipefail

TARGET_DIR="${1:-.}"
ISSUES=0

yellow() { printf '\033[33m[W-12] %s\033[0m\n' "$1"; }
red()    { printf '\033[31m[W-12] %s\033[0m\n' "$1"; }
green()  { printf '\033[32m%s\033[0m\n' "$1"; }

echo "测试完整性检测 (W-12): ${TARGET_DIR}"
echo "---"

# =========================================================
# 1. 库影子文件检测
# =========================================================
echo "检查库影子文件..."

# Python 标准库模块名（最常见的 shadow 目标）
PYTHON_STDLIB_MODULES=(
  os sys re io json math time copy enum abc
  abc ast builtins collections datetime decimal
  functools hashlib hmac http inspect io itertools
  logging math operator os pathlib pickle platform
  queue random re shutil signal socket ssl stat string
  struct subprocess sys tempfile threading time types
  typing unittest urllib uuid warnings weakref
  numpy pandas requests flask django pytest
)

SHADOW_FOUND=0
for mod in "${PYTHON_STDLIB_MODULES[@]}"; do
  shadow_file="${TARGET_DIR}/${mod}.py"
  if [[ -f "$shadow_file" ]]; then
    rel_path="${shadow_file#${TARGET_DIR}/}"
    red "库影子文件: ${rel_path} (shadows '${mod}' module)"
    SHADOW_FOUND=$((SHADOW_FOUND + 1))
    ISSUES=$((ISSUES + 1))
  fi
done

# JavaScript/TypeScript 库影子检测
JS_STDLIB_MODULES=(
  path fs os crypto http https url util events
  assert stream buffer process child_process
)
for mod in "${JS_STDLIB_MODULES[@]}"; do
  for ext in js ts mjs cjs; do
    shadow_file="${TARGET_DIR}/${mod}.${ext}"
    if [[ -f "$shadow_file" ]]; then
      rel_path="${shadow_file#${TARGET_DIR}/}"
      red "库影子文件: ${rel_path} (shadows Node.js '${mod}' module)"
      SHADOW_FOUND=$((SHADOW_FOUND + 1))
      ISSUES=$((ISSUES + 1))
    fi
  done
done

if [[ "$SHADOW_FOUND" -eq 0 ]]; then
  echo "  未发现库影子文件"
fi

# =========================================================
# 2. 空断言测试函数检测 (Python)
# =========================================================
echo "检查空断言测试函数 (Python)..."

EMPTY_STUBS=$(python3 -c '
import ast
import sys
import os

target = sys.argv[1]
violations = []

def find_test_files(root):
    for dirpath, dirnames, filenames in os.walk(root):
        # Skip common non-test directories
        dirnames[:] = [d for d in dirnames if d not in {
            "node_modules", ".git", "target", "dist", "build",
            "__pycache__", ".venv", "vendor", ".mypy_cache"
        }]
        for fname in filenames:
            if fname.startswith("test_") or fname.endswith("_test.py"):
                yield os.path.join(dirpath, fname)

def has_assertion(func_node):
    """Check if a function node contains any assertion-like calls."""
    for node in ast.walk(func_node):
        if isinstance(node, ast.Assert):
            return True
        if isinstance(node, ast.Call):
            func = node.func
            # assert* methods (unittest style)
            if isinstance(func, ast.Attribute) and func.attr.startswith("assert"):
                return True
            # pytest.raises, pytest.warns, etc.
            if isinstance(func, ast.Attribute) and func.attr in ("raises", "warns", "approx"):
                return True
            # expect() calls (jest/chai style via pytest-bdd etc.)
            if isinstance(func, ast.Name) and func.id in ("expect", "raises"):
                return True
    return False

for fpath in find_test_files(target):
    try:
        source = open(fpath, encoding="utf-8", errors="replace").read()
        tree = ast.parse(source, filename=fpath)
    except (SyntaxError, OSError):
        continue

    for node in ast.walk(tree):
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        if not node.name.startswith("test_") and node.name != "test":
            continue
        # Skip functions with only pass/... body (explicit stubs)
        body = node.body
        if all(
            isinstance(s, (ast.Pass, ast.Expr)) and (
                isinstance(s, ast.Pass) or
                (isinstance(s, ast.Expr) and isinstance(s.value, ast.Constant) and s.value.value in (None, ...))
            )
            for s in body
        ):
            continue
        if not has_assertion(node):
            rel = os.path.relpath(fpath, target)
            violations.append(f"{rel}:{node.lineno}: {node.name}() has no assertions")

for v in violations:
    print(v)
' "$TARGET_DIR" 2>/dev/null || true)

if [[ -n "$EMPTY_STUBS" ]]; then
  COUNT=$(echo "$EMPTY_STUBS" | wc -l | tr -d ' ')
  yellow "无断言测试函数: ${COUNT} 处"
  echo "$EMPTY_STUBS" | head -10
  [[ "$COUNT" -gt 10 ]] && echo "  ... 还有 $((COUNT - 10)) 处"
  ISSUES=$((ISSUES + COUNT))
else
  echo "  未发现无断言测试函数"
fi

# =========================================================
# 3. 空断言测试函数检测 (TypeScript/JavaScript)
# =========================================================
echo "检查空断言测试函数 (TypeScript/JavaScript)..."

JS_EMPTY_STUBS=$(grep -rn \
  --include='*.test.ts' --include='*.test.js' \
  --include='*.spec.ts' --include='*.spec.js' \
  --include='*.test.tsx' --include='*.spec.tsx' \
  --exclude-dir=node_modules --exclude-dir=dist --exclude-dir=.git \
  -E '^\s*(it|test)\s*\(' \
  "$TARGET_DIR" 2>/dev/null | while IFS= read -r line; do
    file=$(echo "$line" | cut -d: -f1)
    lineno=$(echo "$line" | cut -d: -f2)
    # Check the next 10 lines for expect(
    if ! sed -n "${lineno},$((lineno + 15))p" "$file" 2>/dev/null | grep -qE 'expect\s*\(|assert\s*\(|should\.|\.toBe|\.toEqual|\.toContain|\.toThrow'; then
      echo "${file#${TARGET_DIR}/}:${lineno}"
    fi
  done 2>/dev/null | head -20 || true)

if [[ -n "$JS_EMPTY_STUBS" ]]; then
  COUNT=$(echo "$JS_EMPTY_STUBS" | wc -l | tr -d ' ')
  yellow "无断言测试块 (JS/TS): ${COUNT} 处 (需人工确认)"
  echo "$JS_EMPTY_STUBS" | head -10
  # Don't increment ISSUES for JS — heuristic is less reliable
fi

# =========================================================
# 总结
# =========================================================
echo ""
echo "---"
if [[ "$ISSUES" -gt 0 ]]; then
  red "发现 ${ISSUES} 个测试完整性问题 (W-12)"
  exit 1
else
  green "测试完整性检测通过"
  exit 0
fi
