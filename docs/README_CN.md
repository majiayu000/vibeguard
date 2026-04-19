# VibeGuard

[![CI](https://github.com/majiayu000/vibeguard/actions/workflows/ci.yml/badge.svg)](https://github.com/majiayu000/vibeguard/actions/workflows/ci.yml)

**阻止 AI 编造代码。**

[English README](../README.md) | [规则索引](rule-reference.md) | [贡献指南](../CONTRIBUTING.md)

无论你在用 Claude Code 还是 Codex，AI 都很容易出现同一类失误：编造不存在的 API、重复造轮子、硬编码假数据、顺手做一堆你没要求的“优化”。VibeGuard 通过 **规则注入 + 实时拦截 + 静态扫描** 三层防线，把这些问题尽量挡在代码落地之前。

> **VibeGuard vs Everything Claude Code：** ECC 更偏通用生产力工具箱；VibeGuard 更偏“防守系统”，重点是约束、拦截、验证和回放。两者不是互斥关系，反而适合一起使用。

设计思路参考了 [OpenAI Harness Engineering](https://openai.com/index/harness-engineering/) 和 [Stripe Minions](https://www.youtube.com/watch?v=bZ0z1ApYjJo)，并把 Harness 的 5 条黄金原则真正落到仓库级工具链里。

## 典型问题

```text
你：   “加一个登录接口”
AI：   新建 auth_service.py（仓库里其实已经有 auth.py）
      引入不存在的库 `flask-auth-magic`
      把 JWT secret 硬编码成 "your-secret-key"
      顺手再加 200 行你根本没要的“改进”
```

**VibeGuard 的目标，就是在这些改动进入仓库之前先发现并打断。**

## 快速开始

```bash
git clone https://github.com/majiayu000/vibeguard.git ~/vibeguard
bash ~/vibeguard/setup.sh
```

安装后重新打开 Claude Code 或 Codex 会话。用下面的命令检查安装状态：

```bash
bash ~/vibeguard/setup.sh --check
```

## 文档导航

| 文档 | 作用 |
|------|------|
| [rule-reference.md](rule-reference.md) | 规则分层、guard 覆盖面、语言专项检查 |
| [CLAUDE.md.example](CLAUDE.md.example) | 只使用规则模板、不安装 hooks 的项目级 CLAUDE 模板 |
| [linux-setup.md](linux-setup.md) | Linux 安装说明 |
| [known-issues/false-positives.md](known-issues/false-positives.md) | 已知误报与修复经验 |
| [../CONTRIBUTING.md](../CONTRIBUTING.md) | 贡献流程、验证命令、提交规范 |

## 产品边界

VibeGuard 现在明确分成两层：

| 表面 | 范围 | canonical source |
|------|------|------------------|
| **VibeGuard Core** | 规则、hooks、静态 guards、安装/运行时契约、可观测性 | `rules/claude-rules/`、`schemas/install-modules.json`、`hooks/`、`guards/` |
| **VibeGuard Workflows** | Slash Commands、agent prompts、规划/执行预设 | `skills/`、`workflows/`、`agents/` |

如果这些表面之间冲突，先以 Core 契约为准，再同步 workflow 和文档。

## 工作方式

### 1. 规则注入

`rules/claude-rules/` 中的原生规则会被安装到 `~/.claude/rules/vibeguard/`，直接影响 Claude Code 的推理层。同时，VibeGuard 还会把 7 层约束索引注入到 `~/.claude/CLAUDE.md`。

| 层级 | 约束 | 作用 |
|------|------|------|
| L1 | 先搜索再创建 | 新建文件/类/函数前先确认仓库里是否已有实现 |
| L2 | 命名规范 | 内部优先 `snake_case`，API 边界再用 `camelCase`，禁止别名 |
| L3 | 质量基线 | 禁止吞异常、公共接口滥用 `Any` |
| L4 | 数据真实性 | 没数据就显示空，不允许硬编码和虚构 API |
| L5 | 最小改动 | 只做被要求的事，不顺手加“升级” |
| L6 | 过程闸门 | 大改动先预检和规划，结束前必须验证 |
| L7 | 提交纪律 | 禁止 AI 标记、禁止 force push、禁止秘钥入库 |

这里大量使用了“负约束”表达，例如“X 不存在”“不要假设 Y 已经有”，通常比纯正向描述更能稳定影响 agent 行为。

当前 canonical 参考入口：
- 安装/运行时契约：`schemas/install-modules.json`
- 原生规则源：`rules/claude-rules/`
- 当前规则摘要：`docs/rule-reference.md`

### 2. Hooks 实时拦截

多数 hooks 都是在 AI 操作过程中自动触发。`skills-loader` 是可选的手动脚本；Codex 目前只支持部署 Bash/Stop 类 hook：

| 场景 | Hook | 结果 |
|------|------|------|
| AI 创建新的 `.py/.ts/.rs/.go/.js` 文件 | `pre-write-guard` | **拦截**，必须先搜索现有实现 |
| AI 执行 `git push --force`、`rm -rf`、`reset --hard` | `pre-bash-guard` | **拦截**，给出安全替代命令 |
| AI 编辑一个不存在的文件 | `pre-edit-guard` | **拦截**，要求先读取文件确认 |
| AI 编辑后引入 `unwrap()`、硬编码路径等问题 | `post-edit-guard` | **告警**，直接给修复建议 |
| AI 编辑后留下 `console.log` / `print()` | `post-edit-guard` | **告警**，要求换成正式日志方案 |
| AI 新建文件后出现重复定义或重名文件 | `post-write-guard` | **告警**，提示重复实现 |
| AI 连续搜索/读取却迟迟不行动 | `analysis-paralysis-guard` | **升级**，要求明确下一步或说明阻塞 |
| `full` / `strict` 档位下编辑源码 | `post-build-check` | **告警**，自动跑对应语言的构建检查 |
| `git commit` | `pre-commit-guard` | **拦截**，只检查 staged 改动，10 秒硬超时 |
| AI 想结束但还没有验证改动 | `stop-guard` | **闸门**，要求先补完验证 |
| 会话结束 | `learn-evaluator` | **评估**，收集指标并识别纠错信号 |

### 3. 静态 Guards

下面是最常用的一组独立扫描脚本。完整清单请看 [rule-reference.md](rule-reference.md)。

```bash
# 通用
bash ~/vibeguard/guards/universal/check_code_slop.sh /path/to/project
python3 ~/vibeguard/guards/universal/check_dependency_layers.py /path/to/project
python3 ~/vibeguard/guards/universal/check_circular_deps.py /path/to/project
bash ~/vibeguard/guards/universal/check_test_integrity.sh /path/to/project

# Rust
bash ~/vibeguard/guards/rust/check_unwrap_in_prod.sh /path
bash ~/vibeguard/guards/rust/check_nested_locks.sh /path
bash ~/vibeguard/guards/rust/check_declaration_execution_gap.sh /path
bash ~/vibeguard/guards/rust/check_duplicate_types.sh /path
bash ~/vibeguard/guards/rust/check_semantic_effect.sh /path
bash ~/vibeguard/guards/rust/check_single_source_of_truth.sh /path
bash ~/vibeguard/guards/rust/check_taste_invariants.sh /path
bash ~/vibeguard/guards/rust/check_workspace_consistency.sh /path

# Go
bash ~/vibeguard/guards/go/check_error_handling.sh /path
bash ~/vibeguard/guards/go/check_goroutine_leak.sh /path
bash ~/vibeguard/guards/go/check_defer_in_loop.sh /path

# TypeScript
bash ~/vibeguard/guards/typescript/check_any_abuse.sh /path
bash ~/vibeguard/guards/typescript/check_console_residual.sh /path
bash ~/vibeguard/guards/typescript/check_component_duplication.sh /path
bash ~/vibeguard/guards/typescript/check_duplicate_constants.sh /path

# Python
python3 ~/vibeguard/guards/python/check_duplicates.py /path
python3 ~/vibeguard/guards/python/check_naming_convention.py /path
python3 ~/vibeguard/guards/python/check_dead_shims.py /path
```

## Slash Commands

仓库内置了 10 个自定义命令，覆盖从需求澄清到验证复盘的完整流程：

| 命令 | 作用 |
|------|------|
| `/vibeguard:preflight` | 修改前生成约束集 |
| `/vibeguard:check` | 全量 guard 扫描 + 合规报告 |
| `/vibeguard:review` | 结构化代码审查（安全 → 逻辑 → 质量 → 性能） |
| `/vibeguard:cross-review` | Claude + Codex 双模型对抗式审查 |
| `/vibeguard:build-fix` | 构建错误修复 |
| `/vibeguard:learn` | 从错误中生成 guard/rule，或提炼 Skill |
| `/vibeguard:interview` | 深度需求访谈，输出 SPEC.md |
| `/vibeguard:exec-plan` | 长任务执行计划，支持跨会话恢复 |
| `/vibeguard:gc` | 垃圾回收（日志归档 + worktree 清理 + code slop 扫描） |
| `/vibeguard:stats` | hook 触发统计 |

快捷别名：`/vg:pf` `/vg:gc` `/vg:ck` `/vg:lrn`

### 复杂度路由

| 规模 | 推荐流程 |
|------|----------|
| 1-2 个文件 | 直接实现 |
| 3-5 个文件 | `/vibeguard:preflight` → 约束集 → 实现 |
| 6 个及以上文件 | `/vibeguard:interview` → SPEC → `/vibeguard:preflight` → 实现 |

## 内置 Agent Prompts

仓库当前内置 14 个 agent prompt（13 个专项角色 + 1 个 dispatcher）：

| Agent | 作用 |
|------|------|
| `dispatcher` | 自动识别任务类型并路由到合适的 agent |
| `planner` / `architect` | 需求分析、系统设计 |
| `tdd-guide` | RED → GREEN → IMPROVE 测试驱动 |
| `code-reviewer` / `security-reviewer` | 分层审查、OWASP Top 10 |
| `build-error-resolver` | 构建错误定位与修复 |
| `go-reviewer` / `python-reviewer` / `database-reviewer` | 语言/数据库专项审查 |
| `refactor-cleaner` / `doc-updater` / `e2e-runner` | 重构、文档同步、端到端验证 |

## 可观测性与学习闭环

```bash
bash ~/vibeguard/scripts/quality-grader.sh
bash ~/vibeguard/scripts/stats.sh
bash ~/vibeguard/scripts/hook-health.sh 24
bash ~/vibeguard/scripts/metrics/metrics-exporter.sh
bash ~/vibeguard/scripts/verify/doc-freshness-check.sh
```

学习系统分两种模式：

**模式 A：防御式学习**

```text
/vibeguard:learn <错误描述>
```

针对一次真实失误做 5-Why 根因分析，然后生成新的 guard / hook / rule，并回放验证。

**模式 B：积累式学习**

```text
/vibeguard:learn extract
```

把会话里出现的非显然解法提炼成 Skill，供后续任务复用。

## Codex 集成

VibeGuard 会同时给 Claude Code 和 Codex CLI 安装技能与 hooks。

### Codex Hooks

`~/.codex/hooks.json` 中当前会部署以下 VibeGuard 管理的 hook：

| 事件 | Hook | 作用 |
|------|------|------|
| `PreToolUse(Bash)` | `pre-bash-guard.sh` | 危险命令拦截 + 包管理器纠偏 |
| `PostToolUse(Bash)` | `post-build-check.sh` | 构建失败检测 |
| `Stop` | `stop-guard.sh` | 未验证改动的结束闸门 |
| `Stop` | `learn-evaluator.sh` | 会话指标与纠错信号采集 |

> **注意：** Codex 目前的 PreToolUse/PostToolUse 只支持 `Bash` matcher，所以 `pre-edit`、`pre-write`、`post-edit`、`post-write` 以及 `analysis-paralysis` 这类 hook 还不能部署到原生 Codex CLI hook 路径。

Codex 中的 hook 命令名会使用 `vibeguard-*.sh` 命名空间，避免与别的工具链共享 `~/.codex/hooks.json` 时发生冲突。Claude 和 Codex 输出格式差异则由 `run-hook-codex.sh` 负责适配。若 hook 给出 `updatedInput` 建议，Codex CLI wrapper 目前不能自动改写命令，VibeGuard 会显式提示建议命令，而不是静默吞掉这条信息。

### App Server 外层封装

如果你在用 `codex app-server` 这类编排器，可以在外层再包一层 VibeGuard：

```bash
python3 ~/vibeguard/scripts/codex/app_server_wrapper.py   --codex-command "codex app-server"
```

- `--strategy vibeguard`：默认模式，在外层补上 pre/stop/post gate
- `--strategy noop`：纯透传，方便调试
- 当前 app-server wrapper 已覆盖：Bash 审批拦截，以及 turn 结束后的 stop/build 反馈，并会显式传递 `thread/session/turn` 上下文
- 当前 app-server wrapper 仍未覆盖：`pre-edit`、`pre-write`、`post-edit`、`post-write`、`analysis-paralysis`

## 安装选项

```bash
# Profiles
bash ~/vibeguard/setup.sh
bash ~/vibeguard/setup.sh --profile minimal
bash ~/vibeguard/setup.sh --profile full
bash ~/vibeguard/setup.sh --profile strict

# 只安装指定语言规则/guards
bash ~/vibeguard/setup.sh --languages rust,python
bash ~/vibeguard/setup.sh --profile full --languages rust,typescript

# 检查 / 卸载
bash ~/vibeguard/setup.sh --check
bash ~/vibeguard/setup.sh --clean
```

### Profiles

| Profile | 安装内容 | 适用场景 |
|---------|----------|----------|
| `minimal` | `pre-write` + `pre-edit` + `pre-bash` | 最轻量的关键拦截 |
| `core` | `minimal` + `post-edit` + `post-write` + `analysis-paralysis` | 默认开发档 |
| `full` | `core` + `stop-guard` + `learn-evaluator` + `post-build-check` | 完整防线 + 学习闭环 |
| `strict` | 与 `full` 相同 hook 集合 | 更严格的运行策略 |

### 给别的仓库做初始化

```bash
bash ~/vibeguard/scripts/project-init.sh /path/to/project
```

这个脚本会检测语言、输出建议的项目级约束片段，并把 pre-commit wrapper 接到目标仓库里。

### 自定义规则

你可以把自定义 `.md` 规则放进 `~/.vibeguard/user-rules/`。下次运行 `setup.sh` 时，这些规则会被同步到 `~/.claude/rules/vibeguard/custom/`。

## 已知限制

当前不少 guard 仍然依赖 grep/awk 或轻量 AST 辅助，因此在复杂语法场景里仍然可能出现误报。

- [known-issues/false-positives.md](known-issues/false-positives.md)：已确认误报场景、修复方式和经验总结

几个最重要的经验：

- **grep 不是 AST parser**：多层嵌套和跨块关系最好交给语言感知工具
- **修复提示本身也会驱动 agent**：提示写得太宽，会诱导 AI 做无关改动
- **项目类型很重要**：CLI、Web、MCP、Library 对同一条规则的可接受模式可能不同

## References

- [OpenAI Harness Engineering](https://openai.com/index/harness-engineering/)
- [Stripe Minions](https://www.youtube.com/watch?v=bZ0z1ApYjJo)
- [Anthropic: Effective Harnesses for Long-Running Agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents)
