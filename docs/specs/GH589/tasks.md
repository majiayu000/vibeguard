# Task Plan

## Linked Issue

GH-589

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## 实现任务

- [ ] `SP589-T1` Owner: implementation agent — 在 `guards/universal/check_code_slop.sh` 复用现有 auto-detection 记录 qualified VibeGuard self-scan，并仅在该 scope 的 legacy-debug 结果中过滤 `vibeguard-runtime/src/` 的 `println!` 行。Depends on: trusted `ready_to_implement`、duplicate evidence 与 human spec approval。Covers: B-001, B-002, B-005, B-006, B-007。Done when: ordinary/缺 marker target 不过滤；default self-scan 只移除指定 println；同路径 `dbg!` 与路径外 debug 仍报告；strict 恢复；`ISSUES` 仍基于过滤后实际 findings，代码不含固定总数阈值或 `eval`。Verify: `bash -n guards/universal/check_code_slop.sh`; focused println/dbg/self/non-self/strict cases in `bash tests/unit/test_universal_check_code_slop.sh`。
- [ ] `SP589-T2` Owner: implementation agent — 在三个 detector Rust files 的每个 intentional dead-code pattern-source 匹配行追加 `// slop-pattern-source`，并在同一 guard 的 dead-code category 内仅对 qualified self-scan 过滤 marker 所在行。Depends on: SP589-T1。Covers: B-003, B-004, B-005, B-006, B-007。Done when: fresh grep inventory 中 intentional source 行逐行有 marker；相邻 marker、whole-file/path 不生效；未标记 true stub 与其他 category finding 保留；strict 恢复 marker lines；Rust detector 逻辑除注释外不变。Verify: focused same-line/adjacent/unmarked/strict cases；对 `vibeguard-runtime/src/hook_checks_common.rs`、`vibeguard-runtime/src/hook_checks_write.rs`、`vibeguard-runtime/src/hook_orchestrator_post_edit.rs` 做逐行 grep/diff review。
- [ ] `SP589-T3` Owner: test agent（与 T1/T2 串行，避免共享 guard file）— 扩展 `tests/unit/test_universal_check_code_slop.sh` 的现有 temp harness，覆盖完整/缺失 self markers、同名 ordinary repo、runtime println + dbg、marked pattern + 同文件真实 stub、相邻 marker、strict 与现有 fixture regression。Depends on: SP589-T2。Covers: B-001, B-002, B-003, B-004, B-005, B-006, B-007。Done when: assertions 绑定具名 path/content 与 rc；不出现 checkout total/debug/dead 固定数字阈值；既有 empty-catch、console、Python print、long-file、clean、fixtures tests 不弱化。Verify: `bash tests/unit/test_universal_check_code_slop.sh`; `bash scripts/ci/validate-guards.sh`。
- [ ] `SP589-T4` Owner: verification owner + independent reviewer — 在同一 implementation head 执行 focused、guard、Rust 与 broad gates，并审查 repo-scoped/category-local/逐行 marker 边界。Depends on: SP589-T3。Covers: B-001, B-002, B-003, B-004, B-005, B-006, B-007。Done when: 所有 deterministic checks 通过；default/strict manual self-scan 只作为具名 finding evidence；reviewer 确认没有 generic Rust behavior、whole-file exclusion、marker 跨 category、固定 count threshold 或弱化测试，并记录 current-head verdict。Verify: `bash tests/unit/test_universal_check_code_slop.sh`; `bash scripts/ci/validate-guards.sh`; `cargo check --manifest-path vibeguard-runtime/Cargo.toml`; `cargo test --manifest-path vibeguard-runtime/Cargo.toml`; `bash scripts/local-contract-check.sh --quick`; `git diff --check`。

## 并行拆分

T1 与 T2 都写 `guards/universal/check_code_slop.sh`，T3 又依赖最终 filter contract，因此
T1 → T2 → T3 串行。T4 在实现完成后作为验证/独立只读 review lane；不得让两个 write
lanes 并发修改 guard 或 test。

| Lane | Owner | Writable files |
| --- | --- | --- |
| Guard + marker implementation | one implementation agent | `guards/universal/check_code_slop.sh`、三个具名 detector Rust files |
| Focused regression | one sequential test agent | `tests/unit/test_universal_check_code_slop.sh` |
| Verification/integration | root coordinator | no concurrent shared-file writes |
| Independent review | non-implementer reviewer | none (read-only) |

## Plan-First Handoff

```yaml
handoff:
  mode: specrail-implement
  artifacts:
    - docs/specs/GH589/product.md
    - docs/specs/GH589/tech.md
    - docs/specs/GH589/tasks.md
  runtime_pinning_snapshot: None
  verification_owner: root coordinator
  stop_conditions:
    - Trusted ready_to_implement evidence, duplicate evidence, or human spec approval is missing.
    - The implementation would change generic Rust println behavior or a non-self-scan target.
    - A whole-file/path exclusion, cross-category marker filter, or fixed finding threshold is proposed.
    - A true unmarked finding, dbg!, existing category, strict behavior, or test assertion would be suppressed.
    - Writable ownership overlaps another lane or scope expands beyond the named guard, detector, and focused test files.
  lane_map:
    guard_marker_implementation: one implementation agent
    focused_regression: one sequential test agent
    verification_integration: root coordinator
    independent_review: non-implementer read-only reviewer
```

`runtime_pinning_snapshot` 为 `None`，因为 packet handoff 是单 issue、文件边界明确的短实现；
若执行跨会话或超过 W-20 长任务阈值，implementation owner 在写前另行捕获 snapshot。

## 验证

实现阶段：

```bash
bash -n guards/universal/check_code_slop.sh
bash tests/unit/test_universal_check_code_slop.sh
bash scripts/ci/validate-guards.sh
cargo check --manifest-path vibeguard-runtime/Cargo.toml
cargo test --manifest-path vibeguard-runtime/Cargo.toml
```

提交前：

```bash
bash scripts/local-contract-check.sh --quick
bash scripts/ci/validate-doc-paths.sh
bash scripts/ci/validate-doc-command-paths.sh
git diff --check
```

## Handoff Notes

- Fresh live issue evidence 的 labels 只有 `P2`、`guard`、`false positive`，
  `state_source: none`、`state_trusted: false`；live write_spec gate 返回 `needs_human`
  并缺 `current_state`/readiness label。
- 显式传入 `--state ready_to_spec` 的 hypothetical local planning check 返回 `allowed`；
  它只证明该假设状态允许 draft spec，不能冒充 live readiness、spec approval 或
  implementation authorization。本次由已批准 plan-first handoff 授权 spec-only drafting。
- 实现仍需 trusted `ready_to_implement`、duplicate evidence 与 human spec approval；本
  tasks packet 不解除 final review、merge、security 或 release gate。
- merge 后 fresh self-scan 为 424/312/23，旧 planning snapshot 为 353/256/20；两组都
  只是诊断快照，禁止写成 implementation threshold。
- 旧 plan/spec-589-slop-self-scan-precision.md 在本 spec PR 删除；后续唯一设计真相是
  `docs/specs/GH589/`。
