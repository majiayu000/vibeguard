# ExecPlan Template（长周期任务执行计划）

> 来源：OpenAI Harness Engineering ExecPlan 规范，适配 VibeGuard plan-flow 格式。
> ExecPlan 是活文档 — 仅凭自身即可在新会话中恢复执行，无需其他上下文。

```md
# ExecPlan: <任务名>

- 创建日期: <YYYY-MM-DD>
- 来源 SPEC: <spec 文件路径 | 无>
- 计划版本: v1
- 状态: draft | active | completed | abandoned

---

## 1. Purpose（目的）

用户获得什么能力？一段话描述最终交付物和核心价值。
不写背景铺垫，不写技术选型理由（理由放 Decision Log）。

## 2. Progress（进度）

> 唯一允许 checklist 的章节。每个里程碑对应 Concrete Steps 中的一组步骤。

- [ ] M1: <里程碑描述>
- [ ] M2: <里程碑描述>
- [ ] M3: <里程碑描述>

## 3. Context（上下文）

恢复执行所需的最小上下文：

- **项目路径**: <绝对路径>
- **语言/框架**: <e.g. Rust + Axum>
- **关键入口**: <e.g. src/main.rs, src/lib.rs>
- **相关约束集**: <preflight 输出路径 | 无>
- **已有决策**: <引用 Decision Log 条目编号>

## 4. Plan of Work（工作规划）

按里程碑分组的高层工作规划，不含实现细节（细节在 Concrete Steps）。

### M1: <里程碑名>
- 目标: <交付什么>
- 涉及文件: <文件列表>
- 前置条件: <依赖的里程碑或外部条件>

### M2: <里程碑名>
- 目标: ...
- 涉及文件: ...
- 前置条件: ...

## 5. Concrete Steps（具体步骤）

> 格式对齐 plan-template.md 的 Step 格式。每步必须包含精确命令、工作目录、预期输出。

### Step A1: <标题>

- 状态: `pending`
- 所属里程碑: M1
- 目标: <这一步交付什么>
- 预计改动文件:
  - `<file1>`
  - `<file2>`
- 详细改动:
  - <实现细节 1>
  - <实现细节 2>
- 步骤级测试命令:
  - `<command>` — 预期: <pass/特定输出>
- 完成判定:
  - <done criteria>

### Step A2: <标题>

- 状态: `pending`
- 所属里程碑: M1
- ...

## 6. Validation（验证）

可观察的行为验证，具体到输入/输出：

| 场景 | 输入 | 预期输出 | 验证命令 |
|------|------|----------|----------|
| 正常路径 | <input> | <output> | `<command>` |
| 边界情况 | <input> | <output> | `<command>` |
| 错误路径 | <input> | <output> | `<command>` |

回归测试:
- `<全量测试命令>`

## 7. Idempotence（幂等性）

安全重试路径和回滚程序：

- **重试安全**: <描述为什么可以安全重新执行步骤>
- **回滚程序**: <git revert / 手动步骤>
- **部分完成恢复**: <如何从中间状态继续>

## 8. Execution Journal（执行日志）

### Decision Log（决策记录）

| 日期 | 编号 | 决策 | 理由 | 替代方案 |
|------|------|------|------|----------|
| <date> | D1 | <决策> | <理由> | <被否决的方案> |

### Surprises（意外发现）

| 日期 | 编号 | 发现 | 影响 | 处理 |
|------|------|------|------|------|
| <date> | S1 | <描述> | <对计划的影响> | <调整措施> |

### Step Completion Log（步骤完成记录）

- <YYYY-MM-DD>
  - Step A1: `completed`
    - 修改文件: `<file>`
    - 主要改动: <summary>
    - 测试结果: `<command>` -> pass
```

## 使用规则

1. **Progress 是唯一允许 checklist 的章节** — 其他章节用散文描述。
2. **Concrete Steps 每次只有一个 `in_progress`** — 完成当前步骤测试后才能推进下一步。
3. **Decision Log 记录所有变更理由** — 偏离原始 SPEC 时必须记录。
4. **ExecPlan 是自包含的** — 新会话仅凭 ExecPlan 文件即可恢复执行，不依赖聊天历史。
5. **散文优先** — 代码块只用于命令和输出，不嵌套 fenced blocks。
