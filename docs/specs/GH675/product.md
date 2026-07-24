# Product Spec — 规则精度反馈通路：闭合生产者缺口并让空反馈可见

## Linked Issue

GH-675

complexity: medium

## 用户问题

规则精度生命周期机制（`scripts/precision-tracker.py` + 本地 scorecard
+ `data/triage.jsonl`）已经完整建成，但**没有任何反馈数据流经它**，所以数据驱动
的 promote / demote 循环今天实际上是空转的。

本会话核实的事实：

- `data/triage.jsonl` 不存在（仓库只有 `data/triage.example.jsonl`），
  本地 scorecard 也不存在，回退到 `data/rule-scorecard.seed.json`。
- `python3 scripts/precision-tracker.py` 输出的 11 条规则全部
  `samples=0`、`precision=N/A`。
- `scripts/report-false-positive.py:160` 生成误报报告时，只是**打印一句提示**
  让人事后自己去跑 `precision-tracker.py --record fp <RULE>`。这一步没有任何
  东西执行，也没有任何文档要求执行。

这是一个典型的声明-执行鸿沟（U-26）：消费者（precision-tracker）建好了，
指路牌（report-false-positive）立好了，**生产者不存在**。

第二个问题是可见性：反馈通道为空时，报告渲染成一张看起来正常的表格，只是
`Prec` 列写 `N/A`。它不说明"没有任何生命周期跃迁能够触发"。空数据被呈现得像
正常状态，属于 U-29 要禁止的静默降级形态。

## 目标

- 让识别出误报的工具能**一步记录**裁定，而不是打印一条要人记住的指令。
- 反馈通道为空时必须显式、醒目地说明"没有样本 → 任何生命周期跃迁都不可能触发"，
  而不是让 `N/A` 冒充正常。
- 在 CONTRIBUTING 中写明 triage 反馈闭环，让它成为有主的流程而不是无主的工具。

## 非目标

- 不改变 `precision-tracker.py` 的生命周期阈值与状态机语义。
- 不自动从事件历史批量回填 triage 记录：机器无法在没有人判断的情况下区分
  真阳性与误报，自动回填等于伪造反馈数据。
- 不把 triage 记录接入 CI 或任何阻断路径。反馈仍然是人工裁定，本 issue 只消除
  "裁定完了却没地方一步落库"的摩擦。
- 不改变 `data/triage.jsonl` 与本地 scorecard 被 gitignore 的现状
  （它们是本地运行时数据，不是仓库产物）。

## Behavior Invariants

1. B-001: `report-false-positive.py` 必须支持在生成报告的同一次调用中记录 triage
   裁定，裁定值限定为 `fp` / `tp` / `acceptable`。
2. B-002: 记录裁定必须复用 `precision-tracker.py` 的既有写入路径，不得在
   `report-false-positive.py` 中重新实现 triage 写入或 scorecard 更新逻辑。
3. B-003: 记录裁定需要一个规则 ID。无法确定规则 ID 时必须报错退出，不得静默跳过
   记录而照常输出报告。
4. B-004: 记录失败（写入错误、triage 文件损坏）必须以非零退出码和可见错误结束，
   不得降级为"报告已生成"的成功假象。
5. B-005: 未传入记录裁定选项时，`report-false-positive.py` 的既有行为与输出保持
   不变。
6. B-006: 当 scorecard 中所有规则的样本总数为 0 时，`precision-tracker.py` 的报告
   必须输出一段显式警告，说明反馈通道为空、没有任何生命周期跃迁能触发，并给出
   两条喂数据的具体命令。
7. B-007: 样本总数大于 0 时不得输出该警告。
8. B-008: CONTRIBUTING 必须描述 triage 反馈闭环：何时记录、用哪条命令记录、
   记录后如何查看生命周期跃迁。

## 验收标准

- [x] `report-false-positive.py --record-triage fp --rule RS-03` 在输出报告的同时
      向 triage 追加一条记录并更新 scorecard。
- [x] 缺少规则 ID 时该选项报错退出。
- [x] 空反馈通道在 `precision-tracker.py` 报告中有显式警告块。
- [x] CONTRIBUTING 有 triage 反馈闭环小节。
- [x] 确定性测试覆盖 B-001 ~ B-007。

## 边界情况清单

| 类别 | 判定（covered: B-xxx / N/A + 原因） |
| --- | --- |
| 空/缺失输入 | covered: B-003, B-006；缺规则 ID 报错，空通道显式告警 |
| 错误与失败路径 | covered: B-004；写入失败非零退出 |
| 授权/权限 | N/A — 只写本地 gitignore 数据文件 |
| 并发/竞态 | covered: B-002；复用 precision-tracker 既有的 scorecard 写锁 |
| 重试/幂等 | covered: B-002；沿用既有"triage 有坏行则不写入"的非幂等防护 |
| 非法状态转换 | covered: B-001；裁定值限定三选一 |
| 兼容/迁移 | covered: B-005；不传新选项时行为不变 |
| 降级/回退 | covered: B-004, B-006；不静默降级，空数据不冒充正常 |
| 证据与审计完整性 | covered: B-002；triage 与 scorecard 仍由同一路径保持一致 |
| 取消/中断 | covered: B-002；沿用既有的 scorecard 先写、triage 后追加顺序 |

## 发布说明

`data/triage.jsonl` 与本地 scorecard（从 `data/rule-scorecard.seed.json` 播种）仍是本地文件，不进仓库。
现有用户无需迁移；新选项是纯增量。
