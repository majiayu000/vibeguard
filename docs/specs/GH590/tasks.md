# Task Plan

## Linked Issue

GH-590

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## 实现任务

- [ ] `SP590-T1` Covers: B-001, B-002, B-003, B-004, B-006, B-008。Owner: Rust cooldown decision owner。Depends on: canonical packet 经 human approval、spec PR #593 merge、fresh duplicate evidence 与 implement route allowed。范围为 `vibeguard-runtime/src/hook_checks_history.rs`、`vibeguard-runtime/src/hook_orchestrator_post_edit_history.rs` 及同模块 unit tests；实现有向 tuple opaque key、config cooldown、shown evidence 与 bounded lookup，保持 `recent_overlap` candidate 语义。Done when: first/no/invalid evidence 显示完整 warning；same key inside window 可 suppress；exact boundary、future/bad/missing/>500 rows、unknown session、different key、reverse pair 均 fail-open；suppressed event 不续期。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml hook_orchestrator_post_edit_history` 与 focused helper tests，禁止 process-global env mutation。

- [ ] `SP590-T2` Covers: B-005, B-007, B-009。Owner: Rust event/output owner（与 T1 串行）。Depends on: SP590-T1。新增 schema-valid `decision=pass,status=skipped` telemetry，只有 append 成功才省略 W-14；失败回到 visible warning；同 run 其他 warnings 继续决定最终 output，并扩展 observe/prior-warn tests。Done when: telemetry shape、reason prefix、file detail、w14_key 稳定；raw W-14 frequency 可见但 negative/prior escalation 不增加；append failure 不 silent pass；mixed warning 只移除重复 W-14。Verify: focused Rust tests、observe tests 与 `cargo test --manifest-path vibeguard-runtime/Cargo.toml`。

- [ ] `SP590-T3` Covers: B-004, B-010。Owner: config distribution owner。Depends on: approved packet；可与 T1 并行，文件所有权不重叠。更新 config example/README、`vibeguard-runtime/tests/runtime_config_cli.rs`、`tests/test_setup.sh`，必要时只在既有 install fixture 补 fresh-seed assertion。Done when: 文档/示例声明 env > JSON > `3600`、`0` disable；子进程 fixture 覆盖 invalid env→JSON、wrong-type/negative JSON→default；fresh seed 有 key 且 existing config 不覆盖。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml --test runtime_config_cli`、`bash tests/test_setup.sh`、docs validators。

- [ ] `SP590-T4` Covers: B-001, B-002, B-003, B-004, B-005, B-006, B-007, B-008, B-009, B-010。Owner: production regression owner。Depends on: SP590-T1, SP590-T2, SP590-T3。扩展 `tests/hooks/test_post_edit_w14.sh` 的真实 wrapper→Rust runtime fixture，不 source dormant shell W-14 helper。Done when: first/repeat/boundary/0/different file/different peer/reverse pair/relative-absolute/unknown/bad history/mixed warning 全部断言可见性、event JSON 与 exit contract；append failure 使用 injectable seam。Verify: `bash tests/hooks/test_post_edit_w14.sh` 与 `bash tests/test_hooks.sh`。

- [ ] `SP590-T5` Covers: B-001, B-002, B-003, B-004, B-005, B-006, B-007, B-008, B-009, B-010。Owner: verification owner + independent read-only reviewer。Depends on: SP590-T4。执行全部 Rust/hook/setup/repository gates，并在 immutable PR head 核对 500-line boundary、schema-valid telemetry、no shell parity、no silent append failure 与 `0` rollback。Done when: deterministic checks 全绿，CI/current-head、0 unresolved threads、review artifact 与 PR gate evidence 完整；merge 仍等待独立 per-PR human authorization。Verify: 下方全部命令与 current-head reviewer verdict。

## 并行拆分

| Lane | Owner | Writable files | Ordering |
| --- | --- | --- | --- |
| Rust decision + event | one implementation owner | `hook_checks_history.rs`, `hook_orchestrator_post_edit_history.rs` 及内联 tests | T1 → T2 serial |
| Config distribution | one config owner | config example/README、`runtime_config_cli.rs`、setup fixture | 可与 T1 并行；在 T4 前合并 |
| Production regression | one sequential test owner | `tests/hooks/test_post_edit_w14.sh`；仅在既有 harness 必需时触及 test registry | T1/T2/T3 后 |
| Verification | coordinator | no concurrent source writes | T4 后 |
| Independent review | non-implementer native reviewer | read-only | immutable PR head |

Forbidden writable scope：`hooks/_lib/post_edit_history.sh`、event decision enum 扩展、新 state
文件、W-15/CHURN 调参、GC digest 新 UI。若实现需要其中任一项，停止并回到 spec human decision。

## 验证

Spec PR #593（本次迁移）：

```bash
python3 checks/check_workflow.py --repo .
python3 checks/check_workflow.py --repo . --spec-dir docs/specs/GH590
bash scripts/ci/validate-doc-paths.sh
bash scripts/ci/validate-doc-command-paths.sh
git diff --check
```

未来 implementation PR：

```bash
bash tests/hooks/test_post_edit_w14.sh
bash tests/test_hooks.sh
cargo test --manifest-path vibeguard-runtime/Cargo.toml --test runtime_config_cli
bash tests/test_setup.sh
cargo fmt --manifest-path vibeguard-runtime/Cargo.toml -- --check
cargo clippy --manifest-path vibeguard-runtime/Cargo.toml --all-targets -- -D warnings
cargo check --manifest-path vibeguard-runtime/Cargo.toml
cargo test --manifest-path vibeguard-runtime/Cargo.toml
bash scripts/ci/validate-hooks.sh
bash scripts/ci/validate-hooks-manifest.sh
bash scripts/local-contract-check.sh --quick
bash scripts/ci/validate-doc-paths.sh
bash scripts/ci/validate-doc-command-paths.sh
python3 checks/check_workflow.py --repo .
python3 checks/check_workflow.py --repo . --spec-dir docs/specs/GH590
git diff --check
```

## Handoff Notes

- 本任务仅迁移并修正现有 spec PR #593；保持 `Refs #590`，不得在 spec PR 中实现或关闭 issue。
- 2026-07-15 write-spec route 以显式 `ready_to_spec` 为 `allowed`。implement route 的 planning
  probe 为 `needs_human`：缺 fresh duplicate evidence，且 readiness/spec approval human gates
  仍保留；tasks 文件不是 implementation authorization。
- Canonical packet 取代未批准的 legacy plan document。旧草案的 shell parity、
  `decision=info`、无向/不完整 key、无限 durability 暗示和 root Cargo 命令均不得沿用。
- Product invariant set 与 tasks Covers union 都是
  `{B-001,B-002,B-003,B-004,B-005,B-006,B-007,B-008,B-009,B-010}`。
- `runtime_pinning_snapshot: None` 只适用于本次 spec-only 短迁移；未来 implementation lane
  在写前按 runtime drift contract 重新决定是否捕获 snapshot。

```yaml
handoff:
  mode: specrail-plan-tasks
  artifacts:
    - docs/specs/GH590/product.md
    - docs/specs/GH590/tech.md
    - docs/specs/GH590/tasks.md
  runtime_pinning_snapshot: None
  verification_owner: root coordinator
  stop_conditions:
    - Human packet approval or fresh duplicate evidence is missing before implementation.
    - The change adds an info decision, mutable cooldown state, or shell fallback parity.
    - Invalid or unavailable evidence would suppress instead of warn.
    - Suppression telemetry cannot be appended successfully.
    - Writable ownership overlaps another live lane.
  lane_map:
    rust_decision_event: one serial implementation owner
    config_distribution: disjoint config owner
    production_regression: sequential test owner
    verification_integration: root coordinator
    independent_review: non-implementer read-only reviewer
```
