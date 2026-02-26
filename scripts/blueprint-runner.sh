#!/usr/bin/env bash
# VibeGuard Blueprint Runner — 蓝图编排器
#
# 读取 JSON 蓝图，按顺序执行确定性节点，代理节点输出提示。
#
# 用法：
#   bash blueprint-runner.sh <blueprint> [target_dir]
#   bash blueprint-runner.sh standard-edit /path/to/project
#   bash blueprint-runner.sh pre-commit
#   bash blueprint-runner.sh --list
#
# 蓝图文件位于 vibeguard/blueprints/*.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BLUEPRINTS_DIR="${REPO_DIR}/blueprints"

source "${REPO_DIR}/hooks/log.sh"

green() { printf '\033[32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }
red() { printf '\033[31m%s\033[0m\n' "$1"; }
dim() { printf '\033[90m%s\033[0m\n' "$1"; }

ACTION="${1:-help}"

# --- List mode ---
if [[ "$ACTION" == "--list" ]]; then
  echo "可用蓝图："
  for bp in "${BLUEPRINTS_DIR}"/*.json; do
    [[ -f "$bp" ]] || continue
    name=$(python3 -c "import json; print(json.load(open('$bp'))['name'])" 2>/dev/null)
    desc=$(python3 -c "import json; print(json.load(open('$bp'))['description'])" 2>/dev/null)
    echo "  ${name}: ${desc}"
  done
  exit 0
fi

if [[ "$ACTION" == "help" ]]; then
  echo "VibeGuard Blueprint Runner"
  echo ""
  echo "用法："
  echo "  blueprint-runner.sh <blueprint> [target_dir]"
  echo "  blueprint-runner.sh --list"
  echo ""
  echo "示例："
  echo "  blueprint-runner.sh standard-edit /path/to/project"
  echo "  blueprint-runner.sh pre-commit"
  exit 0
fi

# --- Run mode ---
BLUEPRINT_NAME="$ACTION"
TARGET_DIR="${2:-$(pwd)}"
BLUEPRINT_FILE="${BLUEPRINTS_DIR}/${BLUEPRINT_NAME}.json"

if [[ ! -f "$BLUEPRINT_FILE" ]]; then
  red "蓝图不存在: ${BLUEPRINT_NAME}"
  echo "运行 blueprint-runner.sh --list 查看可用蓝图"
  exit 1
fi

echo "VibeGuard Blueprint: ${BLUEPRINT_NAME}"
echo "目标目录: ${TARGET_DIR}"
echo "======================================="
echo ""

# 用 python3 解析蓝图并逐节点执行
VG_BLUEPRINT="$BLUEPRINT_FILE" VG_TARGET="$TARGET_DIR" VG_REPO="$REPO_DIR" \
python3 -c '
import json, subprocess, os, sys, time

bp_file = os.environ["VG_BLUEPRINT"]
target = os.environ["VG_TARGET"]
repo = os.environ["VG_REPO"]

with open(bp_file) as f:
    bp = json.load(f)

nodes = bp.get("nodes", [])
results = []
aborted = False

for node in nodes:
    nid = node["id"]
    ntype = node["type"]
    name = node["name"]
    on_fail = node.get("on_fail", "warn")
    timeout = node.get("timeout", 30)

    print(f"  [{nid}] {name} ...", end=" ", flush=True)

    if ntype == "agent":
        # 代理节点：不执行，输出提示
        condition = node.get("condition", "")
        prompt = node.get("prompt", "")
        print(f"\033[33mSKIP (agent)\033[0m")
        print(f"    条件: {condition}")
        print(f"    提示: {prompt}")
        results.append({"id": nid, "status": "skip", "type": "agent"})
        continue

    # 确定性节点
    cmd = node.get("command", "")

    if cmd == "auto":
        # 自动构建检查
        if os.path.exists(os.path.join(target, "Cargo.toml")):
            cmd_args = ["cargo", "check", "--quiet"]
        elif os.path.exists(os.path.join(target, "tsconfig.json")):
            cmd_args = ["npx", "tsc", "--noEmit"]
        elif os.path.exists(os.path.join(target, "go.mod")):
            cmd_args = ["go", "build", "./..."]
        else:
            print(f"\033[90mSKIP (no build system)\033[0m")
            results.append({"id": nid, "status": "skip", "type": "deterministic"})
            continue
    elif cmd.startswith("hooks/"):
        cmd_args = ["bash", os.path.join(repo, cmd)]
    elif cmd.startswith("mcp:"):
        # MCP 工具调用占位：输出提示
        print(f"\033[33mSKIP (mcp)\033[0m")
        print(f"    MCP 调用: {cmd}")
        results.append({"id": nid, "status": "skip", "type": "mcp"})
        continue
    else:
        cmd_args = cmd.split()

    start = time.time()
    try:
        proc = subprocess.run(
            cmd_args,
            cwd=target,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        elapsed = time.time() - start
        if proc.returncode == 0:
            print(f"\033[32mPASS\033[0m ({elapsed:.1f}s)")
            results.append({"id": nid, "status": "pass", "elapsed": elapsed})
        else:
            if on_fail == "abort":
                print(f"\033[31mFAIL (abort)\033[0m ({elapsed:.1f}s)")
                if proc.stdout.strip():
                    for line in proc.stdout.strip().split("\n")[:5]:
                        print(f"    {line}")
                results.append({"id": nid, "status": "fail"})
                aborted = True
                break
            else:
                print(f"\033[33mWARN\033[0m ({elapsed:.1f}s)")
                if proc.stdout.strip():
                    for line in proc.stdout.strip().split("\n")[:3]:
                        print(f"    {line}")
                results.append({"id": nid, "status": "warn"})
    except subprocess.TimeoutExpired:
        elapsed = time.time() - start
        print(f"\033[90mTIMEOUT\033[0m ({elapsed:.1f}s)")
        results.append({"id": nid, "status": "timeout"})

# 汇总
print("")
passed = sum(1 for r in results if r["status"] == "pass")
warned = sum(1 for r in results if r["status"] == "warn")
failed = sum(1 for r in results if r["status"] == "fail")
skipped = sum(1 for r in results if r["status"] in ("skip", "timeout"))

if aborted:
    print(f"\033[31m蓝图中止: {passed} pass / {failed} fail\033[0m")
    sys.exit(1)
elif warned > 0:
    print(f"\033[33m蓝图完成（有警告）: {passed} pass / {warned} warn / {skipped} skip\033[0m")
else:
    print(f"\033[32m蓝图通过: {passed} pass / {skipped} skip\033[0m")
'
