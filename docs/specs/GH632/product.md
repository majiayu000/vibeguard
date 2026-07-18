# Product Spec

## Linked Issue

GH-632

complexity: trivial

## 用户问题

repository map、站点版本文案、历史 benchmark 数字与 plan-mode skill 标题含少量过时或歧义
信息。它们不影响运行时，但会让维护者误判当前目录职责、当前 release 或当前 rule count。

## 目标

- 让当前态文档与仓库目录/发布事实一致。
- 把历史 benchmark 数字明确标记为快照，而不是伪装成实时统计。
- 消除 plan-mode 重复章节标题。

## 非目标

- 不重写站点设计、benchmark 结果或 plan-mode 行为。
- 不移动任何脚本目录。
- 不新增需要人工同步的第四份版本/规则计数来源。

## Behavior Invariants

1. B-001 directory map 必须覆盖当前一级 operational script groups，或声明可验证的分组规则；
   `gc`、`doctors`、`metrics`、`constraints`、`systemd` 不得处于无说明状态。
2. B-002 site release 文案必须来自可维护的 canonical metadata，或改为明确不承诺 patch-level
   freshness 的稳定文案；不得每次 release 靠手工猜测更新。
3. B-003 历史 `110 rules` benchmark 数字必须带快照日期/版本语境，不能被读作当前 126-rule
   inventory；不得伪造未重新运行的当前 benchmark。
4. B-004 plan-mode skill 只保留一个 `When to Activate` 章节，原有触发条件与 routing contract
   语义不变。
5. B-005 文档路径、命令、skill format 与 generated/current counts 检查必须通过，且本项不改
   runtime/install behavior。

## 验收标准

- [ ] directory map 可解释全部当前一级 scripts 子目录。
- [ ] site version 文案不再随 patch release 静默漂移。
- [ ] benchmark 的 110-rule 数字明确为历史快照。
- [ ] plan-mode 无重复标题且 skill validator 通过。

## 边界情况清单

| 类别 | 判定（covered: B-xxx / N/A + 原因） |
| --- | --- |
| 空/缺失输入 | N/A：固定文档修订 |
| 错误与失败路径 | covered: B-005 |
| 授权/权限 | N/A |
| 并发/竞态 | N/A |
| 重试/幂等 | covered: B-002 |
| 非法状态转换 | N/A |
| 兼容/迁移 | covered: B-003, B-004 |
| 降级/回退 | N/A：无运行时 fallback |
| 证据与审计完整性 | covered: B-001, B-002, B-003, B-005 |
| 取消/中断 | N/A |

## 发布说明

纯文档/展示修复，无用户迁移。
