# Task Plan — GH686

## Linked Issue

GH-686

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## 前置决策（实现开始前必须有维护者答复）

| 决策 | 问题 | 阻塞 |
| --- | --- | --- |
| D1 | 非目标任务集来源：新建 `eval/datasets/non-target-v1.jsonl`，还是从 `eval/datasets/v1.jsonl` 划分 | T2 |
| D2 | 打分方式：复用既有 structured-json grader（spec 倾向）还是引入 pairwise judge | T3 |
| D3 | 非目标样本量下限的标定实验是否在本 issue 内做，还是先以 `"calibrated": false` 落地方向性门 | T5 |

## 实现任务

- [ ] `SP686-T1` 新增 `eval/run_paired_eval.py` 的输入构造与身份断言。Covers: B-001, B-002, B-003. Owner: implementation agent. Done when: with/without 两次运行共用模型 ID、数据集摘要、样本集摘要；候选规则在场/缺席有机械断言；任一不满足则非零退出。Verify: `bash tests/test_paired_eval.sh`。
- [ ] `SP686-T2` 目标 / 非目标样本划分。Covers: B-004. Owner: implementation agent. Blocked by: SP686-D1. Done when: 两组划分明确，皆空时非零退出。Verify: `bash tests/test_paired_eval.sh`。
- [ ] `SP686-T3` 两轴指标计算与合取判定。Covers: B-005, B-007. Owner: implementation agent. Blocked by: SP686-D2. Done when: 单轴通过不得整体通过；跳过样本计入分母且可见。Verify: `python3 eval/test_paired_eval.py`。
- [ ] `SP686-T4` 离线 dry-run 路径。Covers: B-008. Owner: implementation agent. Done when: 无 API 密钥可运行并输出完整输入身份与样本划分。Verify: `bash tests/test_paired_eval.sh`。
- [ ] `SP686-T5` `eval/paired/thresholds.json` 与未标定警告。Covers: B-006. Owner: implementation agent. Blocked by: SP686-D3. Done when: 样本量不足报 `inconclusive`；未标定阈值运行时有显式警告。Verify: `python3 eval/test_paired_eval.py`。
- [ ] `SP686-T6` 规则 PR 模板加入配对评测证据要求。Covers: B-009. Owner: implementation agent. Done when: `templates/pull_request.md` 要求附结果或声明豁免理由。Verify: `bash tests/test_eval_contract.sh`。

## 并行拆分

T1 / T4 可与 T3 / T5 并行（前者写 `run_paired_eval.py` 的输入侧，后者写指标侧），
但两者同文件，因此**不拆并行写 lane**，由单 agent 串行完成（W-14）。
可并行的只读 review lane：输入身份断言审查、指标定义审查、阈值标定方法审查。

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
