# Task Plan

## Linked Issue

GH-631

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`
- Status: draft；三个 keep/remove 决策须在 spec review 确认后才能执行

## 实现任务

- [ ] `SP631-T1` 确认并执行 awk skill 的 keep/remove 决策。Covers: B-001, B-004, B-005. Owner: implementation agent. Dependencies: maintainer decision + `ready_to_implement`. Done when: 有真实安装/验证或 clean removal。Verify: skill format、manifest 与 zero-reference checks。
- [ ] `SP631-T2` 确认并执行 alerting template 的 keep/remove 决策。Covers: B-002, B-004, B-005. Owner: implementation agent. Dependencies: maintainer decision. Done when: 有外部 discoverability/validation 或 clean removal。Verify: doc path/YAML/zero-reference checks。
- [ ] `SP631-T3` 文档化并验证 sgconfig manual purpose，或 clean removal。Covers: B-003, B-005. Owner: implementation agent. Dependencies: maintainer decision. Done when: explicit manual command 可运行且不改变 production guards，或无残留。Verify: ast-grep smoke 与 production command audit。
- [ ] `SP631-T4` 增加窄 inventory gate 并保护 architecture template。Covers: B-006, B-007. Owner: implementation agent. Dependencies: SP631-T1..T3 decisions. Done when: unknown fixtures fail，known architecture consumer passes。Verify: inventory/dependency-layer tests。
- [ ] `SP631-T5` 运行 distribution 提交门禁。Covers: B-001, B-002, B-003, B-004, B-005, B-006, B-007. Owner: verification owner. Dependencies: SP631-T1..T4. Done when: skill/manifest/docs gates 同一提交通过。Verify: root validation table 的 skills、manifest、docs commands。

## 并行拆分

决策确认后 T1/T2/T3 文件互斥可并行，但当前单-agent 流程默认串行；T4 最后集成 inventory。

## 验证

- Product invariant 集合：B-001..B-007；task coverage union 完整。
- `python3 checks/check_workflow.py --repo . --spec-dir docs/specs/GH631`

## Handoff Notes

本项含三个人类 keep/remove 决策；未确认时停止。禁止操作系统 Prometheus 目录，禁止误删
architecture template，禁止用 default install 伪造消费方。
