# Task Plan

## Linked Issue

GH-652

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`
- Status: draft；spec approval 与 `ready_to_implement` 后执行

## 实现任务

- [ ] `SP652-T1` 在 structured-report suite 首次 setup invocation 前 build 并 fail-fast pin 当前 runtime。Covers: B-001, B-002, B-003. Owner: implementation agent. Dependencies: spec approval + `ready_to_implement` + W-20 check. Done when: caller runtime 被覆盖，build/executable 失败立即退出，所有 setup 子进程继承当前 absolute binary。Verify: shell syntax、stale caller env full suite、source-order audit。
- [ ] `SP652-T2` 收敛 runtime-config matrix 到唯一 suite pin。Covers: B-004, B-005, B-006. Owner: implementation agent. Dependencies: SP652-T1. Done when: late matrix 不再首次/重复 build，现有 assertions 不变，生产 resolver 无 diff。Verify: one-build-owner audit、260-case suite、production exclusion diff。
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
- `stop_conditions`: 需要修改生产 resolver/runtime semantics、改 runtime version/release、弱化现有 health assertions、允许 build failure fallback、无法用一个 absolute binary 覆盖全 suite、或需要改 GH-631 scope 时停止
- `lane_map`: coordinator `/root` 单 writer 串行 T1..T3；independent reviewer `/root/review_pr612` 只读且无 writable files

实现不得以重试、删断言或版本字符串检查替代 current-source build/pin。
