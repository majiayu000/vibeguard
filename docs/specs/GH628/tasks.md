# Task Plan

## Linked Issue

GH-628

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`
- Status: draft；执行前必须有 spec approval 与 `ready_to_implement`

## 实现任务

- [ ] `SP628-T1` 以 Git tracked files 重构 personal-path 扫描和分类。Covers: B-001, B-002, B-006, B-007. Owner: implementation agent. Dependencies: spec approval. Done when: Markdown 被覆盖、placeholder 不误报、扫描失败非零。Verify: focused classifier/entrypoint fixtures。
- [ ] `SP628-T2` 机械转写历史 plan 的 literal personal paths。Covers: B-003. Owner: implementation agent. Dependencies: SP628-T1. Done when: 保留历史语义且不再依赖 blanket skip。Verify: personal-path validator 与 `rg` audit。
- [ ] `SP628-T3` 为共享 doc allowlist 增加 usage/freshness/migration gate。Covers: B-004, B-005, B-006. Owner: implementation agent. Dependencies: spec approval. Done when: unused/stale/duplicate/migration-pair fixtures 均失败。Verify: 两个 doc validator focused tests。
- [ ] `SP628-T4` 运行跨表面 contract gate。Covers: B-001, B-002, B-003, B-004, B-005, B-006, B-007. Owner: verification owner. Dependencies: SP628-T1..T3. Done when: focused 与 quick contract checks 在同一提交通过。Verify: 三个 path validators；`bash scripts/local-contract-check.sh --quick`; `git diff --check`。

## 并行拆分

T1/T2 与 T3 可在文件所有权明确时串行集成；默认单 owner，避免共享 validator fixture 冲突。

## 验证

- Product invariant 集合：B-001..B-007；task coverage union 完整。
- `python3 checks/check_workflow.py --repo . --spec-dir docs/specs/GH628`

## Handoff Notes

不得删除 completed plans；不得把真实路径问题改成更宽 allowlist。任何合法历史样例争议均
停止并请求维护者决定分类。
