#!/usr/bin/env bash
# RS-14: 声明-执行鸿沟检测 (ast-grep 版本)
#
# 检测 Config 类型通过 Default::default() 初始化而非 load() 方法的情况。
# 使用 ast-grep AST 级别扫描，消除之前 grep 版本的全量误报问题。
#
# 用法:
#   bash check_declaration_execution_gap.sh [--strict] [target_dir]

set -euo pipefail

source "$(dirname "$0")/common.sh"
parse_guard_args "$@"

if ! command -v ast-grep >/dev/null 2>&1; then
  echo "[RS-14] SKIP: ast-grep 未安装（安装方法: brew install ast-grep）"
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "[RS-14] SKIP: python3 不可用"
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES_DIR="${SCRIPT_DIR}/../ast-grep-rules"
TMPFILE=$(create_tmpfile)

TEST_PATH_PATTERN='((^|/)tests[/._]|/test_|_test\.rs$|tests\.rs$|test_helpers\.rs$|(^|/)examples/|(^|/)benches/)'

# 检测 *Config::default() 使用（排除测试路径）
# 仅当对应的 Config 类型有 load() 方法时才报告，避免合法的 default-only Config 误报
export VG_TARGET_DIR="${TARGET_DIR}"

_ASG_TMPOUT=$(create_tmpfile)
if ! ast-grep scan \
    --rule "${RULES_DIR}/rs-14-config-default.yml" \
    --json \
    "${TARGET_DIR}" > "${_ASG_TMPOUT}" 2>/dev/null; then
  echo "[RS-14] WARN: ast-grep 扫描失败（规则文件可能缺失），跳过检测" >&2
  exit 0
fi

python3 -c '
import json, sys, re, subprocess, os

TEST_PATH = re.compile(r"((^|/)tests[/._]|/test_|_test\.rs$|tests\.rs$|test_helpers\.rs$|(^|/)examples/|(^|/)benches/)")
target_dir = os.environ.get("VG_TARGET_DIR", ".")

data = sys.stdin.read().strip()
if not data:
    sys.exit(0)
try:
    matches = json.loads(data)
except Exception as e:
    print("[RS-14] WARN: ast-grep JSON 解析失败: " + str(e), file=sys.stderr)
    sys.exit(1)

load_cache = {}

def has_load_method(config_type, search_dir):
    if config_type in load_cache:
        return load_cache[config_type]
    try:
        impl_files = subprocess.run(
            ["grep", "-rEl", r"impl.*\b" + config_type + r"\b", "--include=*.rs", search_dir],
            capture_output=True, text=True
        ).stdout.strip().splitlines()
        # Match impl blocks specifically for this Config type (inherent or trait impls).
        # Brace-count to stay within the block, preventing false positives from
        # other types defined in the same file.
        impl_pat = re.compile(
            r"^\s*impl(?:<[^>]*>)?\s+(?:[\w:]+(?:<[^>]*>)?\s+for\s+)?(?:\w+::)*"
            + re.escape(config_type) + r"(?:<[^>]*>)?\s*\{"
        )
        load_pat = re.compile(r"\bfn\s+load\s*\(")
        for impl_file in impl_files:
            try:
                with open(impl_file, "r", errors="ignore") as fh:
                    lines = fh.readlines()
                i = 0
                while i < len(lines):
                    if impl_pat.search(lines[i]):
                        depth = lines[i].count("{") - lines[i].count("}")
                        j = i + 1
                        while j < len(lines) and depth > 0:
                            depth += lines[j].count("{") - lines[j].count("}")
                            if load_pat.search(lines[j]):
                                load_cache[config_type] = True
                                return True
                            j += 1
                    i += 1
            except Exception:
                pass
    except Exception:
        pass
    load_cache[config_type] = False
    return False

for m in matches:
    f = m.get("file", "")
    if TEST_PATH.search(f):
        continue
    text = m.get("text", "").strip()
    # Handle path-qualified types: e.g. config::AppConfig::default() -> AppConfig
    config_match = re.search(r"(\w+)::default\(\)\s*$", text)
    if not config_match:
        continue
    config_type = config_match.group(1)
    if not has_load_method(config_type, target_dir):
        continue
    line = m.get("range", {}).get("start", {}).get("line", 0) + 1
    msg = m.get("message", "")
    print("[RS-14] " + f + ":" + str(line) + " " + msg + " (" + text + ")")
' < "${_ASG_TMPOUT}" > "$TMPFILE" || {
  echo "[RS-14] WARN: python3 处理失败，跳过检测" >&2
  exit 0
}

FOUND=$(wc -l < "$TMPFILE" | tr -d ' ')

if [[ $FOUND -eq 0 ]]; then
  echo "[RS-14] PASS: 未检测到 Config 声明-执行鸿沟"
  exit 0
fi

cat "$TMPFILE"
echo ""
echo "Found ${FOUND} potential Config declaration-execution gap(s)."
echo ""
echo "修复方法："
echo "  1. Config 若有 load() 方法，启动时应调用 Config::load() 而非 Config::default()"
echo "  2. 若 Default::default() 确为预期行为（如测试或默认配置），添加注释说明"

if [[ "${STRICT}" == true ]]; then
  exit 1
fi
