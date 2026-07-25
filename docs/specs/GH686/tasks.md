# Task Plan — GH686

## Linked Issue

GH-686

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## 前置决策

初版列了三条，核对代码后两条已由 spec 自答（依据见 `tech.md` 的「前置决策的结论」）：

| 决策 | 结论 | 状态 |
| --- | --- | --- |
| D1 非目标任务集来源 | 必须新建；v1.jsonl 只有 4 条 `NONE`，下限是 30，划分方案在算术上不成立 | 已定 |
| D3 标定实验 | 先落地方向性门；`calibrated: false` 强制 `inconclusive` | 已定 |
| D2 打分方式 | 复用现有 grader（口径 = 误报漂移）还是引入 pairwise judge（口径 = 质量） | **待维护者裁定，阻塞 T3 与 T6** |

## 实现任务

- [ ] `SP686-T1` 在 `eval/` 下新增 `run_paired_eval.py`，实现候选规则的双来源剔除与四条断言。Covers: B-001, B-002, B-003, B-012. Owner: implementation agent. Done when: 规则树按小节剔除、core 文件按表格行剔除；逐文件差分（仅一个文件不同且差异恰为候选小节，不在拼装文本上重放剔除）、在场断言（候选不存在则终止）、定义计数断言（差恰为 1 且删除 span 内无第二个 `^## `，非同源、专抓删多了）、定义位点 token 断言四条齐备；断言范围限定在定义位点而非全文，交叉引用残留逐条列出且超 `max_cross_refs` 判 inconclusive；整文件删除、no-op 剔除、贪婪多删一节均被拒；候选位于文件末节时必须能跑通；任一断言失败非零退出。Verify: `bash tests/test_paired_eval.sh`。
- [ ] `SP686-T2` 目标 / 非目标样本划分与新建 non-target 数据集。Covers: B-004. Owner: implementation agent. Done when: 目标样本用精确 `==` 匹配、不复用 `filter_samples`（它是前缀匹配且强制混入 `NONE`）；non-target 数据集独立于 `v1.jsonl`；两组皆空时非零退出。Verify: `bash tests/test_paired_eval.sh`。
- [ ] `SP686-T3` 四次运行的指标计算、合取判定与退出码语义。Covers: B-005, B-007, B-011. Owner: implementation agent. Blocked by: D2. Done when: 不复用 `model_summary_metrics`（它把跳过样本剔出分母）；分母为请求样本数；跳过率与跳过率差超阈值判 `inconclusive`；目标轴用严格大于；单轴通过不得整体通过。真实运行的 `inconclusive` 与不通过均非零退出。Verify: `python3 eval/test_paired_eval.py`。
- [ ] `SP686-T4` 离线 dry-run 路径。Covers: B-008. Owner: implementation agent. Done when: 无 API 密钥可运行，输出四次运行的输入身份、四条断言结果、交叉引用与空壳文件残留清单、样本划分；**dry-run 不产出判定，正常完成退出 0**，不受 B-010/B-011 约束。Verify: `bash tests/test_paired_eval.sh`。
- [ ] `SP686-T5` 在 `eval/paired/` 下新增 `thresholds.json` 与未标定强制降级。Covers: B-006, B-010. Owner: implementation agent. Done when: 任一轴样本量不足报 `inconclusive`；`calibrated: false` 时整体强制 `inconclusive`、永不输出 `pass`。Verify: `python3 eval/test_paired_eval.py`。
- [ ] `SP686-T6` 规则 PR 模板加入配对评测证据要求与受限豁免。Covers: B-009. Owner: implementation agent. Blocked by: D2. Done when: `templates/pull_request.md` 要求附结果；豁免仅限非 prompt 注入类改动且需维护者批准记录；写明 `calibrated: false` 阶段可接受的证据形态是 inconclusive 报告加两轴 delta 与样本量，而非 `pass`。Verify: 在 `bash tests/test_eval_contract.sh` 内新增模板断言段（仓库已有 `tests/test_issue_template_contract.sh` 这类模板契约测试可参照，勿另建新脚本）。

## 并行拆分

T1 / T4 与 T3 / T5 都写 `run_paired_eval.py`，因此**不拆并行写 lane**，由单 agent
串行完成（W-14）。可并行的只读 review lane：双来源剔除与差集断言审查、指标口径审查、
阈值标定方法审查。

## 验证

```bash
python3 checks/check_workflow.py --repo . --spec-dir=docs/specs/GH686
python3 checks/check_workflow.py --repo . --all-specs
bash tests/test_paired_eval.sh
python3 eval/test_paired_eval.py
bash tests/test_eval_contract.sh
bash tests/test_behavior_eval.sh
bash scripts/ci/validate-doc-paths.sh
```
