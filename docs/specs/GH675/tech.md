# Tech Spec — 规则精度反馈通路：闭合生产者缺口并让空反馈可见

## Linked Issue

GH-675

## Product Spec

`docs/specs/GH675/product.md`

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| 消费者 | `scripts/precision-tracker.py:540` | `--record` 已实现完整写入路径：scorecard 写锁、坏行阻断、先写 scorecard 再追加 triage | 生产者应复用它，不能重写 |
| 报告渲染 | `scripts/precision-tracker.py:445` | 全 0 样本渲染成 `N/A` 表格，读起来像正常 | 空通道需要显式警告 |
| 指路牌 | `scripts/report-false-positive.py:160` | 只打印一句"事后请自己去 record" | 这是缺失的生产者位置 |
| 数据文件 | `.gitignore` | triage 日志与本地 scorecard 被忽略，仓库只跟踪 `data/rule-scorecard.seed.json` | 本地运行时数据，不改变这一点 |
| 种子 | `data/rule-scorecard.seed.json` | 无本地 scorecard 时的回退 | 空样本的来源 |
| 测试 | `tests/test_report_false_positive.sh`、`tests/test_precision_tracker.sh` | 均已在 CI 中显式列步骤 | 新断言挂在既有测试上，不新增 CI 步骤 |

## 设计方案

1. `scripts/report-false-positive.py` 新增 `--record-triage {fp,tp,acceptable}`，
   以及 `--triage-file` / `--scorecard-file` 透传选项（供测试与非默认路径使用）。
2. 记录动作**通过 subprocess 调用 `scripts/precision-tracker.py --record`** 完成。
   两个理由：
   - `precision-tracker.py` 含连字符，不能作为普通模块 import；
   - 写入路径含 scorecard 写锁与"triage 有坏行则拒写"的非幂等防护，复制一份必然
     漂移（L1 / 反重复）。
3. 规则 ID 缺失或为 `unknown` 时以退出码 2 报错，不记录（B-003）。子进程失败时
   透传其退出码并明确指出"上面的报告没有 triage 记录支撑"（B-004）。
4. `--context` 只由非 `unknown` 的字段拼成，全都未知时回退到 `event_id`，避免写入
   `"unknown unknown"` 这种垃圾上下文。
5. `render_report` 在所有规则样本总和为 0 时插入一段显式警告块（B-006/B-007），
   给出两条喂数据命令。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 | `report-false-positive.py` `--record-triage` | `bash tests/test_report_false_positive.sh` |
| B-002 | subprocess 委托给 `precision-tracker.py --record` | `bash tests/test_report_false_positive.sh`（断言 triage 与 scorecard 同时产生） |
| B-003 | `record_triage_verdict` 规则 ID 校验 | `bash tests/test_report_false_positive.sh` |
| B-004 | 子进程退出码透传 | `bash tests/test_report_false_positive.sh`（triage 损坏时非零退出、报告声明未被记录支撑、triage 无新增） |
| B-005 | 未传选项时的既有路径 | `bash tests/test_report_false_positive.sh` |
| B-006 | `render_report` 空通道警告 | `bash tests/test_precision_tracker.sh` |
| B-007 | 有样本时不输出警告 | `bash tests/test_precision_tracker.sh` |
| B-008 | `CONTRIBUTING.md` Triage Feedback Loop | `bash scripts/ci/validate-doc-paths.sh` |

## 数据流

```
guard 命中 → 人判断这是误报
        |
        v
report-false-positive.py <EVENT> --rule R --record-triage fp
        |  (subprocess)
        v
precision-tracker.py --record fp R
        |  scorecard 写锁
        +--> data/rule-scorecard.json  (先写, 原子)
        +--> data/triage.jsonl         (后追加)
        |
        v
生命周期跃迁 experimental → warn → error / demoted
```

## 风险与权衡

- **subprocess 而非 import**：多一次进程启动开销。这条路径是人工触发的低频操作，
  开销无关紧要；换来的是写入逻辑只有一份。
- **不自动回填历史**：issue 提到可以从 40 天事件历史 seed 一批。本实现明确拒绝：
  机器无法在没有人判断的情况下区分真阳性与误报，自动回填等于伪造反馈数据，会让
  生命周期跃迁建立在假证据上。CONTRIBUTING 中写明了这一点。
- **警告块不改变退出码**：`health-report.py` 等既有调用方依赖 `precision-tracker.py`
  的退出码，把空通道改成非零会破坏它们。可见性通过输出而非退出码表达。

## 未解决的上游问题

issue 中的前置假设（"precision-tracker 是要驱动生产的，还是纯手工工具"）本实现
不做裁定。本 PR 只消除"人判断完了却没有一步落库的地方"这个摩擦，以及"空数据冒充
正常"这个可见性问题。若维护者裁定它是纯手工工具，本 PR 的改动仍然成立。
