#!/usr/bin/env bash
# VibeGuard Hook 精度测试运行器
#
# 用法：
#   bash tests/run_precision.sh --all              # 跑所有 hook
#   bash tests/run_precision.sh post-edit-guard     # 跑单个 hook
#   bash tests/run_precision.sh --csv               # 输出 CSV 格式
#
# 输出：每个守卫的 Precision / Recall / F1，以及汇总

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES_DIR="$REPO_DIR/tests/fixtures"

GREEN='\033[32m'
RED='\033[31m'
BOLD='\033[1m'
RESET='\033[0m'

TOTAL=0
PASS_COUNT=0
FAIL_COUNT=0
CSV_MODE=0
TARGET_HOOK=""

declare -a RESULTS=()
declare -a CLEANUP_DIRS=()

export VIBEGUARD_LOG_DIR=$(mktemp -d)

cleanup() {
  rm -rf "$VIBEGUARD_LOG_DIR"
  for d in "${CLEANUP_DIRS[@]}"; do
    [[ -d "$d" ]] && rm -rf "$d"
  done
}
trap cleanup EXIT

# macOS 兼容的毫秒时间戳
now_ms() {
  python3 -c "import time; print(int(time.time()*1000))"
}

# 从 meta.json 读取字段的 helper
meta_get() {
  local meta_file="$1" case_rel="$2" field="$3" default="${4:-}"
  python3 -c "
import json, sys
m = json.load(open(sys.argv[1]))
c = m['cases'][sys.argv[2]]
# case 级别优先，然后 hook 级别
val = c.get(sys.argv[3], m.get(sys.argv[3], sys.argv[4]))
print(val)
" "$meta_file" "$case_rel" "$field" "$default"
}

meta_has() {
  local meta_file="$1" case_rel="$2" field="$3"
  python3 -c "
import json, sys
m = json.load(open(sys.argv[1]))
c = m['cases'][sys.argv[2]]
sys.exit(0 if sys.argv[3] in c else 1)
" "$meta_file" "$case_rel" "$field"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) TARGET_HOOK="ALL"; shift ;;
    --csv) CSV_MODE=1; shift ;;
    --help|-h) echo "用法: bash tests/run_precision.sh [--all | --csv | <hook-name>]"; exit 0 ;;
    *) TARGET_HOOK="$1"; shift ;;
  esac
done
[[ -z "$TARGET_HOOK" ]] && TARGET_HOOK="ALL"

# ============================================================
# JSON 构造（通过 python3 安全转义）
# ============================================================

build_json() {
  # 通用 JSON 构造: key=value pairs
  python3 -c "
import json, sys
pairs = {}
for arg in sys.argv[1:]:
    k, v = arg.split('=', 1)
    pairs[k] = v
print(json.dumps({'tool_input': pairs}))
" "$@"
}

# ============================================================
# 运行单个 fixture case
# ============================================================

run_case() {
  local hook_dir="$1" case_rel="$2"
  local meta_file="$hook_dir/meta.json"
  local case_file="$hook_dir/$case_rel"
  local case_type="${case_rel%%/*}"

  local hook case_expect keyword description rule input_format
  hook=$(meta_get "$meta_file" "$case_rel" "hook" "")
  case_expect=$(meta_get "$meta_file" "$case_rel" "expect" "")
  keyword=$(meta_get "$meta_file" "$case_rel" "keyword" "")
  description=$(meta_get "$meta_file" "$case_rel" "description" "")
  rule=$(meta_get "$meta_file" "$case_rel" "rule" "")
  input_format=$(meta_get "$meta_file" "$case_rel" "input_format" "")

  local hook_script="$REPO_DIR/hooks/$hook"
  [[ ! "$hook" == hooks/* ]] || hook_script="$REPO_DIR/$hook"

  local output="" exit_code=0
  local start_ms end_ms latency_ms
  start_ms=$(now_ms)

  case "$input_format" in
    raw_json)
      output=$(cat "$case_file" | bash "$hook_script" 2>&1) || exit_code=$?
      ;;

    command)
      local cmd
      cmd=$(cat "$case_file")
      output=$(build_json "command=$cmd" | bash "$hook_script" 2>&1) || exit_code=$?
      ;;

    edit_path)
      local fpath
      fpath=$(cat "$case_file")
      output=$(python3 -c "
import json
print(json.dumps({'tool_input': {'file_path': $(python3 -c "import json; print(json.dumps('$(cat "$case_file")'))"  ), 'old_string': 'test'}}))
" | bash "$hook_script" 2>&1) || exit_code=$?
      ;;

    edit_content)
      local content file_path_meta
      content=$(cat "$case_file")
      file_path_meta=$(meta_get "$meta_file" "$case_rel" "file_path" "")
      output=$(python3 -c "
import json, sys
content = sys.stdin.read()
print(json.dumps({'tool_input': {'file_path': '$file_path_meta', 'new_string': content}}))
" <<< "$content" | bash "$hook_script" 2>&1) || exit_code=$?
      ;;

    write_path)
      local fpath
      fpath=$(cat "$case_file")
      output=$(build_json "file_path=$fpath" | bash "$hook_script" 2>&1) || exit_code=$?
      ;;

    write_json)
      local fpath_to_use content_meta
      content_meta=$(meta_get "$meta_file" "$case_rel" "content" "")
      if meta_has "$meta_file" "$case_rel" "file_path_override" 2>/dev/null; then
        fpath_to_use=$(meta_get "$meta_file" "$case_rel" "file_path_override" "")
      else
        fpath_to_use=$(cat "$case_file")
      fi
      output=$(python3 -c "
import json
print(json.dumps({'tool_input': {'file_path': '''$fpath_to_use''', 'content': '''$content_meta'''}}))
" | bash "$hook_script" 2>&1) || exit_code=$?
      ;;

    build_file)
      if meta_has "$meta_file" "$case_rel" "file_path_override" 2>/dev/null; then
        local fp_override
        fp_override=$(meta_get "$meta_file" "$case_rel" "file_path_override" "")
        output=$(build_json "file_path=$fp_override" | bash "$hook_script" 2>&1) || exit_code=$?
      else
        local tmp_dir tmp_file
        tmp_dir=$(mktemp -d)
        CLEANUP_DIRS+=("$tmp_dir")
        tmp_file="$tmp_dir/$(basename "$case_file")"
        cp "$case_file" "$tmp_file"
        output=$(build_json "file_path=$tmp_file" | bash "$hook_script" 2>&1) || exit_code=$?
      fi
      ;;

    script)
      local script_output
      script_output=$(bash "$case_file" </dev/null 2>/dev/null) || true
      # 提取 ENV= 行设置环境变量，剩余作为 JSON payload
      local env_vars="" json_payload=""
      while IFS= read -r line; do
        if [[ "$line" == ENV=* ]]; then
          export "${line#ENV=}"
          env_vars="${env_vars} ${line#ENV=}"
        else
          json_payload="${json_payload}${line}"
        fi
      done <<< "$script_output"
      # 从 JSON 中提取 tmp.XXXXX 目录用于清理
      local tmp_path
      tmp_path=$(echo "$json_payload" | python3 -c "
import json, sys, re
try:
  d = json.load(sys.stdin)
  fp = d.get('tool_input',{}).get('file_path','')
  m = re.search(r'(/.+?/tmp\.\w+)', fp)
  print(m.group(1) if m else '')
except: print('')
" 2>/dev/null || echo "")
      [[ -n "$tmp_path" && -d "$tmp_path" ]] && CLEANUP_DIRS+=("$tmp_path")
      output=$(echo "$json_payload" | bash "$hook_script" 2>&1) || exit_code=$?
      # 清理环境变量
      for ev in $env_vars; do
        unset "${ev%%=*}"
      done
      ;;

    pre_push_script)
      local script_output
      script_output=$(bash "$case_file" </dev/null 2>/dev/null) || true

      if echo "$script_output" | grep -q "^CWD="; then
        local push_cwd push_stdin
        push_cwd=$(echo "$script_output" | grep "^CWD=" | head -1 | cut -d= -f2-)
        push_stdin=$(echo "$script_output" | grep "^STDIN=" | head -1 | cut -d= -f2-)
        CLEANUP_DIRS+=("$push_cwd")
        output=$(cd "$push_cwd" && echo "$push_stdin" | bash "$hook_script" 2>&1) || exit_code=$?
      else
        output=$(echo "$script_output" | bash "$hook_script" 2>&1) || exit_code=$?
      fi
      ;;

    commit_script)
      local script_output commit_cwd extra_path
      script_output=$(bash "$case_file" </dev/null 2>/dev/null) || true
      commit_cwd=$(echo "$script_output" | grep "^CWD=" | head -1 | cut -d= -f2-)
      extra_path=$(echo "$script_output" | grep "^EXTRA_PATH=" | head -1 | cut -d= -f2-)
      CLEANUP_DIRS+=("$commit_cwd")

      if [[ -n "$extra_path" ]]; then
        output=$(cd "$commit_cwd" && PATH="$extra_path:/usr/bin:/bin:$PATH" bash "$hook_script" 2>&1) || exit_code=$?
      else
        output=$(cd "$commit_cwd" && bash "$hook_script" 2>&1) || exit_code=$?
      fi
      ;;

    paralysis_script)
      # analysis-paralysis-guard: 脚本预填充 events.jsonl 并输出 ENV= 行
      local script_output env_vars=""
      script_output=$(bash "$case_file" </dev/null 2>/dev/null) || true
      while IFS= read -r line; do
        if [[ "$line" == ENV=* ]]; then
          export "${line#ENV=}"
          env_vars="${env_vars} ${line#ENV=}"
        fi
      done <<< "$script_output"
      # hook 期望从 stdin 读取 tool JSON
      output=$(echo '{}' | bash "$hook_script" 2>&1) || exit_code=$?
      for ev in $env_vars; do
        unset "${ev%%=*}"
      done
      ;;

    *)
      output="ERROR: unknown input_format '$input_format'"
      exit_code=99
      ;;
  esac

  end_ms=$(now_ms)
  latency_ms=$((end_ms - start_ms))

  # 判断是否检出
  # Claude Code hooks: exit 2 = block
  # Git hooks: exit != 0 = block
  local detected=0
  local hook_type
  hook_type=$(meta_get "$meta_file" "$case_rel" "hook_type" "")

  if [[ "$hook_type" == "git-hook" ]]; then
    # git hooks: 非零退出码 = 拦截
    [[ $exit_code -ne 0 ]] && detected=1
  else
    # Claude Code hooks: exit 2 = block, 或 output 含 keyword
    if [[ $exit_code -eq 2 ]]; then
      detected=1
    elif [[ -n "$keyword" ]] && echo "$output" | grep -qF "$keyword"; then
      detected=1
    fi
  fi

  local test_pass=0
  case "$case_expect" in
    block|warn)
      [[ $detected -eq 1 ]] && test_pass=1
      ;;
    pass)
      [[ $detected -eq 0 ]] && test_pass=1
      ;;
  esac

  TOTAL=$((TOTAL + 1))
  if [[ $test_pass -eq 1 ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    [[ $CSV_MODE -eq 0 ]] && printf "  ${GREEN}PASS${RESET} %s: %s (%dms)\n" "$case_rel" "$description" "$latency_ms"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    if [[ $CSV_MODE -eq 0 ]]; then
      printf "  ${RED}FAIL${RESET} %s: %s (expected=%s detected=%d exit=%d)\n" \
        "$case_rel" "$description" "$case_expect" "$detected" "$exit_code"
      [[ -n "$output" ]] && printf "       output: %.200s\n" "$output"
    fi
  fi

  RESULTS+=("$(printf '%s,%s,%s,%s,%s,%d,%d,%d' \
    "$(basename "$hook_dir")" "$case_rel" "$case_type" "$rule" "$case_expect" "$detected" "$test_pass" "$latency_ms")")

  if [[ $CSV_MODE -eq 1 ]]; then
    printf '%s,%s,%s,%s,%s,%d,%d,%d\n' \
      "$(basename "$hook_dir")" "$case_rel" "$case_type" "$rule" "$case_expect" "$detected" "$test_pass" "$latency_ms"
  fi
}

# ============================================================
# 运行单个 hook 的所有 fixture
# ============================================================

run_hook() {
  local hook_dir="$1"
  local hook_name
  hook_name=$(basename "$hook_dir")

  [[ -f "$hook_dir/meta.json" ]] || return 0

  [[ $CSV_MODE -eq 0 ]] && printf "\n${BOLD}=== %s ===${RESET}\n" "$hook_name"

  local cases
  cases=$(python3 -c "
import json
m = json.load(open('$hook_dir/meta.json'))
for k in sorted(m['cases'].keys()):
    print(k)
")

  while IFS= read -r case_rel <&3; do
    [[ -z "$case_rel" ]] && continue
    run_case "$hook_dir" "$case_rel"
  done 3<<< "$cases"
}

# ============================================================
# 精度报告
# ============================================================

print_precision_report() {
  printf "\n${BOLD}====== Layer 1 精度报告 ======${RESET}\n"

  declare -A hook_tp hook_fp hook_fn hook_tn
  for result in "${RESULTS[@]}"; do
    IFS=',' read -r hook case_rel case_type rule expect detected test_pass latency <<< "$result"
    hook_tp[$hook]=${hook_tp[$hook]:-0}
    hook_fp[$hook]=${hook_fp[$hook]:-0}
    hook_fn[$hook]=${hook_fn[$hook]:-0}
    hook_tn[$hook]=${hook_tn[$hook]:-0}

    if [[ "$case_type" == "tp" ]]; then
      if [[ "$detected" -eq 1 ]]; then
        hook_tp[$hook]=$(( ${hook_tp[$hook]} + 1 ))
      else
        hook_fn[$hook]=$(( ${hook_fn[$hook]} + 1 ))
      fi
    else
      if [[ "$detected" -eq 1 ]]; then
        hook_fp[$hook]=$(( ${hook_fp[$hook]} + 1 ))
      else
        hook_tn[$hook]=$(( ${hook_tn[$hook]} + 1 ))
      fi
    fi
  done

  printf "\n%-22s %4s %4s %4s %4s  %8s %8s %8s\n" "Hook" "TP" "FP" "FN" "TN" "Prec" "Recall" "F1"
  printf "%-22s %4s %4s %4s %4s  %8s %8s %8s\n" "$(printf -- '-%.0s' {1..22})" "----" "----" "----" "----" "--------" "--------" "--------"

  local total_tp=0 total_fp=0 total_fn=0 total_tn=0

  for hook in $(echo "${!hook_tp[@]}" | tr ' ' '\n' | sort); do
    local tp=${hook_tp[$hook]} fp=${hook_fp[$hook]} fn=${hook_fn[$hook]} tn=${hook_tn[$hook]}
    total_tp=$((total_tp + tp))
    total_fp=$((total_fp + fp))
    total_fn=$((total_fn + fn))
    total_tn=$((total_tn + tn))

    local precision recall f1
    if (( tp + fp > 0 )); then
      precision=$(python3 -c "print(f'{$tp/($tp+$fp)*100:.1f}%')")
    else
      precision="N/A"
    fi
    if (( tp + fn > 0 )); then
      recall=$(python3 -c "print(f'{$tp/($tp+$fn)*100:.1f}%')")
    else
      recall="N/A"
    fi
    if [[ "$precision" != "N/A" ]] && [[ "$recall" != "N/A" ]]; then
      f1=$(python3 -c "
p=$tp/($tp+$fp) if ($tp+$fp)>0 else 0
r=$tp/($tp+$fn) if ($tp+$fn)>0 else 0
f1=2*p*r/(p+r) if (p+r)>0 else 0
print(f'{f1*100:.1f}%')
")
    else
      f1="N/A"
    fi

    printf "%-22s %4d %4d %4d %4d  %8s %8s %8s\n" "$hook" "$tp" "$fp" "$fn" "$tn" "$precision" "$recall" "$f1"
  done

  printf "%-22s %4s %4s %4s %4s  %8s %8s %8s\n" "$(printf -- '-%.0s' {1..22})" "----" "----" "----" "----" "--------" "--------" "--------"

  local total_precision total_recall total_f1
  if (( total_tp + total_fp > 0 )); then
    total_precision=$(python3 -c "print(f'{$total_tp/($total_tp+$total_fp)*100:.1f}%')")
  else
    total_precision="N/A"
  fi
  if (( total_tp + total_fn > 0 )); then
    total_recall=$(python3 -c "print(f'{$total_tp/($total_tp+$total_fn)*100:.1f}%')")
  else
    total_recall="N/A"
  fi
  if [[ "$total_precision" != "N/A" ]] && [[ "$total_recall" != "N/A" ]]; then
    total_f1=$(python3 -c "
p=$total_tp/($total_tp+$total_fp) if ($total_tp+$total_fp)>0 else 0
r=$total_tp/($total_tp+$total_fn) if ($total_tp+$total_fn)>0 else 0
f1=2*p*r/(p+r) if (p+r)>0 else 0
print(f'{f1*100:.1f}%')
")
  else
    total_f1="N/A"
  fi
  printf "%-22s %4d %4d %4d %4d  %8s %8s %8s\n" "TOTAL" "$total_tp" "$total_fp" "$total_fn" "$total_tn" "$total_precision" "$total_recall" "$total_f1"

  printf "\n${BOLD}Tests: %d total, ${GREEN}%d passed${RESET}, ${RED}%d failed${RESET}\n" "$TOTAL" "$PASS_COUNT" "$FAIL_COUNT"
}

# ============================================================
# Main
# ============================================================

[[ $CSV_MODE -eq 1 ]] && echo "hook,case,type,rule,expect,detected,pass,latency_ms"

if [[ "$TARGET_HOOK" == "ALL" ]]; then
  for hook_dir in "$FIXTURES_DIR"/*/; do
    run_hook "$hook_dir"
  done
else
  hook_dir="$FIXTURES_DIR/$TARGET_HOOK"
  if [[ -d "$hook_dir" ]]; then
    run_hook "$hook_dir"
  else
    echo "ERROR: fixture 目录不存在: $hook_dir"
    exit 1
  fi
fi

[[ $CSV_MODE -eq 0 ]] && print_precision_report

exit "$FAIL_COUNT"
