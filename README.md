# VibeGuard

让 AI 写代码时不再瞎编。

用 Claude Code / Codex 写代码时，AI 经常凭空捏造 API、重复造轮子、硬编码假数据、过度设计。VibeGuard 通过**规则注入 + 实时拦截 + 静态扫描**三道防线，从源头阻止这些问题。

## 安装

```bash
git clone https://github.com/majiayu000/vibeguard.git ~/vibeguard
bash ~/vibeguard/setup.sh
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
| L2 | 命名约束 | Python 内部 snake_case，API 边界 camelCase，禁止别名 |
| L3 | 质量基线 | 禁止静默吞异常，公开方法禁 `Any` 类型 |
| L4 | 数据真实 | 无数据就显示空白，不硬编码，不发明不存在的 API |
| L5 | 最小改动 | 只做被要求的事，不加额外"改进" |
| L6 | 流程约束 | 大改动先 preflight，完成后 check |
| L7 | 提交纪律 | 禁 AI 标记、force push、向后兼容 |

### 2. Hooks 实时拦截（写代码时自动触发）

不需要手动运行，AI 操作时自动拦截：

| 场景 | 触发 | 结果 |
|------|------|------|
| AI 要创建新的 `.py/.ts/.rs/.go/.js` 文件 | `pre-write-guard` | **拦截** — 必须先搜索是否已有类似实现 |
| AI 要执行 `git push --force`、`rm -rf`、`reset --hard` | `pre-bash-guard` | **拦截** — 给出安全替代方案 |
| AI 要编辑不存在的文件 | `pre-edit-guard` | **拦截** — 先 Read 确认文件内容 |
| AI 编辑后新增了 `unwrap()`、硬编码路径 | `post-edit-guard` | **警告** — 给出具体修复方法 |
| AI 编辑后新增了 `console.log` / `print()` 调试语句 | `post-edit-guard` | **警告** — 提示使用 logger |
| AI 想结束但有未验证的源码变更 | `stop-guard` | **门禁** — 提醒完成验证后再结束 |

### 3. MCP 工具（按需调用）

AI 可在会话中主动调用这些工具检查代码质量：

- `guard_check` — 运行指定语言的守卫脚本
- `compliance_report` — 项目合规检查报告
- `metrics_collect` — 采集代码指标

## 日常使用

### 场景一：开始一个大改动

```
/vibeguard:preflight /path/to/project
```

AI 会自动探索项目结构、识别共享资源、运行守卫获取基线，生成一份**约束集**。后续编码严格遵守这些约束，避免改一处破三处。

### 场景二：改完代码，检查健康度

```
/vibeguard:check /path/to/project
```

自动检测项目语言，运行对应的守卫脚本，输出健康度报告和评分。如果之前跑过 preflight，还会对比基线标记恶化项。

### 场景三：代码审查

```
/vibeguard:review /path/to/project
```

先运行守卫获取基线，再按**安全 → 逻辑 → 质量 → 性能**优先级结构化审查。

### 场景四：双模型对抗审查

```
/vibeguard:cross-review /path/to/project
```

Claude 生成审查报告后，Codex 做对抗性验证（确认/质疑/补充），迭代至收敛。比单模型审查更可靠。需要安装 Codex CLI（`npm i -g @openai/codex`），不可用时自动降级为单模型。

### 场景五：构建报错，快速修复

```
/vibeguard:build-fix
```

读取构建错误 → 定位根因 → 执行最小修复 → 验证构建通过。

### 场景六：AI 犯了错，防止再犯

```
/vibeguard:learn
```

分析错误根因，自动生成新的守卫规则或 hook，同类错误不再发生。

### 场景七：看看 hooks 有没有在工作

```
/vibeguard:stats
```

查看 hook 触发统计 — 拦截了多少次、警告了什么、每天活跃度。也可以直接跑脚本：

```bash
bash ~/vibeguard/scripts/stats.sh       # 最近 7 天
bash ~/vibeguard/scripts/stats.sh 30    # 最近 30 天
bash ~/vibeguard/scripts/stats.sh all   # 全部历史
```

日志存储在 `~/.vibeguard/events.jsonl`，每行一个 JSON 事件。

### 场景八：大功能开发前，深度采访需求

```
/vibeguard:interview <功能描述>
```

AI 主动采访你：功能边界 → 技术实现 → 边界情况 → 验收标准。挖掘你没想到的难点，最后输出结构化 SPEC.md。建议在新会话中执行 SPEC，干净上下文更可靠。（来自 Anthropic 官方推荐的面试模式）

### 复杂度路由

VibeGuard 根据改动规模自动选择流程深度：

| 规模 | 流程 |
|------|------|
| 1-2 文件 | 直接实现 |
| 3-5 文件 | `/vibeguard:preflight` → 约束集 → 实现 |
| 6+ 文件 | `/vibeguard:interview` → SPEC → `/vibeguard:preflight` → 实现 |

### 推荐工作流

```
interview（采访）→ preflight（预防）→ 编码 → check（验证）→ review（审查）→ learn（闭环改进）→ stats（观测）
```

## Agents

13 个专项 agent，在需要时由 AI 自动调度：

| Agent | 做什么 |
|-------|--------|
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

所有 agent 内置 VibeGuard 约束。

## 守卫脚本

可单独运行的静态检查：

**Rust**
```bash
bash ~/vibeguard/guards/rust/check_unwrap_in_prod.sh /path/to/project   # 生产代码 unwrap/expect
bash ~/vibeguard/guards/rust/check_duplicate_types.sh /path/to/project  # 跨文件重复类型
bash ~/vibeguard/guards/rust/check_nested_locks.sh /path/to/project     # 嵌套锁（死锁风险）
```

**Python**
```bash
python3 ~/vibeguard/guards/python/check_duplicates.py /path/to/project        # 重复文件/函数
python3 ~/vibeguard/guards/python/check_naming_convention.py /path/to/project  # camelCase 混用
```

## 规则体系

守卫脚本的检查规则定义在 `rules/` 下：

| 文件 | 内容 |
|------|------|
| `universal.md` | U-01 ~ U-22 通用规则 |
| `security.md` | SEC-01 ~ SEC-10 安全规则 |
| `typescript.md` | TS-01 ~ TS-12 |
| `python.md` | PY-01 ~ PY-12 |
| `go.md` | GO-01 ~ GO-12 |
| `rust.md` | Rust 专项规则 |

## 管理

```bash
bash ~/vibeguard/setup.sh           # 安装 / 更新（pull 新版后重新运行）
bash ~/vibeguard/setup.sh --check   # 检查安装状态
bash ~/vibeguard/setup.sh --clean   # 卸载（清除所有注入的规则和 hooks）
```

## 仓库结构

```
vibeguard/
├── setup.sh                          # 一键安装/卸载/检查
├── agents/                           # 13 个专项 agent
├── hooks/                            # 实时拦截脚本
│   ├── log.sh                        #   共享日志模块（写入 ~/.vibeguard/events.jsonl）
│   ├── pre-write-guard.sh            #   新文件拦截
│   ├── pre-bash-guard.sh             #   危险命令拦截
│   ├── pre-edit-guard.sh             #   防幻觉编辑
│   ├── post-edit-guard.sh            #   质量警告
│   ├── post-guard-check.sh           #   修复提示
│   └── stop-guard.sh                 #   完成前验证门禁
├── guards/                           # 静态检查脚本
│   ├── rust/                         #   Rust 守卫
│   └── python/                       #   Python 守卫
├── .claude/commands/vibeguard/       # 8 个自定义命令
├── templates/project-rules/          # 路径作用域规则模板（可选部署到项目）
├── claude-md/vibeguard-rules.md      # 注入到 CLAUDE.md 的规则索引
├── mcp-server/                       # MCP Server
├── rules/                            # 规则定义文件
├── skills/                           # 可复用工作流
├── workflows/                        # 工作流（auto-optimize 等）
├── context-profiles/                 # 上下文模式（dev/review/research）
├── scripts/ci/                       # CI 验证脚本
└── spec.md                           # 完整规范
```

## CLAUDE.md 模板

仓库附带一份完整的 CLAUDE.md 模板（[`docs/CLAUDE.md.example`](docs/CLAUDE.md.example)），融合了 Anthropic 官方最佳实践 + VibeGuard 七层防御。

**和网上流传的"10x Engineer CLAUDE.md"的区别：** 那些配置只是告诉 AI "你应该怎么做"，VibeGuard 版是**用 Hooks 自动拦截 + 守卫脚本强制执行**，确保 AI 必须这么做。

模板包含 Anthropic 官方推荐的核心实践：
- **复杂度路由** — 1-2 文件直接做，3-5 文件先 preflight，6+ 文件先 interview 再 spec
- **Stop Gate** — AI 想结束时自动检查是否有未验证的变更
- **两次纠正法则** — 同一问题纠正 2 次后必须 `/clear` 重来
- **上下文压缩保留** — 压缩时自动保留关键决策和约束
- **面试模式** — 大功能前让 AI 采访你，输出结构化 SPEC

### 使用方式

**方式一：安装 VibeGuard（推荐）**

```bash
bash ~/vibeguard/setup.sh
```

安装脚本会自动把七层规则注入 `~/.claude/CLAUDE.md`，Hooks 自动注册，开箱即用。

**方式二：只用模板，不装 VibeGuard**

把模板复制到项目根目录，作为项目级配置：

```bash
cp ~/vibeguard/docs/CLAUDE.md.example ./CLAUDE.md
```

> 注意：不安装 VibeGuard 的情况下，模板中的 Hooks 自动拦截和 `/vibeguard:*` 命令不会生效，只有规则约束部分起作用（依赖 AI 自觉遵守）。完整防御需要安装 VibeGuard。

**方式三：和项目已有 CLAUDE.md 共存**

Claude Code 会叠加加载所有层级的 CLAUDE.md：

```
用户级  ~/.claude/CLAUDE.md          ← VibeGuard 全局规则（setup.sh 安装）
项目级  ./CLAUDE.md                  ← 项目特定约束（你自己写的）
```

两个文件的规则全部 concatenate 进 AI context，天然共存。项目级可以补充特定约束（如"用 pnpm 不用 npm"），VibeGuard 继续保护底线。

**方式四：路径作用域规则（可选，进阶）**

不同目录自动加载不同规则，减少无关规则的 token 消耗：

```bash
# 复制模板到项目
mkdir -p .claude/rules
cp ~/vibeguard/templates/project-rules/*.md .claude/rules/
```

模板包含三个常用规则：
- `api-security.md` — API 路由安全规则（自动加载于 `**/api/**`、`**/routes/**`）
- `test-patterns.md` — 测试编写规范（自动加载于 `**/*test*`、`**/tests/**`）
- `config-protection.md` — 配置文件保护（自动加载于 `**/.env*`、`**/config/**`）

## 设计理念

- **机械化优先** — 能用脚本检测的写脚本，不依赖 AI 自觉遵守
- **错误消息即修复指令** — 每个拦截都告诉 AI 怎么修，不只说哪里错
- **地图而非手册** — CLAUDE.md 注入精简索引，详细规则按需加载
- **失败闭环** — 犯错 → 分析根因 → 生成新守卫 → 同类错误不再发生
