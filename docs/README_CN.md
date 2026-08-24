# VibeGuard

[![CI](https://github.com/majiayu000/vibeguard/actions/workflows/ci.yml/badge.svg)](https://github.com/majiayu000/vibeguard/actions/workflows/ci.yml)

**阻止 AI 编造代码。**

[English README](../README.md) | [规则索引](rule-reference.md) | [贡献指南](../CONTRIBUTING.md)

无论你在用 Claude Code、Codex 还是 Gemini CLI，AI 都很容易出现同一类失误：编造不存在的 API、重复造轮子、硬编码假数据、顺手做一堆你没要求的“优化”。VibeGuard 通过 **规则注入 + 实时拦截 + 静态扫描** 三层防线，把能机械覆盖的高风险场景先告警或拦截；未被 hook/guard 覆盖的规则则通过审查、工作流和验证契约约束。

> **VibeGuard vs Everything Claude Code：** ECC 更偏通用生产力工具箱；VibeGuard 更偏“防守系统”，重点是约束、拦截、验证和回放。两者不是互斥关系，反而适合一起使用。

设计思路参考了 [OpenAI Harness Engineering](https://openai.com/index/harness-engineering/) 和 [Stripe Minions](https://www.youtube.com/watch?v=bZ0z1ApYjJo)，并把 Harness 的 5 条黄金原则映射到仓库级规则、hooks、工作流和可观测性里；不是每条原则都会变成 hook 级硬拦截。

## 典型问题

```text
你：   “加一个登录接口”
AI：   新建 auth_service.py（仓库里其实已经有 auth.py）
      引入不存在的库 `flask-auth-magic`
      把 JWT secret 硬编码成 "your-secret-key"
      顺手再加 200 行你根本没要的“改进”
```

**VibeGuard 的目标，是把能机械覆盖的问题尽早发现并打断，把其余风险转成明确的规则、审查和验证要求。**

## 快速开始

```bash
git clone https://github.com/majiayu000/vibeguard.git ~/vibeguard
bash ~/vibeguard/setup.sh
```

在支持的 macOS/Linux release 目标上，生产安装/check/clean 路径不需要 Python：
`setup.sh` 默认下载并校验预编译的 `vibeguard-runtime` release binary。
当当前 checkout pin 住的 runtime 版本已经发布 release assets 时，默认也不需要 Rust/Cargo；如果你从未发布的 `main` commit 安装，而 `vibeguard-runtime/VERSION` 已经领先于最新 tag，setup 会在找不到匹配 assets 时回退到本地 Cargo 构建，除非启用了 `--require-provenance`。Python 仍用于 eval、文档生成、开发者工具和可选的语言专项 guard packs。

安装后重新打开 Claude Code 或 Codex 会话。交互式诊断用 `doctor`，CI/post-install
验证用 `verify-install`：

```bash
bash ~/vibeguard/setup.sh doctor
bash ~/vibeguard/setup.sh verify-install
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

仓库目录职责见 [Directory Map](directory-map.md)。

## 工作方式

### 1. 规则注入

Claude Code 的 `full` 和 `strict` profile 会把 `rules/claude-rules/` 中的原生规则暴露到 `~/.claude/rules/vibeguard/`；默认的 `core` profile 和 `minimal` profile 不会前置注入这棵规则树。所有 profile 的全局高上下文文件都会接收一份较小的共享核心，覆盖范围、事实真实性、错误可见性、安全、内容保留和验证；安装器再按宿主追加专属说明：Claude Code 获得与 profile 一致的原生规则和 slash command 指引，Codex 获得 `AGENTS.md`、托管 Skill 和原生 hook 能力边界。项目事实与准确测试命令仍由最近的仓库级说明提供。

当前 canonical 参考入口：
- 安装/运行时契约：`schemas/install-modules.json`
- 原生规则源：`rules/claude-rules/`
- 当前规则摘要：`docs/rule-reference.md`

### 2. Hooks 实时拦截

多数 hooks 都是在 AI 操作过程中自动触发。`skills-loader` 是可选的手动脚本；所有 Codex profile 都会部署原生 Bash/apply_patch/PermissionRequest 和文件 PostToolUse hooks，`full` 与 `strict` 还会部署 post-build 和 Stop hooks。读操作相关 hooks 仍只在 Claude Code 或 app-server wrapper 路径生效：

| 场景 | Hook | 结果 |
|------|------|------|
| AI 创建新的 `.py/.ts/.rs/.go/.js` 文件 | `pre-write-guard` | 默认 **告警**，提醒先搜索现有实现；设置 `VIBEGUARD_WRITE_MODE=block` 或在 `~/.vibeguard/config.json` 中设置 `write_mode=block` 后硬拦截 |
| AI 创建或编辑超过 400 行的生产源码文件 | `pre-write-guard`、`pre-edit-guard`、`post-write-guard`、`post-edit-guard` | **告警**，提示已超过典型范围；当前改动保持局部，后续再规划拆分 |
| AI 创建或编辑超过 800 行的生产源码文件 | `pre-write-guard`、`pre-edit-guard` | **拦截**，必须先拆分文件 |
| AI 执行危险本地清理（危险路径 `rm -rf`、`git clean -f`、批量 `git checkout/restore .`） | `pre-bash-guard` | **拦截**，给出安全替代命令；如确实要清理本地改动，先运行 `python3 ~/vibeguard/scripts/authorized-discard.py --plan` 查看逐路径计划，再用确认短语执行 |
| AI 推送非快进更新或删除远端分支 | git `pre-push` | **拦截**，保护远端历史；改写历史或删除远端分支需要明确人工批准，并按仓库旁路策略处理 |
| AI 编辑一个不存在的文件 | `pre-edit-guard` | **拦截**，要求先读取文件确认 |
| AI 编辑后引入 `unwrap()`、硬编码路径等问题 | `post-edit-guard` | **告警**，直接给修复建议 |
| AI 编辑后留下 `console.log` / `print()` | `post-edit-guard` | **告警**，要求换成正式日志方案 |
| AI 新建文件后出现重复定义或重名文件 | `post-write-guard` | **告警**，提示重复实现 |
| AI 连续搜索/读取却迟迟不行动 | `analysis-paralysis-guard` | **升级**，要求明确下一步或说明阻塞 |
| `full` / `strict` 档位下编辑源码 | `post-build-check` | **告警**，自动跑对应语言的构建检查 |
| `git commit` | `pre-commit-guard` | **拦截**，staged-only 质量检查超时 10 秒；构建检查独立超时 60 秒 |
| AI 想结束但还没有验证改动 | `stop-guard` | **信号**，记录 Stop 提醒；Stop hook 退出 0 以避免反馈循环 |
| `full` / `strict` 档位下会话结束 | `learn-evaluator` | **评估**，收集指标并识别纠错信号 |

U-16 文件行数限制只覆盖非测试源码扩展名：`.rs`、`.ts`、`.tsx`、`.js`、`.jsx`、`.py`、`.go`。默认 400 行以上触发典型范围告警（`~/.vibeguard/config.json` 中的 `u16.warn_limit` / `VG_U16_WARN_LIMIT`），800 行仍是硬上限（`~/.vibeguard/config.json` 中的 `u16.limit` / `VG_U16_LIMIT`）。在 Codex 路径里，`apply_patch Add File` 和 `apply_patch Update File` 都会先被规范化再进入文件 hook；如果 patch 会让生产源码超过硬上限，会在写入前被 deny。

### 3. 静态 Guards

下面是最常用的一组独立扫描脚本。完整清单请看 [rule-reference.md](rule-reference.md)。

```bash
# 通用
bash ~/vibeguard/guards/universal/check_code_slop.sh /path/to/project
python3 ~/vibeguard/guards/universal/check_dependency_layers.py /path/to/project
python3 ~/vibeguard/guards/universal/check_circular_deps.py /path/to/project
bash ~/vibeguard/guards/universal/check_test_integrity.sh /path/to/project
bash ~/vibeguard/guards/universal/check_dependency_changes.sh --base origin/main --head HEAD
bash ~/vibeguard/guards/universal/check_test_weakening.sh --base origin/main --head HEAD

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

仓库内置了 12 个自定义命令，覆盖从需求澄清到验证复盘的完整流程：

| 命令 | 作用 |
|------|------|
| `/vibeguard:preflight` | 修改前生成约束集 |
| `/vibeguard:check` | 全量 guard 扫描 + 合规报告 |
| `/vibeguard:review` | 结构化代码审查（安全 → 逻辑 → 质量 → 性能） |
| `/vibeguard:cross-review` | Claude + Codex 双模型对抗式审查 |
| `/vibeguard:build-fix` | 构建错误修复 |
| `/vibeguard:learn` | 从错误中生成 guard/rule，或提炼 Skill |
| `/vibeguard:skill-validate` | 用 repair/regression 证据门验证新 Skill 是否值得接受 |
| `/vibeguard:interview` | 深度需求访谈，输出 SPEC.md |
| `/vibeguard:exec-plan` | 长任务执行计划，支持跨会话恢复 |
| `/vibeguard:live-truth` | 为 latest、PR ready、merged、running、deployed、published 等可变状态声明提供新鲜证据门 |
| `/vibeguard:gc` | 垃圾回收（日志归档 + worktree 清理 + 规则预算 + code slop 扫描） |
| `/vibeguard:stats` | hook 触发统计 |

快捷别名：`/vg:pf` `/vg:gc` `/vg:ck` `/vg:lrn`

### 交付契约

目标清楚、范围有限的任务直接执行。只有重大架构、迁移、跨系统策略变更，
或用户明确要求时才写简短计划；信息不足时先澄清，不生成路由数据包。

- 纯文档、小 bug、明确的机械修改免 spec。
- 普通 spec 最多约两个文件、300 行。
- 同一仓库最多一个可写会话；委派必须显式启用，默认只读。
- 同一 PR 最多两轮 Review；`Findings: 0` 且 `PASS` 时立即停止。

共享限制见 [`delivery-base.md`](../workflows/references/delivery-base.md)。

## 可选 Agent Prompts

仓库内置 14 个可选 prompt。只有用户明确选择专项角色或有边界的辅助任务时才启用，
不会默认组成 coordinator/reviewer 流水线：

| Agent | 作用 |
|------|------|
| `dispatcher` | 建议可选专项角色，不自动启动可写并行任务 |
| `planner` / `architect` | 需求分析、系统设计 |
| `tdd-guide` | RED → GREEN → IMPROVE 测试驱动 |
| `code-reviewer` / `security-reviewer` | 分层审查、OWASP Top 10 |
| `build-error-resolver` | 构建错误定位与修复 |
| `go-build-resolver` | Go 构建错误专项定位 |
| `go-reviewer` / `python-reviewer` / `database-reviewer` | 语言/数据库专项审查 |
| `refactor-cleaner` / `doc-updater` / `e2e-runner` | 重构、文档同步、端到端验证 |

## 可观测性与学习闭环

```bash
bash ~/vibeguard/scripts/quality-grader.sh
bash ~/vibeguard/scripts/stats.sh
bash ~/vibeguard/scripts/hook-health.sh 24
bash ~/vibeguard/scripts/doctors/codex-doctor.sh
bash ~/vibeguard/scripts/metrics/metrics-exporter.sh
bash ~/vibeguard/scripts/verify/doc-freshness-check.sh
```

Doctor 是现有防御系统之上的只读诊断入口，不替代 hooks 或 guards。它负责汇总安装状态、能力差异、噪声 hook、最近事件和修复命令；真正的拦截/告警仍然发生在 hook 和 guard 执行层。

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

`~/.codex/hooks.json` 中当前会按 profile 部署以下 VibeGuard 管理的 hook。Bash/apply_patch 闸门与文件 post-hooks 属于所有 profile；`post-build-check` 和 `Stop` 两类只由 `full`、`strict` 安装：

| 事件 | Hook | 作用 |
|------|------|------|
| `PreToolUse(Bash)` | `pre-bash-guard.sh` | 危险本地清理拦截 + 包管理器纠偏 |
| `PermissionRequest(Bash)` | `pre-bash-guard.sh` | 危险命令审批前的 fail-closed 闸门 |
| `PreToolUse(Edit/Write via apply_patch)` | `pre-edit-guard.sh`、`pre-write-guard.sh` | patch 前检查文件存在性和 search-first |
| `PermissionRequest(Edit/Write via apply_patch)` | `pre-edit-guard.sh`、`pre-write-guard.sh` | 需要额外权限的 patch 审批前闸门 |
| `PostToolUse(Bash/apply_patch)` | `post-build-check.sh` | 命令或 patch 后的构建失败检测 |
| `PostToolUse(Edit/Write via apply_patch)` | `post-edit-guard.sh`、`post-write-guard.sh` | patch 后质量检查与重复实现检查 |
| `Stop` | `stop-guard.sh` | 未验证改动信号（记录 `gate` 事件，但 Stop 不阻塞） |
| `Stop` | `learn-evaluator.sh` | 会话指标与纠错信号采集 |

这是默认强制层，走 Codex 原生 hooks，不包也不替换 Codex server。Codex 当前没有原生 `Read`、`Glob`、`Grep` hook surface，所以 `analysis-paralysis` 不在原生 Codex 路径生效；需要读操作循环拦截时优先用 Claude Code。只有已经必须接入 `codex app-server` 的外部编排系统，才需要考虑下面的可选 wrapper。

Codex 中的 hook 命令名会使用 `vibeguard-*.sh` 命名空间，避免与别的工具链共享 `~/.codex/hooks.json` 时发生冲突。Claude 和 Codex 输出格式差异由 `run-hook-codex.sh` 负责适配；Codex 的 `apply_patch` 会先被 wrapper 规范化成 Edit/Write 形状，再复用现有文件 hook。对 `Update File` patch，wrapper 还会传递行数 delta，让 `pre-edit-guard.sh` 能在 Codex 真正改文件之前执行 U-16 拦截。若 hook 给出 `updatedInput` 建议，Codex CLI wrapper 目前不能自动改写命令，VibeGuard 会显式提示建议命令，而不是静默吞掉这条信息。

### 可选 App Server 外层封装

普通本地 Codex 使用不需要这一层，本地默认保护应使用 `~/.codex/hooks.json` 里的 Codex 原生 hooks。只有你已经在用 `codex app-server` 这类编排器，才需要考虑在外层再包一层 VibeGuard：

```bash
~/.vibeguard/installed/bin/vibeguard-runtime codex-app-server-wrapper \
  --repo-dir ~/vibeguard \
  --codex-command "codex app-server"
```

- `--strategy vibeguard`：默认模式，在外层补上 command、file-change、analysis-loop、post-turn gate
- `--strategy noop`：纯透传，方便调试
- app-server wrapper 是可选编排外壳，主要给已经使用 `codex app-server` 协议的上层系统
- 当前 app-server wrapper 已覆盖：Bash 审批拦截，`applyPatchApproval` / `item/fileChange/requestApproval` 文件变更审批，`pre-edit`、`pre-write`、`post-edit`、`post-write`，读命令循环的 `analysis-paralysis` 提醒，以及 turn 结束后的 stop/build 反馈。
- 运行时是 Rust-only 的 `vibeguard-runtime` 子命令，不再保留 Python app-server wrapper 兼容入口。
- 本地默认保护应使用 `~/.codex/hooks.json` 里的 Codex 原生 hooks
- 原生 Codex 路径仍不支持：`Read`/`Glob`/`Grep` 这类 hook，例如 `analysis-paralysis`

## 安装选项

### Gemini CLI（显式启用）

Gemini CLI 适配器会修改高上下文文件 `~/.gemini/settings.json`，因此默认不启用：

```bash
bash ~/vibeguard/setup.sh --yes --host gemini
bash ~/vibeguard/setup.sh --check --host gemini
```

它为 `run_shell_command`、`write_file`、`replace` 注册一个同步
`BeforeTool` hook，复用现有 Bash/Write/Edit guards，并把拦截结果转换成
Gemini 原生的 `decision: deny`。重复安装是幂等的，保留其他 Gemini 设置和
hooks；`--clean` 只移除 VibeGuard 管理的 hook 与 wrapper。

### 运行时依赖

默认安装会下载并校验与当前版本钉住的 `vibeguard-runtime` release binary。
不支持的平台、离线安装、或显式使用 `--build-from-source` 时，才需要本地
Rust/Cargo 构建。

| 平台 | 默认运行时路径 | 是否需要 Rust/Cargo |
|------|----------------|---------------------|
| macOS arm64 (`aarch64-apple-darwin`) | 预编译 release binary | 否 |
| macOS x86_64 (`x86_64-apple-darwin`) | 预编译 release binary | 否 |
| Linux x86_64 (`x86_64-unknown-linux-musl`) | 预编译 release binary | 否 |
| Linux arm64 (`aarch64-unknown-linux-musl`) | 预编译 release binary | 否 |
| 其他平台、离线安装、或 `--build-from-source` | 本地源码构建 | 是 |

`setup.sh` 优先使用 `gh release download`，没有 `gh` 时使用 `curl`。下载失败且
本机有 Cargo 时会回退到源码构建；校验和不匹配或 `SHA256SUMS` 缺项会直接失败，
不会静默回退。

```bash
# Profiles
bash ~/vibeguard/setup.sh                              # 默认 core profile
bash ~/vibeguard/setup.sh --profile minimal           # 最轻量 Bash/文件闸门 + 文件 post-hooks
bash ~/vibeguard/setup.sh --profile full              # 增加 Stop 信号、Build Check、学习闭环
bash ~/vibeguard/setup.sh --profile strict            # full hooks + Claude Code U-32 SessionStart 约束预算

# 只安装指定语言规则/guards
bash ~/vibeguard/setup.sh --languages rust,python
bash ~/vibeguard/setup.sh --profile full --languages rust,typescript

# 运行时 / 调度器
bash ~/vibeguard/setup.sh --build-from-source          # 强制使用 Cargo 本地构建
bash ~/vibeguard/setup.sh --with-scheduler             # opt in 安装 launchd/systemd 定时 GC
bash ~/vibeguard/setup.sh --yes --host gemini          # opt in Gemini CLI BeforeTool 防护
bash ~/vibeguard/scripts/install-health-report-scheduler.sh --dry-run
bash ~/vibeguard/scripts/install-health-report-scheduler.sh --install  # opt in 安装每周健康报告

# 检查 / 卸载
bash ~/vibeguard/setup.sh doctor                 # 面向人的友好报告，兼容性退出 0
bash ~/vibeguard/setup.sh --check                # doctor 的兼容别名
bash ~/vibeguard/setup.sh verify-install         # CI/post-install 验证，必需状态损坏时退出 2
bash ~/vibeguard/setup.sh verify-project         # strict 项目验证，degraded/broken 时退出 1/2
bash ~/vibeguard/setup.sh verify-dev-repo        # VibeGuard 开发仓库 strict 验证
bash ~/vibeguard/setup.sh verify-project --json  # CI 使用的 JSON 输出
bash ~/vibeguard/setup.sh --clean
```

迁移路径：`--check --strict` 仍可用，推荐改为 `verify-project`；
`--check --json` 推荐改为 `verify-project --json`；`--check --install`
推荐改为 `verify-install`。

### Profiles

| Profile | 安装内容 | 适用场景 |
|---------|----------|----------|
| `minimal` | `pre-write` + `pre-edit` + `pre-bash` + `post-edit` + `post-write` | 最轻量 Bash/文件保护 |
| `core` | `minimal` + Claude Code `analysis-paralysis`（Codex 原生 hooks 不支持） | 默认开发档 |
| `full` | `core` + `stop-guard` + `learn-evaluator` + `post-build-check` | 完整防线 + 学习闭环 |
| `strict` | `full` + Claude Code `count-active-constraints` (SessionStart/U-32)；Codex 原生 hooks 仍为 `full` | 最严格运行策略 |

`setup.sh` 同时会准备共享的 pre-commit wrapper：`~/.vibeguard/pre-commit`，并给本仓库安装 git `pre-commit` 和 `pre-push` hooks。git `pre-push` hook 负责非快进推送/删除远端分支保护；`pre-bash-guard` 不用正则匹配 `git push --force`。要把 wrapper 接到其他仓库，用 `scripts/project-init.sh` 或目标仓库自己的安装步骤。

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
