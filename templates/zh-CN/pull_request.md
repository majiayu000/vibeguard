# 摘要

用 1-3 句话说明用户可见结果。

## 关联工作

- Issue（如有）：

## 验证

- [ ] 聚焦测试：
- [ ] 更广的相关检查：
- [ ] 用户可见变更的截图或日志：

## Review

- [ ] 已处理具体的正确性、安全和回归问题。
- [ ] `Findings: 0` 且 `PASS` 时已停止 Review。
- [ ] Review 不超过两轮。
- [ ] 剩余纯流程决策已明确交给人工。

## 配对 Prompt 规则评测

- [ ] 本 PR 未新增或修改 prompt-injected 原生规则。
- [ ] 本 PR 新增或修改了 prompt-injected 原生规则，并已附配对评测报告：
  - 候选规则 ID：
  - 报告或产物链接：
  - 目标集 delta 与样本数：
  - 非目标集 delta 与样本数：
  - Producer 模型 ID：
  - Judge 模型 ID：
  - Judge prompt digest：
  - 阈值校准：当 `calibrated: false` 时，附带包含两组 delta、样本数和模型证据的 `inconclusive` 报告，不得声称 `pass`。
  - 注意：CI 不会自动核验这些数字；reviewer 需对照 `report.json` 人工核对。
- [ ] 仅对非 prompt-injection 变更申请豁免：
  - 原因：
  - 维护者批准：

## 发布说明

- [ ] 需要 changelog 或 release note。
- [ ] 对用户不可见。
