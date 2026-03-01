# VibeGuard

让 AI 写代码时不再瞎编。

用 Claude Code / Codex 写代码时，AI 经常凭空捏造 API、重复造轮子、硬编码假数据、过度设计。VibeGuard 通过**规则注入 + 实时拦截 + 静态扫描**三道防线，从源头阻止这些问题。

设计受 [OpenAI Harness Engineering](https://openai.com/index/harness-engineering/) 和 [Stripe Minions](https://www.youtube.com/watch?v=bZ0z1ApYjJo) 启发，完整实现了 Harness 5 条 Golden Principles。

## 安装

```bash
git clone https://github.com/majiayu000/vibeguard.git ~/vibeguard
bash ~/vibeguard/setup.sh                 # 默认 core（推荐）
bash ~/vibeguard/setup.sh --profile full  # full：额外启用 Stop Gate + post-build-check
```

安装完成后新开一个 Claude Code 会话即生效。运行 `bash ~/vibeguard/setup.sh --check` 验证安装状态。

## 它做了什么

安装后，VibeGuard 在三个层面自动工作：

### 1. 规则注入（开会话就生效）

七层约束规则自动追加到 `~/.claude/CLAUDE.md`（用户级全局配置）。Claude Code 启动时会加载所有层级的 CLAUDE.md 并叠加生效，不会互相覆盖：

```
企业级  /Library/Application Support/ClaudeCode/CLAUDE.md   ← IT 部署
用户级  ~/.claude/CLAUDE.md                                  ← VibeGuard 规则在这里
项目级  ./CLAUDE.md 或 ./.claude/CLAUDE.md                   ← 项目特定约束
本地    ./CLAUDE.local.md                                    ← 个人配置（自动 gitignore）
子目录  ./subdir/CLAUDE.md                                   ← 懒加载，访问时才加载
```

所有层级全部 concatenate 进 AI 的 context，**VibeGuard 全局规则和项目规则天然共存**。项目的 CLAUDE.md 可以补充项目特定约束（比如"用 pnpm 不用 npm"），VibeGuard 继续保护底线。如果指令冲突，Claude 倾向于遵守更具体的那条。

七层约束：

| 层 | 约束 | 效果 |
|----|------|------|
| L1 | 先搜后写 | 新建文件/类/函数前必须先搜索已有实现，防止重复造轮子 |
| L2 | 命名约束 | Python 内部 snake_case，API 边界 camelCase，禁止任何别名 |
| L3 | 质量基线 | 禁止静默吞异常，公开方法禁 `Any` 类型 |
| L4 | 数据真实 | 无数据就显示空白，不硬编码，不发明不存在的 API |
| L5 | 最小改动 | 只做被要求的事，不加额外"改进" |
| L6 | 流程约束 | 大改动先 preflight，完成后 check |
| L7 | 提交纪律 | 禁 AI 标记、force push、向后兼容 |

规则使用**否定约束**（"不存在 X"）隐式引导 AI，比肯定描述更有效（Golden Principle #5: 给地图不给手册）。

### 2. Hooks 实时拦截（写代码时自动触发）

不需要手动运行，AI 操作时自动拦截：

| 场景 | 触发 | 结果 |
|------|------|------|
| AI 要创建新的 `.py/.ts/.rs/.go/.js` 文件 | `pre-write-guard` | **拦截** — 必须先搜索是否已有类似实现 |
| AI 要执行 `git push --force`、`rm -rf`、`reset --hard` | `pre-bash-guard` | **拦截** — 给出安全替代方案 |
| AI 要编辑不存在的文件 | `pre-edit-guard` | **拦截** — 先 Read 确认文件内容 |
| AI 编辑后新增了 `unwrap()`、硬编码路径 | `post-edit-guard` | **警告** — 给出具体修复方法 |
| AI 编辑后新增了 `console.log` / `print()` 调试语句 | `post-edit-guard` | **警告** — 提示使用 logger |
| AI 想结束但有未验证的源码变更（`full` profile） | `stop-guard` | **门禁** — 提醒完成验证后再结束 |

每个 Hook 执行自动记录耗时（`duration_ms`）和 agent 类型到日志，支持性能监控。

### 3. MCP 工具（按需调用）

AI 可在会话中主动调用这些工具检查代码质量：

- `guard_check` — 运行指定语言的守卫脚本
- `guard_check` 支持语言：`python | rust | typescript | javascript | go | auto`
- `compliance_report` — 项目合规检查报告
- `metrics_collect` — 采集代码指标

## 命令

10 个自定义命令，覆盖从需求到运维的全生命周期：

| 命令 | 用途 |
|------|------|
| `/vibeguard:interview` | 大功能需求深度采访，输出 SPEC.md |
| `/vibeguard:exec-plan` | 长周期任务执行计划，支持跨会话恢复 |
| `/vibeguard:preflight` | 修改前生成约束集，从源头预防问题 |
| `/vibeguard:check` | 全量守卫扫描 + 合规报告 |
| `/vibeguard:review` | 结构化代码审查（安全→逻辑→质量→性能） |
| `/vibeguard:cross-review` | 双模型对抗审查（Claude + Codex） |
| `/vibeguard:build-fix` | 构建错误修复 |
| `/vibeguard:learn` | 从错误生成守卫规则 / 从发现提取 Skill |
| `/vibeguard:gc` | 垃圾回收（日志归档 + worktree 清理 + 代码垃圾扫描） |
| `/vibeguard:stats` | Hook 触发统计 |

### 推荐工作流

```
interview（采访）→ exec-plan（计划）→ preflight（预防）→ 编码 → check（验证）→ review（审查）→ learn（闭环）→ stats（观测）
```

### 复杂度路由

根据改动规模自动选择流程深度：

| 规模 | 流程 |
|------|------|
| 1-2 文件 | 直接实现 |
| 3-5 文件 | `/vibeguard:preflight` → 约束集 → 实现 |
| 6+ 文件 | `/vibeguard:interview` → SPEC → `/vibeguard:preflight` → 实现 |

## Harness Engineering — 五条 Golden Principles 实现

VibeGuard 完整实现了 OpenAI Harness Engineering 的 5 条 Golden Principles：

### 1. Agent 看不到的等于不存在

所有决策写进仓库，不留在 Slack 或脑子里：

- CLAUDE.md 七层规则 — AI 启动时自动加载
- ExecPlan Decision Log — 长周期任务的决策全部记录在文档中
- preflight 约束集 — 编码前的约束以文档形式固化

### 2. 问"缺什么能力"而非"为什么失败"

遇到问题时补能力，不写更好的 prompt：

- `/vibeguard:learn` — 从错误自动生成新守卫规则，能力增量积累
- learn-evaluator Hook — 会话结束时评估是否有可提取的经验
- Skill 系统 — 提取的经验保存为 Skill，未来自动复用

### 3. 机械执行 > 文档描述

能用脚本检测的就写脚本，不靠 AI 自觉：

- Pre/Post Hooks — 实时拦截，不可绕过
- 依赖层 Linter (`check_dependency_layers.py`) — 检测跨层违规，错误信息**包含修复指令**
- 循环依赖检测 (`check_circular_deps.py`) — 构建模块依赖图，检测环路
- 代码垃圾扫描 (`check_code_slop.sh`) — 检测空 catch、遗留调试、过期 TODO、死代码

### 4. 给 Agent 一双眼睛

可观测栈让 AI 从数据发现问题：

- `hooks/log.sh` — 每次操作记录时间戳、耗时（ms）、agent 类型、session ID
- `scripts/metrics-exporter.sh` — 输出 Prometheus 格式指标，支持 Pushgateway
- `templates/alerting-rules.yaml` — 4 条告警规则（违规率、Hook 超时、不活跃、Block 突增）
- `/vibeguard:stats` — Hook 触发统计分析

### 5. 给地图不给手册

渐进披露，索引精简，详细规则按需加载：

- `vibeguard-rules.md` 控制在 32 行 — 只放索引，详细规则在 `rules/` 目录
- 否定约束 — "不存在 ORM"、"不存在别名"比"请使用 X"更有效
- 路径作用域规则 — 不同目录自动加载不同约束，减少无关 token
- `templates/AGENTS.md` — 为 OpenAI Codex 用户提供等价约束文件

## ExecPlan — 长周期任务执行计划

跨会话的大任务需要自包含的执行文档，仅凭自身即可在新会话中恢复执行：

```
/vibeguard:exec-plan init [spec路径]     # 从 SPEC 生成 ExecPlan
/vibeguard:exec-plan status <路径>       # 查看进度
/vibeguard:exec-plan update <路径>       # 追加决策/发现/完成状态
```

ExecPlan 8 节结构：Purpose → Progress → Context → Plan of Work → Concrete Steps → Validation → Idempotence → Execution Journal

完整流水线：`interview → SPEC → exec-plan → preflight → 执行 → exec-plan update`

## 垃圾回收（GC）

防止 AI 代码垃圾和运行时垃圾积累（参考 Harness GC Agent）：

```
/vibeguard:gc
```

| 模块 | 功能 |
|------|------|
| `gc-logs.sh` | events.jsonl 超 10MB 按月归档（gzip），保留 3 个月 |
| `gc-worktrees.sh` | 删除 >7 天未活跃的 worktree，有未合并变更只警告 |
| `check_code_slop.sh` | 5 类 AI 垃圾：空 catch、调试代码、过期 TODO、死代码、超长文件 |

也可单独运行：

```bash
bash ~/vibeguard/scripts/gc-logs.sh --dry-run
bash ~/vibeguard/scripts/gc-worktrees.sh --days 14
bash ~/vibeguard/guards/universal/check_code_slop.sh /path/to/project
```

## 依赖层 Linter

强制执行 `Types → Config → Repo → Service → Runtime → UI` 单向依赖：

```bash
# 检测跨层违规
python3 ~/vibeguard/guards/universal/check_dependency_layers.py /path/to/project

# 检测循环依赖
python3 ~/vibeguard/guards/universal/check_circular_deps.py /path/to/project
```

需要在项目根目录放置 `.vibeguard-architecture.yaml` 定义分层结构。模板：

```bash
cp ~/vibeguard/templates/vibeguard-architecture.yaml .vibeguard-architecture.yaml
```

违规时输出包含修复指令的错误信息（Golden Principle #3）。

## Multi-Agent 自动调度

14 个专项 agent + 1 个 dispatcher 自动路由：

| Agent | 做什么 |
|-------|--------|
| `dispatcher` | **自动调度** — 分析任务类型，路由到最合适的 agent |
| `planner` | 需求分析、任务分解 |
| `architect` | 技术方案、架构设计 |
| `tdd-guide` | RED → GREEN → IMPROVE 测试驱动 |
| `code-reviewer` | 分层代码审查 |
| `security-reviewer` | OWASP Top 10 安全审查 |
| `build-error-resolver` | 构建错误修复 |
| `e2e-runner` | 端到端测试 |
| `refactor-cleaner` | 重构、消除重复 |
| `doc-updater` | 代码变更后同步文档 |
| `go-reviewer` / `go-build-resolver` | Go 专项 |
| `python-reviewer` | Python 专项 |
| `database-reviewer` | SQL 注入、N+1、事务 |

Dispatcher 自动调度规则：
- 编译错误 → `build-error-resolver`
- 测试文件变更 → `tdd-guide`
- 数据库迁移 → `database-reviewer`
- 安全相关 → `security-reviewer`
- 5+ 文件重构 → `refactor-cleaner`

推理预算三明治（参考 Harness）：规划用 opus → 执行用 sonnet → 验证用 opus。

## 可观测栈

```bash
# Prometheus 指标导出
bash ~/vibeguard/scripts/metrics-exporter.sh                     # 输出到 stdout
bash ~/vibeguard/scripts/metrics-exporter.sh --push <gateway>    # Push 到 Pushgateway
bash ~/vibeguard/scripts/metrics-exporter.sh --file /path/to.prom # 写入 textfile

# 日志统计
bash ~/vibeguard/scripts/stats.sh       # 最近 7 天
bash ~/vibeguard/scripts/stats.sh 30    # 最近 30 天
```

指标包括：`hook_trigger_total`、`tool_total`、`hook_duration_seconds`、`guard_violation_total`。

告警规则模板在 `templates/alerting-rules.yaml`，覆盖违规率过高、Hook 超时、不活跃、Block 突增四种场景。

## 学习系统

双模式闭环学习，从错误中自动进化：

### Mode A — 防御向（从错误中学习）

```
/vibeguard:learn <错误描述>
```

分析错误根因（5-Why）→ 生成新的守卫脚本/Hook/规则 → 验证能检测到原始错误 → 同类错误不再发生。

### Mode B — 积累向（从发现中提取 Skill）

```
/vibeguard:learn extract
```

会话中发现非显而易见的方案时，提取为结构化 Skill 文件，未来遇到类似问题自动复用。

质量门控：可复用 + 非平凡 + 具体 + 已验证，全部满足才保存。

### 自动评估

`learn-evaluator.sh` 在会话结束时自动评估是否有值得提取的经验，提醒用户运行 learn。

## 守卫脚本

可单独运行的静态检查：

**通用**
```bash
bash ~/vibeguard/guards/universal/check_code_slop.sh /path/to/project       # AI 代码垃圾
python3 ~/vibeguard/guards/universal/check_dependency_layers.py /path/to/project  # 依赖层方向
python3 ~/vibeguard/guards/universal/check_circular_deps.py /path/to/project     # 循环依赖
```

**Rust**
```bash
bash ~/vibeguard/guards/rust/check_unwrap_in_prod.sh /path/to/project
bash ~/vibeguard/guards/rust/check_duplicate_types.sh /path/to/project
bash ~/vibeguard/guards/rust/check_nested_locks.sh /path/to/project
bash ~/vibeguard/guards/rust/check_workspace_consistency.sh /path/to/project
bash ~/vibeguard/guards/rust/check_single_source_of_truth.sh /path/to/project
bash ~/vibeguard/guards/rust/check_semantic_effect.sh /path/to/project
```

**Python**
```bash
python3 ~/vibeguard/guards/python/check_duplicates.py /path/to/project
python3 ~/vibeguard/guards/python/check_naming_convention.py /path/to/project
```

## 规则体系

守卫脚本的检查规则定义在 `rules/` 下：

| 文件 | 内容 |
|------|------|
| `universal.md` | U-01 ~ U-23 通用规则 |
| `security.md` | SEC-01 ~ SEC-10 安全规则 |
| `typescript.md` | TS-01 ~ TS-12 |
| `python.md` | PY-01 ~ PY-12 |
| `go.md` | GO-01 ~ GO-12 |
| `rust.md` | Rust 专项规则 |

## 管理

```bash
bash ~/vibeguard/setup.sh                    # 安装 / 更新（默认 core）
bash ~/vibeguard/setup.sh --profile full     # 切换到 full profile
bash ~/vibeguard/setup.sh --check            # 检查安装状态
bash ~/vibeguard/setup.sh --clean            # 卸载
```

## 仓库结构

```
vibeguard/
├── setup.sh                              # 一键安装/卸载/检查
├── agents/                               # 14 个专项 agent（含 dispatcher 自动调度）
├── hooks/                                # 实时拦截脚本
│   ├── log.sh                            #   共享日志（duration_ms + agent 类型）
│   ├── pre-write-guard.sh                #   新文件拦截
│   ├── pre-bash-guard.sh                 #   危险命令拦截
│   ├── pre-edit-guard.sh                 #   防幻觉编辑
│   ├── post-edit-guard.sh                #   质量警告
│   ├── stop-guard.sh                     #   完成前验证门禁
│   └── learn-evaluator.sh                #   会话结束学习评估
├── guards/                               # 静态检查脚本
│   ├── universal/                        #   通用守卫（代码垃圾、依赖层、循环依赖）
│   ├── rust/                             #   Rust 守卫
│   ├── python/                           #   Python 守卫
│   └── typescript/                       #   TypeScript 守卫
├── .claude/commands/vibeguard/           # 10 个自定义命令
├── templates/                            # 模板
│   ├── project-rules/                    #   路径作用域规则
│   ├── vibeguard-architecture.yaml       #   依赖层定义
│   ├── alerting-rules.yaml               #   Prometheus 告警规则
│   └── AGENTS.md                         #   OpenAI Codex 等价约束
├── workflows/plan-flow/                  # 工作流 + ExecPlan 模板
├── claude-md/vibeguard-rules.md          # 注入到 CLAUDE.md 的规则索引
├── mcp-server/                           # MCP Server（语言检测 + 任务调度）
├── rules/                                # 规则定义文件
├── resources/skill-template.md           # Skill 提取模板
├── skills/                               # 可复用工作流
├── scripts/                              # 工具脚本
│   ├── stats.sh                          #   统计分析
│   ├── gc-logs.sh                        #   日志归档
│   ├── gc-worktrees.sh                   #   Worktree 清理
│   └── metrics-exporter.sh              #   Prometheus 指标导出
├── context-profiles/                     # 上下文模式（dev/review/research）
├── scripts/ci/                           # CI 验证脚本
└── spec.md                               # 完整规范
```

## CLAUDE.md 模板

仓库附带完整的 CLAUDE.md 模板（[`docs/CLAUDE.md.example`](docs/CLAUDE.md.example)），融合 Anthropic 官方最佳实践 + VibeGuard 七层防御 + Harness Golden Principles。

**和网上流传的"10x Engineer CLAUDE.md"的区别：** 那些配置只是告诉 AI "你应该怎么做"，VibeGuard 版是**用 Hooks 自动拦截 + 守卫脚本强制执行**，确保 AI 必须这么做。

### 使用方式

**方式一：安装 VibeGuard（推荐）**

```bash
bash ~/vibeguard/setup.sh
```

**方式二：只用模板，不装 VibeGuard**

```bash
cp ~/vibeguard/docs/CLAUDE.md.example ./CLAUDE.md
```

> 注意：不安装 VibeGuard 的情况下，Hooks 和 `/vibeguard:*` 命令不会生效，只有规则约束部分起作用。

**方式三：OpenAI Codex 用户**

```bash
cp ~/vibeguard/templates/AGENTS.md ./AGENTS.md
```

等价于 CLAUDE.md 的约束，适配 Codex agent 格式。

**方式四：路径作用域规则（可选）**

```bash
mkdir -p .claude/rules
cp ~/vibeguard/templates/project-rules/*.md .claude/rules/
```

## 设计理念

| 原则 | 来源 | 实现 |
|------|------|------|
| 机械化优先 | Harness #3 | Hooks + 守卫脚本强制执行，不靠 AI 自觉 |
| 错误消息即修复指令 | Harness #3 | 每个拦截都告诉 AI 怎么修，不只说哪里错 |
| 给地图不给手册 | Harness #5 | 32 行索引 + 否定约束 + 按需加载 |
| 失败闭环 | Harness #2 | 犯错 → learn → 新守卫 → 同类不再犯 |
| Agent 看不到的不存在 | Harness #1 | 所有决策写进仓库（CLAUDE.md / ExecPlan / 约束集） |
| 给 Agent 一双眼睛 | Harness #4 | 可观测栈（日志 + 指标 + 告警） |

## 参考资料

| 外部实践 | VibeGuard 对应 |
|----------|---------------|
| Harness: Golden Principles 写进仓库 | CLAUDE.md 七层规则注入 |
| Harness: 架构约束机械化强制 | Pre/Post Hooks + 依赖层 Linter |
| Harness: ExecPlan 长周期任务 | `/vibeguard:exec-plan` 8 节模板 |
| Harness: Garbage Collection 自动清理 | `/vibeguard:gc` 三模块清理 |
| Harness: 可观测栈 | metrics-exporter + alerting-rules |
| Harness: Multi-Agent 调度 | dispatcher agent + classify_task() |
| Harness: Skills 渐进披露 | `/vibeguard:learn` Mode B + skill-template |
| Harness: 否定约束引导 | 规则中"不存在 X" + AGENTS.md 模板 |
| Stripe: 蓝图编排 | blueprints/*.json + blueprint-runner.sh |
| Stripe: 反馈左移 | pre-commit-guard.sh |
| Stripe: 工具子集分配 | MCP detector 按语言动态分配守卫 |

---

- [OpenAI Harness Engineering](https://openai.com/index/harness-engineering/)
- [Stripe Minions](https://www.youtube.com/watch?v=bZ0z1ApYjJo)
- [Anthropic: Effective Harnesses for Long-Running Agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents)
