# Task Plan

## Linked Issue

GH-626

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`
- Status: draft；执行前必须由维护者批准规格并把 issue 置为 `ready_to_implement`

## 实现任务

- [ ] `SP626-T1` 增加有序 compact rule-id selection 与 canonical renderer。Covers: B-001, B-002, B-006. Owner: implementation agent. Dependencies: spec approval. Done when: renderer 只从 canonical records 读取展示字段且重复生成无 diff。Verify: generator unit tests；连续两次生成后 `git diff --exit-code`。
- [ ] `SP626-T2` 增加缺失/重复 id 与 stale output 的 fail-visible checks。Covers: B-003, B-004. Owner: implementation agent. Dependencies: SP626-T1. Done when: negative fixtures 返回非零并指明 id/文件，CI 检测 stale compact table。Verify: `bash scripts/ci/validate-generated-rule-docs.sh` 与 focused negative tests。
- [ ] `SP626-T3` 更新 compact 维护说明并验证 setup/U-32 兼容。Covers: B-005. Owner: implementation agent. Dependencies: SP626-T1. Done when: 维护者入口指向 canonical source，默认注入集合与预算不扩大。Verify: `bash tests/hooks/test_count_active_constraints.sh` 和 focused setup tests。
- [ ] `SP626-T4` 运行规则文档提交门禁并记录 fresh output。Covers: B-001, B-003, B-004, B-005, B-006. Owner: verification owner. Dependencies: SP626-T1..T3. Done when: 所有必跑命令在同一提交通过。Verify: `bash scripts/ci/validate-rules.sh`; `bash scripts/ci/validate-generated-rule-docs.sh`; `bash scripts/verify/doc-freshness-check.sh --strict`。

## 并行拆分

本项不并行：generator、compact 产物与 tests 属于同一可写契约，单 owner 可避免
生成文件竞态。

## 验证

- Product invariant 集合：B-001..B-006；task coverage union 完整。
- `python3 checks/check_workflow.py --repo . --spec-dir docs/specs/GH626`
- `git diff --check`

## Handoff Notes

当前仅为 draft task plan。未获得 spec approval 或 `ready_to_implement` 标签时停止；
不得开始 generator/高上下文文件修改，不得降低 U-32 或 freshness 测试。
