# Task Plan

## Linked Issue

GH-627

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`
- Status: draft；执行前必须有 spec approval 与 `ready_to_implement`

## 实现任务

- [ ] `SP627-T1` 实现 closed-map namespaced resolver，并保留 requested-name diagnostics。Covers: B-001, B-002, B-006. Owner: implementation agent. Dependencies: spec approval. Done when: 所有合法名唯一映射，非法 basename/path fail closed。Verify: focused resolver negative/positive tests。
- [ ] `SP627-T2` 把 repo-linked 与 installed lookup 切换到 canonical files。Covers: B-003, B-004. Owner: implementation agent. Dependencies: SP627-T1. Done when: 两种模式输出与 policy/adapter 语义兼容。Verify: Codex runtime adapter tests。
- [ ] `SP627-T3` 删除 8 个 alias shells并更新 manifest/install/test set-sync contract。Covers: B-005. Owner: implementation agent. Dependencies: SP627-T1..T2. Done when: alias glob 为空且无物理依赖。Verify: `bash scripts/ci/validate-hooks.sh`; `bash scripts/ci/validate-hooks-manifest.sh`。
- [ ] `SP627-T4` 运行提交门禁并记录 fresh output。Covers: B-001, B-002, B-003, B-004, B-005, B-006. Owner: verification owner. Dependencies: SP627-T1..T3. Done when: focused 与 broad hook gates 同一提交通过。Verify: root validation table 的 hooks/guard commands 与 `git diff --check`。

## 并行拆分

不并行：wrapper、alias 删除与 fixtures 共享同一 hook-name contract。

## 验证

- Product invariant 集合：B-001..B-006；task coverage union 完整。
- `python3 checks/check_workflow.py --repo . --spec-dir docs/specs/GH627`
- `git diff --check`

## Handoff Notes

规格未批准或 issue 未置 `ready_to_implement` 时停止。禁止接受任意 strip 后的文件名，
禁止保留 silent alias fallback。
