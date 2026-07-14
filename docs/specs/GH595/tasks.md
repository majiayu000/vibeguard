# Task Plan

## Linked Issue

GH-595

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## 实现任务

- [ ] `SP595-T1` Covers: B-001, B-003. Owner: adoption worker. Depends on: none. 将 pinned SpecRail pack 的 workflow validator、核心 gates、shared libraries、schemas、fixtures、templates、skills 和 policies 纳入原 PR #594。Done when: 所有 required assets 位于仓库内，pack/spec validator 对缺失、空文件、非法 schema、错误 packet identity、skills-lock drift、target helper 弱化以及 missing/non-directory configured root 非零退出；默认 CLI 与 `--all-specs` 均验证 configured root。Verify: `python3 checks/check_workflow.py --repo .`；`python3 -m pytest -q`；`bash tests/test_specrail_adoption.sh`。
- [ ] `SP595-T2` Covers: B-002, B-010, B-011. Owner: consumer override worker. Depends on: SP595-T1. 应用 VibeGuard consumer overrides，并记录精确上游 pin、target-local/external evidence 边界和 preserved files。Done when: configured packet 为 `docs/specs/GH{issue_number}/`、locale 为 `zh-CN`、persisted `auth_mode` 为 `review`，错误 `product_spec=README.md` 被拒绝，config/evidence 中等价 `./` 路径被规范化，未执行 local skill `--apply`，README/LICENSE/CHANGELOG 无 diff。Verify: `bash tests/test_specrail_adoption.sh`；`git diff --name-only origin/main...HEAD` 人工审查。
- [ ] `SP595-T3` Covers: B-004, B-005, B-006, B-007. Owner: PR gate worker. Depends on: SP595-T1, SP595-T2. 实现只读 GitHub PR evidence adapter 与完全离线 PR gate。Done when: evidence 绑定采集前后相同 head/issue relation，分页读取全部 review threads，并包含 CI/review/threads/review source/lane failure/resolver role/merge state；分页不完整时 fail closed，仅缺人工授权时精确返回 `needs_human`，其他确定性负例保持 non-allowed，完整 pre-merge evidence 可在没有 `merge_record` 时 `allowed`；声明 merge dispatch 时强制校验字段配对、head SHA 和时间顺序，声明 `merge_record` 时强制校验 merge path、remote confirmation 和 merge commit SHA；self-review 不可静默替代失败 reviewer lane。Verify: `python3 -m pytest -q`；`bash tests/test_specrail_adoption.sh`；对 later-page unresolved thread、PR allowed、missing-auth、pending-CI、unresolved-thread、merge-confirmed、merge-missing-path、merge-unconfirmed、query-after-merge、self-review 和 implementer-resolved-thread fixtures 运行 `checks/pr_gate.py`。
- [ ] `SP595-T4` Covers: B-008, B-009. Owner: runtime ledger worker. Depends on: SP595-T1, SP595-T3. 实现 runtime checkpoint schema、ledger gate 与 queue/tranche 语义规则。Done when: merge-ready/merged 项必须绑定 current-head PR gate、CI、reviewer lane、零 unresolved threads、clean merge state 和显式授权；false-complete、invalid spec status、未声明 spec-only streak、超预算 continuation、未报告 lane failure 均被阻断并保留 resume handoff。Verify: `python3 -m pytest -q`；`bash tests/test_specrail_adoption.sh`；对 `examples/fixtures/runtime-*.json` 运行 `checks/runtime_ledger_gate.py`。
- [ ] `SP595-T5` Covers: B-001, B-002, B-003, B-005, B-008, B-009, B-010, B-011. Owner: adoption verification worker. Depends on: SP595-T1, SP595-T2, SP595-T3, SP595-T4. 接入 target-local adoption smoke 与独立 CI workflow。Done when: smoke 锁定上游 SHA、验证 consumer overrides/local evidence、trusted helper、默认 CLI configured root、configured path、review-thread 全分页、精确 missing-auth decision 和 PR/runtime 正负 fixture；CI 在 PR/push 上运行 all-spec、smoke，并对实际 base/head committed diff 做 whitespace check。Verify: `bash tests/test_specrail_adoption.sh`；`python3 checks/check_workflow.py --repo . --all-specs`；检查 `.github/workflows/workflow-check.yml`。
- [ ] `SP595-T6` Covers: B-006, B-007, B-012. Owner: independent reviewer and maintainer. Depends on: SP595-T1, SP595-T2, SP595-T3, SP595-T4, SP595-T5. 完成与 implementation lane 独立的复核和 human final review，并保留上游兼容依赖与 draft gate。Done when: reviewer 对 current PR head 给出无 P0/P1/P2 的证据，所有 review threads 由合规角色解决，维护者确认是否解除 draft；没有 comment/mark-ready/merge 被本 task plan 自动执行。Verify: `gh pr view 594 --repo majiayu000/vibeguard --json isDraft,state,headRefOid,statusCheckRollup`；human final review record。
- [ ] `SP595-T7` Covers: B-001, B-002, B-003, B-004, B-005, B-006, B-007, B-008, B-009, B-010, B-011, B-012. Owner: root coordinator. Depends on: SP595-T1, SP595-T2, SP595-T3, SP595-T4, SP595-T5, SP595-T6. 在提交或 merge-ready 声明前执行完整验证与白名单 diff 审计。Done when: focused/all-spec、adoption smoke、Python、shell contracts、Rust、doc path、whitespace 和 remote-current-head evidence 全部新鲜通过，tracked diff 仅包含授权 adoption/spec 文件，任何缺口都明确阻断而非降级。Verify: 执行本文件“验证”中的全部命令并记录 head SHA 与日志路径。

## 并行拆分

- SP595-T1 是共享 pack 基线，先行完成。
- SP595-T2 负责 consumer config/docs/evidence；SP595-T3 负责 PR evidence/gate；
  SP595-T4 负责 runtime checkpoint gate。只有在 writable file ownership 完全
  不重叠时可并行，shared libraries 和 integration 由 root coordinator 单点合并。
- SP595-T5 在 T1-T4 后串行执行 target-local integration。
- SP595-T6 是只读 reviewer/human lane，不得写 implementation 文件或自行解除
  draft/merge gate。
- 当前补 packet 的 bounded worker 仅拥有 `docs/specs/GH595/` 和
  `docs/specs/README.md`；不得修改既有 adoption implementation。

## 验证

- `python3 checks/check_workflow.py --repo . --spec-dir docs/specs/GH595`
- `python3 checks/check_workflow.py --repo . --all-specs`
- `bash tests/test_specrail_adoption.sh`
- `python3 -m pytest -q`
- `bash tests/test_manifest_contract.sh`
- `bash tests/test_workflow_contracts.sh`
- `bash scripts/ci/validate-doc-paths.sh`
- `bash scripts/ci/validate-doc-command-paths.sh`
- `bash scripts/local-contract-check.sh --quick`
- `python3 -m compileall -q checks`
- `cargo check --manifest-path vibeguard-runtime/Cargo.toml`
- `cargo test --manifest-path vibeguard-runtime/Cargo.toml`
- `git diff --check origin/main...HEAD`

## Plan-First Handoff

```yaml
handoff:
  mode: specrail-implement
  artifacts:
    - docs/specs/GH595/product.md
    - docs/specs/GH595/tech.md
    - docs/specs/GH595/tasks.md
  runtime_pinning_snapshot: .specrail/runtime/runtime-pinning.snapshot
  verification_owner: root coordinator
  stop_conditions:
    - Remote PR head differs from the recorded implementation or review head.
    - Any deterministic gate returns blocked or required evidence is missing.
    - Writable ownership overlaps another active lane.
    - Work would install local skills, change auth_mode away from review, or bypass a human gate.
  lane_map:
    adoption_implementation: original PR #594 implementation owner
    independent_review: read-only reviewer lane
    human_final_review: maintainer
    verification_integration: root coordinator
```

## Handoff Notes

- PR #594 是已有 implementation PR；本 packet 为其补齐 canonical contract，不把
  post-hoc spec 当成额外 implementation progress。
- Stable IDs、paths、commands、JSON keys、states 和 decision values 保持英文。
- `runtime_pinning_snapshot` 是 coordinator-owned 本地证据，不纳入本 spec commit。
- 持久化 `auth_mode` 保持 `review`；不得因为 checks 绿色而自行 mark-ready 或 merge。
- 后续用 #587 验证 adoption 时必须重新收集 current-head GitHub evidence，不能复用
  #594 或旧 head 的 CI/review 结论。
