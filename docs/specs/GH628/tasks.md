# Task Plan

## Linked Issue

GH-628

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`
- Status: draft；执行前必须有 spec approval 与 `ready_to_implement`

## 实现任务

- [ ] `SP628-T1` 以 Git tracked files 重构 personal-path 扫描和分类。Covers: B-001, B-002, B-006, B-007. Owner: implementation agent. Dependencies: spec approval. Done when: Markdown 被覆盖、placeholder 不误报、扫描失败非零。Verify: focused classifier/entrypoint fixtures。
- [ ] `SP628-T2` 机械转写全部 tracked Markdown 中不可判定的 literal personal paths，包含历史 plan、docs、examples 与 workflows。Covers: B-003. Owner: implementation agent. Dependencies: SP628-T1. Done when: 保留历史/示例语义，统一使用 repo-relative path 或明确 placeholder，且不再依赖 blanket skip。Verify: personal-path validator 与 tracked Markdown `rg` audit。
- [ ] `SP628-T3` 为 doc-path allowlist 增加 strict structured parser 与 usage/freshness/live-alias gate。Covers: B-004, B-005, B-006. Owner: implementation agent. Dependencies: spec approval. Done when: invalid format/category/source/scope、unused、duplicate、overlap hit、stale runtime alias 与 invalid manifest rule-link pair fixtures 均失败；single-entry multi-occurrence、scoped historical/planned 与 current live-alias pairs 通过；command-path validator 保持独立语义。Verify: doc-path focused fixtures 与既有 command-path regressions。
- [ ] `SP628-T4` 运行跨表面 contract gate。Covers: B-001, B-002, B-003, B-004, B-005, B-006, B-007. Owner: verification owner. Dependencies: SP628-T1..T3. Done when: focused 与 quick contract checks 在同一提交通过。Verify: 三个 path validators；`bash scripts/local-contract-check.sh --quick`; `git diff --check`。

## 并行拆分

T1/T2 与 T3 可在文件所有权明确时串行集成；默认单 owner，避免共享 validator fixture 冲突。

## 验证

- Product invariant 集合：B-001..B-007；task coverage union 完整。
- `python3 checks/check_workflow.py --repo . --spec-dir docs/specs/GH628`

## Handoff Notes

- `mode`: `plan_first`
- `artifacts`: `docs/specs/GH628/{product,tech,tasks}.md`、spec index；implementation 计划修改 personal/doc path validators、既有 regression runners、结构化 allowlist 与历史 plan 路径
- `runtime_pinning_snapshot`: None；CI-only path validation，不改变 production runtime 或 tool inventory
- `verification_owner`: coordinator `/root`; independent reviewer `/root/review_pr612`
- `stop_conditions`: 需要删除 completed plan、必须恢复 Markdown/tests blanket skip、合法例外无法落入四个窄 category、Git/read error 不能 fail visible、或 current-head gate 不满足时停止
- `lane_map`: spec 与 implementation 均由 coordinator 单 writer；independent reviewer 只读，无 writable files；setup/full contract 等共享状态验证串行运行
- 不得删除 completed plans；不得把真实路径问题改成更宽 allowlist。任何合法历史样例争议均停止并请求维护者决定分类。
