# ExecPlan 集成说明

> ExecPlan 如何与 VibeGuard 现有的 plan-flow 和 plan-mode 协作。

## 何时用 ExecPlan vs plan-flow vs plan-mode

| 工具 | 适用场景 | 生命周期 | 产出 |
|------|----------|----------|------|
| **plan-mode** | 单会话任务，需要用户审批方案 | 当前会话 | 实现方案（会话内消费） |
| **plan-flow** | 存量代码整理，冗余分析+逐步收敛 | 1-3 会话 | plan/*.md（分析+步骤+日志） |
| **ExecPlan** | 长周期功能开发，从 SPEC 驱动的跨会话执行 | 2+ 会话 | *-execplan.md（自包含恢复文档） |

### 决策树

```
任务到手
├── 能一个会话做完？
│   ├── 是 → 1-2 文件直接做 / 3-5 文件 plan-mode
│   └── 否 ↓
├── 是存量代码整理/重构？
│   ├── 是 → plan-flow（冗余扫描 + 逐步收敛）
│   └── 否 ↓
└── 是新功能开发/长周期任务？
    └── 是 → interview → SPEC → exec-plan → preflight → 执行
```

## plan-flow 如何识别 ExecPlan

plan-flow 的 redundancy_scan.sh 扫描时，遇到 `*-execplan.md` 文件应跳过冗余分析。原因：ExecPlan 的 Concrete Steps 与 plan-flow 的 Step 格式相同但语义不同 — ExecPlan 步骤描述的是未来要做的事，不是已完成的冗余收敛记录。

识别规则：
- 文件名匹配 `*-execplan.md`
- 或文件头包含 `状态: draft | active | completed | abandoned`

## 完整流水线

```
/vibeguard:interview
    │
    ▼
  SPEC.md（需求合同）
    │
    ▼
/vibeguard:exec-plan init
    │
    ▼
  *-execplan.md（执行计划）
    │
    ▼
/vibeguard:preflight（约束集）
    │
    ▼
  执行（按 Concrete Steps 逐步推进）
    │
    ├── 每步完成 → /vibeguard:exec-plan update
    ├── 新会话恢复 → /vibeguard:exec-plan status
    └── 验证 → /vibeguard:check
    │
    ▼
  完成 → /vibeguard:exec-plan update（标记 completed）
```

## 与 preflight 的关系

ExecPlan 和 preflight 是互补的：

- **ExecPlan** 定义"做什么" — 里程碑、步骤、验证标准
- **preflight** 定义"不可做什么" — 约束集、守卫基线、防护边界

推荐流程：先生成 ExecPlan（明确执行路径），再运行 preflight（建立防护边界），然后按 ExecPlan 步骤执行时对照 preflight 约束集自检。

## 跨会话恢复协议

新会话恢复执行时：

1. 读取 `*-execplan.md`
2. 运行 `/vibeguard:exec-plan status` 查看进度
3. 找到第一个 `in_progress` 或 `pending` 的步骤
4. 读取 Context 章节恢复项目上下文
5. 读取 Decision Log 了解已有决策
6. 继续执行
