#!/usr/bin/env bash
# VibeGuard Go Guards — 共享函数库
#
# 所有 Go 守卫脚本通过 source common.sh 引入，消除重复代码。
# 提供：list_go_files、参数解析、临时文件管理

set -euo pipefail

# 列出 .go 源文件
# 优先级：VIBEGUARD_STAGED_FILES（pre-commit 模式，只扫 staged）> git ls-files > find
list_go_files() {
  local dir="$1"
  if [[ -n "${VIBEGUARD_STAGED_FILES:-}" ]] && [[ -f "${VIBEGUARD_STAGED_FILES}" ]]; then
    grep '\.go$' "${VIBEGUARD_STAGED_FILES}" || true
  elif git -C "${dir}" rev-parse --is-inside-work-tree &>/dev/null; then
    git -C "${dir}" ls-files '*.go' | while IFS= read -r f; do echo "${dir}/${f}"; done
  else
    find "${dir}" -name '*.go' -not -path '*/vendor/*' -not -path '*/.git/*'
  fi
}

# 解析 --strict / --baseline 标志和 target_dir
# 用法: parse_guard_args "$@"
# 设置变量: TARGET_DIR, STRICT, BASELINE_COMMIT
parse_guard_args() {
  TARGET_DIR="."
  STRICT=false
  BASELINE_COMMIT=""
  local positional_count=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --strict)
        STRICT=true
        ;;
      --baseline)
        shift
        BASELINE_COMMIT="${1:-}"
        ;;
      --help|-h)
        echo "Usage: $0 [--strict] [--baseline <commit>] [target_dir]" >&2
        return 1
        ;;
      --*)
        echo "Unknown option: $1" >&2
        return 1
        ;;
      *)
        positional_count=$((positional_count + 1))
        if [[ ${positional_count} -gt 1 ]]; then
          echo "Too many positional arguments: $*" >&2
          return 1
        fi
        TARGET_DIR="$1"
        ;;
    esac
    shift
  done
  # 解析为绝对规范路径（消除 . / 相对路径 / macOS /var→/private/var 符号链接歧义）
  TARGET_DIR="$(cd "${TARGET_DIR}" 2>/dev/null && pwd -P || echo "${TARGET_DIR}")"
}

# vg_build_diff_linemap OUTPUT_FILE [EXT_FILTER]
#
# 构建 diff 新增行号索引文件（每行格式: "filepath:linenum"）。
# 用于 baseline 扫描：只报告本次 diff 新增的问题，不报告既有问题。
#
# pre-commit 模式（VIBEGUARD_STAGED_FILES 已设置）: 读取 git diff --cached
# baseline  模式（BASELINE_COMMIT 已设置）        : 读取 git diff BASELINE..HEAD
#
# 返回: 0 = 成功（linemap 可能为空）；1 = 不在任何 diff 模式
vg_build_diff_linemap() {
  local out="$1"
  local ext_filter="${2:-}"
  : > "$out"

  command -v python3 >/dev/null 2>&1 || return 1

  local staged="${VIBEGUARD_STAGED_FILES:-}"
  local baseline="${BASELINE_COMMIT:-}"
  [[ -z "$staged" && -z "$baseline" ]] && return 1

  VG_STAGED="$staged" VG_BASELINE="$baseline" VG_EXT="$ext_filter" VG_OUT="$out" \
  python3 -c '
import sys, re, subprocess, os

staged     = os.environ.get("VG_STAGED", "")
baseline   = os.environ.get("VG_BASELINE", "")
ext_filter = os.environ.get("VG_EXT", "")
out_path   = os.environ.get("VG_OUT", "")

_git_root_cache = {}

def get_git_root(dirpath):
    """Detect git root from a directory; returns canonical absolute path."""
    key = os.path.realpath(dirpath)
    if key not in _git_root_cache:
        r = subprocess.run(
            ["git", "-C", key, "rev-parse", "--show-toplevel"],
            capture_output=True, text=True
        )
        _git_root_cache[key] = os.path.realpath(r.stdout.strip()) if r.returncode == 0 else ""
    return _git_root_cache[key]

def iter_files():
    if staged and os.path.isfile(staged):
        with open(staged) as fh:
            for line in fh:
                p = os.path.realpath(line.strip())
                if p and (not ext_filter or re.search(ext_filter, p)):
                    yield p
    elif baseline:
        root = get_git_root(".")
        if not root:
            return
        result = subprocess.run(
            ["git", "-C", root, "diff", "--name-only", baseline + "..HEAD"],
            capture_output=True, text=True
        )
        for fname in result.stdout.splitlines():
            if fname and (not ext_filter or re.search(ext_filter, fname)):
                yield os.path.join(root, fname)

def added_linenos(fpath):
    file_dir = os.path.dirname(fpath) or "."
    git_root = get_git_root(file_dir)
    if not git_root:
        return []
    if baseline:
        cmd = ["git", "-C", git_root, "diff", "-U0", baseline + "..HEAD", "--", fpath]
    else:
        cmd = ["git", "-C", git_root, "diff", "--cached", "-U0", "--", fpath]
    result = subprocess.run(cmd, capture_output=True, text=True)
    cur = 0
    nums = []
    for line in result.stdout.splitlines():
        if line.startswith("@@"):
            m = re.search(r"\+(\d+)(?:,(\d+))?", line)
            if m:
                cur = int(m.group(1))
                cnt = int(m.group(2)) if m.group(2) is not None else 1
                if cnt == 0:
                    cur = 0
        elif line.startswith("+++"):
            continue
        elif line.startswith("+"):
            if cur > 0:
                nums.append(cur)
                cur += 1
        elif not line.startswith("-") and not line.startswith("\\\\"):
            if cur > 0:
                cur += 1
    return nums

with open(out_path, "w") as out:
    for fpath in iter_files():
        if not os.path.isfile(fpath):
            continue
        for n in added_linenos(fpath):
            out.write(fpath + ":" + str(n) + "\n")
' 2>/dev/null || true
  return 0
}

# 临时文件清理目录：所有守卫共享同一清理 trap
_VG_TMPDIR=""

_vg_cleanup() {
  [[ -n "$_VG_TMPDIR" && -d "$_VG_TMPDIR" ]] && rm -rf "$_VG_TMPDIR" || true
}
trap '_vg_cleanup' EXIT

# 创建临时文件并自动在脚本退出时清理
# 用法: TMPFILE=$(create_tmpfile)
create_tmpfile() {
  if [[ -z "$_VG_TMPDIR" ]]; then
    _VG_TMPDIR=$(mktemp -d)
  fi
  mktemp "$_VG_TMPDIR/vg.XXXXXX"
}

# ---------------------------------------------------------------------------
# Inline suppression: // vibeguard-disable-next-line <RULE-ID> [-- reason]
# ---------------------------------------------------------------------------

# check_suppression FILE LINE_NUM RULE_ID
# Returns 0 (suppressed) if the line before LINE_NUM has a disable comment for RULE_ID.
# In pre-commit mode (VIBEGUARD_STAGED_FILES set) reads from staged content so that
# unstaged suppression comments cannot bypass checks on staged violations.
check_suppression() {
  local file="$1" line_num="$2" rule_id="$3"
  local prev=$((line_num - 1))
  [[ $prev -lt 1 ]] && return 1
  local prev_line
  if [[ -n "${VIBEGUARD_STAGED_FILES:-}" ]]; then
    # Pre-commit mode: read from staged content, not the working tree.
    # git show ":path" requires a path relative to the repo root.
    # Use python3 realpath resolution to handle macOS /var→/private/var symlinks.
    local rel_file="$file"
    if [[ "$file" == /* ]]; then
      local git_root
      git_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
      if [[ -n "$git_root" ]]; then
        if command -v python3 >/dev/null 2>&1; then
          rel_file=$(python3 -c "import os,sys; f=os.path.realpath(sys.argv[1]); r=os.path.realpath(sys.argv[2]); print(f[len(r)+1:] if f.startswith(r+os.sep) else sys.argv[1])" "$file" "$git_root" 2>/dev/null || echo "$file")
        else
          [[ "$file" == "$git_root/"* ]] && rel_file="${file#$git_root/}"
        fi
      fi
    fi
    prev_line=$(git show ":${rel_file}" 2>/dev/null | sed -n "${prev}p" || true)
  else
    [[ ! -f "$file" ]] && return 1
    prev_line=$(sed -n "${prev}p" "$file" 2>/dev/null || true)
  fi
  if printf '%s' "$prev_line" \
      | grep -qE "^[[:space:]]*//[[:space:]]*vibeguard-disable-next-line[[:space:]]+${rule_id}([[:space:]]|--|$)"; then
    return 0
  fi
  return 1
}

# apply_suppression_filter TMPFILE
# Reads findings from TMPFILE in format "[RULE-ID] file:line ..." and removes those
# suppressed by a vibeguard-disable-next-line comment on the preceding source line.
# Modifies TMPFILE in-place.
apply_suppression_filter() {
  local tmpfile="$1"
  [[ ! -s "$tmpfile" ]] && return 0

  local filtered_file
  filtered_file=$(create_tmpfile)

  while IFS= read -r finding; do
    local rule_id
    rule_id=$(printf '%s' "$finding" | sed -n 's/^\[\([^]]*\)\].*/\1/p')

    if [[ -z "$rule_id" ]]; then
      printf '%s\n' "$finding" >> "$filtered_file"
      continue
    fi

    local rest
    rest="${finding#\[${rule_id}\] }"

    local line_num
    line_num=$(printf '%s' "$rest" | grep -oE ':[0-9]+' | head -1 | tr -d ':' || true)

    if [[ -z "$line_num" ]]; then
      printf '%s\n' "$finding" >> "$filtered_file"
      continue
    fi

    local file_path
    file_path=$(printf '%s' "$rest" | sed "s/:${line_num}.*$//")

    if [[ ! -f "$file_path" ]]; then
      printf '%s\n' "$finding" >> "$filtered_file"
      continue
    fi

    if check_suppression "$file_path" "$line_num" "$rule_id"; then
      continue  # suppressed — skip this finding
    fi

    printf '%s\n' "$finding" >> "$filtered_file"
  done < "$tmpfile"

  cp "$filtered_file" "$tmpfile"
}
