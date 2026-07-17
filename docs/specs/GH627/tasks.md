# Task Plan

## Linked Issue

GH-627

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`
- Status: implemented；规格已合并且 issue 已置为 `ready_to_implement`

## 实现任务

- [x] `SP627-T1` 实现 closed-map namespaced resolver，并保留 requested-name diagnostics。Covers: B-001, B-002, B-006. Owner: implementation agent. Dependencies: spec approval. Done when: 所有合法名唯一映射；缺失/空/未知/路径型 requested name 在执行任何目标前，对 PreToolUse/PermissionRequest/Stop/其他已知事件分别产生 protocol-valid visible denial/failure、stable reason 和 wrapper exit 0，且目标 fixture 未执行。Verify: focused resolver negative/positive event matrix。
- [x] `SP627-T2` 把 repo-linked 与 installed lookup 切换到 canonical files。Covers: B-003, B-004. Owner: implementation agent. Dependencies: SP627-T1. Done when: 两种模式输出与 policy/adapter 语义兼容。Verify: `bash tests/test_codex_runtime.sh`。
- [x] `SP627-T3` 删除 8 个 alias shells并更新 manifest validator/install/test set-sync 与 safe-bash pack contract。Covers: B-005. Owner: implementation agent. Dependencies: SP627-T1..T2. Done when: alias glob 为空且无物理依赖；`hooks_manifest.py` 要求 requested `codex.script` 精确等于 `vibeguard-${canonical item.script}` 且只检查 canonical 文件存在；`packs/safe-bash/pack.yaml` 的 source/install 列表只含 canonical hook，Codex audit commands 仍传 requested namespaced name。Verify: `bash scripts/ci/validate-hooks.sh`; `bash scripts/ci/validate-hooks-manifest.sh`; `bash tests/test_manifest_contract.sh`; `bash tests/test_guard_packs.sh`。
- [x] `SP627-T4` 运行提交门禁并记录 fresh output。Covers: B-001, B-002, B-003, B-004, B-005, B-006. Owner: verification owner. Dependencies: SP627-T1..T3. Done when: focused 与 broad hook/manifest/guard-pack gates 同一提交通过。Verify: root validation table 的 hooks/guard commands、`bash tests/test_manifest_contract.sh`、`bash tests/test_guard_packs.sh` 与 `git diff --check`。

## 并行拆分

不并行：wrapper、alias 删除与 fixtures 共享同一 hook-name contract。

## 验证

- Product invariant 集合：B-001..B-006；task coverage union 完整。
- `python3 checks/check_workflow.py --repo . --spec-dir docs/specs/GH627`
- `git diff --check`

## Handoff Notes

实现按已批准规格完成：Codex wrapper 使用 manifest 同步的 closed map 解析 requested 名称，
repo-linked/installed snapshot 与 Rust/Python setup 健康检查只验证 canonical 文件；8 个物理 alias
shell 已删除。非法名称按 event 输出可见拒绝并保留 stable diagnostic。Rust 全量、Codex runtime
181/181、manifest 97/97、guard packs 79/79 与 setup 535/535 均通过 fresh verification。
