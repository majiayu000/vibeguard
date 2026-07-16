# Product Spec: pre-write L1 escalation 可恢复搜索边界

## Linked Issue

GH-615

## 用户问题

`pre-write-guard` 当前把同一会话中的每次新 source file 尝试都视为“未响应提醒”，包括 circuit
breaker 已经静默放行、用户根本看不到 L1 提醒的尝试。达到阈值后，即使用户按阻断文案执行了
Grep 或 Glob，同一会话仍永久阻断后续新文件；文案建议在当前 session 中 `export` 环境变量，但
hook 子进程无法修改已运行 agent 的父进程环境。结果是正常 greenfield scaffolding 可能被无证据、
不可恢复地锁死。

## 目标

- escalation 只累计用户实际可见的 `New source file reminder`，不累计 circuit-breaker-silenced
  attempt。
- 同一 session 中实际执行 Grep 或 Glob 后，清除此前未响应提醒的计数边界，使下一次新 source
  file write 不再被旧 escalation 锁死。
- 保留“搜索后若继续忽略新的可见提醒，仍会再次 escalation”的 L1 anti-duplication 约束。
- escalation 文案只给出当前 session 内真实可执行的恢复动作，不再声称 child hook 内的 `export`
  能解除父进程中的阈值。

## 非目标

- 不引入“greenfield repository”、commit 数量、文件数量或目录为空等新启发式。
- 不改变 `VIBEGUARD_WRITE_MODE=block` 的立即阻断语义，也不改变 escalation threshold 为 `0` 时的
  禁用语义。
- 不改变 circuit breaker 的 threshold、cooldown、状态文件或 pass/reset 规则。
- 不删除 `New source file attempt` 观测事件，不改变现有 event schema、字段名或持久化格式。
- 不把 Read 视为满足 L1“search first”的恢复证据；仅 Grep 与 Glob 有效。
- 不扩展为 event-log 读取错误、损坏历史或超过 500 条窗口的全新失败策略。

## Behavior Invariants

1. B-001：只有同一 session 中实际产生的 `New source file reminder` 才算一次未响应提醒；仅有
   `New source file attempt`、circuit-breaker-silenced write 或其他 hook event 不增加 escalation
   计数。
2. B-002：同一 session 最新一次由 `analysis-paralysis-guard` 记录的 Grep 或 Glob 是 heed boundary；
   escalation 只计算该边界之后的可见 source-new reminders。
3. B-003：Read、其他 session 的 Grep/Glob、malformed event 与不相关 hook/tool/reason 不得创建 heed
   boundary，也不得增加计数。
4. B-004：circuit breaker OPEN 期间的新 source-file writes 继续保持既有空输出/允许语义，并且不会
   因静默 attempts 推进 escalation；breaker 自身的 cooldown/reset 行为不变。
5. B-005：在最近一次有效搜索之后，如果可见 reminders 再次达到配置阈值，下一次新 source-file
   write 仍必须阻断，并报告实际未响应 reminder 数量。
6. B-006：一次 escalation 后，同一 session 的 Grep 或 Glob 必须让下一次新 source-file write 不再
   被旧 reminder 历史阻断；若 circuit breaker 仍 OPEN，该次 write 可以继续被 breaker 静默，但
   不能被旧 escalation trap 阻断。
7. B-007：escalation block 文案要求用户运行 Grep/Glob 后重试，不再建议
   `export VIBEGUARD_PRE_WRITE_ESCALATE_THRESHOLD=0` 可在当前 agent session 生效；不再把必须新建
   session 作为唯一恢复路径。
8. B-008：`VIBEGUARD_PRE_WRITE_ESCALATE_THRESHOLD=0`、`VIBEGUARD_WRITE_MODE=block`、现有 event
   schema、`New source file attempt` observability 与最多扫描最近 500 条 event 的边界保持兼容。

## 验收标准

- [ ] threshold=3、breaker threshold=1 时，仅第一条可见 reminder 被计数；后续多个静默 writes
  不触发 escalation。
- [ ] breaker 允许连续输出至少 threshold 条 reminders 时，下一次 write 正常 escalation，并报告
  reminder 数而非全部 attempts。
- [ ] escalation 后同一 session 的 Grep 和 Glob 分别都能恢复；Read 与其他 session 的 Grep 不恢复。
- [ ] 搜索恢复后产生的新可见 reminders 可以重新累计并再次触发 escalation。
- [ ] block 文案包含可执行的 Grep/Glob retry 指引，且不包含无效的 session-local `export` 建议。
- [ ] threshold=0、write-mode block、circuit breaker 与既有 attempt/reminder telemetry 回归全绿。
- [ ] focused hook test、Rust tests、hook validators、quick contract 与 current-head CI 全绿。

## 边界情况清单

| 类别 | 判定（covered: B-xxx / N/A + 原因） |
| --- | --- |
| 空/缺失输入 | covered: B-008；沿用现有 pre-write input 与缺失 event-log 行为 |
| 错误与失败路径 | covered: B-003, B-005, B-007 |
| 授权/权限 | N/A：本变更不新增授权或外部权限面 |
| 并发/竞态 | covered: B-004, B-008；沿用既有 append-only event log 与 breaker locking |
| 重试/幂等 | covered: B-002, B-005, B-006 |
| 非法状态转换 | covered: B-003, B-004, B-006 |
| 兼容/迁移 | covered: B-008；无 schema 或持久化迁移 |
| 降级/回退 | covered: B-001, B-004；静默 breaker 不得伪造未响应证据 |
| 证据与审计完整性 | covered: B-001, B-002, B-003, B-008 |
| 取消/中断 | N/A：hook 调用是单次同步判定，无独立取消状态 |

## 发布说明

这是 pre-write L1 escalation 的纠错与可恢复性修复。用户看到的搜索要求不变，但阻断只由真正展示过
且搜索后仍未响应的提醒触发；同一 session 完成 Grep/Glob 后即可重试。配置和 event schema 无需迁移。
