# Product Spec

## Linked Issue

GH-626

## 用户问题

VibeGuard 会把 `claude-md/vibeguard-rules.md` 的 compact core 注入用户级
`CLAUDE.md`/`AGENTS.md`。其中 `Key Detailed Rules` 当前手工重写 canonical
规则内容，却没有生成或防漂移门禁；维护者更新 `rules/claude-rules/**` 后，
可能在 CI 全绿的情况下继续向用户分发旧规则语义。

## 目标

- 让 compact detailed-rule 表只从 canonical rule source 派生。
- canonical 规则与 compact 产物不一致时确定性失败。
- 保持默认上下文预算和现有 profile 行为。

## 非目标

- 不改变任何 canonical rule 的正文、severity 或适用范围。
- 不把完整 126 条规则注入 minimal/core 默认上下文。
- 不改变 setup marker、profile 或用户自定义高上下文文件的写入边界。

## Behavior Invariants

1. B-001 compact `Key Detailed Rules` 中每个 rule id、severity 与展示摘要必须
   来自 `rules/claude-rules/**` 的同一 canonical 记录；生成链路不得维护第二份
   规则语义正文。
2. B-002 compact 规则集合必须由显式、稳定、可审查的 rule-id selection 决定；
   canonical 新增规则不得自动扩大默认注入集合。
3. B-003 selection 中的 id 缺失、重复，或 canonical source 无法解析时，生成与
   `--check` 都必须返回非零并指出具体 id/文件，不得保留旧产物继续成功。
4. B-004 canonical 字段或 selection 顺序变化导致产物差异时，CI check 必须失败，
   直到确定性生成产物被更新。
5. B-005 生成后的 compact core 必须继续保留 VibeGuard marker、动态 rule-count
   占位符和 setup 注入契约，并保持 U-32 默认约束预算通过。
6. B-006 相同 canonical 输入与 selection 必须生成字节稳定的表格顺序和内容；
   重复运行不得产生无意义 diff。

## 验收标准

- [ ] 修改被选中 canonical rule 的 severity/摘要后，未刷新 compact 产物的 CI 失败。
- [ ] 修改未选中规则不会扩大 compact table。
- [ ] 缺失/重复 selection id 有明确非零错误。
- [ ] setup 与 U-32 focused tests 通过，默认注入集合不扩大。

## 边界情况清单

| 类别 | 判定（covered: B-xxx / N/A + 原因） |
| --- | --- |
| 空/缺失输入 | covered: B-003 |
| 错误与失败路径 | covered: B-003, B-004 |
| 授权/权限 | N/A：离线生成器不改变文件系统授权模型 |
| 并发/竞态 | N/A：生成器是单进程确定性命令 |
| 重试/幂等 | covered: B-006 |
| 非法状态转换 | N/A：无持久状态机 |
| 兼容/迁移 | covered: B-005 |
| 降级/回退 | covered: B-003；禁止旧产物假成功 |
| 证据与审计完整性 | covered: B-001, B-002, B-004 |
| 取消/中断 | N/A：中断后重新运行生成/check 即可 |

## 发布说明

这是维护与分发一致性修复；不改变用户配置或规则集合。实现 PR 应说明 compact
table 已成为 generated surface，并更新维护者编辑入口。
