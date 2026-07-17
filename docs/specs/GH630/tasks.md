# Task Plan

## Linked Issue

GH-630

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`
- Status: draft；执行前必须有 spec approval 与 `ready_to_implement`

## 实现任务

- [ ] `SP630-T1` 定义 model-baseline manifest 与离线 freshness validator。Covers: B-001, B-004, B-005. Owner: implementation agent. Dependencies: spec approval. Done when: 三个精确 ID、官方来源、UTC date 与固定 90-day closed window 可审计，future/day-91 非零且 day-90 有效。Verify: manifest/freshness unit tests。
- [ ] `SP630-T2` 让 run_eval resolver 消费 baseline 并保留 default/passthrough。Covers: B-001, B-002, B-003. Owner: implementation agent. Dependencies: SP630-T1. Done when: aliases 更新、默认 `haiku` 固定解析到 dated Haiku ID、full ID 不变、既有 `metadata.model` 继续记录 resolved ID。Verify: eval Python unit tests。
- [ ] `SP630-T3` 对齐 behavior/benchmark entrypoints 与 dry-run/help evidence。Covers: B-006, B-007. Owner: implementation agent. Dependencies: SP630-T2. Done when: 无第二份 mapping，输出显示 resolved baseline，artifact schema/reader 无变化。Verify: `bash tests/test_eval_contract.sh`。
- [ ] `SP630-T4` 运行 eval 提交门禁。Covers: B-001, B-002, B-003, B-004, B-005, B-006, B-007. Owner: verification owner. Dependencies: SP630-T1..T3. Done when: unit/integration/dry-run 同一提交通过且未调用 API。Verify: unittest、eval contract test、两条 dry-run commands。

## 并行拆分

不并行：manifest、resolver 与 entrypoint tests 共享 model contract。

## 验证

- Product invariant 集合：B-001..B-007；task coverage union 完整。
- `python3 checks/check_workflow.py --repo . --spec-dir docs/specs/GH630`

## Handoff Notes

- `mode`: `plan_first`
- `artifacts`: `docs/specs/GH630/{product,tech,tasks}.md` 与 `docs/specs/README.md`；implementation 计划修改 eval baseline manifest、共享 resolver、三个 entrypoint 显示/契约及 focused tests
- `runtime_pinning_snapshot`: `None`；单 writer、非 hook/runtime hot path、预计少于 10 分钟的实现 tranche，不满足 W-20 长任务阈值；若实际执行达到 10 分钟或 3 个以上 agent step，必须在继续前生成并记录 snapshot
- `verification_owner`: coordinator `/root`；independent reviewer 由 threads lane 指派且只读
- `stop_conditions`: 无 spec approval/`ready_to_implement`、官方 ID 与 `verified_at` 无法再次核实、需要 CI 联网、默认不再是 dated Haiku ID、freshness 无法按 UTC day-90 闭区间确定、出现旧模型 silent fallback、需要改变 artifact schema/reader、或三个 entrypoint 产生第二份 mapping 时停止
- `lane_map`: spec 与 implementation 由 coordinator `/root` 单 writer；independent reviewer `/root/review_pr612` 只读且无 writable files；时间边界、dry-run 与 eval contract 验证由 coordinator 串行运行

不改变默认 haiku，不在 CI 联网，不自动 fallback 旧模型，不修改 artifact schema。官方 model
ID 必须在实现开始时再次核实并记录 evidence。
