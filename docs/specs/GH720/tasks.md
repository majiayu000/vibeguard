# Task Plan — GH-720 SpecRail packet 阶段化

## Linked Issue

GH-720

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## 实现任务

- [x] `SP720-T1` 增加 CLI stage、Draft/Complete packet 规则、fail-closed base-ref 解析及当前/基线 packet 并集。Covers: B-001, B-002, B-003, B-004, B-005, B-006, B-010. Owner: root coordinator. Dependencies: none. Done when: 新 Draft 可无 tasks，通过删除 tasks 或整个基线 packet 均失败，默认 Complete 不变。Verify: `bash tests/test_specrail_adoption.sh && python3 checks/check_workflow.py --repo . --all-specs`
- [x] `SP720-T2` 让 GitHub workflow 按 PR Draft 状态选择 stage，并覆盖 Draft/Ready 转换事件。Covers: B-007, B-008. Owner: root coordinator. Dependencies: SP720-T1. Done when: Draft 使用 base SHA 和 Draft stage，其余事件使用 Complete，状态切换触发新 run。Verify: `bash tests/test_specrail_adoption.sh && bash tests/test_workflow_contracts.sh`
- [x] `SP720-T3` 更新 route 输出和使用合同，保持其他 gate 与默认授权不变。Covers: B-009, B-010. Owner: root coordinator. Dependencies: SP720-T1. Done when: write_spec 输出 Draft 命令、implement 输出 Complete 命令，adoption pin 与 auth_mode 未改变。Verify: `bash tests/test_specrail_adoption.sh && bash scripts/local-contract-check.sh --quick`
- [ ] `SP720-T4` 完成独立审查、PR CI 与离线 PR gate，修复所有阻断项后才允许合并。Covers: B-001, B-002, B-003, B-004, B-005, B-006, B-007, B-008, B-009, B-010. Owner: independent reviewer + root coordinator. Dependencies: SP720-T1, SP720-T2, SP720-T3. Done when: 当前 head 的独立审查无阻断、review threads 为零、CI 全绿、`checks/pr_gate.py` allowed。Verify: `python3 checks/github_pr_evidence.py --github-repo majiayu000/vibeguard --pr <pr-number> --issue 720 --review-source independent_lane --json`

## 并行拆分

- 实现文件由 root coordinator 独占。
- 独立 reviewer 为只读 lane，不拥有可写文件。
- 后续队列诊断 lane 只读，不接触本任务分支。

## 验证

- `bash tests/test_specrail_adoption.sh`
- `python3 checks/check_workflow.py --repo . --all-specs`
- `bash tests/test_workflow_contracts.sh`
- `bash scripts/ci/validate-workflow-contracts.sh`
- `bash scripts/ci/validate-doc-paths.sh`
- `bash scripts/ci/validate-doc-command-paths.sh`
- `bash scripts/local-contract-check.sh --quick`
- Fresh PR CI + review-thread evidence + offline PR gate

## Handoff Notes

- `implx auto` 仅是本次 transient authorization；不得修改持久化
  `automation_policy.auth_mode: review`。
- 禁止 force push、release 或绕过失败 gate。
- 独立审查已发现并阻断过“删除整个基线 packet”绕过；该失败历史必须保留在
  本轮证据中，修复后需用当前 head 重新审查。
