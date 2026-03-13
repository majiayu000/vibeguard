#!/usr/bin/env bash
# VibeGuard Project Init — 为当前仓库生成项目级守卫配置
#
# 检测语言/框架 → 列出激活的守卫/规则 → 生成项目级 CLAUDE.md 片段
#
# 用法: bash project-init.sh [project_root]
set -euo pipefail

PROJECT_ROOT="${1:-$(pwd)}"
cd "$PROJECT_ROOT" || { echo "ERROR: 无法进入目录 $PROJECT_ROOT"; exit 1; }

VIBEGUARD_DIR="${VIBEGUARD_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"

echo "=== VibeGuard Project Init ==="
echo "项目: $PROJECT_ROOT"
echo

# --- 语言/框架检测 ---
LANGS=()
FRAMEWORKS=()
BUILD_CMDS=()
TEST_CMDS=()

if [[ -f "Cargo.toml" ]]; then
  LANGS+=("rust")
  BUILD_CMDS+=("cargo check")
  TEST_CMDS+=("cargo test")
  if grep -q "actix-web\|axum\|rocket" Cargo.toml 2>/dev/null; then
    FRAMEWORKS+=("rust-web")
  fi
fi

if [[ -f "tsconfig.json" ]]; then
  LANGS+=("typescript")
  BUILD_CMDS+=("npx tsc --noEmit")
  if [[ -f "package.json" ]]; then
    if grep -q '"test"' package.json 2>/dev/null; then
      TEST_CMDS+=("npm test")
    fi
    if grep -q "next" package.json 2>/dev/null; then
      FRAMEWORKS+=("nextjs")
    elif grep -q "react" package.json 2>/dev/null; then
      FRAMEWORKS+=("react")
    fi
  fi
elif [[ -f "package.json" ]]; then
  LANGS+=("javascript")
  if grep -q '"test"' package.json 2>/dev/null; then
    TEST_CMDS+=("npm test")
  fi
fi

if [[ -f "go.mod" ]]; then
  LANGS+=("go")
  BUILD_CMDS+=("go build ./...")
  TEST_CMDS+=("go test ./...")
fi

if [[ -f "pyproject.toml" ]] || [[ -f "requirements.txt" ]]; then
  LANGS+=("python")
  TEST_CMDS+=("pytest")
fi

if [[ ${#LANGS[@]} -eq 0 ]]; then
  echo "未检测到已知语言，跳过。"
  exit 0
fi

echo "检测到语言: ${LANGS[*]}"
[[ ${#FRAMEWORKS[@]} -gt 0 ]] && echo "检测到框架: ${FRAMEWORKS[*]}"
echo

# --- 列出激活的守卫 ---
echo "--- 激活的守卫 ---"
GUARDS_DIR="$VIBEGUARD_DIR/guards"
ACTIVE_GUARDS=()

# 通用守卫
if [[ -d "$GUARDS_DIR/universal" ]]; then
  for g in "$GUARDS_DIR/universal"/check_*.sh; do
    [[ -f "$g" ]] || continue
    ACTIVE_GUARDS+=("$(basename "$g")")
    echo "  [通用] $(basename "$g")"
  done
fi

# 语言守卫
for lang in "${LANGS[@]}"; do
  LANG_DIR=""
  case "$lang" in
    rust) LANG_DIR="$GUARDS_DIR/rust" ;;
    typescript|javascript) LANG_DIR="$GUARDS_DIR/typescript" ;;
    go) LANG_DIR="$GUARDS_DIR/go" ;;
  esac
  if [[ -n "$LANG_DIR" ]] && [[ -d "$LANG_DIR" ]]; then
    for g in "$LANG_DIR"/check_*.sh; do
      [[ -f "$g" ]] || continue
      ACTIVE_GUARDS+=("$(basename "$g")")
      echo "  [${lang}] $(basename "$g")"
    done
  fi
done
echo "共 ${#ACTIVE_GUARDS[@]} 个守卫激活"
echo

# --- 列出激活的原生规则 ---
echo "--- 激活的原生规则 ---"
RULES_DIR="$HOME/.claude/rules/vibeguard"
RULE_COUNT=0

if [[ -d "$RULES_DIR/common" ]]; then
  for rf in "$RULES_DIR/common"/*.md; do
    [[ -f "$rf" ]] || continue
    RC=$(grep -cE '^## [A-Z]+-[0-9]+' "$rf" 2>/dev/null || echo "0")
    RULE_COUNT=$((RULE_COUNT + RC))
    echo "  [通用] $(basename "$rf"): ${RC} 条规则"
  done
fi

for lang in "${LANGS[@]}"; do
  LANG_RULE_DIR=""
  case "$lang" in
    rust) LANG_RULE_DIR="$RULES_DIR/rust" ;;
    typescript|javascript) LANG_RULE_DIR="$RULES_DIR/typescript" ;;
    go|golang) LANG_RULE_DIR="$RULES_DIR/golang" ;;
    python) LANG_RULE_DIR="$RULES_DIR/python" ;;
  esac
  if [[ -n "$LANG_RULE_DIR" ]] && [[ -d "$LANG_RULE_DIR" ]]; then
    for rf in "$LANG_RULE_DIR"/*.md; do
      [[ -f "$rf" ]] || continue
      RC=$(grep -cE '^## [A-Z]+-[0-9]+' "$rf" 2>/dev/null || echo "0")
      RULE_COUNT=$((RULE_COUNT + RC))
      echo "  [${lang}] $(basename "$rf"): ${RC} 条规则"
    done
  fi
done
echo "共 ${RULE_COUNT} 条规则激活"
echo

# --- 检测是否已有项目级 CLAUDE.md ---
if [[ -f "CLAUDE.md" ]]; then
  echo "项目已有 CLAUDE.md，跳过生成。"
  echo "建议手动添加以下内容："
  echo
else
  echo "项目无 CLAUDE.md，可选择生成。"
  echo
fi

# --- 输出建议的 CLAUDE.md 片段 ---
echo "--- 建议的项目 CLAUDE.md 片段 ---"
echo
echo '```markdown'
echo "# 项目约束"
echo
echo "## 构建命令"
for cmd in "${BUILD_CMDS[@]}"; do
  echo "- \`$cmd\`"
done
echo
echo "## 测试命令"
for cmd in "${TEST_CMDS[@]}"; do
  echo "- \`$cmd\`"
done
echo

# monorepo 检测
ENTRY_POINTS=$(find . -maxdepth 3 \( -name node_modules -o -name .git -o -name target -o -name vendor -o -name dist \) -prune -o \( -name "main.rs" -o -name "main.go" \) -print 2>/dev/null | wc -l | tr -d ' ')
if [[ "$ENTRY_POINTS" -gt 1 ]]; then
  echo "## 数据一致性（Monorepo）"
  echo "多入口项目（${ENTRY_POINTS} 个入口），注意 U-11~U-14 数据一致性规则。"
  echo
fi

echo "## VibeGuard 守卫"
echo "已激活 ${#ACTIVE_GUARDS[@]} 个守卫 + ${RULE_COUNT} 条规则"
echo '```'
echo
echo "=== 完成 ==="
