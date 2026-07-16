# Task Plan

## Linked Issue

GH-627

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`
- Status: draft；执行前必须有 spec approval 与 `ready_to_implement`

## 实现任务

- [ ] `SP627-T1` 实现 closed-map namespaced resolver，并保留 requested-name diagnostics。Covers: B-001, B-002, B-006. Owner: implementation agent. Dependencies: spec approval. Done when: 所有合法名唯一映射；缺失/空/未知/路径型 requested name 在执行任何目标前，对 PreToolUse/PermissionRequest/Stop/其他已知事件分别产生 protocol-valid visible denial/failure、stable reason 和 wrapper exit 0，且目标 fixture 未执行。Verify: focused resolver negative/positive event matrix。
- [ ] `SP627-T2` 把 repo-linked 与 installed lookup 切换到 canonical files。Covers: B-003, B-004. Owner: implementation agent. Dependencies: SP627-T1. Done when: 两种模式输出与 policy/adapter 语义兼容。Verify: `bash tests/test_codex_runtime.sh`。
- [ ] `SP627-T3` 删除 8 个 alias shells并更新 manifest/install/test set-sync 与 safe-bash pack contract。Covers: B-005. Owner: implementation agent. Dependencies: SP627-T1..T2. Done when: alias glob 为空且无物理依赖；`packs/safe-bash/pack.yaml` 的 source/install 列表只含 canonical hook，Codex audit commands 仍传 requested namespaced name。Verify: `bash scripts/ci/validate-hooks.sh`; `bash scripts/ci/validate-hooks-manifest.sh`; `bash tests/test_guard_packs.sh`。
- [ ] `SP627-T4` 运行提交门禁并记录 fresh output。Covers: B-001, B-002, B-003, B-004, B-005, B-006. Owner: verification owner. Dependencies: SP627-T1..T3. Done when: focused 与 broad hook/guard-pack gates 同一提交通过。Verify: root validation table 的 hooks/guard commands、`bash tests/test_guard_packs.sh` 与 `git diff --check`。

## 并行拆分

不并行：wrapper、alias 删除与 fixtures 共享同一 hook-name contract。

## 验证

- Product invariant 集合：B-001..B-006；task coverage union 完整。
- `python3 checks/check_workflow.py --repo . --spec-dir docs/specs/GH627`
- `git diff --check`

## Handoff Notes

- `mode`: `specrail-implement`
- `artifacts`: `docs/specs/GH627/product.md`, `docs/specs/GH627/tech.md`,
  `docs/specs/GH627/tasks.md`
- `runtime_pinning_snapshot`: None；实现必须从 Spec merge 后的最新 `origin/main` 建立独立
  worktree，并在 PR evidence 中记录 exact base/head SHA。
- `verification_owner`: `/root`
- `stop_conditions`: 规格未批准或 issue 未置 `ready_to_implement`；解析不能保持 manifest
  hook 闭集；必须接受任意 strip、路径型名称或 alias fallback；canonical 文件缺失不能产生可见
  install-incomplete 失败；focused hook、manifest、setup 或 broad contract 检查失败；独立 reviewer
  有 blocker；current-head CI、review threads 或 SpecRail required gate 未通过。
- `lane_map`: specification `/root` 独占 `docs/specs/GH627/` 与 spec index；implementation
  `/root` 独占 wrapper、alias/pack 分发声明删除及相关 fixtures/tests；independent reviewer `/root/review_pr612`
  只读，无可写文件。
- Spec PR 只 `Refs #627`；只有独立 Impl PR 使用 `Fixes #627` 并在合并后关闭 Issue。
