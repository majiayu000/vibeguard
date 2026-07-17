# Task Plan

## Linked Issue

GH-632

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`
- Status: draft；执行前必须有 spec approval 与 `ready_to_implement`

## 实现任务

- [ ] `SP632-T1` 补齐 directory map 的 operational script groups。Covers: B-001. Owner: implementation agent. Dependencies: spec approval. Done when: 当前遗漏的 `constraints`、`doctors`、`gc`、`learn`、`metrics`、`systemd` 六个一级目录都有简洁职责说明，且动态枚举全部 tracked 一级 `scripts/` 目录（包括已记录的 `ci`、`lib`、`setup`、`verify`）后，每个精确路径都能在 map 中命中。Verify: inventory/map focused assertion；fixture 或临时新增未知一级目录时断言失败。
- [ ] `SP632-T2` 把 site version badge 改为 canonical 或稳定文案。Covers: B-002. Owner: implementation agent. Dependencies: maintainer 选择 stable wording 或 existing canonical source. Done when: 下一 patch release 不需手改该 literal。Verify: site search/link check。
- [ ] `SP632-T3` 标记 benchmark 快照并合并 plan-mode 标题。Covers: B-003, B-004. Owner: implementation agent. Dependencies: spec approval. Done when: 不伪造新 benchmark 且 heading count 为 1。Verify: focused search + skill format。
- [ ] `SP632-T4` 运行 docs/skill 提交门禁。Covers: B-001, B-002, B-003, B-004, B-005. Owner: verification owner. Dependencies: SP632-T1..T3. Done when: 所有 docs/skill checks 同一提交通过。Verify: doc path、command path、skill format、`git diff --check`。

## 并行拆分

改动很小，单 owner 串行完成；不启动并行 lanes。

## 验证

- Product invariant 集合：B-001..B-005；task coverage union 完整。
- `python3 checks/check_workflow.py --repo . --spec-dir docs/specs/GH632`

## Handoff Notes

不得把历史 benchmark 数字直接替换为 126 后声称已重跑；不得新增另一份手工 patch version。
