# Summary

用 1-3 句话描述本次变更。

## Linked Work

- Issue:
- Spec packet:

## Readiness Gate

- [ ] 关联 issue 已有 `ready_to_implement`，或这是一个已说明的小型 bug fix。
- [ ] 需要 product/tech spec 时，已链接 spec。
- [ ] 涉及安全敏感区域时，已走私有流程或获得维护者批准。

## Review Gate

- [ ] 已完成 agent first-pass review，或明确说明跳过原因。
- [ ] 已请求 human final review。
- [ ] 需要 ownership approval 时，已明确 owner。

## Merge Gate

- [ ] 已记录 PR head SHA。
- [ ] CI/check rollup 已完成且通过。
- [ ] 已检查 review threads，未解决的 actionable threads 已处理。
- [ ] native threads 可用时，已记录独立 reviewer 或 merge-reviewer lane evidence。
- [ ] merge state 为 clean。
- [ ] merge 前已记录 human merge authorization。
- [ ] `python3 checks/github_pr_evidence.py --github-repo OWNER/REPO --pr <pr-number> --json > pr-evidence.json` 结果：
- [ ] `python3 checks/pr_gate.py --repo . --evidence <evidence.json>` 结果：

## Verification

- [ ] Tests:
- [ ] Manual proof:
- [ ] 用户可见变更附 screenshots 或 logs:

## 配对 Prompt 规则评测

- [ ] 本 PR 未新增或修改 prompt 注入的原生规则。
- [ ] 本 PR 新增或修改了 prompt 注入的原生规则，并已附配对评测报告：
  - 候选规则 ID：
  - 报告或 artifact 链接：
  - 目标轴 delta 与样本量：
  - 非目标轴 delta 与样本量：
  - Producer model ID：
  - Judge model ID：
  - Judge prompt digest：
  - 阈值标定：`calibrated: false` 时附包含两轴 delta、样本量和模型证据的 `inconclusive` 报告，不得声称 `pass`。
  - 注意：CI 不会机器核验上述数字与所附报告是否一致，reviewer 需对照 `report.json` 人工核对。
- [ ] 仅为非 prompt 注入类变更申请豁免：
  - 理由：
  - 维护者批准：

## Release Notes

- [ ] 需要 changelog 或 release note。
- [ ] 非用户可见。

## Agent Disclosure

- [ ] No agent was used.
- [ ] Agent assisted; human author reviewed the full diff.
