# Minions 系统实现分析（基于 Stripe Part 2）

- 参考文章: https://stripe.dev/blog/minions-stripes-one-shot-end-to-end-coding-agents-part-2
- 文章日期: 2026-02-19
- 目标: 把 Stripe 在 Part 2 提到的核心机制，转成一套可在 VibeGuard/企业内落地的实现方案

## 1. 核心设计抽象（从文章提炼）

1. 运行环境先行: 不是先做 Agent，而是先有可并行、可隔离、可复现的 devbox。
2. 编排采用 Blueprint: 用“确定性节点 + Agent 节点”混合状态机，避免纯 ReAct 漫游。
3. 上下文分层: 静态规则走文件系统（规则文件），动态信息走 MCP 工具。
4. 工具集中治理: 一个共享 MCP 能力层（Toolshed），对不同 Agent 下发不同工具子集。
5. 反馈左移: 本地确定性 lint/test 先跑，再进入 CI；CI 只给有限回合迭代（通常 1~2 轮）。
6. 安全靠“多层收敛”: 环境隔离 + 工具权限收敛 + 破坏性动作拦截 + 全量审计。

## 2. 目标架构（建议 7 层）

1. 任务入口层
- 来源: CLI、Slack、Web、Issue/Ticket。
- 产物: 标准化任务对象（需求、代码范围、风险级别、完成定义）。

2. 编排层（Blueprint Engine）
- 将任务映射为状态机。
- 每个状态声明: 输入、输出、可用工具、预算、重试上限、退出条件。
- 节点类型:
  - DeterministicNode（shell/check/git/ci/api）
  - AgentNode（LLM + 工具循环）

3. 执行环境层（Devbox Pool）
- 预热池 + 秒级分配。
- 每个任务独占环境，自动销毁，杜绝任务间污染。
- 预热内容: repo 克隆、依赖缓存、编译缓存、代码生成服务、静态索引。

4. Agent Harness 层
- 负责调用模型、工具路由、上下文压缩、对话记忆窗口管理。
- 支持子代理配置（Implement/Fix CI/Refactor 各自独立配置）。

5. 上下文层（Rules + MCP）
- Rules: 路径/模式匹配自动注入（类似 AGENTS.md/CLAUDE.md/Cursor Rules）。
- MCP: 文档、工单、CI、代码检索、服务元数据、发布系统等动态信息获取。

6. 反馈与质量层
- 本地 deterministic checks: format/lint/typecheck/smoke tests。
- 选择性测试策略: 仅跑与改动路径相关的测试子集。
- CI 回合上限: 1 次自动修复 + 1 次最终尝试，超限转人工。

7. 安全与审计层
- 运行在 QA/沙箱网络，不可访问生产数据。
- 工具按能力分级，默认最小权限。
- 所有工具调用、命令、差异、CI 结果可回放审计。

## 3. Blueprint 最小可行状态机（MVP）

```yaml
name: one_shot_codegen
states:
  - plan_task: agent
  - implement: agent
  - run_format_lint: deterministic
  - run_targeted_tests: deterministic
  - push_branch: deterministic
  - run_ci_round_1: deterministic
  - apply_ci_autofix: deterministic
  - fix_ci_failures: agent
  - run_ci_round_2: deterministic
  - handoff_to_human: deterministic

transitions:
  - plan_task -> implement
  - implement -> run_format_lint
  - run_format_lint(pass) -> run_targeted_tests
  - run_format_lint(fail,retry<2) -> implement
  - run_targeted_tests(pass) -> push_branch
  - run_targeted_tests(fail,retry<2) -> implement
  - push_branch -> run_ci_round_1
  - run_ci_round_1(pass) -> handoff_to_human
  - run_ci_round_1(fail_with_autofix) -> apply_ci_autofix
  - apply_ci_autofix -> run_ci_round_2
  - run_ci_round_1(fail_no_autofix) -> fix_ci_failures
  - fix_ci_failures -> run_ci_round_2
  - run_ci_round_2(*) -> handoff_to_human
```

## 4. 关键实现细节（决定成败）

1. “小盒子”原则
- AgentNode 不共享同一套超大工具集。
- 每个节点只开放该节点需要的工具和规则，减少误操作和 token 浪费。

2. 上下文注入策略
- 全局规则严格限长。
- 主体依赖“目录级规则 + 文件模式规则”按需加载。
- Rules 一套多端复用（Minion/IDE Agent/CLI Agent），避免知识分叉。

3. 失败恢复语义
- 每个节点输出结构化错误码（如 `LINT_FAIL`、`TEST_FAIL`、`CI_INFRA_FAIL`）。
- 只对“可恢复失败”重试；基础设施故障直接中断并回传人工。

4. 成本控制
- 每个节点设置 token/时间预算。
- CI 轮次硬上限（建议 2）。
- 对高成本工具（全量测试、大索引检索）设置触发条件。

5. 安全闭环
- 命令执行白名单 + 高风险命令阻断。
- MCP 工具动作分级（read/write/privileged），默认只读。
- 每次 run 保留可审计工件（prompt、tool call、patch、日志、CI 链接）。

## 5. 分阶段落地路线图（10 周示例）

第 1-2 周: 执行环境
- 建 devbox 预热池（先支持单仓库）。
- 完成任务级隔离与自动回收。

第 3-4 周: Blueprint 引擎
- 实现 DeterministicNode + AgentNode + 状态转移。
- 打通最小链路: `implement -> lint -> tests -> push`。

第 5-6 周: 上下文层
- 上线路径规则自动加载。
- 接入 MCP 网关与 10~20 个核心只读工具。

第 7-8 周: CI 迭代闭环
- 接入 CI 查询、失败解析、autofix 应用。
- 实现 2 轮上限策略与人工回退。

第 9-10 周: 安全与观测
- 完成工具权限模型、网络隔离校验、审计日志回放。
- 上线核心指标看板与告警。

## 6. 指标体系（上线即追踪）

1. `one_shot_success_rate`: 首轮 CI 通过并可评审的比例。
2. `pr_merge_rate`: Agent 产出 PR 的最终合并率。
3. `median_cycle_time`: 从任务下发到可评审 PR 的中位时长。
4. `ci_rounds_per_task`: 每任务平均 CI 回合数（目标 <= 2）。
5. `token_cost_per_merged_pr`: 每个合并 PR 的 token 成本。
6. `human_rework_ratio`: 人工重写代码占比（越低越好）。
7. `policy_violation_count`: 安全策略触发次数。

## 7. 对 VibeGuard 的直接落地建议

1. 先把 `vibeguard hooks` 提升为 Blueprint 中的 deterministic nodes，而不是纯被动检查。
2. 新增 `run_targeted_tests` 节点（按改动路径映射测试），减少全量测试依赖。
3. 将 `AGENTS.md` 规则做路径化拆分，避免全局规则占满上下文窗口。
4. 建一个最小 MCP 聚合层（文档检索、Issue、CI 三类工具先行）。
5. 固化“最多 2 轮 CI”策略，超限直接转人工，避免无界循环。

## 8. MVP 验收标准

1. 能稳定并行运行 20+ 任务，任务间无文件污染。
2. 70% 以上任务在本地 checks 阶段即可发现问题并修复。
3. 首轮 CI 通过率达到可持续提升趋势（初期 25%~40% 可接受）。
4. 全链路可审计，可追踪每个 patch 的来源和决策路径。
5. 任一任务失败后可在 5 分钟内定位失败节点与根因类型。
