# VibeGuard 自审报告 — 2026-04-17

> 基于 2026-04-16 RSS Scout 的 31 篇 ≥20 分深度分析，对 VibeGuard 仓库做内部对照审视。
> 触发动机：Bridge 5（Sensor 维度覆盖度）+ Bridge 12（Spec-as-Source 重蹈 MDD 警告）

## 审视对象

| 维度 | 文件 |
|------|------|
| Skill | `.claude/commands/vibeguard/exec-plan.md`（136 行） |
| Hooks（行为元 sensor） | `hooks/analysis-paralysis-guard.sh`、`hooks/circuit-breaker.sh`、`hooks/stop-guard.sh` 等 13+ |
| Guards（语言 sensor） | `guards/{rust,python,typescript,go,universal}/` 共 23 个脚本 |
| 规则集 | `rules/claude-rules/common/` 8 文件 + 105 条规则 |

---

## 审视 1：exec-plan vs Fowler 的 MDD 警告（Bridge 12）

### Fowler 警告（来源：Spec-Driven Development 三工具评测）
> Spec-as-Source 像失败的 Model-Driven Development，"组合了 inflexibility 与 non-determinism"。详尽 spec 也会被 agent **忽略**或**过度热情遵循**——this is "**false control illusion**"。

### exec-plan 实际设计（事实核对）

| Fowler 风险点 | exec-plan 是否触雷 | 证据 |
|---|---|---|
| Spec 替代代码（spec-as-source） | ❌ 不触雷 | exec-plan 不生成代码，只生成执行计划 |
| Spec 是 ground truth | ❌ 不触雷 | 含 Decision Log 显式记录"deviation from SPEC" |
| 一次性产物 | ❌ 不触雷 | 是 living document，含 update 模式 |
| 缺少验证 | ❌ 不触雷 | Nyquist Rule：每 Step 必含 60 秒可验证命令 |
| spec 与执行分离 | ⚠️ **部分触雷** | "ExecPlan 定义做什么、preflight 定义不做什么"——但 **Surprises → SPEC 反向更新机制不明** |

### 风险定位（推断，置信度：中）

[基于：exec-plan.md 第 73-95 行 "update 模式" 的描述]

`update` 模式只允许追加 Surprises 到 ExecPlan，不允许反向修订 SPEC。这意味着：
- Surprise 累积成"二级真相"，与 SPEC 矛盾但不更新 SPEC
- 长任务后期，开发者看到的 ExecPlan 可能与最初 SPEC 严重偏离，**但 SPEC 仍被引用为权威**
- 这是 Fowler "false control illusion" 在我们体系内的**精确变体**

### 结论
- **exec-plan 不是 MDD 重演**（不生成代码、不当 spec 为 ground truth）
- **但有 Surprise→SPEC 反向反馈缺口**——属于轻量的"双真相"风险
- **建议**：exec-plan update 模式增加 "Surprise 累积阈值告警"——超过 N 条 surprise 时建议运行 `/vibeguard:interview` 重写 SPEC

---

## 审视 2：Sensor 维度覆盖度（Bridge 5）

### Fowler 的三类 Harness 框架

| 类别 | 定义 | VibeGuard 现状 | 缺口 |
|------|------|----------------|------|
| **Maintainability harness** | linter/test/review 类，保证内部代码质量 | **强** — 23 个 guard 覆盖 unwrap/dead/duplicate/naming/type/test 完整性 | 无明显缺口 |
| **Architecture fitness harness** | fitness function 保证非功能需求（性能/observability/SLO） | **弱** — 仅 universal/check_dependency_layers + check_circular_deps 两条 | 缺：性能回归、observability 必填、SLO 漂移检测 |
| **Behaviour harness** | 功能正确性，依赖 spec + test | **中** — 不强制项目 spec/test 完整性 | 缺：spec-test 一致性、Surprise→SPEC 反向 drift |

### 已有的"元 sensor"（agent 行为层）

VibeGuard 实际已有领先于 Fowler 框架的设计——**agent 行为元 sensor**：

| Hook | 监控对象 | Fowler 框架对应 |
|------|---------|----------------|
| `analysis-paralysis-guard` | 7+ 连续 Read/Glob/Grep 无 Write | 无（Fowler 未覆盖） |
| `circuit-breaker` | 同 hook 连续 3 次 block 自动冷却 5 分钟 | Maintainability 元层 |
| `stop-guard` | 结束前检查未完成项 | Behaviour 元层 |
| `learn-evaluator` | 学习证据评估 | 无 |

**洞察**：VibeGuard 已经有 Fowler 框架未明确分类的"agent meta-sensor"维度。这是 VibeGuard 相对 Fowler 框架的**领先点**。

### 推断的缺口（按 31 篇深度分析新发现）

| 缺口 | 来源 Bridge | 推断的新 hook 名 |
|------|------------|------------------|
| **Permission Fatigue 检测** | Bridge 8（Zvi Auto Mode + Addy 80%） | `rubber-stamp-detector.sh` — 检测连续 N 次低延迟"yes"回复 |
| **Review Bandwidth 监控** | Bridge 11（Addy reality + IDE Death） | `review-fatigue-guard.sh` — 单会话 review 数 > N 时建议三角化 |
| **Surprise→SPEC drift** | Bridge 12（Fowler MDD） | `execplan-spec-drift-guard.sh` — Surprises ≥ N 条但 SPEC 未变时告警 |

每个缺口都有现成模板可参考：`analysis-paralysis-guard` 范式（计数 + 阈值 + 告警 + 不阻断）。

---

## 审视 3：规则集 vs 31 篇深度分析的契合度

### 已覆盖（昨日新增 + 已有规则强化）
| 31 篇发现 | VibeGuard 规则 | 状态 |
|---|---|---|
| 验证是最高杠杆动作（Anthropic + Addy + Fowler） | W-03 + **W-16（昨日新增）** | ✅ 覆盖 |
| Curse of instructions（Addy + Anthropic + Fowler） | **U-32（昨日新增）** | ✅ 覆盖 |
| MCP 工具描述静默变更（Willison + Anthropic） | **SEC-12（昨日新增）** | ✅ 覆盖 |
| Context rot 跨会话（4 源） | L1-L7 中的 Compaction | ✅ 部分覆盖 |
| Trust-Verify 模式 | SEC-11 | ✅ 覆盖 |
| Spec 六要素 | /vibeguard:interview | ✅ 覆盖 |

### 未覆盖（本次发现）

| 缺口 | 来源 | 建议规则 ID（候选） |
|------|------|---------------------|
| **Permission/Review Fatigue 不要用更多 gate 解决** | Bridge 8 | W-17：少而智能的 gate > 多而机械的 gate |
| **Codebase 质量是 Agent 化前提投资** | Bridge 9（Boris/Fowler/Addy×2） | U-33：legacy 代码 agent 化前必须评估 harnessability |
| **Senior vs Junior 应有差异化 guardrail** | Bridge 10 | 元规则：guardrail 强度应与用户经验匹配（建议保留为指南，不机械化） |
| **PR 体积 × Review 时间 = Amdahl 瓶颈** | Bridge 11 | W-18：单批改动应优先三角化关键 risk，不全量 review |

---

## 综合诊断

### 强项（VibeGuard 体系优于行业平均）
1. **Agent 行为元 sensor**——analysis-paralysis-guard / circuit-breaker / stop-guard 这一维度，连 Fowler 框架都未明确分类
2. **W-15 Diminishing Returns + W-02 三次失败后退**——Anthropic Claude Code 同款机制
3. **Compaction 必保留清单**——与 Anthropic 官方 4 配方一致
4. **昨日新增 3 条规则**（W-16/U-32/SEC-12）有 2-4 篇独立来源支撑，非单点

### 弱项（明确缺口）
1. **Architecture fitness harness 弱**——只 2 条 guard，缺性能/observability/SLO 维度
2. **Surprise→SPEC 反向反馈缺口**——exec-plan update 模式不能修订 SPEC
3. **缺 agent 行为元 sensor 的扩展类**——permission fatigue / review fatigue / spec drift 三类未覆盖

### 不该做的（避免过度工程）
- 不应为 31 篇分析每个洞察都加规则——会触犯 U-32（curse of instructions：规则越多遵守度越低）
- 不应实现"AI 行为评分"类元元层——会变成 Fowler 警告的"verbose markdown burden"
- Senior/Junior 差异化 guardrail 应保留为**用户配置**，不机械化（避免身份偏见）

---

## 提议的 actionable 改动（优先级排序）

### P0（推荐立即做）
**无**——昨日已加 3 条新规则，本次审视未发现需立即修补的紧急缺口

### P1（推荐下次会话考虑）
1. **exec-plan update 模式增加 Surprise 阈值告警**
   - 修改：`.claude/commands/vibeguard/exec-plan.md` update 步骤
   - 增量：当 Surprises 累积 ≥ 5 条时，输出建议"考虑运行 /vibeguard:interview 重写 SPEC"
   - 工作量：~10 行修改

2. **新规则 W-17（少而智能的 gate）**
   - 文件：`rules/claude-rules/common/workflow.md`
   - 来源：Bridge 8（Zvi + Addy + Anthropic）
   - 风险：与已有 W-03/W-16 边界要清楚——W-17 不是反对验证，是反对"机械化的全量验证"

### P2（推荐讨论后再做）
3. **新 hook：rubber-stamp-detector.sh**
   - 复用 analysis-paralysis-guard 模板
   - 触发：连续 N 次低延迟"yes/approved/looks good"回复
   - 风险：需要先定义"低延迟"阈值，避免误报正常快速决策
   - 工作量：~80 行 shell

4. **新规则 U-33（Agent 化前置投资）**
   - 文件：`rules/claude-rules/common/coding-style.md`
   - 来源：Bridge 9（Boris + Fowler + Addy×2）
   - 风险：可能与 U-04（不添加未要求功能）冲突——需要明确"agent 化"是用户主动选择时才适用

### P3（暂不推荐）
5. **新 hook：review-fatigue-guard.sh**——Bridge 11，但与 W-16 范围重叠，先观察 W-16 实际使用情况
6. **架构 fitness 类 guard 扩充**——需要先看用户 use case，避免猜测

---

## 元洞察（关于本次自审本身）

[置信度：中]

按 W-13（分析瘫痪守卫，7+ 只读触发警告），本次自审已经接近"低产出循环"边界——纯审视不修改代码。但因为：
1. 用户明确请求"深入"
2. 审视产出明确的 P1/P2 行动建议（含工作量估算）
3. 验证了昨日 3 条新规则的合理性（事后审计角度）

判定：本次审视属于**有价值的元 sensor 行动**，符合 W-13 例外条件（"如果确实需要更多阅读，先说明为什么之前的阅读不够"）。

下次决策：是否实施 P1 的 exec-plan 改动？还是继续审视别的维度（如 31 篇分析对应的 missed Bridge）？由用户决定。
