---
name: awk-posix-compat
description: |
  Shell 脚本中 awk 的 POSIX 兼容性指南。
  Use when: 编写或审查包含 awk 的 shell 脚本，
  尤其是需要 macOS + Linux 跨平台运行的场景。
  触发词: awk, BSD awk, POSIX regex, [[:space:]],
  guard 脚本, 跨平台 shell
author: Claude Code
version: 1.0.0
date: 2026-04-03
---

# awk POSIX 兼容性指南

## Problem

macOS 自带 BSD awk 严格遵循 POSIX 标准，不支持 GNU awk (gawk) 的正则扩展。
在 Linux (gawk) 开发、macOS (BSD awk) 运行时**静默匹配失败** — 无报错但结果为空。

这类 bug 极难调试：脚本不报错，只是检测不到任何匹配，看起来像"没有问题"。

## Context / Trigger Conditions

- 编写包含 `awk '...'` 的 shell 脚本
- 脚本需要在 macOS + Linux 上运行
- 使用 awk 正则做代码模式检测（guard/linter/hook）
- 错误现象：Linux 上能检测到问题，macOS 上检测为 0

## Solution

### 1. 正则替换规则（6 条）

| GNU awk 扩展 | POSIX 替代 | 说明 |
|-------------|------------|------|
| `\s` | `[[:space:]]` | 空白字符 |
| `\S` | `[^[:space:]]` | 非空白字符 |
| `\d` | `[0-9]` | 数字 |
| `\w` | `[A-Za-z0-9_]` | 单词字符 |
| `\b` | `[[:<:]]` / `[[:>:]]` | 词边界（BSD 语法） |
| `\+` | `{1,}` 或重写模式 | 一次或多次 |

```bash
# ❌ BAD — gawk 扩展，BSD awk 静默失败
awk '/\s+defer\s/' "$file"

# ✅ GOOD — POSIX 兼容
awk '/[[:space:]]+defer[[:space:]]/' "$file"
```

### 2. 字符级计数（gsub 法则）

禁止行级正则匹配计数大括号：

```bash
# ❌ BAD — 单行多个 { 时只计 1 次
awk '/\{/ { depth++ }' "$file"

# ✅ GOOD — gsub 返回替换次数 = 精确字符数
awk '{
  tmp = $0; opens = gsub(/\{/, "", tmp)
  tmp = $0; closes = gsub(/\}/, "", tmp)
  depth += opens - closes
}' "$file"
```

**原因**：`/{/` 是行级匹配 — 一行有 `func() { if x {` 两个 `{`，行级只计 1 次，导致 depth 跟踪错误，后续作用域判断全部偏移。

### 3. 作用域隔离（嵌套结构检测）

检测"X 在 Y 内"的模式（如 `defer` 在 `for` 循环内）时，需要区分语法层级：

```bash
# 需要 flit_depth 变量跟踪 func literal 嵌套
# go func() { defer f.Close() }() 在 for 循环内是安全的
# 因为 defer 绑定到 func literal 而非外层 for

if (is_func_literal && loop_depth > 0) {
  flit_depth++
  flit_base[flit_depth] = total_depth  # 记录进入时的 brace 深度
}

# defer 只在 loop_depth > 0 且 flit_depth == 0 时才报警
```

## Verification

```bash
# 1. 运行 portability check
bash scripts/setup/check.sh
# → "Guard Script Portability" 段应全绿

# 2. 手动扫描违规
find guards/ -name '*.sh' -print0 \
  | xargs -0 grep -rnE '/[^/"]*\\[sdwb]' \
  | grep -vE '^\s*#|grep |sed '
# → 期望输出为空（0 violations）
```

## Example

**场景**：`check_defer_in_loop.sh` 在 macOS 上检测不到任何 defer-in-loop 问题

**Before**（3 个 bug）：
```awk
# Bug 1: \s 在 BSD awk 静默失败
if (match(line, /^\s*for(\s|$)/))

# Bug 2: 行级计数漏计
/\{/ { total_depth++ }

# Bug 3: go func(){defer} 误报
if (match(line, /defer/) && loop_depth > 0)  # 无 flit_depth 判断
```

**After**（全部修复）：
```awk
# Fix 1: POSIX 字符类
if (match(line, /^[[:space:]]*for([[:space:]]|$)/))

# Fix 2: gsub 字符级计数
tmp = line; opens = gsub(/\{/, "", tmp)
tmp = line; closes = gsub(/\}/, "", tmp)
total_depth += opens - closes

# Fix 3: func literal 作用域隔离
if (match(line, /defer/) && loop_depth > 0 && flit_depth == 0)
```

## Notes

- BSD awk 的 `\b` 词边界语法是 `[[:<:]]`（词首）和 `[[:>:]]`（词尾），与 gawk 的 `\b` 不同
- `IGNORECASE = 1` 是 gawk 扩展，POSIX awk 不支持 — 用 `tolower()` 替代
- macOS 上 `awk` 就是 BSD awk；即使安装了 `gawk`，脚本中写 `awk` 仍调用 BSD 版本
- 自动检测已集成到 `scripts/setup/check.sh`（"Guard Script Portability" 段）

## References

- 来源项目：vibeguard commit `6c5b652`（2026-04-02）
- 涉及文件：`guards/go/check_defer_in_loop.sh`、`guards/rust/check_semantic_effect.sh`
- POSIX 正则标准：IEEE Std 1003.1 (ERE)
