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
    "${TARGET_DIR}" > "${_ASG_TMPOUT}"; then
  echo "[RS-14] WARN: ast-grep 扫描失败（规则文件可能缺失），跳过检测" >&2
  if [[ "${STRICT}" == true ]]; then
    exit 1
  fi
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

def has_load_method(full_type_path, search_dir):
    """Check if the Config type has a load() method.

    full_type_path preserves module namespace (e.g. "config::AppConfig") so that
    same-named Config types in different modules do not pollute each other cache
    entries or impl-file search results.
    """
    if full_type_path in load_cache:
        return load_cache[full_type_path]

    bare_type = full_type_path.split("::")[-1]
    module_parts = full_type_path.split("::")[:-1]

    try:
        all_impl_files = subprocess.run(
            ["grep", "-rEl", r"impl.*\b" + re.escape(bare_type) + r"\b", "--include=*.rs", search_dir],
            capture_output=True, text=True
        ).stdout.strip().splitlines()

        # Narrow to files whose path is consistent with the module namespace to
        # avoid cross-module pollution when multiple modules define same-named
        # Config types.  Fall back to the full list only when filtering yields
        # nothing (e.g. re-exported types with path aliases).
        if module_parts:
            module_suffix = os.path.join(*module_parts)
            narrowed = [f for f in all_impl_files if module_suffix in f]
            impl_files = narrowed if narrowed else all_impl_files
        else:
            impl_files = all_impl_files

        # Match impl blocks specifically for this Config type (inherent or trait impls).
        # Brace-count to stay within the block, preventing false positives from
        # other types defined in the same file.
        # Match impl header line: allow { on same line, or where clause, or bare line-break.
        # [^<>]*(?:<[^<>]*>[^<>]*)* handles one level of nested generics in the type params.
        _nested_generic = r"[^<>]*(?:<[^<>]*>[^<>]*)*"
        impl_pat = re.compile(
            r"^\s*impl(?:<" + _nested_generic + r">)?\s+(?:[\w:]+(?:<" + _nested_generic + r">)?\s+for\s+)?(?:\w+::)*"
            + re.escape(bare_type) + r"(?:<" + _nested_generic + r">)?\s*(?:\{|where\b|$)"
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
                        # Handle where clause / line-broken brace: scan until we enter the block.
                        while j < len(lines) and depth <= 0:
                            depth += lines[j].count("{") - lines[j].count("}")
                            j += 1
                        # Scan inside the impl block for fn load.
                        while j < len(lines) and depth > 0:
                            depth += lines[j].count("{") - lines[j].count("}")
                            if load_pat.search(lines[j]):
                                load_cache[full_type_path] = True
                                return True
                            j += 1
                    i += 1
            except Exception:
                pass
    except Exception:
        pass
    load_cache[full_type_path] = False
    return False

for m in matches:
    f = m.get("file", "")
    if TEST_PATH.search(f):
        continue
    text = m.get("text", "").strip()
    # Extract full qualified path before ::default(), preserving module namespace.
    # Handles plain, path-qualified, and turbofish forms:
    #   AppConfig::default()
    #   config::AppConfig::default()
    #   AppConfig::<Prod>::default()          (turbofish pattern in yml)
    #   config::AppConfig::<Prod>::default()
    config_match = re.search(r"((?:\w+::)*\w+)::(?:<[^<>]*(?:<[^<>]*>[^<>]*)*>::)?default\(\)\s*$", text)
    if not config_match:
        continue
    full_type_path = config_match.group(1)  # e.g. "config::AppConfig" or "AppConfig"
    if not has_load_method(full_type_path, target_dir):
        continue
    line = m.get("range", {}).get("start", {}).get("line", 0) + 1
    msg = m.get("message", "")
    print("[RS-14] " + f + ":" + str(line) + " " + msg + " (" + text + ")")
' < "${_ASG_TMPOUT}" > "$TMPFILE" || {
  echo "[RS-14] WARN: python3 处理失败，跳过检测" >&2
  if [[ "${STRICT}" == true ]]; then
    exit 1
  fi
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
