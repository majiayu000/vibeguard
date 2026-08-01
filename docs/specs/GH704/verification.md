# GH-704 Verification Contract

## Linked Spec

- [Product Spec](product.md)
- [Technical Design](tech.md)
- [Runtime Integrity Supplement](runtime-integrity.md)

> 本文件承载 GH-704 的 exact behavior-to-test ownership、数据流和实施后 broad verification。
> 它是 Draft specification 的验证补充，不是 implementation tasks，也不代表 H-001–H-020 已批准。

## Product-to-Test Mapping

Planned shell/Python/benchmark test entrypoints below must accept the named case selector and reject unknown
selectors nonzero。Rust names are exact full test names to create in the planned modules；每条
focused Rust command 必须传 `-- --exact`，且 `tests/test_manifest_contract.sh` 必须先解析本表，
对 `cargo test -- --list` 的 exact full-name count 断言为 1。零匹配、重名或 rename drift
均须 nonzero；表中每个 selector 都必须出现在完整 executable command 内，禁止 bare selector、
“config/setup tests”等模糊 owner 或无 selector broad suite，不能依赖 libtest 的 “running 0 tests” 成功退出。因此 tasks 不能把这些验证
退化成“人工观察”、substring-only filter 或无 selector 的 broad suite。

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 approval gate | payload project identity + config/policy join | `bash tests/hooks/test_semantic_defense.sh project_scoped_opt_in`、`bash tests/hooks/test_semantic_defense.sh payload_directory_replacement`、`cargo test --manifest-path vibeguard-runtime/Cargo.toml --test project_config_cli semantic_defense_project_scope -- --exact`、`bash tests/test_gc_config.sh semantic_defense_project_schema`、`bash tests/test_setup.sh semantic_defense_project_config`；每个 shell selector unknown/zero-match nonzero；missing cwd off；path swap/Git redirect/PATH/replacement/config race/external env/stale approval 全部零 provider/cache/metrics |
| B-002 flag-off parity | hook orchestration | `bash tests/hooks/test_semantic_defense.sh flag_off_parity`、`bash tests/hooks/test_runtime_rule_signals.sh disable_freezes_pending_backlog`、`bash tests/hooks/test_runtime_rule_signals.sh cross_project_receipt_freeze`、`bash tests/hooks/test_runtime_rule_signals.sh direct_opt_out_acknowledgement`、`bash tests/hooks/test_runtime_rule_signals.sh stable_missing_config_off_identity`、`bash tests/hooks/test_runtime_rule_signals.sh off_absence_mutation_fence`、`bash tests/hooks/test_runtime_rule_signals.sh source_off_live_capacity_drain`、`bash tests/hooks/test_runtime_rule_signals.sh source_off_completed_capacity_handoff`、`bash tests/hooks/test_runtime_rule_signals.sh source_off_retained_ack_history`、`bash tests/hooks/test_runtime_rule_signals.sh acknowledged_success_history_capacity`、`bash tests/hooks/test_runtime_rule_signals.sh off_terminal_proof`、`bash tests/hooks/test_runtime_rule_signals.sh off_request_admin_adoption`、`bash tests/hooks/test_runtime_rule_signals.sh off_request_admin_adoption_atomic_generation`、`bash tests/hooks/test_runtime_rule_signals.sh off_supersession_mode_recovery`、`bash tests/hooks/test_runtime_rule_signals.sh frozen_lag_query_scope`、`bash tests/hooks/test_runtime_rule_signals.sh off_preparing_config_reversal`、`bash tests/hooks/test_runtime_rule_signals.sh off_preparing_new_off_restart`；receipt_delivered/pending off-blocking；retained acknowledged history nonblocking；stable missing-config TOCTOU；adopt-all or terminal-all closure；no age-delete/leak |
| B-003 L1/L2 precedence | policy reducer | `cargo test --manifest-path vibeguard-runtime/Cargo.toml semantic_defense::tests::l1_l2_precedence_total_function -- --exact` |
| B-004 closed inputs | config/protocol schemas | `bash tests/hooks/test_semantic_defense.sh closed_schema_inputs` 与 `bash tests/test_runtime_config_schema.sh` |
| B-005 exact model + sidecar identity | identity/provenance + release contract | `bash tests/hooks/test_semantic_defense.sh model_identity_provenance`、`bash tests/hooks/test_semantic_defense.sh sidecar_artifact_identity_invalidation`、`bash tests/setup/semantic_asset_install_tests.sh provenance`、`bash tests/test_release_workflow.sh semantic_asset_provenance`；每个 script 必须接受 exact named selector、unknown/zero-match nonzero；逐字段 removal/digest/platform/license/protocol mismatch；sidecar byte/version/target/manifest/attestation/revoke 任一变化同时使 approval/eligibility、cache、precision 与 status evidence 失效；每个 same-tag asset 证明 checksum、attestation、dependency metadata、target matrix 与 install provenance |
| B-006 untrusted output | protocol/provider sandbox | `bash tests/hooks/test_semantic_defense.sh untrusted_provider_output`；malformed/extra/injection/tool/oversize fixture 的 mutation canary 不变 |
| B-007 input privacy | request builder/redactor | `bash tests/hooks/test_semantic_defense.sh input_privacy_redaction`；比较 request/log golden 并扫描 secret/path canary |
| B-008 network policy | provider/install boundary | `bash tests/hooks/test_semantic_defense.sh runtime_network_and_fallback` 与 `bash tests/setup/semantic_asset_install_tests.sh explicit_network_only` |
| B-009 bounded execution | provider/cache | `bash tests/hooks/test_semantic_defense.sh timeout_oom_crash_cancel`；逐项断言 child reaped、无后续 request、bounded root clean |
| B-010 latency evidence | synchronous canonical core + installed-hook runners and metrics contract | `bash tests/bench_semantic_core.sh --fixture semantic-defense-core-cold-cache --runs=30 --confirmation-runs=30 --fail-on-regression`、`bash tests/bench_semantic_core.sh --fixture semantic-defense-core-warm-cache --runs=30 --confirmation-runs=30 --fail-on-regression`、`bash tests/bench_hook_latency.sh --fixture semantic-defense-direct-cold-cache --runs=3 --confirmation-runs=3 --fail-on-regression`、`bash tests/bench_hook_latency.sh --fixture semantic-defense-direct-warm-cache --runs=3 --confirmation-runs=3 --fail-on-regression`、`bash tests/bench_hook_latency.sh --fixture semantic-defense-codex-wrapper-cold-cache --runs=3 --confirmation-runs=3 --fail-on-regression`、`bash tests/bench_hook_latency.sh --fixture semantic-defense-codex-wrapper-warm-cache --runs=3 --confirmation-runs=3 --fail-on-regression`、`bash tests/test_hook_perf_contract.sh semantic_defense_fixture_registry`、`bash tests/hooks/test_semantic_defense.sh synchronous_advisory_delivery`、`bash tests/hooks/test_semantic_defense.sh latency_evidence_shape`；所有 runner/script 对 unknown/zero-match fixture/selector nonzero；两个 runner 的 initial/confirmation batch 都逐 sample 记录 timing 外 cold reset-empty 或 warm prewarm-hit evidence，contract selector 对六个 exact IDs、compile-only smoke、budget、CI/result、identity/confirmation 做 exact-count 检查；provider 在同一 response 完成且无后台 delivery |
| B-011 cache identity | cache + app-server owner | `cargo test --manifest-path vibeguard-runtime/Cargo.toml semantic_defense::cache::tests::identity_invalidation_and_isolation -- --exact` 与 `bash tests/hooks/test_semantic_defense.sh trusted_session_identity`；captured values/restart/spoof/conflict/rotation/missing/drift cannot reuse partition |
| B-012 API scope | TypeScript/npm inventory resolver | `bash tests/hooks/test_semantic_defense.sh typescript_npm_inventory_scope`；覆盖 supported/unknown/generated/dynamic/feature/version/missing inventory |
| B-013 production-only API detector | Core handler + GH-700 adapter | `python3 eval/test_semantic_eval.py production_entrypoint_only`；拒绝 test-only/case-ID/path-existence mapping |
| B-014 deterministic W-12 baseline | test-weakening join | `bash tests/unit/test_sec11_review_guards.sh` 与 `bash tests/hooks/test_semantic_defense.sh w12_baseline_identity` |
| B-015 semantic weakening edges | semantic test detector | `bash tests/hooks/test_semantic_defense.sh semantic_test_weakening_edges`；覆盖 parameterized/property/snapshot/tolerance/generated/unsupported |
| B-016 independent evidence | semantic eval schemas | `python3 eval/test_semantic_eval.py independent_evidence_and_reviewers`；覆盖 empty side、digest mismatch、ground-truth-from-output |
| B-017 honest metrics | deterministic scorer + semantic evidence schema | `python3 eval/test_semantic_eval.py metric_arithmetic_and_slices`；覆盖 TP/FP/FN/TN/unclassified/error/zero-denominator，并证明 exact sidecar artifact drift 产生独立 slice、旧 precision 不可复用 |
| B-018 promotion/demotion | eligibility pure function | `cargo test --manifest-path vibeguard-runtime/Cargo.toml semantic_defense::metrics::tests::eligibility_matrix -- --exact` |
| B-019 complete block gate | policy reducer | `cargo test --manifest-path vibeguard-runtime/Cargo.toml semantic_defense::tests::block_requires_every_gate -- --exact` |
| B-020 typed signal | runtime signal + every consumer | `bash tests/hooks/test_runtime_rule_signals.sh schema_identity`、`bash tests/test_observability_schemas.sh observe_output_v1_v2_migration`、`bash tests/test_observability_schemas.sh observe_output_mixed_barrier_lag`、`bash tests/test_observability_schemas.sh observe_output_aggregate_snapshot`、`bash tests/test_observability_schemas.sh observe_output_aggregate_admin_history_generations`、`bash tests/test_observability_schemas.sh project_acknowledged_reader_boundary`、`bash tests/test_observability_schemas.sh project_acknowledged_query_scope`、`bash tests/test_observability_schemas.sh acknowledged_success_history_query_scope`、`bash tests/test_observability_schemas.sh completed_projection_index_retention`、`bash tests/hooks/test_runtime_rule_signals.sh completed_projection_capacity_token_recovery`、`bash tests/hooks/test_runtime_rule_signals.sh administrative_token_lifecycle_recovery`、`bash tests/hooks/test_runtime_rule_signals.sh claim_binding_reclaim_crash`、`bash tests/hooks/test_runtime_rule_signals.sh off_frozen_lag_proof`、`bash tests/hooks/test_runtime_rule_signals.sh quarantine_lag_query_scope`、`bash tests/hooks/test_runtime_rule_signals.sh unreachable_registration_query_scope`、`bash tests/hooks/test_runtime_rule_signals.sh receipt_route_quarantine_rebind`、`bash tests/hooks/test_runtime_rule_signals.sh receipt_delivered_route_quarantine`、`bash tests/hooks/test_runtime_rule_signals.sh quarantine_permission_and_corruption_isolation`、`bash tests/test_gc_scheduled.sh semantic_projection_barrier_gc`、`bash tests/test_gc_scheduled.sh receipt_delivered_retention_handoff`、`bash tests/test_gc_scheduled.sh unacknowledged_receipt_retention`、`bash tests/test_report_false_positive.sh semantic_barrier_identity`、`bash tests/test_health_report.sh semantic_projection_lag`、`bash tests/test_codex_status.sh semantic_barrier_status`、`bash tests/test_codex_status.sh semantic_projection_lag`、`bash tests/test_quality_grader.sh semantic_barrier_projection`、`bash tests/hooks/test_count_active_constraints.sh semantic_barrier_frequency`；`cargo test --manifest-path vibeguard-runtime/Cargo.toml hook_orchestrator_post_edit_history::tests::semantic_pending_aborted_do_not_affect_decision -- --exact`、`cargo test --manifest-path vibeguard-runtime/Cargo.toml hook_orchestrator_post_edit_history::tests::semantic_projection_lag_does_not_affect_decision -- --exact`、`cargo test --manifest-path vibeguard-runtime/Cargo.toml hook_orchestrator_post_edit_history::review_tests::semantic_pending_aborted_do_not_affect_churn_w14_w15_escalation -- --exact`、`cargo test --manifest-path vibeguard-runtime/Cargo.toml hook_orchestrator_post_edit_history::review_tests::semantic_projection_lag_does_not_affect_churn_w14_w15_escalation -- --exact`、`cargo test --manifest-path vibeguard-runtime/Cargo.toml hook_checks_history::tests::semantic_pending_aborted_do_not_count -- --exact`、`cargo test --manifest-path vibeguard-runtime/Cargo.toml hook_checks_history::tests::semantic_projection_lag_does_not_count -- --exact`、`cargo test --manifest-path vibeguard-runtime/Cargo.toml hook_checks::tests::semantic_pending_aborted_do_not_change_fast_decision -- --exact`、`cargo test --manifest-path vibeguard-runtime/Cargo.toml hook_checks::tests::semantic_projection_lag_does_not_change_fast_decision -- --exact`、`cargo test --manifest-path vibeguard-runtime/Cargo.toml log_query::tests::semantic_pending_aborted_do_not_count -- --exact`、`cargo test --manifest-path vibeguard-runtime/Cargo.toml log_query::tests::semantic_projection_lag_does_not_count -- --exact`、`cargo test --manifest-path vibeguard-runtime/Cargo.toml --test cli_hook_checks post_edit_history_ignores_unfinalized_semantic_rows -- --exact`、`cargo test --manifest-path vibeguard-runtime/Cargo.toml --test cli_log_commands semantic_queries_ignore_unfinalized_rows -- --exact`；all lag zero use |
| B-021 baseline/delta ownership | rule registry | `bash tests/hooks/test_runtime_rule_signals.sh baseline_delta_registry`；reason-only delta 不计数 |
| B-022 two distinct rules | W-rule corpus | `bash tests/hooks/test_runtime_rule_signals.sh two_distinct_rule_deltas`；覆盖两套独立正负/错误/history/retry 与 duplicate signal negative |
| B-023 W-02 evidence | W-02 reducer | `bash tests/hooks/test_runtime_rule_signals.sh w02_hypothesis_attempt_evidence` |
| B-024 W-12 attribution | W-12 reducer | `bash tests/hooks/test_runtime_rule_signals.sh w12_signal_attribution`；三种 signal kind 与去重 precedence |
| B-025 corrupt history | history reader | `bash tests/hooks/test_runtime_rule_signals.sh corrupt_and_cross_scope_history` |
| B-026 W state machine | runtime signal module | `cargo test --manifest-path vibeguard-runtime/Cargo.toml semantic_defense::runtime_signal::tests::transition_replay_concurrency_matrix -- --exact` |
| B-027 fail-visible group commit | project WAL + reconciler | `bash tests/hooks/test_runtime_rule_signals.sh projection_write_failures_preserve_l1`、`bash tests/hooks/test_runtime_rule_signals.sh bounded_reconciliation_backlog`、`bash tests/hooks/test_runtime_rule_signals.sh atomic_recovery_io_floor`、`bash tests/hooks/test_runtime_rule_signals.sh atomic_recovery_time_floor`、`bash tests/hooks/test_runtime_rule_signals.sh blocking_recovery_io_cancel`、`bash tests/hooks/test_runtime_rule_signals.sh bounded_project_lock`、`bash tests/hooks/test_runtime_rule_signals.sh pre_barrier_global_registration`、`bash tests/hooks/test_runtime_rule_signals.sh live_registration_query_scope`、`bash tests/hooks/test_runtime_rule_signals.sh unreachable_registration_replicated_recovery`、`bash tests/hooks/test_runtime_rule_signals.sh unreachable_registration_full_reconstruction`、`bash tests/hooks/test_runtime_rule_signals.sh concurrent_global_registration`、`bash tests/hooks/test_runtime_rule_signals.sh orphan_registration_recovery`、`bash tests/hooks/test_runtime_rule_signals.sh pre_barrier_unreachable_isolation`、`bash tests/hooks/test_runtime_rule_signals.sh off_orphan_slot_reclamation`、`bash tests/hooks/test_runtime_rule_signals.sh project_recovery_wal_capacity`、`bash tests/hooks/test_runtime_rule_signals.sh project_recovery_wal_compaction_recovery`、`bash tests/hooks/test_runtime_rule_signals.sh canonical_journal_append_lease`、`bash tests/test_gc_logs_rotation.sh semantic_recovery_pins`、`bash tests/test_gc_logs_concurrent.sh semantic_journal_watermark_concurrency`；每个 script 必须对 unknown/zero-match selector nonzero；WAL entry/byte/segment full与 checkpoint/pin/crash exact；legacy append cannot steal expected offset；GC honors pins/watermarks；byte/time floor-1 zero writes；hung exact floor includes teardown/reap/verify；pre-barrier + ready off capacity reclaimed；unreachable ref retains body and query-window inclusion/exclusion |
| B-028 single authority + projection | journal + global sequencer/outbox | `bash tests/hooks/test_runtime_rule_signals.sh one_canonical_projection`、`bash tests/hooks/test_runtime_rule_signals.sh derived_global_projection_recovery`、`bash tests/hooks/test_runtime_rule_signals.sh cross_project_offset_reservation`、`bash tests/hooks/test_runtime_rule_signals.sh derived_log_capacity_retention`、`bash tests/hooks/test_runtime_rule_signals.sh derived_log_compaction_crash_recovery`、`bash tests/hooks/test_runtime_rule_signals.sh derived_log_compaction_scratch_entitlement`、`bash tests/hooks/test_runtime_rule_signals.sh reservation_outbox_entitlement_recovery`、`bash tests/hooks/test_runtime_rule_signals.sh reservation_outbox_query_scope`、`bash tests/hooks/test_runtime_rule_signals.sh global_administrative_plane_capacity`、`bash tests/hooks/test_runtime_rule_signals.sh acknowledged_success_history_capacity`、`bash tests/hooks/test_runtime_rule_signals.sh keyed_receipt_slots`、`bash tests/hooks/test_runtime_rule_signals.sh keyed_receipt_slot_capacity_recovery`、`bash tests/hooks/test_runtime_rule_signals.sh keyed_receipt_slot_retirement_recovery`、`bash tests/hooks/test_runtime_rule_signals.sh project_acknowledged_slot_retirement_identity`、`bash tests/hooks/test_runtime_rule_signals.sh off_receipt_slot_retirement_identity`、`bash tests/hooks/test_runtime_rule_signals.sh receipt_directory_fsync_recovery`、`bash tests/hooks/test_runtime_rule_signals.sh receipt_project_lock_ownership`、`bash tests/hooks/test_runtime_rule_signals.sh receipt_delivered_route_locator_recovery`、`bash tests/hooks/test_runtime_rule_signals.sh source_off_receipt_defer`、`bash tests/hooks/test_runtime_rule_signals.sh claim_before_reservation_recovery`、`bash tests/hooks/test_runtime_rule_signals.sh active_claim_absent_reservation_recovery`、`bash tests/hooks/test_runtime_rule_signals.sh reservation_seed_offset_binding`、`bash tests/hooks/test_runtime_rule_signals.sh claim_binding_reclaim_crash`、`bash tests/hooks/test_runtime_rule_signals.sh source_off_outbox_drain`、`bash tests/hooks/test_runtime_rule_signals.sh receipt_route_quarantine_rebind`、`bash tests/hooks/test_runtime_rule_signals.sh receipt_delivered_route_quarantine`、`bash tests/hooks/test_runtime_rule_signals.sh quarantine_lag_query_scope`、`bash tests/hooks/test_runtime_rule_signals.sh quarantine_permission_and_corruption_isolation`、`bash tests/hooks/test_runtime_rule_signals.sh quarantine_alternate_root_isolation`、`bash tests/hooks/test_runtime_rule_signals.sh quarantine_primary_alternate_handoff_crash`、`bash tests/hooks/test_runtime_rule_signals.sh quarantine_rebind_dual_capacity`、`bash tests/hooks/test_runtime_rule_signals.sh quarantine_rebind_route_replacement`、`bash tests/hooks/test_runtime_rule_signals.sh quarantine_rebind_replacement_staging_capacity`、`bash tests/hooks/test_runtime_rule_signals.sh quarantine_retirement_before_token_reuse`、`bash tests/hooks/test_runtime_rule_signals.sh quarantine_retirement_pending_recovery`、`bash tests/hooks/test_runtime_rule_signals.sh deleted_source_runtime_terminalization`、`bash tests/hooks/test_runtime_rule_signals.sh deleted_source_object_identity_rebind`、`bash tests/hooks/test_runtime_rule_signals.sh projection_done_global_ack_recovery`、`bash tests/hooks/test_runtime_rule_signals.sh quarantine_ack_pending_transfer`、`bash tests/hooks/test_runtime_rule_signals.sh administrative_token_lifecycle_recovery`、`bash tests/hooks/test_runtime_rule_signals.sh global_admin_entitlement_release_recovery`；每个 selector unknown/zero-match nonzero；live-full compaction uses independent scratch；project ack/off refs preserve complete slot entitlement/key/digest/locator through crash-safe retirement；binding/ack/quarantine/deletion crash exact；worker no marker |
| B-029 candidate identity | Learn schema/analyzer | `bash tests/test_workflow_contracts.sh semantic_learn_contract` 与 `bash tests/test_learn_adoption.sh semantic_candidate_identity`；该 script 必须接受 exact named selector、unknown/zero-match nonzero；semantic-defense signal/typed source 的 valid fixture 与 invalid classification/action/path 全部固定，multi-session replay 后 ID/count/window/privacy 精确相等 |
| B-030 deterministic Learn core | Learn analyzer/model adapter | `bash tests/test_learn_adoption.sh semantic_candidate_without_model`；provider disabled/crash 时 identity/count/state 不变 |
| B-031 human adoption gate | Learn adoption | `bash tests/test_learn_adoption.sh semantic_candidate_human_gate`；preview read-only，仅 explicit adopt/skip/snooze 变更 |
| B-032 outcome verification | Learn outcome evaluator | `bash tests/test_learn_adoption.sh semantic_candidate_outcomes`；fresh/absent/regressed 与 raw-source export canary |
| B-033 GH-700 boundary | production mapping contract | `python3 eval/test_semantic_eval.py gh700_core_mapping_boundary`；拒绝 headline/paired/aggregate precision 输入 |
| B-034 GH-702 boundary | capability/policy contract | `bash tests/hooks/test_semantic_defense.sh gh702_sealed_core_boundary`；携带 executable/model/provider 或 unapproved policy 必须失败 |
| B-035 truthful rendering | doctor/status/observe/stats/health/readers | B-020 consumer commands plus `bash tests/test_setup_check.sh semantic_projection_rendering`、`bash tests/test_hook_status.sh semantic_projection_rendering`、`bash tests/hooks/test_semantic_defense.sh status_rendering_and_redaction`、`bash tests/test_observe.sh semantic_barrier_projection`、`bash tests/test_stats.sh semantic_barrier_projection`；`cargo test --manifest-path vibeguard-runtime/Cargo.toml hook_orchestrator_learn::tests::recent_log_error_is_fail_visible -- --exact`、`cargo test --manifest-path vibeguard-runtime/Cargo.toml hook_orchestrator_learn::tests::metrics_error_is_fail_visible -- --exact`、`cargo test --manifest-path vibeguard-runtime/Cargo.toml hook_orchestrator_learn::tests::projection_lag_has_zero_suggestion -- --exact`；project canonical barrier vs project history `projection_done` vs global `project_acknowledged`；v1 legacy；mixed lag empty；all formats agree |
| B-036 cleanup/rollback | provider/cache/hook lifecycle | `bash tests/hooks/test_semantic_defense.sh cleanup_interrupt_and_l1_rollback`；success/error/timeout/SIGINT matrix |
| B-037 completion-backed post-edit | app-server lifecycle | `bash tests/hooks/test_semantic_defense.sh codex_post_edit_requires_completion`、`bash tests/hooks/test_semantic_defense.sh codex_thread_cap_pending_backpressure`；每个 selector unknown/zero-match nonzero；pre-completion zero L2；accepted patch exactly once；cap+1/all-pending backpressure before mutation；missing state visible；duplicate/no-callback safe |

## ResourceLedger mandatory matrix

以下是 B-027/B-028 的 mandatory exact supplement，不得由上表其它宽泛 crash/capacity suite 代替：

- B-027：`bash tests/hooks/test_runtime_rule_signals.sh wal_compaction_capacity_transfer`、
  `bash tests/hooks/test_runtime_rule_signals.sh allocator_wal_capacity_contract`、
  `bash tests/test_gc_logs_rotation.sh canonical_journal_gc_scratch_capacity`、
  `bash tests/hooks/test_runtime_rule_signals.sh project_wal_pre_provider_terminal_closure`、
  `bash tests/test_gc_logs_concurrent.sh canonical_journal_l1_entitlement_capacity_one`；
- B-028：`bash tests/hooks/test_runtime_rule_signals.sh capacity_ledger_model_check`、
  `bash tests/hooks/test_runtime_rule_signals.sh reservation_bundle_terminal_closure`、
  `bash tests/hooks/test_runtime_rule_signals.sh success_history_gc_release_receipt`、
  `bash tests/hooks/test_runtime_rule_signals.sh derived_log_compaction_capacity_transfer`、
  `bash tests/hooks/test_runtime_rule_signals.sh admin_adoption_capacity_preflight`、
  `bash tests/hooks/test_runtime_rule_signals.sh compaction_role_exchange_capacity_one`、
  `bash tests/hooks/test_runtime_rule_signals.sh admin_adoption_scratch_capacity_one`、
  `bash tests/hooks/test_runtime_rule_signals.sh resource_kind_edge_coverage`。

每个 owner script 必须接受 exact named selector，unknown/zero-match nonzero。`capacity_ledger_model_check`
使用 capacity=1 与 2、两个 source、两个 reservation，穷举 reserve/commit/cancel/abort/ack/off/rebind/
discard/expiry/GC/compaction/crash/replay；每个 reachable committed state 检查 closed resource-kind inventory、
`sum(free,reserved,live,transfer/retirement states)=maximum`、single owner、无 early credit、bundle terminal
totality、receipt replay idempotence与至少一条 bounded forward edge。`reservation_bundle_terminal_closure`
逐 item 覆盖 completed/outbox/quarantine/history/admin/slot/derived 等 cancel/abort，以及 project-ack、
off-receipt、rebind、terminal discard，mutation 分别删除任一 cancel token、owner 或 resource kind，均须在
root commit 前 nonzero。`resource_kind_edge_coverage` 枚举所有声明 edge，mutation 增加 scratch→live、
kind rewrite、无 absence proof 的 reserved direct release 或 unknown edge 均须在 root commit 前 nonzero。

compaction selectors 与 canonical-journal selector必须对 project WAL、derived log、journal 分别在
scratch reserve、stage write/fsync、manifest receipt、publish CAS、每个 old unlink + directory fsync、final
exchange receipt 的 before/after 注入 crash/lost response；publish 后到 final receipt 前断言 old live + new
scratch 同时计费，final 后 old-live token kind 不变且 retarget new object、scratch kind 不变且 released；连续
compaction 两次仍只能走该 exchange。mutation 把 kind 改写或 live release 提前到 tombstone/dir-fsync 前必须失败。history selector 删除 quota item
或 release receipt 必须失败；adoption selector 使用 manifest maximum、`floor - 1` 与 concurrent set drift，
并在 live admin capacity=1/full 下证明 preprovisioned fixed A/B scratch 仍可完成 exact-max adoption。
`project_wal_pre_provider_terminal_closure` 对 full WAL 断言 cache/provider/validator/reducer call count=0，并
覆盖 cache hit/miss、provider/validator/reducer error/timeout/cancel/crash 的 bundle totality；journal L1 selector
覆盖 capacity=1、不可借用 floor、pin/full bounded backpressure、eventual-unpin progress与 permanent failure
fail-visible no-overrun。allocator selector证明所谓 WAL
只有预分配 fixed A/B root、无 append/GC 第三容量平面。

所有十三个 selector 还必须执行 capacity=1/2、两个 source/reservation 与 `N >> capacity` deterministic
long-run：正常完成、重复 cancel/abort、ack+history expiry、off/adopt/discard 与至少连续两次 compaction 后，ledger 使用量回到 exact expected baseline，
storage physical maximum 不增长，下一次 admission 在 capacity 可用时成功；token、entries、bytes、segments、
per-source quota 任一泄漏、双 credit、ownerless state 或永久 earliest-reservation/adopt-all stall 都 nonzero。
该 matrix 显式覆盖四个新增 P1、project-ack/off-receipt slot retirement、project WAL/GC/append lease 与
derived-log counterpart；原有 focused selectors 仍保留，不能由 model check 反向替代。

## 数据流

```text
approved config/policy + verified semantic asset
  → eligible runtime identity

completed host event + project/session/change
  → L1 deterministic result
  → approved minimal semantic input + dependency inventory
  → input-envelope digest
  → project-WAL semantic-attempt bundle + exact entitlement/root receipt
  → cache lookup
  → bounded local provider
  → closed semantic result
  → deterministic detector/W-rule reducer
  → candidate hook decision
  → project WAL prepared intent + queue-metadata commit (fsync)
  → project durable typed pending event at expected offset (fsync)
  → WAL journaled transition (fsync)
  → one durable group commit by event/group digest
       ├─ staged/provisional latency/outcome metrics + receipt
       ├─ staged/provisional exact-identity precision + receipt
       └─ staged/provisional Learn defense_gap + receipt
  → inert bounded global source registration (fsync; barrier-gated)
  → project all_activated barrier (ordered stage/activation receipt digests)
       ├─ release barrier-joined hook decision/status
       ├─ expose Learn candidate → explicit human adopt → later verify/regressed
       └─ any global worker verifies barrier + eligibility epoch
              → serialized projection + exact-route durable receipt outbox
              → keyed slot + global receipt_delivered lag (reclaim; quarantine token retained)
              → source projection_done → global project_acknowledged, or quarantine lag
```

外部调用在 Recommended path 中仅存在于显式 semantic asset install/update；runtime 与
Learn 默认零网络。raw source/prompt/model output 不持久化。cache、event、precision 和
Learn state 的位置、retention 与 delete/export 仍由 H-004/H-005/H-012/H-014/H-016/
H-020 批准。

## 测试计划

- [ ] Unit tests: closed schemas、identity joins、protocol parser、precedence、inventory、
      semantic weakening、W state machine、cache、scorer、eligibility 与 redaction。
- [ ] Integration tests: Claude/Codex production hooks、real sidecar failure matrix、structured
      projection、precision/Learn、planned **tests/setup/semantic_asset_install_tests.sh** 的
      install/update/revoke、`tests/test_setup.sh`、payload/no-clone 和 interruption。
- [ ] Regression tests: 现有 W-12/W-16/W-02/W-13/W-14/W-15、runtime config/event schema、
      project opt-in schema/parser/isolation、precision tracker、Learn schema/adoption、
      observability legacy/current fixtures、release asset checksums/attestations/metadata、
      payload、hook manifest、两 crate 独立 ≥80% line coverage；closed critical inventory
      覆盖 final reducer/mod、inventory/adapters、test weakening、runtime signal、metrics、Learn reader、
      Git/project config/context/orchestrator/event schema、cache/journal recovery 与 sidecar
      protocol/sandbox 的所有 decision/isolation/durability 分支 100% line + branch
      coverage。独立合同
      必须对 inventory/mandatory set 任一方向差异、每个 critical file 的 missing/empty/unknown
      exact `owner_suites`、suite 反向零 owner、selector zero-match/rename drift、aggregate masking、
      path-normalization 和每个关键文件低于 100% 失败；以及 docs contracts。
- [ ] Performance tests: cold/warm core 和 installed hook P50/P95/P99/max、large diff/
      inventory、parallel sessions、timeout/cancel；cold/warm L2 必须分别通过
      planned **tests/bench_semantic_core.sh** core runner、`tests/bench_hook_latency.sh` installed
      runner 和 `tests/test_hook_perf_contract.sh` contract，不得静默调整现有 SLA。
- [ ] Manual security review: model/license/provenance、asset attestation、process sandbox、
      source/secret privacy、network/API key、prompt injection、feedback/export 与 release
      rollback。
- [ ] Required broad verification after implementation:
      `cargo check --manifest-path vibeguard-runtime/Cargo.toml`;
      `cargo test --manifest-path vibeguard-runtime/Cargo.toml`;
      `cargo check --manifest-path semantic-sidecar/Cargo.toml`;
      `cargo test --manifest-path semantic-sidecar/Cargo.toml`;
      `bash tests/test_u22_coverage.sh`;
      `bash scripts/ci/self-application/check-u22-coverage.sh`;
      `bash scripts/ci/validate-hooks.sh`;
      `bash scripts/ci/validate-hooks-manifest.sh`;
      `bash tests/setup/semantic_asset_install_tests.sh`;
      `bash tests/test_setup.sh`;
      `bash tests/test_setup_check.sh`;
      `bash tests/test_hook_status.sh`;
      `bash tests/test_observability_schemas.sh`;
      `bash tests/test_release_workflow.sh`;
      `bash tests/test_workflow_contracts.sh`;
      planned **bash tests/bench_semantic_core.sh --runs=30 --confirmation-runs=30 --fail-on-regression**;
      `bash tests/bench_hook_latency.sh --runs=3 --confirmation-runs=3 --fail-on-regression`;
      `bash tests/test_hook_perf_contract.sh`;
      `bash tests/test_manifest_contract.sh`;
      `bash tests/test_workflow_contracts.sh`;
      `bash scripts/local-contract-check.sh --quick`.
