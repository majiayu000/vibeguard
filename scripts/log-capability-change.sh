#!/usr/bin/env bash
# VibeGuard 能力进化日志
#
# 扫描 git log 中涉及 guards/、rules/、skills/ 的提交，
# 输出格式化的能力进化时间线。
#
# 用法：
#   bash log-capability-change.sh                    # 全部历史
#   bash log-capability-change.sh --since 2026-02-01 # 指定日期起
#   bash log-capability-change.sh --type guard       # 仅守卫变更
#   bash log-capability-change.sh --json             # JSON 格式输出

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SINCE=""
TYPE_FILTER=""
JSON_OUTPUT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) SINCE="$2"; shift 2 ;;
    --type) TYPE_FILTER="$2"; shift 2 ;;
    --json) JSON_OUTPUT=true; shift ;;
    *) shift ;;
  esac
done

cd "$REPO_DIR"

if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo "不在 git 仓库中"
  exit 1
fi

# 构建 git log 参数
GIT_ARGS=("log" "--pretty=format:%H|%aI|%s" "--name-only" "--diff-filter=ACDMR")
if [[ -n "$SINCE" ]]; then
  GIT_ARGS+=("--since=$SINCE")
fi
GIT_ARGS+=("--" "guards/" "rules/" "hooks/" "skills/")

# 运行 git log 并解析
GIT_OUTPUT=$(git "${GIT_ARGS[@]}" 2>/dev/null || true)

VG_GIT_OUTPUT="$GIT_OUTPUT" VG_TYPE_FILTER="$TYPE_FILTER" VG_JSON="$JSON_OUTPUT" python3 -c '
import sys, os, json
from collections import defaultdict

type_filter = os.environ.get("VG_TYPE_FILTER", "")
json_output = os.environ.get("VG_JSON", "false") == "true"

# 从环境变量读取 git log 输出
raw = os.environ.get("VG_GIT_OUTPUT", "")
if not raw.strip():
    print("没有找到能力变更记录。")
    sys.exit(0)

# 解析 git log 输出
entries = []
current = None
for line in raw.split("\n"):
    line = line.strip()
    if not line:
        continue
    if "|" in line and line.count("|") >= 2:
        # 新提交行
        parts = line.split("|", 2)
        if len(parts) == 3:
            if current:
                entries.append(current)
            current = {
                "hash": parts[0][:8],
                "date": parts[1][:10],
                "message": parts[2],
                "files": [],
            }
    elif current is not None:
        current["files"].append(line)

if current:
    entries.append(current)

# 分类文件变更
def classify(path):
    if path.startswith("guards/"):
        return "guard"
    elif path.startswith("rules/"):
        return "rule"
    elif path.startswith("hooks/"):
        return "hook"
    elif path.startswith("skills/"):
        return "skill"
    return "other"

# 丰富条目信息
for entry in entries:
    types = set()
    for f in entry["files"]:
        t = classify(f)
        if t != "other":
            types.add(t)
    entry["types"] = sorted(types)

# 过滤
if type_filter:
    entries = [e for e in entries if type_filter in e["types"]]

if not entries:
    print(f"没有找到类型为 \"{type_filter}\" 的能力变更记录。")
    sys.exit(0)

if json_output:
    print(json.dumps(entries, ensure_ascii=False, indent=2))
    sys.exit(0)

# 格式化输出
print(f"""
VibeGuard 能力进化时间线
{"=" * 50}
共 {len(entries)} 次变更
""")

# 按月分组
by_month = defaultdict(list)
for entry in entries:
    month = entry["date"][:7]
    by_month[month].append(entry)

type_icons = {"guard": "🛡", "rule": "📏", "hook": "🪝", "skill": "🎯"}

for month in sorted(by_month.keys(), reverse=True):
    month_entries = by_month[month]
    print(f"--- {month} ({len(month_entries)} 次变更) ---")
    for entry in month_entries:
        e_date = entry["date"]
        e_msg = entry["message"]
        icons = " ".join(type_icons.get(t, "?") for t in entry["types"])
        print(f"  {e_date}  {icons}  {e_msg}")
        # 列出变更文件（最多 5 个）
        e_files = entry["files"]
        for ef in e_files[:5]:
            cat = classify(ef)
            print(f"    {cat:>5}: {ef}")
        extra = len(e_files) - 5
        if extra > 0:
            print(f"    ... +{extra} 个文件")
    print()

# 统计摘要
type_counts = defaultdict(int)
for entry in entries:
    for t in entry["types"]:
        type_counts[t] += 1

print("变更类型分布:")
for t in sorted(type_counts.keys()):
    icon = type_icons.get(t, "?")
    print(f"  {icon} {t}: {type_counts[t]} 次")
print()
'
