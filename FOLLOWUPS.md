# VibeGuard Follow-ups（跨会话待办中央索引）

此文件是 **跨会话**/跨协作者的待办索引。当一个动作从想法落到 commit/PR/规则时，从这里移除或标记完成。

**原则**：
- **单一来源**：每个待办只存一处详细内容（通常在对应日期的 knowledge-discovery 文档），此文件只存**一行摘要 + 指针**
- **状态只有三种**：`[ ]` pending / `[~]` in-progress / `[x]` done（同时从此处移除或归档）
- 按"能触发执行"的条件组织，不按时间；已触发的条件放前
- 每条必须可直接变成一个 commit / PR / 实验（否则不是 follow-up，是想法）

---

## P1 — 有具体触发条件，可随时执行

- [ ] **E3 — 合 PR 到 main**：PR #78 / 分支 `docs/scout-2026-04-17` 包含 2026-04-17 scout 文档、Round 2 补分析、W-16 rationalizations 试点，可整体 review 后合入
- [ ] **E1 — W-16 rationalizations 效果观察**：需要 hooks stats（`/vibeguard:stats`）累计 1-2 天数据，量化"试点前后 skip 率变化"

## P2 — 需先验证/试点，结果决定后续

### 规则字段扩散（来自 Round 2 Bridge Note 10）
- [ ] 若 E1 正向 → **E2** rollout `rationalizations` 字段到 W-12 / W-15 / SEC-11 / SEC-12
- [ ] 若 E1 负向 → 开 follow-up PR 移除 W-16 rationalizations 字段，把该概念收回到 `docs/knowledge-discovery/2026-04-17.md` 的 bridge note 段（只记为概念，不入规则）

### 规则内容补充（来自 Round 1/2 Bridge Notes）
- [ ] SEC-12 补 note："即使 5 项机械检查全过仍需人工确认高风险 MCP 工具调用"（Willison 视角，反 illusion of control）
- [ ] W-15 补交叉证据：Stripe Minions CI ≤ 2 轮上限作为跨领域印证
- [ ] `exec-plan` skill 加 Context Anchoring litmus test（"能否无焦虑关闭 session?"作为验收项）

### 产出实验（可能转 skill / 新流程）
- [ ] rss-scout Step 2 本地 heuristics 粗筛 PoC — 对比 GPT-5.4 API 当前 token 成本，决定是否替换
- [ ] 对照 addyosmani/agent-skills 的 20 个 skills 做 VibeGuard 差距分析（半小时，产出差距表）
- [ ] 验证 review / build-fix skill 是否适用 Aider Architect/Editor 分离模式（推理 vs 编辑分离）

## P3 — 背景债务（不阻塞，触发才看）

### 原文核对债务（高置信数据来自二手加工）
**触发条件**：当要据以下数据改规则/改 skill 时，必须先用 `curl | Read` 核对原文，仅文档摘要可不核。

- [ ] Aider 85% SOTA / 14× cheaper（R2.1）
- [ ] Anthropic Code Execution MCP 98.7% token 节省
- [ ] Addy Reality Productivity 数据（Google 21% / Microsoft 26% / METR -19% / Faros +91% review）
- [ ] Stripe Minions CI ≤ 2 轮上限的原文位置

---

## 归档约定

- 完成时：在对应日期的 knowledge-discovery 文档 Follow-ups 段同步标 `[x]`，从本文件移除
- 放弃时：标 `[x]` + 备注"放弃原因"，保留 1 个月后清除
- 新增时：必须写明"触发条件"或"验证实验"，不接受"有空做一下"这类开放项

## 溯源

- Round 1 scout：`docs/knowledge-discovery/2026-04-17.md` 决策表
- Round 2 补分析：`docs/knowledge-discovery/2026-04-17.md` Round 2 决策表
- 创建 commit: 见本文件 git log
