# Product Spec

## Linked Issue

GH-611

## 用户问题

CI 只采集 3 个 hook latency 样本，却把其中最大值标为 P95 并直接作为 hard gate。一次
runner 调度停顿即可让完全无关的 PR 失败；手工 rerun 又会把初次 breach 的证据割裂，
使瞬时 outlier 与持续性能回归难以区分。

## 目标

- 初次 latency breach 必须经过同一 fixture 的独立确认批次后才能判为持续回归。
- 瞬时 outlier 可恢复为通过，但初次 breach 与确认结果必须完整可见。
- 持续慢 fixture 与 synthetic slow fixture 继续 fail closed。
- 不提高任何 latency budget，不把 tail latency 从报告中删除。

## 非目标

- 不优化 hook 生产代码或改变 fixture workload。
- 不改变各 fixture 的 P95 budget。
- 不处理 macOS CI 30 分钟 timeout。
- 不把 performance hard gate 改成 advisory，也不自动 rerun 整个 workflow。

## Behavior Invariants

1. B-001 健康环境中任一 fixture 的初始 P95 超过既有 budget 时，benchmark 必须只对该
   fixture 执行新的独立确认批次；不得仅凭初始批次直接判整个 gate 失败。
2. B-002 同一 fixture 的确认 P95 仍超过同一 budget 时，最终状态必须为 confirmed
   regression，`--fail-on-regression` 必须返回非零；预算和 workload 不得在确认时放宽。
3. B-003 确认 P95 未超过 budget 时，最终 gate 可以通过，但状态必须明确区分于普通
   PASS，并记录 initial breach、confirmation pass 与最终 cleared decision。
4. B-004 console、internal JSON 与 benchmark-action machine output 必须保留可关联的初始
   P95、确认 P95、budget 和最终 decision；确认不得覆盖或删除初次证据。旧的 canonical
   P50/P95/P99 machine rows 必须继续表示 initial batch，避免历史序列静默改义。
5. B-005 未发生初始 breach 的 fixture 不得额外运行确认批次；正常路径的 workload、
   PASS 语义和输出兼容。
6. B-006 现有 environment-distorted 语义保持独立：已被 spawn baseline 判为 distorted 的
   环境继续报告并抑制 SLA failure，不得伪造 confirmation pass。
7. B-007 direct hook 与 Codex wrapper fixture 必须使用同一 confirmation/decision contract，
   不得出现两套状态或证据格式。
8. B-008 deterministic transient fixture 必须证明“初次慢、确认正常”不会失败；现有
   persistent synthetic slow fixture 必须证明“初次慢、确认仍慢”继续失败。
9. B-009 参数非法、fixture 无法执行或 confirmation 无法完成时必须 fail visibly；不得把
   缺失确认当作 cleared 或普通 PASS。机器输出必须保留 initial evidence、把 decision 标为
   confirmation error，并明确让 confirmation 为缺失状态。

## 验收标准

- [ ] transient slow fixture 输出 initial breach + confirmation pass + cleared decision，退出 0。
- [ ] persistent slow fixture 输出两次 breach + confirmed regression，退出非 0。
- [ ] 两条路径的 console、internal JSON 与 action output 均有具名、可关联证据。
- [ ] 所有既有 budget 数值和普通 fixture workload 不变。
- [ ] performance contract tests、真实 focused benchmark、validators 与 broad local gate 通过。

## 边界情况清单

| 类别 | 判定（covered: B-xxx / N/A + 原因） |
| --- | --- |
| 空/缺失输入 | covered: B-009 |
| 错误与失败路径 | covered: B-002, B-009 |
| 授权/权限 | N/A：本地 benchmark 不执行授权决策 |
| 并发/竞态 | covered: B-001, B-003（独立批次按 fixture 串行、证据不可互相覆盖） |
| 重试/幂等 | covered: B-001, B-003, B-004 |
| 非法状态转换 | covered: B-002, B-003, B-009 |
| 兼容/迁移 | covered: B-005, B-007 |
| 降级/回退 | covered: B-006, B-009 |
| 证据与审计完整性 | covered: B-003, B-004, B-008 |
| 取消/中断 | covered: B-009 |

## 发布说明

Hook latency hard gate 增加 fixture-local confirmation：持续回归仍严格失败，孤立 runner
outlier 不再直接使无关 PR 变红，同时初次 breach 会保留在机器可读证据中。
