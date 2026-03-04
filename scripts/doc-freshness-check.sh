#!/usr/bin/env bash
# VibeGuard 文档新鲜度检测
#
# 交叉比对 rules/*.md 定义的规则 ID 和 guards/ 实现的规则 ID。
# 输出：未实现的规则（有规则无守卫）和未文档化的守卫（有守卫无规则）。
#
# 用法：
#   bash doc-freshness-check.sh             # 默认检查
#   bash doc-freshness-check.sh --strict    # >10% 不一致返回退出码 1

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STRICT=false

for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=true ;;
  esac
done

RULES_DIR="${REPO_DIR}/rules"
GUARDS_DIR="${REPO_DIR}/guards"
NATIVE_RULES_DIR="${HOME}/.claude/rules/vibeguard"

if [[ ! -d "$RULES_DIR" ]]; then
  echo "规则目录不存在: ${RULES_DIR}"
  exit 1
fi

if [[ ! -d "$GUARDS_DIR" ]]; then
  echo "守卫目录不存在: ${GUARDS_DIR}"
  exit 1
fi

VG_RULES_DIR="$RULES_DIR" VG_GUARDS_DIR="$GUARDS_DIR" VG_NATIVE_RULES_DIR="$NATIVE_RULES_DIR" \
  VG_STRICT="$STRICT" python3 -c '
import os, re, sys, glob

rules_dir = os.environ["VG_RULES_DIR"]
guards_dir = os.environ["VG_GUARDS_DIR"]
native_rules_dir = os.environ.get("VG_NATIVE_RULES_DIR", "")
strict = os.environ.get("VG_STRICT", "false") == "true"

id_pattern = re.compile(r"\b(RS|GO|TS|PY|U|SEC)-(\d+)\b")

# 从规则文件提取规则 ID 及其描述
rule_ids = {}  # id -> (file, description)
for md_file in sorted(glob.glob(os.path.join(rules_dir, "*.md"))):
    basename = os.path.basename(md_file)
    with open(md_file) as f:
        for line in f:
            for m in id_pattern.finditer(line):
                rule_id = m.group()
                if rule_id not in rule_ids:
                    # 取行内容作简要描述
                    desc = line.strip()[:80]
                    rule_ids[rule_id] = (basename, desc)

# 从守卫脚本提取已实现的规则 ID
guard_ids = {}  # id -> [files]
for guard_file in sorted(glob.glob(os.path.join(guards_dir, "**/*"), recursive=True)):
    if not os.path.isfile(guard_file):
        continue
    try:
        with open(guard_file) as f:
            content = f.read()
    except (UnicodeDecodeError, PermissionError):
        continue
    rel_path = os.path.relpath(guard_file, guards_dir)
    for m in id_pattern.finditer(content):
        gid = m.group()
        guard_ids.setdefault(gid, []).append(rel_path)

# 从 hooks 目录也扫描（hooks 中也实现了部分规则）
hooks_dir = os.path.join(os.path.dirname(guards_dir), "hooks")
if os.path.isdir(hooks_dir):
    for hook_file in sorted(glob.glob(os.path.join(hooks_dir, "*.sh"))):
        try:
            with open(hook_file) as f:
                content = f.read()
        except (UnicodeDecodeError, PermissionError):
            continue
        rel_path = "hooks/" + os.path.basename(hook_file)
        for m in id_pattern.finditer(content):
            gid = m.group()
            guard_ids.setdefault(gid, []).append(rel_path)

# AI 可见规则: 优先 ~/.claude/rules/vibeguard/，缺失时回退到 repo rules/（CI 友好）
ai_visible_ids = {}  # id -> [files]
if native_rules_dir and os.path.isdir(native_rules_dir):
    ai_rules_dir = native_rules_dir
    ai_source_label = "~/.claude/rules/"
    ai_fallback_used = False
else:
    ai_rules_dir = rules_dir
    ai_source_label = "repo/rules (fallback)"
    ai_fallback_used = True

for nr_file in sorted(glob.glob(os.path.join(ai_rules_dir, "**/*.md"), recursive=True)):
    try:
        with open(nr_file) as f:
            content = f.read()
    except (UnicodeDecodeError, PermissionError):
        continue
    rel_path = os.path.relpath(nr_file, ai_rules_dir)
    for m in id_pattern.finditer(content):
        aid = m.group()
        ai_visible_ids.setdefault(aid, []).append(rel_path)

# 计算缺口
rule_set = set(rule_ids.keys())
guard_set = set(guard_ids.keys())
ai_set = set(ai_visible_ids.keys())

implemented = sorted(rule_set & guard_set)
ai_visible = sorted(rule_set & ai_set)
dual_covered = sorted(rule_set & guard_set & ai_set)
all_covered = sorted(rule_set & (guard_set | ai_set))
unimplemented = sorted(rule_set - guard_set)
not_ai_visible = sorted(rule_set - ai_set)
fully_uncovered = sorted(rule_set - guard_set - ai_set)
undocumented = sorted(guard_set - rule_set)

total_rules = len(rule_ids)
gap_count = len(fully_uncovered) + len(undocumented)
gap_rate = (gap_count / total_rules * 100) if total_rules > 0 else 0

# 输出报告
print(f"""
VibeGuard 文档新鲜度报告
{"=" * 40}
规则总数:     {total_rules}
综合覆盖:     {len(all_covered)} ({len(all_covered)/total_rules*100:.0f}%)
  机械强制:   {len(implemented)} (守卫/hooks)
  AI 可见:    {len(ai_visible)} ({ai_source_label})
  双重覆盖:   {len(dual_covered)}
完全未覆盖:   {len(fully_uncovered)}
未文档化守卫: {len(undocumented)}
不一致率:     {gap_rate:.1f}%
""")

if ai_fallback_used:
    print(f"NOTE: native rules dir 不存在，已回退到 {rules_dir}")
    print()

def print_by_prefix(ids, label):
    if not ids:
        return
    print(f"{label}:")
    by_prefix = {}
    for rid in ids:
        prefix = rid.split("-")[0]
        by_prefix.setdefault(prefix, []).append(rid)
    for prefix in sorted(by_prefix.keys()):
        ids_str = ", ".join(by_prefix[prefix])
        print(f"  {prefix}: {ids_str}")
    print()

dual_set = set(dual_covered)
print_by_prefix(dual_covered, "双重覆盖（守卫 + AI 可见）")
print_by_prefix([r for r in implemented if r not in dual_set], "仅机械强制（守卫/hooks）")
print_by_prefix([r for r in ai_visible if r not in dual_set], f"仅 AI 可见（{ai_source_label}）")

if fully_uncovered:
    print("完全未覆盖的规则:")
    for rid in fully_uncovered:
        if rid in rule_ids:
            src_file, desc = rule_ids[rid]
            print(f"  {rid} ({src_file})")
    print()

if undocumented:
    print("未文档化的守卫（守卫中引用，无规则定义）:")
    for gid in undocumented:
        files = guard_ids[gid]
        files_str = ", ".join(files)
        print(f"  {gid} → {files_str}")
    print()

# 判定
if gap_rate > 20:
    print("FAIL: 不一致率 > 20%，建议立即补齐")
    status = 2
elif gap_rate > 10:
    print("WARN: 不一致率 > 10%，建议安排补齐")
    status = 1
else:
    print("PASS: 规则-守卫一致性良好")
    status = 0

if strict and status > 0:
    sys.exit(1)
'
