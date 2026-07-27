# Product Spec — Draft 与 Complete 分阶段校验 SpecRail packet

## Linked Issue

GH-720

complexity: medium

## 用户问题

SpecRail 当前把所有 spec packet 都当作已进入实现阶段：即使 PR 仍是 Draft，
也强制要求 `tasks.md`。因此只包含已完成产品与技术设计、尚待形成任务计划的
Draft spec PR 会必然红灯。维护者无法通过 PR 状态表达“设计可评审但尚不可实现”，
已有的五个 Draft spec PR 也被同一条非阶段化检查阻断。

## 目标

- 让 Draft PR 能以 product + tech 的设计阶段 packet 进入评审。
- 保持 Ready PR、`main` 和本地默认检查对完整三件套的强制要求。
- 防止通过删除已有 `tasks.md` 或整个已有 packet 将 Complete 工作降级为 Draft。
- 让 route gate 返回与工作阶段一致、可直接执行的验证命令。

## 非目标

- 不改变 readiness label、duplicate-work、PR、review、runtime ledger 或 merge gate。
- 不批准任何具体 spec，也不改变持久化的 `automation_policy.auth_mode: review`。
- 不为 Draft 放宽 `product.md`、`tech.md` 或已存在 `tasks.md` 的内容校验。
- 不改变 `docs/specs/GH<number>/` 的公开路径。

## Behavior Invariants

1. B-001 未显式选择阶段时，packet 校验必须使用 `complete`；每个被选中的
   `GH<number>` packet 都必须存在 `product.md`、`tech.md` 和有效的
   `tasks.md`，缺少任一项即失败。
2. B-002 显式选择 `draft` 时，每个新建 packet 必须存在且校验
   `product.md` 与 `tech.md`；仅当当前和基线都没有 `tasks.md` 时，
   `tasks.md` 才可缺省。
3. B-003 Draft packet 一旦包含 `tasks.md`，必须执行与 Complete 相同的任务
   计划结构校验；路径是目录、悬空链接或其他非普通文件，或文件为空、格式非法、
   issue 关联错误时，均不得视为成功。
4. B-004 提供有效 `base-ref` 时，`--all-specs` 必须校验当前工作树和基线中
   `GH<number>` packet 的并集；基线已有 packet、当前整体删除时必须失败。
5. B-005 基线 packet 已有 `tasks.md`、当前仅删除该文件时，Draft 校验必须失败，
   不得把删除解释为合法的设计阶段。
6. B-006 无法解析 `base-ref`、无法查询基线树或 packet 路径逃逸配置根时，
   校验必须 fail-closed，并返回非零退出码及可定位错误；合法非 ASCII 配置根
   必须按 Git 原始路径识别，不能因 quoting 丢失基线证据。
7. B-007 GitHub workflow 中所有 checkout-wide packet 检查（包括 adoption
   smoke 内部检查）只能在 Draft pull request 上选择 `draft` 并传入 PR base
   SHA；Ready pull request、push、手工触发均必须选择 `complete`。
8. B-008 pull request 在 Draft 与 Ready 之间切换时必须重新执行 workflow，
   避免复用旧阶段的检查结果。
9. B-009 `write_spec` route 必须返回单 packet 的 Draft 验证命令；
   `implement` 及后续 route 必须返回 Complete 验证命令。
10. B-010 阶段选择只改变 `tasks.md` 的阶段性必需性；现有 pack asset、状态图、
    label、授权模式、skill lock 与 packet 内容检查必须继续执行。

## 验收标准

- [ ] product + tech-only 的新 Draft packet 校验通过。
- [ ] 同一 packet 在 Complete 阶段缺少 `tasks.md` 时校验失败。
- [ ] Draft 中存在但非法的 `tasks.md` 校验失败。
- [ ] 删除基线 `tasks.md` 或整个基线 packet 时 `--all-specs` 校验失败。
- [ ] 无效基线引用 fail-closed。
- [ ] Draft/Ready 状态切换与 route 输出均有回归覆盖。
- [ ] SpecRail adoption、workflow contract 与 broad local contract checks 通过。

## 边界情况清单

| 类别 | 判定（covered: B-xxx / N/A + 原因） |
| --- | --- |
| 空/缺失输入 | covered: B-001, B-002, B-003 |
| 错误与失败路径 | covered: B-006 |
| 授权/权限 | covered: B-007；阶段选择不得改变授权 gate |
| 并发/竞态 | covered: B-007, B-008；每个事件使用自身 base/head 状态 |
| 重试/幂等 | covered: B-008；相同树与相同阶段重复检查结果一致 |
| 非法状态转换 | covered: B-004, B-005, B-008 |
| 兼容/迁移 | covered: B-001, B-010 |
| 降级/回退 | covered: B-004, B-005, B-006 |
| 证据与审计完整性 | covered: B-004, B-006, B-007 |
| 取消/中断 | N/A：离线校验无持久化中间状态，可从头安全重跑 |

## 发布说明

这是 CI/workflow 合同变更，无用户数据迁移。回滚会重新造成 Draft spec PR
必然红灯；若需回滚，必须同时恢复旧 workflow 调用和 CLI/route 文档，不能只
移除一侧。
