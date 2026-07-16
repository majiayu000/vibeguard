# Task Plan

## Linked Issue

GH-630

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`
- Status: draft；执行前必须有 spec approval 与 `ready_to_implement`

## 实现任务

- [ ] `SP630-T1` 定义 model-baseline manifest 与离线 freshness validator。Covers: B-001, B-004, B-005. Owner: implementation agent. Dependencies: spec approval. Done when: 官方来源/date/window 可审计且 stale fixture 非零。Verify: manifest/freshness unit tests。
- [ ] `SP630-T2` 让 run_eval resolver 消费 baseline 并保留 default/passthrough。Covers: B-001, B-002, B-003. Owner: implementation agent. Dependencies: SP630-T1. Done when: aliases 更新、默认 haiku、full ID 不变。Verify: eval Python unit tests。
- [ ] `SP630-T3` 对齐 behavior/benchmark entrypoints 与 dry-run/help evidence。Covers: B-006, B-007. Owner: implementation agent. Dependencies: SP630-T2. Done when: 无第二份 mapping 且输出显示 resolved baseline。Verify: `bash tests/test_eval_contract.sh`。
- [ ] `SP630-T4` 运行 eval 提交门禁。Covers: B-001, B-002, B-003, B-004, B-005, B-006, B-007. Owner: verification owner. Dependencies: SP630-T1..T3. Done when: unit/integration/dry-run 同一提交通过且未调用 API。Verify: unittest、eval contract test、两条 dry-run commands。

## 并行拆分

不并行：manifest、resolver 与 entrypoint tests 共享 model contract。

## 验证

- Product invariant 集合：B-001..B-007；task coverage union 完整。
- `python3 checks/check_workflow.py --repo . --spec-dir docs/specs/GH630`

## Handoff Notes

不改变默认 haiku，不在 CI 联网，不自动 fallback 旧模型。官方 model ID 必须在实现时再次
核实并记录 evidence。
