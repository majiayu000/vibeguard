# Task Plan — GH671

## Linked Issue

GH-671

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## 实现任务

- [x] `SP671-T1` 新增 centralized U-16 baseline decision。Covers: B-001, B-002, B-003, B-004, B-005, B-008. Owner: implementation agent. Done when: new/crossing/legacy-growth/legacy-debt/below-limit matrix 有 Rust unit test。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml u16_baseline`。
- [x] `SP671-T2` 将 pre-edit 与 pre-write 改为比较 old/new line counts。Covers: B-003, B-004, B-005. Owner: implementation agent. Done when: legacy shrinking/same-size 不 block，legacy growth 仍 block。Verify: `bash tests/hooks/test_pre_edit_guard.sh`; `bash tests/hooks/test_pre_write_guard.sh`。
- [x] `SP671-T3` 新增 staged/CI Git baseline command 并接入 pre-commit。Covers: B-001, B-002, B-003, B-006, B-007, B-008. Owner: implementation agent. Done when: initial commit、新导入、跨线、遗留增长、未变遗留文件、rename 与 exemption 均由同一 runtime command 判定。Verify: `bash tests/hooks/test_u16_baseline.sh`。
- [x] `SP671-T4` 将 CI workflow 接入 U-16 changed-file check。Covers: B-001, B-002, B-003, B-006. Owner: implementation agent. Done when: checkout 可计算 merge-base，CI step 调用 `scripts/ci/validate-u16-baseline.sh`。Verify: `bash scripts/ci/validate-u16-baseline.sh origin/main HEAD`。
- [x] `SP671-T5` 更新 SpecRail packet、README、CHANGELOG 与 spec index。Covers: none — documentation/release evidence. Owner: implementation agent. Done when: docs 描述 baseline-aware behavior 与 reinstall note。Verify: workflow/spec/doc validators。

## 并行拆分

本实现未使用并行写 lane。可并行的只读 review lane 为：`vibeguard-runtime/src/u16_baseline.rs` decision review、hook shell wiring review、SpecRail packet review。所有写入由当前 implementation agent 串行完成，避免共享文件冲突。

## 验证

```bash
python3 checks/check_workflow.py --repo . --spec-dir=docs/specs/GH671
python3 checks/check_workflow.py --repo . --all-specs
cargo fmt --manifest-path vibeguard-runtime/Cargo.toml -- --check
cargo check --manifest-path vibeguard-runtime/Cargo.toml
cargo test --manifest-path vibeguard-runtime/Cargo.toml
bash scripts/ci/validate-hooks.sh
bash scripts/ci/validate-hooks-manifest.sh
bash tests/hooks/test_u16_baseline.sh
bash tests/hooks/test_pre_edit_guard.sh
bash tests/hooks/test_pre_write_guard.sh
bash tests/hooks/test_u16_config.sh
bash tests/test_hooks.sh
bash scripts/local-contract-check.sh --quick
git diff --check
```

## Handoff Notes

No workflow tables were edited. Issue GH-671 remains open until the implementation PR is reviewed and merged.
