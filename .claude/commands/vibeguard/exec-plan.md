---
name: "VibeGuard: ExecPlan"
description: "长周期任务执行计划 — 从 SPEC 生成自包含执行文档，支持跨会话恢复"
category: VibeGuard
tags: [vibeguard, execplan, long-horizon, planning]
---

<!-- VIBEGUARD:EXEC-PLAN:START -->
**核心理念**（来自 OpenAI Harness Engineering）
- 长周期任务需要自包含的执行文档，仅凭自身即可在新会话中恢复执行
- Progress 是唯一允许 checklist 的章节，其余用散文描述
- Decision Log 记录所有偏离 SPEC 的决策，确保可追溯
- ExecPlan 是活文档，随执行持续更新

**三种模式**

| 模式 | 用法 | 说明 |
|------|------|------|
| `init` | `/vibeguard:exec-plan init [spec路径]` | 从 SPEC 生成 ExecPlan |
| `update` | `/vibeguard:exec-plan update <execplan路径>` | 追加 Discovery/Decision/完成状态 |
| `status` | `/vibeguard:exec-plan status <execplan路径>` | 查看 Progress 进度摘要 |

**触发条件**
- SPEC 已通过 `/vibeguard:interview` 生成并确认
- 预计跨 2+ 会话完成的任务
- 需要跨会话恢复执行上下文的场景

**Guardrails**
- `init` 模式不做任何代码修改，只生成文档
- `update` 模式只修改 ExecPlan 文件本身
- 不替代 preflight — ExecPlan 定义"做什么"，preflight 定义"不可做什么"

---

### Mode: init

从 SPEC 生成 ExecPlan 文件。

**Steps**

1. **读取 SPEC**
   - 如果提供了 spec 路径（$ARGUMENTS），读取该文件
   - 如果未提供，搜索项目根目录的 `SPEC.md`
   - 如果没有 SPEC，提示用户先运行 `/vibeguard:interview`

2. **分析 SPEC 并分解里程碑**
   - 从 SPEC 的功能需求（FR-XX）提取里程碑
   - 每个里程碑包含 1-3 个具体步骤
   - 识别里程碑间的依赖关系

3. **扫描项目上下文**
   - 识别语言/框架、关键入口文件
   - 检查是否有 preflight 约束集可引用
   - 记录与 SPEC 相关的现有代码位置

4. **生成 ExecPlan**
   - 按模板（`workflows/plan-flow/references/execplan-template.md`）填充 8 个章节
   - Purpose 直接从 SPEC 概述提取
   - Progress 映射为带 checkbox 的里程碑列表
   - Concrete Steps 对齐 plan-template.md 的 Step 格式（状态/目标/文件/改动/测试/判定）
   - Validation 从 SPEC 验收标准（AC-XX）转化
   - Decision Log 初始为空，记录生成时的选型决策

5. **保存并确认**
   - 保存到 `<项目名>-execplan.md`（项目根目录）
   - 展示 Progress 和 Concrete Steps 摘要给用户确认
   - 用 AskUserQuestion 确认是否需要调整

---

### Mode: update

追加执行过程中的发现和状态变更。

**Steps**

1. **读取 ExecPlan**
   - 读取 $ARGUMENTS 指定的 ExecPlan 文件
   - 解析当前 Progress 和 Concrete Steps 状态

2. **识别更新类型**
   - 步骤完成：更新 Step 状态为 `completed`，追加 Step Completion Log
   - 新发现：追加到 Surprises 表
   - 决策变更：追加到 Decision Log 表
   - 里程碑完成：勾选 Progress 中对应 checkbox

3. **执行更新**
   - 修改 ExecPlan 文件中对应章节
   - 如果步骤完成，自动将下一个 `pending` 步骤标记为 `in_progress`
   - 如果所有里程碑完成，将计划状态改为 `completed`

4. **展示更新摘要**
   - 输出变更的章节内容
   - 如果有 Surprises，高亮提示可能需要调整后续步骤

---

### Mode: status

查看执行进度摘要。

**Steps**

1. **读取 ExecPlan**
   - 读取 $ARGUMENTS 指定的 ExecPlan 文件

2. **输出进度报告**
   ```
   ExecPlan: <任务名>
   状态: active
   进度: 2/5 里程碑完成 (40%)

   [x] M1: <描述>
   [x] M2: <描述>
   [ ] M3: <描述> ← 当前
       Step C1: completed
       Step C2: in_progress
       Step C3: pending
   [ ] M4: <描述>
   [ ] M5: <描述>

   最近决策: D3 — <决策摘要>
   意外发现: 1 项未处理
   ```

**后续衔接**
- 完整流水线：`/vibeguard:interview` → SPEC → `/vibeguard:exec-plan init` → `/vibeguard:preflight` → 执行 → `/vibeguard:exec-plan update`
- ExecPlan 与 preflight 互补：ExecPlan 定义执行路径，preflight 定义防护边界
- 新会话恢复：读取 ExecPlan → `/vibeguard:exec-plan status` → 继续执行

**Reference**
- ExecPlan 模板：`workflows/plan-flow/references/execplan-template.md`
- 集成说明：`workflows/plan-flow/references/execplan-integration.md`
- Plan-flow 步骤格式：`workflows/plan-flow/references/plan-template.md`
- OpenAI Harness 参考：`memory/harness-engineering.md`
<!-- VIBEGUARD:EXEC-PLAN:END -->
