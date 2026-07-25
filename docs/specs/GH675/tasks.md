# Task Plan — GH675

## Linked Issue

GH-675

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## 实现任务

- [x] `SP675-T1` 为 `scripts/report-false-positive.py` 新增 `--record-triage` 及路径透传选项。Covers: B-001, B-005. Owner: implementation agent. Done when: 传入裁定时同一次调用记录，不传时行为不变。Verify: `bash tests/test_report_false_positive.sh`。
- [x] `SP675-T2` 记录动作委托给 `precision-tracker.py --record`，不复制写入逻辑。Covers: B-002. Owner: implementation agent. Done when: triage 与 scorecard 由同一路径产生。Verify: `bash tests/test_report_false_positive.sh`。
- [x] `SP675-T3` 缺规则 ID 与子进程失败时可见报错并非零退出。Covers: B-003, B-004. Owner: implementation agent. Done when: 缺 rule 时退出码非零且不产生 triage 条目。Verify: `bash tests/test_report_false_positive.sh`。
- [x] `SP675-T4` `render_report` 在样本总数为 0 时输出显式警告块。Covers: B-006, B-007. Owner: implementation agent. Done when: 空通道有警告、有样本时无警告。Verify: `bash tests/test_precision_tracker.sh`。
- [x] `SP675-T5` 在 CONTRIBUTING 补 Triage Feedback Loop 小节。Covers: B-008. Owner: implementation agent. Done when: 写明何时记录、用哪条命令、以及为何禁止批量回填。Verify: `bash scripts/ci/validate-doc-paths.sh`。

## 并行拆分

单 implementation agent 串行写入，无并行写 lane（W-14）。可并行的只读 review lane：
生产者委托路径审查、报告渲染审查。

## 验证

```bash
python3 checks/check_workflow.py --repo . --spec-dir=docs/specs/GH675
python3 checks/check_workflow.py --repo . --all-specs
bash tests/test_report_false_positive.sh
bash tests/test_precision_tracker.sh
bash tests/test_health_report.sh
bash scripts/ci/validate-doc-paths.sh
bash scripts/ci/validate-doc-command-paths.sh
bash scripts/ci/validate-no-personal-paths.sh
```
