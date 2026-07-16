# Task Plan

## Linked Issue

GH-605

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## 实现任务

- [ ] `SP605-T1` Owner: implementation agent — 在 authoritative runtime classifier 中加入精确 `_tests.rs` suffix，并扩展 unit/CLI 正负例。Depends on: Spec PR merged and live implementation route allowed。Covers: B-001, B-003, B-005。Done when: `--test`/`--prod` 互补分类正确，现有 test conventions 与相似 production names 保持原行为。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml test_path_matches_rust_guard_exclusions`；focused CLI filter assertions。
- [ ] `SP605-T2` Owner: implementation agent — 同步 shell fallback 与 hook runtime stub，不在任何 hook/guard consumer 新增独立 glob。Depends on: SP605-T1。Covers: B-002, B-003, B-005。Done when: forced runtime failure 与正常 runtime 对具名路径分类一致，self-application check 证明没有第二套 consumer classifier。Verify: `bash tests/unit/test_rust_check_unwrap_in_prod.sh`; `bash scripts/ci/self-application/check-rust-test-path-classifier.sh .`。
- [ ] `SP605-T3` Owner: implementation agent — 扩展 RS-03 focused harness，覆盖 standalone/staged 的 `_tests.rs` ignore、普通 `.rs` finding、相似文件负例与 strict/non-strict contract。Depends on: SP605-T2。Covers: B-003, B-004, B-006。Done when: assertions 绑定具名路径/finding，不含 checkout count threshold，不弱化现有 production failure assertions。Verify: `bash tests/unit/test_rust_check_unwrap_in_prod.sh`; manual self-scan grep。
- [ ] `SP605-T4` Owner: verification owner + independent reviewer — 执行 focused、Rust、hook/guard 与 broad gates，并按 product spec 做逐项覆盖审查。Depends on: SP605-T3。Covers: B-001, B-002, B-003, B-004, B-005, B-006。Done when: deterministic checks 全绿；review 确认无通用 contains-tests 排除、无复制 classifier、无固定计数或测试弱化。Verify: `bash scripts/ci/validate-guards.sh`; `bash scripts/ci/validate-hooks.sh`; `cargo check --manifest-path vibeguard-runtime/Cargo.toml`; `cargo test --manifest-path vibeguard-runtime/Cargo.toml`; `bash scripts/local-contract-check.sh --quick`; `git diff --check`。

## 并行拆分

T1-T3 共享 classifier/focused harness 且有顺序依赖，必须由单一 implementation lane 串行
完成。T4 的 independent reviewer 只读，不与实现 lane 共享 writable file。

| Lane | Owner | Writable files |
| --- | --- | --- |
| implementation | `/root` | `vibeguard-runtime/src/hook_checks_common.rs`, `guards/rust/common.sh`, `tests/lib/hook_test_lib.sh`, `tests/unit/test_rust_check_unwrap_in_prod.sh` 及必要的现有 classifier test file |
| verification | `/root` | none（只运行命令与记录证据） |
| independent_review | native reviewer agent | none（只读 review） |

## Plan-First Handoff

```yaml
handoff:
  mode: specrail-implement
  artifacts:
    - docs/specs/GH605/product.md
    - docs/specs/GH605/tech.md
    - docs/specs/GH605/tasks.md
  runtime_pinning_snapshot: None
  verification_owner: /root
  stop_conditions:
    - A real CI, review-thread, or SpecRail PR gate is blocked.
    - The implementation would classify filenames by broad substring instead of exact suffix.
    - Any hook or guard consumer introduces a duplicate test-path classifier.
    - A production finding disappears, a test assertion is weakened, or scope expands beyond GH-605.
  lane_map:
    implementation: /root
    verification: /root
    independent_review: native reviewer agent (read-only)
```

## 验证

```bash
python3 checks/check_workflow.py --repo . --spec-dir=docs/specs/GH605
bash scripts/ci/validate-doc-paths.sh
bash scripts/ci/validate-doc-command-paths.sh
git diff --check
```

## Handoff Notes

- 写作基线：`origin/main@2a2190ce2e890d8c8a5599dbf4c3a558dfa01a51`。
- Issue #605 的 readiness 必须由 live GitHub label 证明；durable spec packet 不构成未来
  PR 的 merge authorization。每次 merge 前仍需当前 head 的 CI、独立 review、review
  threads 与 SpecRail PR gate 证据。
- 59 个 test-suffix finding 与 11 个 production finding 只是诊断快照，不得写入测试阈值。
