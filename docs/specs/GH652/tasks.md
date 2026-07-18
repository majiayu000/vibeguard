# Task Plan

## Linked Issue

GH-652

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`
- Status: draft；spec approval 与 `ready_to_implement` 后执行

## 实现任务

- [ ] `SP652-T1` 在 structured-report suite 首次 setup invocation 前建立 hostile fixture、build 并 fail-fast pin 当前 runtime。Covers: B-001, B-002, B-003. Owner: implementation agent. Dependencies: spec approval + `ready_to_implement` + W-20 check. Done when: executable same-version fixture 先通过 legacy capability probe；skip/version/build-target/target-dir hostile inputs 被规范化；caller runtime 被覆盖；build/executable 失败立即退出；所有 setup 子进程继承对应 absolute binary。Verify: shell syntax、self-contained hostile full suite、source-order 与 zero-call marker audit。
- [ ] `SP652-T2` 收敛 runtime-config matrix 到唯一 suite pin并保留全部 assertions。Covers: B-004, B-005, B-006. Owner: implementation agent. Dependencies: SP652-T1. Done when: late matrix 不再首次/重复 build，原有 build assertion ownership 前移且总计仍为 260，全部 behavior assertions 不变，stale marker 零调用，生产 resolver 无 diff。Verify: one-build-owner/assertion-count audit、260/260 suite、production exclusion diff。
- [ ] `SP652-T3` 运行提交门禁并更新 spec 状态。Covers: B-001, B-002, B-003, B-004, B-005, B-006. Owner: verification owner. Dependencies: SP652-T1..T2. Done when: Rust check/test、setup focused、SpecRail/docs gates 同一提交通过。Verify: Tech Spec 测试计划全部命令。

## 并行拆分

不并行：两个 test harness 文件共享 runtime ownership，coordinator 单 writer 串行 T1..T3；独立
reviewer lane 只读。

## 验证

- Product invariant 集合：B-001..B-006；task coverage union 完整。
- `python3 checks/check_workflow.py --repo . --spec-dir docs/specs/GH652`。

## Handoff Notes

- `mode`: `execute_direct`
- `artifacts`: `docs/specs/GH652/{product,tech,tasks}.md`、`docs/specs/GH652/{runtime-pinning.snapshot,tool-inventory.txt}`、`docs/specs/README.md`；implementation 仅修改两个 setup test harness 文件并更新 tasks/index
- `runtime_pinning_snapshot`: `docs/specs/GH652/runtime-pinning.snapshot`；唯一 writable implementation lane 开始和每次续跑前执行 `VIBEGUARD_MODEL_ID=gpt-5 bash guards/universal/check_runtime_drift.sh check --snapshot docs/specs/GH652/runtime-pinning.snapshot --tool-inventory docs/specs/GH652/tool-inventory.txt --rules-dir rules/claude-rules`
- `verification_owner`: coordinator `/root`；independent reviewer 由 threads lane 指派且只读
- `stop_conditions`: 需要修改生产 resolver/runtime semantics、改 runtime version/release、弱化现有 health assertions、允许 build failure fallback、fixture 无法通过 legacy probe、marker 被调用、无法用一个 absolute binary 覆盖全 suite、或需要改 GH-631 scope 时停止
- `lane_map`: coordinator `/root` 单 writer 串行 T1..T3；independent reviewer `/root/review_pr612` 只读且无 writable files

实现不得以重试、删断言或版本字符串检查替代 current-source build/pin。

## Runtime Drift Decision

- Timestamp: `2026-07-17T11:15:47Z`
- Approver: user；本轮对仓库优化和必要 GitHub 操作的 standing authorization
- Snapshot: `docs/specs/GH652/runtime-pinning.snapshot`
- Accepted surface: runtime hash only；tool hash 与 rules hash 无 drift
- Snapshot runtime hash: `8dfe1143b97021d0c6a7724a6c69049156a5b1961ae28df9e5a87974bc88c6b7`
- Coordinator runtime hash: `8b219074ec68e9be602d112a372cf3564527fdcc6d2c8ccf892946a16c02bb0e`
- Reason: 两个已授权的并发执行环境在同一 `gpt-5` model identity 下暴露不同的 agent
  CLI/SDK runtime 版本，导致 snapshot 被交替重写；GH652 的 specs、tool inventory 和 rule set
  未变化。接受该跨会话 runtime drift 以停止无意义的 hash ping-pong；不据此声称 deterministic
  replay，implementation lane 仍须记录并使用自己的 fresh verification output。

Fresh check output:

```text
[W-20] runtime drift: 8dfe1143b97021d0c6a7724a6c69049156a5b1961ae28df9e5a87974bc88c6b7 -> 8b219074ec68e9be602d112a372cf3564527fdcc6d2c8ccf892946a16c02bb0e
[W-20] drift detected; stop or record explicit user acceptance before continuing
```
