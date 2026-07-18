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

- 不改变任何 canonical rule 的既有规范正文、severity 或适用范围；新增的
  `Compact guidance` 是同一 record 的分发展示字段，不替代规范正文。
- 不把完整 126 条规则注入 minimal/core 默认上下文。
- 不改变 setup marker、profile 或用户自定义高上下文文件的写入边界。
- 不让 generator 改写 compact 表之外的 L1-L7、Chat Contract、workflow maturity、
  order、priority 或其他人工维护内容。

## Behavior Invariants

1. B-001 compact `Key Detailed Rules` 中每个 rule id、severity 与展示文案必须
   来自 `rules/claude-rules/**` 的同一 canonical 记录。被选中的记录必须包含唯一、
   非空、单行的 `**Compact guidance:**` 字段；renderer 不得用通用 `Rule.summary`
   启发式、rule title 或旧产物 fallback 代替该字段。
2. B-002 compact 规则集合必须由显式、稳定、可审查的 rule-id selection 决定；
   canonical 新增规则不得自动扩大默认注入集合。
3. B-003 selection id 缺失/重复、同一 selected id 在 canonical source 中出现多条
   记录、selected record 的 compact guidance 缺失/重复/为空，或 canonical source
   无法解析时，生成与 `--check` 都必须返回非零并指出具体 id/文件，不得读取旧产物
   后继续成功。
4. B-004 canonical severity/compact guidance 或 selection 顺序变化导致产物差异时，
   CI check 必须失败，直到确定性生成产物被更新。
5. B-005 compact table 必须位于唯一、顺序正确的专用 inner start/end markers 之间。
   marker 缺失、重复或错序时 write/check 都必须非零失败；成功生成只能替换 marker
   内部，marker 之前和之后的字节必须保持不变。
6. B-006 生成后的 compact core 必须继续保留外层 VibeGuard marker、动态 rule-count
   占位符和 setup 注入契约，并保持 U-32 默认约束预算通过。
7. B-007 首次迁移必须把当前 16 条 compact 行逐条写入各自 canonical record 的
   `Compact guidance` 字段；生成后的 id、severity、顺序和展示文案必须与迁移前
   compact 表逐行一致，不得把可执行约束弱化为首句摘要或截断文本。
8. B-008 相同 canonical 输入与 selection 必须生成字节稳定的表格顺序和内容；
   重复运行不得产生无意义 diff。

## 验收标准

- [ ] 修改被选中 canonical rule 的 severity/compact guidance 后，未刷新 compact 产物的
      CI 失败。
- [ ] 修改未选中规则不会扩大 compact table。
- [ ] 缺失/重复 selection id、重复 selected canonical record 与缺失/重复/空 guidance
      都有包含 id/文件的非零错误。
- [ ] inner marker 缺失、重复或错序时非零失败，且成功生成前后的区块外字节完全一致。
- [ ] 迁移前后的 16 条 compact 行逐行一致，U-17、SEC-01、SEC-02 与 SEC-13 等
      行仍保留当前可执行指导，不使用首句启发式或截断文本。
- [ ] setup 与 U-32 focused tests 通过，默认注入集合不扩大。

## 边界情况清单

| 类别 | 判定（covered: B-xxx / N/A + 原因） |
| --- | --- |
| 空/缺失输入 | covered: B-003, B-005 |
| 错误与失败路径 | covered: B-003, B-004, B-005 |
| 授权/权限 | N/A：离线生成器不改变文件系统授权模型 |
| 并发/竞态 | N/A：生成器是单进程确定性命令 |
| 重试/幂等 | covered: B-008 |
| 非法状态转换 | N/A：无持久状态机 |
| 兼容/迁移 | covered: B-006, B-007 |
| 降级/回退 | covered: B-001, B-003, B-007；禁止启发式/旧产物假成功 |
| 证据与审计完整性 | covered: B-001, B-002, B-004, B-005, B-007 |
| 取消/中断 | N/A：中断后重新运行生成/check 即可 |

## 发布说明

这是维护与分发一致性修复；不改变用户配置或规则集合。实现 PR 应说明 compact
table 已成为 generated surface，并更新维护者编辑入口。
