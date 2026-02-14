# VibeGuard

AI 辅助开发防幻觉框架。通过七层防御架构 + 机械化拦截，系统性阻止 LLM 代码生成中的常见失效模式。

## 解决什么问题

LLM 写代码的主要失效模式不是语法错误，而是：

| 失效模式 | 例子 |
|----------|------|
| 凭空捏造 | 发明不存在的 API、文件路径、数据字段 |
| 重复造轮子 | 不搜索就新建，同一功能多份实现 |
| 数据分裂 | 多入口各自硬编码路径，数据写入不同文件 |
| 过度设计 | 添加不需要的抽象层、兼容代码、deprecated 标记 |
| 硬编码交付 | 生成看起来正确但数据为空或硬编码的页面 |

VibeGuard 通过**规则注入 + 实时拦截 + 静态扫描**三道防线解决这些问题。

## 快速开始

```bash
# 1. Clone
git clone https://github.com/majiayu000/vibeguard.git ~/vibeguard

# 2. 一键安装（部署规则 + 构建 MCP Server + 注册 Hooks）
bash ~/vibeguard/setup.sh

# 3. 验证
bash ~/vibeguard/setup.sh --check
```

安装完成后，新开一个 Claude Code 会话即可生效。

## 工作原理

```
                  ┌─────────────────────────────────────────┐
                  │          Claude Code 会话                │
                  │                                         │
  ┌───────────┐   │  ┌──────────┐   ┌──────────┐           │
  │ CLAUDE.md │──▶│  │ 规则索引 │   │ 自检清单 │           │
  │ 规则注入  │   │  └──────────┘   └──────────┘           │
  └───────────┘   │       │                                 │
                  │       ▼                                 │
  ┌───────────┐   │  ┌──────────┐        ┌──────────┐      │
  │  Hooks    │──▶│  │ Write    │──Block──│ 先搜后写 │      │
  │ 实时拦截  │   │  │ Bash     │──Block──│ 禁危险命令│      │
  │           │   │  │ Edit     │──Warn───│ 质量警告 │      │
  └───────────┘   │  └──────────┘        └──────────┘      │
                  │                                         │
  ┌───────────┐   │  ┌───────────────────────────────┐      │
  │ MCP Tools │──▶│  │ guard_check / compliance_report│      │
  │ 按需扫描  │   │  └───────────────────────────────┘      │
  └───────────┘   └─────────────────────────────────────────┘
```

### 三道防线

| 防线 | 机制 | 时机 |
|------|------|------|
| **规则注入** | 七层约束自动追加到 `~/.claude/CLAUDE.md` | 会话开始时 |
| **实时拦截** | Hooks 在操作前/后自动触发 | 写文件/执行命令/编辑代码时 |
| **按需扫描** | MCP 工具 + 自定义命令 | 手动或 preflight/check 时 |

## 核心功能

### Hooks（自动拦截）

| Hook | 触发条件 | 行为 |
|------|----------|------|
| `pre-write-guard` | 创建新源码文件 (.rs/.py/.ts/.js/.go) | **Block** — 必须先搜索已有实现 |
| `pre-bash-guard` | 危险命令 (force push / reset --hard / rm -rf) | **Block** — 提供安全替代方案 |
| `post-edit-guard` | 编辑后新增 unwrap() 或硬编码路径 | **Warn** — 输出具体修复方法 |

每个拦截消息都包含**具体修复步骤**，而非笼统的"不允许"。

### 自定义命令

```bash
/vibeguard:preflight    # 修改前：探索项目，生成约束集（预防）
/vibeguard:check        # 修改后：运行全部守卫 + 合规检查（验证）
/vibeguard:learn        # 犯错后：分析根因，生成新守卫规则（闭环）
```

**典型工作流**：`preflight（预防）→ 编码 → check（验证）→ learn（闭环改进）`

### MCP Server 工具

| 工具 | 用途 |
|------|------|
| `guard_check` | 运行指定语言的守卫脚本 |
| `compliance_report` | 项目合规检查报告 |
| `metrics_collect` | 采集代码指标 |

### 守卫脚本

**Rust 守卫**

| ID | 脚本 | 检测 |
|----|------|------|
| RS-01 | `check_nested_locks.sh` | 同一函数内嵌套锁获取（死锁风险） |
| RS-03 | `check_unwrap_in_prod.sh` | 生产代码中的 unwrap()/expect() |
| RS-05 | `check_duplicate_types.sh` | 跨文件重复类型定义 |
| RS-06 | `check_workspace_consistency.sh` | Workspace 跨入口配置/路径一致性 |

**Python 守卫**

| 脚本 | 检测 |
|------|------|
| `check_duplicates.py` | 重复文件/函数 |
| `check_naming_convention.py` | camelCase 混用 |
| `test_code_quality_guards.py` | 架构约束（异常处理、模块边界） |

所有守卫发现问题时，输出包含**具体修复方法和代码示例**。

## 七层防御框架

| 层 | 名称 | 核心约束 |
|----|------|----------|
| L1 | 先搜后写 | 新建文件/类/函数前必须搜索已有实现 |
| L2 | 命名约束 | Python snake_case，API 边界 camelCase；禁止别名 |
| L3 | 质量基线 | 禁止静默吞异常；公开方法禁 Any 类型 |
| L4 | 数据真实 | 无数据显示空白；不硬编码；不发明不存在的 API |
| L5 | 最小改动 | 只做被要求的事；不加额外改进/注释/抽象 |
| L6 | 流程约束 | 3+ 文件改动先 preflight；完成后 check |
| L7 | 提交纪律 | 禁 AI 标记；禁 force push；禁向后兼容 |

完整规范见 [spec.md](spec.md)。

## 仓库结构

```
vibeguard/
├── setup.sh                    # 一键安装/卸载/状态检查
├── spec.md                     # 完整规范文档
├── README.md
│
├── claude-md/
│   └── vibeguard-rules.md      # 注入到 ~/.claude/CLAUDE.md 的规则索引
│
├── .claude/commands/vibeguard/
│   ├── preflight.md            # /vibeguard:preflight 命令
│   ├── check.md                # /vibeguard:check 命令
│   └── learn.md                # /vibeguard:learn 命令
│
├── hooks/
│   ├── pre-write-guard.sh      # PreToolUse(Write) — 新文件拦截
│   ├── pre-bash-guard.sh       # PreToolUse(Bash) — 危险命令拦截
│   ├── post-edit-guard.sh      # PostToolUse(Edit) — 质量警告
│   └── post-guard-check.sh     # PostToolUse(guard_check) — 修复提示
│
├── guards/
│   ├── rust/
│   │   ├── common.sh           # 共享函数库
│   │   ├── check_nested_locks.sh
│   │   ├── check_unwrap_in_prod.sh
│   │   ├── check_duplicate_types.sh
│   │   └── check_workspace_consistency.sh
│   ├── python/
│   │   ├── check_duplicates.py
│   │   ├── check_naming_convention.py
│   │   └── test_code_quality_guards.py
│   └── typescript/
│       └── eslint-guards.ts
│
├── mcp-server/                 # MCP Server (TypeScript)
│   └── src/
│       ├── index.ts            # 入口 + Zod schema
│       ├── tools.ts            # 守卫注册 + 执行逻辑
│       └── executor.ts         # 脚本执行器
│
├── scripts/
│   ├── compliance_check.sh     # 项目合规检查
│   └── metrics_collector.sh    # 代码指标采集
│
├── skills/vibeguard/           # Claude Code Skill
├── workflows/                  # 工作流 Skills
│   ├── auto-optimize/          #   自主优化（守卫 + LLM 分析 + 自动执行）
│   ├── plan-folw/              #   冗余分析 + 计划
│   ├── fixflow/                #   工程交付
│   ├── optflow/                #   优化发现
│   └── plan-mode/              #   计划落地
└── project-templates/          # 新项目 CLAUDE.md 模板
```

## 新项目接入

### Rust 项目

```bash
# 直接运行守卫（无需复制文件）
bash ~/vibeguard/guards/rust/check_unwrap_in_prod.sh /path/to/rust-project
bash ~/vibeguard/guards/rust/check_duplicate_types.sh /path/to/rust-project
bash ~/vibeguard/guards/rust/check_nested_locks.sh /path/to/rust-project
bash ~/vibeguard/guards/rust/check_workspace_consistency.sh /path/to/rust-project

# 或使用自定义命令一键检查
# 在 Claude Code 中输入：/vibeguard:check /path/to/rust-project
```

### Python 项目

```bash
# 复制守卫到项目
cp ~/vibeguard/guards/python/test_code_quality_guards.py my-project/tests/architecture/
cp ~/vibeguard/guards/python/check_duplicates.py my-project/scripts/
cp ~/vibeguard/guards/python/check_naming_convention.py my-project/scripts/

# 合规检查
bash ~/vibeguard/scripts/compliance_check.sh my-project/
```

### 通用（任何项目）

```bash
# 合规检查
bash ~/vibeguard/scripts/compliance_check.sh /path/to/project

# 在 Claude Code 中使用自定义命令
/vibeguard:preflight /path/to/project    # 修改前生成约束集
/vibeguard:check /path/to/project        # 修改后验证
```

## 管理

```bash
# 检查安装状态
bash ~/vibeguard/setup.sh --check

# 重新安装（更新规则后）
bash ~/vibeguard/setup.sh

# 卸载
bash ~/vibeguard/setup.sh --clean
```

## 设计理念

- **机械化优先**：能用脚本检测的就写脚本，不依赖 agent 自觉遵守
- **错误消息即修复指令**：每个拦截/警告都告诉 agent HOW to fix，不只是 WHAT is wrong
- **地图而非手册**：CLAUDE.md 注入精简索引（56 行），详细规则按需加载
- **失败闭环**：agent 犯错 → 分析根因 → 生成新守卫 → 同类错误不再发生

灵感来源：[OpenAI Harness Engineering](https://openai.com/index/harness-engineering/)、[TDD Guard](https://github.com/AidenYuanDev/tdd-guard)、[GudaSpec Commands](https://github.com/GuDaStudio/commands)
