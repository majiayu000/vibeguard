# VibeGuard 系统性问题报告与改进路线图

> 基于 40 天运行数据（2026-02-18 → 2026-03-23）、39,166 条事件日志、124 个 commit 的全面复盘。
> 10 个并行子 agent 搜索行业最佳实践（ast-grep、Semgrep、Clippy、Claude Code hooks、GaaS 论文、OpenAI Baker et al.）。
> 生成日期：2026-03-23

## 运行数据概览

```
总事件数:     39,166
决策分布:     pass 35,661 (91.0%) | warn 2,238 (5.7%) | escalate 649 (1.7%)
              correction 266 (0.7%) | gate 196 (0.5%) | block 156 (0.4%)
项目覆盖:     148 个项目目录
Hook 触发:    pre-bash 21,870 | analysis-paralysis 4,596 | post-edit 4,386
              pre-edit 3,836 | post-write 1,458 | post-build 1,215
```

---

## 一、守卫误报（根因：grep ≠ AST）

**影响**: 7+ 守卫误报已修复，2 个被迫禁用/移除

### 1.1 问题清单

| 守卫 | 误报场景 | 根因 | 状态 |
|------|---------|------|------|
| RS-14 声明-执行鸿沟 | 注释/变量/外部 trait 误匹配 | `rg -A 50` + grep 行数 ≠ struct 字段计数 | 已禁用 (exit 0) |
| U-HARDCODE 硬编码检测 | `= "POST"`、枚举、i18n key 全误报 | 正则无法区分字符串语义 | 已移除 |
| TS-01 any 检测 | 块注释和字符串内的 `: any` | grep 不识别注释/字符串边界 | 已修复（追加过滤） |
| TS-03 console 残留 | CLI 项目的 `console.log` 是正常输出 | 不识别项目类型（CLI vs Web） | 已修复（检测 bin 字段） |
| GO-02 goroutine 枚举 | 所有 `go func()` 全量报告 | 只枚举不检测风险 | 已修复（启发式过滤） |
| GO-01 error 处理 | `for _, v := range` 的 `_` 误报 | 正则不理解 range 语义 | 已修复（排除 range） |
| TS-13 组件重复 | HTML 原生属性、标准状态管理 | 特征过宽 | 已修复（收紧阈值） |

**未修复 P2** (9 个): RS-03 多 cfg(test)、RS-01 clone 计数错误、RS-06 字符串常量、RS-12 TodoList 数据结构、TASTE-ASYNC-UNWRAP 全文件标记、post-write 目录误命中、post-write 正则跨语言污染、post-build 跨项目无隔离、doc-file-blocker 临时路径

### 1.2 根因分析（5-Why）

```
表面原因: 守卫输出误报
  ↓ Why?
直接原因: grep/正则匹配无法区分代码结构（注释 vs 代码 vs 字符串）
  ↓ Why?
系统原因: 守卫基于文本匹配而非语法树
  ↓ Why?
设计选择: 项目初期选择 bash + grep 以保持零依赖、快速启动
  ↓ Why?
根本原因: 缺少"守卫成熟度阶梯" — grep 守卫适合 MVP，但需要升级路径到 AST 工具
```

### 1.3 改进方案：ast-grep 迁移路径

**推荐工具**: [ast-grep](https://ast-grep.github.io/) — 基于 tree-sitter 的多语言 AST 搜索，CLI 友好，零运行时依赖。

**迁移优先级**:

| P0 (误报率 >50%) | 工具 | ast-grep rule 示例 |
|-------------------|------|-------------------|
| RS-14 struct 字段检测 | ast-grep | `pattern: "struct $NAME { $$$ }"` |
| TS-01 any 检测 | ast-grep | `pattern: ": any"`, `kind: type_annotation` |
| TASTE-ASYNC-UNWRAP | ast-grep | `pattern: "$EXPR.unwrap()"`, `inside: { kind: async_block }` |

**渐进迁移策略**:
```
Phase 1: 安装 ast-grep，为 P0 守卫写 YAML 规则
Phase 2: 新守卫默认用 ast-grep，grep 守卫保留
Phase 3: 高误报 grep 守卫逐个替换为 ast-grep
Phase 4: grep 仅用于纯文本检测（文件名、配置值）
```

**ast-grep 集成模式** (bash 脚本内调用):
```bash
# 替代 grep 的调用方式
ast-grep --pattern '$EXPR.unwrap()' --lang rust --json \
  | jq -r '.[] | "\(.file):\(.range.start.line): [RS-03] unwrap in prod code"'
```

### 1.4 改进方案：误报率管理体系

借鉴 Semgrep 的 **severity × confidence 矩阵**:

| | confidence: high | confidence: medium | confidence: low |
|---|---|---|---|
| severity: error | **block** | **warn + review** | warn |
| severity: warning | warn | info | suppress |
| severity: info | info | suppress | suppress |

**规则毕业制度**:
```
experimental (7天) → warn (30天,FP<10%) → error (稳定,FP<5%) → 降级/退役 (FP>20%)
```

**精度追踪**: 每条规则记录 `{true_positive, false_positive, suppressed}` 计数，月度计算 precision = TP / (TP + FP)。

---

## 二、Hook 系统 Bug

**影响**: 6 个 bug，包含 1 个死循环

### 2.1 问题清单

| 问题 | 根因 | 事件数据佐证 | 状态 |
|------|------|-------------|------|
| Stop hook exit 2 无限循环 | exit 2 反馈给 Claude，Claude 无工具可解决 | — | 已修复 |
| Escalation 跨 session 误触发 | warn 计数不区分 session | 649 escalate 事件 | 已修复 |
| 子目录 commit 语言检测失败 | 相对路径 `Cargo.toml` | 67 block "guard fail" | 已修复 |
| git checkout ./path 误拦 | 正则缺行尾锚定 | 40 block "pre-commit check failed" | 已修复 |
| force push 误拦 | 项目级允许但守卫全局禁止 | 6 block "禁止 force push" | 已修复 |
| analysis paralysis 噪声 | 连续 7+ 只读就报警 | 437x warn (所有 paralysis 级别) | 需调优 |

### 2.2 根因分析

```
表面原因: Hook 行为异常（循环、误触发、跨边界）
  ↓ Why?
直接原因: Hook 设计缺少三个关键保护：上下文感知、重入防护、作用域隔离
  ↓ Why?
根本原因: Hook exit code 语义不完整 — exit 2 "要求 Claude 修复"但未检查 Claude 是否有能力修复
```

### 2.3 改进方案：Hook 安全设计原则

**原则 1: Exit 2 可用性前提检查**
```bash
# Stop hook 中禁止 exit 2，除非条件可被 Claude 在当前上下文自行解决
# PreToolUse/PostToolUse 中 exit 2 安全（Claude 有完整工具权限）
hook_context_safe_for_exit2() {
    case "$HOOK_TYPE" in
        Stop) return 1 ;;  # Stop 上下文无工具，禁用 exit 2
        PreToolUse|PostToolUse) return 0 ;;  # 有工具，允许
    esac
}
```

**原则 2: 重入防护（Circuit Breaker）**
```bash
HOOK_ATTEMPT_FILE="/tmp/vibeguard-${HOOK_NAME}-attempts"
ATTEMPTS=$(cat "$HOOK_ATTEMPT_FILE" 2>/dev/null || echo 0)
if [ "$ATTEMPTS" -ge 3 ]; then
    echo "Circuit breaker: $HOOK_NAME triggered $ATTEMPTS times, degrading to warn" >&2
    exit 0  # 降级为不阻塞
fi
echo $((ATTEMPTS + 1)) > "$HOOK_ATTEMPT_FILE"
```

**原则 3: Session 作用域隔离**
```bash
# 所有计数器必须包含 session ID
SESSION_ID="${CLAUDE_SESSION_ID:-$(date +%Y%m%d_%H%M%S)_$$}"
COUNTER_FILE="$STATE_DIR/${SESSION_ID}_${HOOK_NAME}_count"
```

---

## 三、状态跨边界泄漏

**影响**: 3 个问题，escalation 误触发最严重（649 次）

### 3.1 问题模式

| 泄漏类型 | 具体表现 | 事件数据 |
|----------|---------|---------|
| 跨 session | warn 计数累积，新 session 立即 escalate | 649 escalate |
| 跨项目 | 构建失败计数不区分项目 | 197+54+29 build warn |
| 跨时间 | session 计数用递增代替真实文件计数 | — |

### 3.2 改进方案：三层状态隔离

```
全局状态  ~/.vibeguard/events.jsonl           — 所有事件的追加日志
项目状态  ~/.vibeguard/projects/<hash>/        — 项目级 metrics
会话状态  /tmp/vibeguard-<session_id>/         — session 级计数器（临时目录，自动清理）
```

**状态键命名规范**:
```
<scope>_<hook>_<metric>
例: session_post-build_fail_count
    project_pre-commit_guard_fail_total
    global_events_total
```

**Session ID 来源优先级**:
```
1. $CLAUDE_SESSION_ID (Claude Code 注入)
2. $VIBEGUARD_SESSION_ID (用户设置)
3. 基于 JSONL 文件名推导
4. fallback: date +%Y%m%d_%H%M%S_$$
```

---

## 四、Guard 消息被 AI Agent 字面执行

**影响**: TS-03 建议"用 logger 替代" → Agent 创建 logger 并重构 11 个文件

### 4.1 根因

守卫消息为人类设计（"使用项目 logger 替代"），但消费者是 AI Agent。Agent 将建议解读为指令，执行了全量重构。

### 4.2 改进方案：Agent-Aware 消息格式

**消息模板 v2**:
```
[GUARD_ID] OBSERVATION: <客观描述问题>
SCOPE: <仅修改当前文件 | 仅修改当前行 | 不需要修改>
ACTION: <REVIEW（人工审查）| FIX-LINE（修复这一行）| SKIP（此场景可忽略）>
REASON: <为什么标记>
```

**对比**:
```
# ❌ v1 — Agent 当指令执行
[TS-03] src/cli.ts:42 console 残留。修复：使用项目 logger 替代，或删除调试代码

# ✅ v2 — Agent 理解为信息
[TS-03] OBSERVATION: src/cli.ts:42 uses console.log
SCOPE: REVIEW-ONLY — do NOT create new files or refactor
ACTION: SKIP if this is a CLI project (bin field in package.json)
REASON: console.log may be intentional output in CLI tools
```

**关键原则**:
1. **OBSERVATION 不是 INSTRUCTION** — 描述事实，不给修复命令
2. **SCOPE 限定行动范围** — 明确告诉 Agent "不要扩大范围"
3. **提供 SKIP 条件** — 让 Agent 自行判断是否需要行动
4. **禁止在消息中写"替代方案"** — Agent 会把替代方案当作要求执行的重构

---

## 五、分发渠道文件遗漏

**影响**: npm 漏目录 ×2，Docker 漏依赖 ×2，符号链接未解析 ×1

### 5.1 根因

手动维护 `files` 列表 + 无自动校验 = 新增目录必然遗漏。

### 5.2 改进方案：四层发布防线

| 层 | 工具 | 检测点 |
|----|------|--------|
| 1. 声明 | `package.json` `files` 白名单 | 新目录必须加入 |
| 2. 静态校验 | `npm pack --dry-run` + `publint` | CI 自动运行 |
| 3. 冒烟测试 | `npm pack` → 解压 → 检查必要目录存在 | CI 自动运行 |
| 4. 发布后验证 | `npm install <pkg>@latest` → require 测试 | CI 发布后步骤 |

**CI 集成** (`prepublishOnly`):
```json
{
  "scripts": {
    "prepublishOnly": "bash scripts/verify-package-contents.sh && npx publint ."
  }
}
```

**必要目录检查脚本** (`scripts/verify-package-contents.sh`):
```bash
#!/usr/bin/env bash
set -euo pipefail
REQUIRED_DIRS=("hooks" "guards" "rules" "scripts" ".claude/commands")
TMPDIR=$(mktemp -d)
npm pack --pack-destination "$TMPDIR" --quiet
TARBALL=$(ls "$TMPDIR"/*.tgz)
tar -xzf "$TARBALL" -C "$TMPDIR"
errors=0
for dir in "${REQUIRED_DIRS[@]}"; do
  if [ ! -d "$TMPDIR/package/$dir" ]; then
    echo "ERROR: 缺少目录 $dir"; errors=$((errors + 1))
  fi
done
rm -rf "$TMPDIR"
[ "$errors" -gt 0 ] && exit 1
echo "PASSED: 包完整性检查通过"
```

**Docker 构建时完整性校验**:
```dockerfile
# 在 runtime stage 中加入校验层
RUN node -e " \
  const fs = require('fs'); \
  const required = ['hooks', 'guards', 'rules', 'scripts']; \
  const missing = required.filter(p => !fs.existsSync(p)); \
  if (missing.length) { console.error('MISSING:', missing); process.exit(1); } \
"
```

---

## 六、跨平台 Shell 兼容性

**影响**: Windows CI 失败 ×3

### 6.1 问题清单

| 问题 | 平台 | 根因 |
|------|------|------|
| PowerShell glob 展开 | Windows | `*.test.sh` 被 PowerShell 展开 |
| UnicodeEncodeError | Windows | Python stdout 默认编码非 UTF-8 |
| CRLF 换行 | Windows | bash 脚本含 `\r` 导致解析失败 |
| `GUARDS_DIR` 路径含空格 | 全平台 | 变量未引用 |

### 6.2 决策框架："修 Shell" vs "迁移运行时"

| 维度 | 修 Shell | 迁移到 Node.js/Deno |
|------|---------|-------------------|
| 短期成本 | 低（逐个修复） | 高（全部重写） |
| 长期维护 | 高（持续踩坑） | 低（原生跨平台） |
| 依赖 | 零（bash 内置） | 需要 Node.js 运行时 |
| AST 能力 | 无（只能 grep） | 可集成 tree-sitter |
| 用户安装 | 简单（bash 自带） | 需要 npm install |

**推荐**: **混合策略** — bash 守卫保留用于简单检测（文件存在、命名规范），复杂代码分析迁移到 ast-grep（跨平台二进制）。

**立即可做的 Shell 加固**:
```bash
# 1. 所有变量引用
"${GUARDS_DIR}" 而非 ${GUARDS_DIR}

# 2. .gitattributes 强制 LF
*.sh text eol=lf

# 3. CI 中设置 UTF-8
env:
  PYTHONIOENCODING: utf-8

# 4. 显式 shell 指定
- run: bash scripts/test.sh
  shell: bash
```

---

## 七、Claude Code 平台级 Bug

**影响**: 3 个 OPEN issue 需要 workaround

| Issue | 问题 | VibeGuard 应对 | 监控 |
|-------|------|---------------|------|
| #21858 | `paths:` YAML 数组解析 broken | CSV 格式 workaround | 定期检查修复状态 |
| #16299 | 项目级 paths 全局加载 | 不影响用户级规则 | — |
| #13905 | YAML `*` 保留字符无效 | CSV 格式绕过 | — |

**YAML frontmatter 安全写法**:
```yaml
# ✅ 唯一可靠格式（CSV 单行，无引号，无空格）
---
paths: **/*.ts,**/*.tsx,**/*.js,**/*.jsx
---

# ❌ 全部不可靠
paths: ["**/*.ts"]          # YAML 数组 — broken
paths: "**/*.ts"            # 引号值 — broken
paths:                      # 多行数组 — broken
  - "**/*.ts"
```

---

## 改进路线图

### P0（本周）

- [ ] **Guard 消息格式 v2**: 所有守卫输出改为 `OBSERVATION + SCOPE + ACTION` 格式
- [ ] **Session 隔离**: 计数器加 session ID，escalation 仅在当前 session 内生效
- [ ] **npm 发布防线**: 添加 `verify-package-contents.sh` + `prepublishOnly` 钩子

### P1（两周内）

- [ ] **ast-grep 引入**: 为 TS-01(any)、RS-03(unwrap) 写 ast-grep 规则替代 grep
- [ ] **规则毕业制度**: 新规则默认 experimental，7 天后按 FP 率升级/降级
- [ ] **Hook circuit breaker**: 所有 exit 2 hook 加重入计数器（≥3 次降级）

### P2（一个月内）

- [ ] **精度追踪系统**: 每条规则 TP/FP 计数，月度精度报告
- [ ] **Docker 构建完整性**: Dockerfile 加 RUN 校验层
- [ ] **.gitattributes**: `*.sh text eol=lf` 防 CRLF
- [ ] **RS-14 重写**: 用 ast-grep 替代 `rg -A 50` 重写声明-执行鸿沟检测

### P3（长期）

- [ ] **复杂守卫迁移到 ast-grep**: 所有语义分析类守卫从 grep 迁移
- [ ] **Suppression 注释**: 支持 `// vibeguard-disable-next-line RS-03`
- [ ] **Baseline 模式**: 只对 diff 新增行报警，忽略存量问题

---

## 附录：事件数据 Top 警告/拦截

### Top 15 Warn

| 次数 | Hook | 原因 |
|------|------|------|
| 437 | pre-write-guard | 新源码文件提醒 |
| 197 | post-build-check | 构建错误 1 个 |
| 104 | analysis-paralysis | paralysis 7x |
| 86 | analysis-paralysis | paralysis 8x |
| 67 | analysis-paralysis | paralysis 9x |
| 61 | analysis-paralysis | paralysis 10x |
| 54 | post-build-check | 构建错误 2 个 |
| 46 | analysis-paralysis | paralysis 11x |
| 34 | analysis-paralysis | paralysis 14x |
| 33 | pre-bash-guard | 非标准 .md 文件 |
| 33 | analysis-paralysis | paralysis 12x |
| 32 | analysis-paralysis | paralysis 13x |
| 29 | post-build-check | 构建错误 3 个 |
| 26 | analysis-paralysis | paralysis 15x |
| 23 | analysis-paralysis | paralysis 16x |

### Top 10 Block

| 次数 | Hook | 原因 |
|------|------|------|
| 67 | pre-commit-guard | guard fail |
| 40 | pre-bash-guard | pre-commit check failed |
| 18 | pre-write-guard | 新源码文件未搜索 |
| 10 | pre-edit-guard | old_string 不存在 |
| 6 | pre-bash-guard | 禁止 force push |
| 6 | pre-bash-guard | 禁止 rm -rf 危险路径 |
| 2 | pre-edit-guard | 文件不存在 |
| 2 | pre-commit-guard | guard fail, build fail |
| 2 | pre-bash-guard | 禁止 git reset --hard |
| 1 | pre-bash-guard | 禁止启动开发服务器 |

### 教训总结

1. **grep 不是 AST 解析器** — 对代码结构的分析不可接受，复杂检测必须用 AST 工具
2. **守卫消息是给 Agent 看的指令** — 不能写"替代方案"，Agent 会当真执行
3. **项目类型感知是基础能力** — CLI/Web/MCP/Library 有完全不同的合理模式
4. **枚举器不是检测器** — 只列出不判断风险，开发者和 Agent 都会养成忽略习惯
5. **状态必须带作用域** — 计数器没有 session/project scope = 必然跨边界泄漏
6. **白名单优于黑名单** — npm `files` 优于 `.npmignore`，显式声明优于隐式排除

---

## 附录 B：10 个子 Agent 搜索的关键发现

> 以下为 10 个并行 agent 搜索行业最佳实践后的核心结论。完整输出保存在 session task files 中。

### Agent 1: ast-grep 迁移方案

- **ast-grep YAML 规则已就绪**: 为 RS-03(unwrap)、TS-01(any)、GO-01(error)、TS-03(console) 写了完整 YAML 规则
- **核心优势**: `kind: type_annotation` 精确匹配代码节点，天然排除注释/字符串，消除 grep 的 4 层 `grep -v`
- **性能**: 万文件扫描 ~1-3s（grep ~0.1s，semgrep ~30-60s），是精确度/速度最优平衡
- **迁移策略**: 4 阶段渐进迁移，每规则约 30min + 15min 集成
- **关键限制**: 不支持跨语言单条规则；CLI 项目检测仍需外层脚本；`#[cfg(test)]` scope 需实测验证

### Agent 2: Hook 循环防护

- **5 个已知 Claude Code 陷阱**: Stop hook exit 2 死循环、`continue: true` 误用、CI 环境命令失败、`stop_hook_active` 未检查、exit 2 在 UI 显示为 "Error"
- **Circuit Breaker 三态模型**: CLOSED(正常) → OPEN(熔断跳过) → HALF-OPEN(试探)，适配到 hook 系统
- **可解决性矩阵**: 反馈前判断 Agent 是否有能力修复（Stop 上下文无法 commit → 降级为 log）
- **来源**: Git hooks `--no-verify`、WordPress unhook-execute-rehook、VS Code `inhibit-modification-hooks`

### Agent 3: Session 状态隔离

- **发现具体 bug**: `post-build-check.sh:85-106` 连续失败计数**缺少 session 过滤**（P0，1 行修复）
- **Session ID 文件应改为项目级**: 从全局 `~/.vibeguard/.session_id` 改到 `${PROJECT_LOG_DIR}/.session_id`（P0，3 行）
- **POSIX `>>` 追加在单行写入时是原子的**: 只要 JSON 行 < 4KB (PIPE_BUF)，当前 vg_log 实现是并发安全的

### Agent 4: AI-Friendly 消息格式

- **6 个真实过度修复案例**: VibeGuard console→重构 11 文件、Clippy→替换整个渲染库、BitsAI-Fix→修改错误消息文本、Copilot→放弃 PR、Claude Code→`--no-verify` 绕过
- **Clippy Applicability 四级模型**: `MachineApplicable` > `MaybeIncorrect` > `HasPlaceholders` > `Unspecified`
- **DO NOT 字段是最关键的防御**: 每条消息必须包含明确禁止的过度行为
- **SARIF 标准**: severity/applicability/scope 三维分离，VibeGuard 可采用类似设计
- **研究**: BitsAI-Fix 论文确认"constrain edits strictly to locations implicated by the reported issue"

### Agent 5: npm/Docker 完整性

- **`files` 白名单优于 `.npmignore`**: Next.js, Vite, TypeScript, esbuild 全部使用 `files`
- **四层发布防线**: `npm pack --dry-run` → `publint` → `arethetypeswrong` → `pkg-ok`
- **Verdaccio 本地 registry**: 发布前先发到本地做完整验证
- **Docker multi-stage + RUN 层校验**: 构建时就发现文件遗漏，不等运行时

### Agent 6: 跨平台 Shell 兼容

- **决策**: 混合策略最优 — 简单检测保留 bash，复杂分析用 ast-grep（跨平台二进制）
- **立即做 3 件事**: `.gitattributes` (\*.sh eol=lf) + `PYTHONUTF8=1` + CI `shell: bash`
- **`dax` 库**: Deno/Node.js 的跨平台 shell，语法接近 bash 但真正跨平台（中期考虑）
- **macOS vs Linux sed**: 统一用 `sed -i.bak` + 删 .bak，或统一用 `sed -E`

### Agent 7: 误报率管理

- **Semgrep severity × confidence 矩阵**: severity(影响) 和 confidence(可靠度) 正交，CI 阻断应基于组合
- **规则毕业阶梯**: nursery(off) → warn(precision≥70%) → error(precision≥90%+50 样本+30 天无 FP)
- **triage 反馈闭环**: 新增 `triage.jsonl`，用户标记 tp/fp/acceptable，反馈到 rule-scorecard
- **Suppression 注释**: `// vibeguard-disable-next-line RS-03 -- reason`，检测前 grep 上一行
- **基线扫描**: pre-commit 只对 `git diff --cached` 新增行运行守卫

### Agent 8: AI 编码代理守卫架构

- **OpenAI Baker et al. 7 类 hack**: VibeGuard W-12 覆盖前 4 类，#5-7（反编译/提取期望值/库影子）需补充
- **GaaS 四级渐进执行**: Allow → Warn → Block → Escalate，信任因子随合规行为衰减
- **Claude Code `updatedInput`**: PreToolUse 可透明修改参数（如 `npm install` → `pnpm install`），比阻止+重试更优
- **受保护文件列表**: conftest.py/test config/覆盖率阈值设为不可修改，Agent 修改时立即阻止
- **PostToolUse 反馈的 `suppressOutput`**: 控制哪些反馈进入 Claude 上下文，避免信息过载

### Agent 9: YAML Frontmatter 陷阱

- **5 个已确认的 Claude Code bug**: #19377(YAML 数组)、#17204(引号保留)、#21858(用户级 paths 忽略)、#23478(Write 时不加载)、compaction 后 paths 失效
- **唯一可靠格式**: `paths: **/*.ts,**/*.tsx`（裸 CSV，无引号，无空格）
- **新发现 #23478**: `paths:` 规则仅在 Read 时加载，Write/Edit 时不加载（影响守卫范围）
- **Norway Problem**: YAML 1.1 将 `NO` 解析为 `false`，有 22 种布尔写法

### Agent 10: Semgrep/Tree-sitter 替代方案

- 研究被 Agent 7 (ast-grep) 覆盖，ast-grep 是最优选择（精确度高于 grep，速度优于 semgrep）
