# GH-702 Anchor Identity And Verification Contract

## Status and ownership

Draft supporting contract for GH-702. This annex owns the exhaustive anchor/H-010/atomic identity-pointer
union and semantic negative corpus. `h010_decision_body.anchor_identity_verification_contract_digest`
must equal the digest of this exact file; no other GH-702 document may redefine a shorter pointer set.
The checked-in positive/golden vectors and independent expected constants are
[`anchor_contract_vectors.json`](anchor_contract_vectors.json) and
[`verify_anchor_contract.py`](verify_anchor_contract.py); run `bash tests/test_gh702_anchor_contract.sh`.
The verifier parses this annex and recursively compiles the atomic Draft semantic schemas changed by this
PR, generates embedded leaves, and compares the result to an independently pinned count and digest before
running per-leaf omission/type/alias negatives. It does not count object roots as leaves or claim the
planned complete-stage public-schema registry is already implemented.
`fixture_sha256_binding_v1` is a deterministic test-only binding primitive for mutation coverage; it is not
an H-010 production signature algorithm and every production consumer must reject that literal.

## Exhaustive identity registry

schema registry 必须导出下列 exhaustive identity field sets，且每项使用 schema 的 canonical exact
field name/path；consumer 不得将 alias 归一化成 canonical field。fixture generator 以
`one_field_at_a_time` 对每个 field 执行 change/delete/cross-record-swap/alias mutation，并证明所有
consumer nonzero；新增 identity field 却未进入 registry 本身也是 contract failure。result body 的真实字段
只叫 `decision`；任何替代名称都是 unknown alias，必须拒绝：
Registry entries are unique RFC 6901 schema JSON Pointers；array element schemas use the literal
`items` node, never an instance index or wildcard. Duplicate strings are invalid, and every pointer must resolve to
one closed leaf—not an object/array parent:
```text
anchor_identity_schema_pointers = [
  "/anchor/backend_identity/backend_kind", "/anchor/backend_identity/backend_instance_id",
  "/anchor/backend_identity/device_key_digest", "/anchor/backend_identity/protocol_version",
  "/anchor/root_identity/root_id", "/anchor/root_identity/root_schema_version",
  "/anchor/root_identity/principal_id", "/anchor/root_identity/core_installation_id",
  "/anchor/per_leaf_authority_body/schema_version", "/anchor/per_leaf_authority_body/root_identity/root_id",
  "/anchor/per_leaf_authority_body/root_identity/root_schema_version", "/anchor/per_leaf_authority_body/root_identity/principal_id",
  "/anchor/per_leaf_authority_body/root_identity/core_installation_id", "/anchor/per_leaf_authority_body/leaf_identity/leaf_kind",
  "/anchor/per_leaf_authority_body/leaf_identity/installation_scope_id", "/anchor/per_leaf_authority_id",
  "/anchor/from_leaf_state/per_leaf_authority_id", "/anchor/from_leaf_state/leaf_counter",
  "/anchor/from_leaf_state/leaf_value_digest", "/anchor/from_leaf_proof_digest",
  "/anchor/target_leaf_body/schema_version", "/anchor/target_leaf_body/target_leaf_counter",
  "/anchor/target_leaf_body/target_leaf_value_digest", "/anchor/target_leaf_digest",
  "/anchor/post_cas_backend_attestation_digest", "/anchor/anchor_operation_id", "/anchor/operation",
  "/anchor/authorized_operation_digest", "/anchor/target_authorization_digest",
  "/anchor/authorizer_key_id", "/anchor/authorization_nonce", "/anchor/authorization_expires_at",
  "/anchor/lock_fence_identity", "/anchor/mirror_generation_id", "/anchor/mirror_file_digest",
  "/anchor/previous_mirror_generation_id", "/anchor/previous_mirror_file_digest",
  "/anchor/prepared_phase_digest", "/anchor/external_advanced_phase_digest",
  "/anchor/selected_phase_digest", "/anchor/barrier_complete_phase_digest", "/anchor/barrier_id"
]
h010_identity_schema_pointers = [
  "/global_platform_registry_envelope/digest_domain", "/global_platform_registry_envelope/schema_version", "/global_platform_registry_envelope/global_platform_registry_digest",
  "/global_platform_registry_envelope/registry_body/registry_generation", "/global_platform_registry_envelope/registry_body/previous_registry_digest",
  "/global_platform_registry_envelope/registry_body/entries/items/platform_id", "/global_platform_registry_envelope/registry_body/entries/items/platform_profile_family_id",
  "/global_platform_registry_envelope/registry_body/entries/items/global_profile_generation", "/global_platform_registry_envelope/registry_body/entries/items/authority_mode",
  "/global_platform_registry_envelope/registry_body/entries/items/transition_policy", "/global_platform_registry_envelope/signatures/items/signer_key_id",
  "/global_platform_registry_envelope/signatures/items/signature_algorithm", "/global_platform_registry_envelope/signatures/items/signature",
  "/launch_authority_profile_body/schema_version", "/launch_authority_profile_digest", "/launch_authority_profile_body/launch_authority_profile_id", "/launch_authority_profile_body/launch_authority_backend_identity/backend_kind",
  "/launch_authority_profile_body/launch_authority_backend_identity/backend_instance_id", "/launch_authority_profile_body/launch_authority_backend_identity/device_key_digest",
  "/launch_authority_profile_body/launch_authority_backend_identity/protocol_version", "/launch_authority_profile_body/trusted_signers/items/signer_key_id",
  "/launch_authority_profile_body/trusted_signers/items/signature_algorithm", "/launch_authority_profile_body/trusted_signers/items/verification_key_digest",
  "/launch_authority_profile_body/signature_quorum", "/launch_authority_profile_body/max_attestation_validity_ms", "/launch_authority_profile_body/resume_token_min_entropy_bits", "/launch_authority_profile_body/max_suspended_lifetime_ms",
  "/launch_authority_profile_body/freshness_protocol", "/launch_authority_profile_body/resume_protocol",
  "/h010_decision_envelope/digest_domain", "/h010_decision_envelope/schema_version", "/h010_decision_envelope/h010_decision_artifact_digest", "/h010_decision_envelope/h010_decision_body/product_spec_digest", "/h010_decision_envelope/h010_decision_body/tech_spec_digest",
  "/h010_decision_envelope/h010_decision_body/anchor_contract_digest", "/h010_decision_envelope/h010_decision_body/atomic_launch_machine_contract_digest", "/h010_decision_envelope/h010_decision_body/anchor_identity_verification_contract_digest", "/h010_decision_envelope/h010_decision_body/approved_by/items",
  "/h010_decision_envelope/h010_decision_body/approved_at", "/h010_decision_envelope/h010_decision_body/expires_at",
  "/h010_decision_envelope/h010_decision_body/global_platform_registry_digest", "/h010_decision_envelope/h010_decision_body/platform_profiles/items/platform_id",
  "/h010_decision_envelope/h010_decision_body/platform_profiles/items/platform_profile_family_id", "/h010_decision_envelope/h010_decision_body/platform_profiles/items/global_profile_generation",
  "/h010_decision_envelope/h010_decision_body/platform_profiles/items/global_platform_registry_entry_digest", "/h010_decision_envelope/h010_decision_body/platform_profiles/items/authority_mode",
  "/h010_decision_envelope/h010_decision_body/platform_profiles/items/anchor_profile/backend_profile_id", "/h010_decision_envelope/h010_decision_body/platform_profiles/items/anchor_profile/service_profile_id",
  "/h010_decision_envelope/h010_decision_body/platform_profiles/items/anchor_profile/launch_authority_profile_digest", "/h010_decision_envelope/h010_decision_body/platform_profiles/items/anchor_profile/launch_policy_digest",
  "/h010_decision_envelope/h010_decision_body/platform_profiles/items/anchor_profile/per_leaf_authority_mode", "/h010_decision_envelope/h010_decision_body/platform_profiles/items/anchor_profile/target_authorizer_profile_id",
  "/h010_decision_envelope/h010_decision_body/platform_profiles/items/anchor_profile/authorizer_key_id", "/h010_decision_envelope/h010_decision_body/platform_profiles/items/anchor_profile/provision_ipc_lifecycle_decisions",
  "/h010_decision_envelope/h010_decision_body/platform_profiles/items/no_block_profile/core_release_digest", "/h010_decision_envelope/h010_decision_body/platform_profiles/items/no_block_profile/release_pin_digest",
  "/h010_decision_envelope/h010_decision_body/platform_profiles/items/no_block_profile/maximum_effective_decision", "/h010_decision_envelope/h010_decision_body/platform_profiles/items/no_block_profile/transition_policy",
  "/h010_decision_envelope/h010_decision_body/platform_profiles/items/anchor_profile/fixture_budgets/items/fixture_id", "/h010_decision_envelope/h010_decision_body/platform_profiles/items/anchor_profile/fixture_budgets/items/host_kind",
  "/h010_decision_envelope/h010_decision_body/platform_profiles/items/anchor_profile/fixture_budgets/items/installed_wrapper_path", "/h010_decision_envelope/h010_decision_body/platform_profiles/items/anchor_profile/fixture_budgets/items/workload_schedule_digest",
  "/h010_decision_envelope/h010_decision_body/platform_profiles/items/anchor_profile/fixture_budgets/items/runs", "/h010_decision_envelope/h010_decision_body/platform_profiles/items/anchor_profile/fixture_budgets/items/hook_e2e_p50_ms",
  "/h010_decision_envelope/h010_decision_body/platform_profiles/items/anchor_profile/fixture_budgets/items/hook_e2e_p95_ms", "/h010_decision_envelope/h010_decision_body/platform_profiles/items/anchor_profile/fixture_budgets/items/hook_e2e_p99_ms",
  "/h010_decision_envelope/h010_decision_body/platform_profiles/items/anchor_profile/fixture_budgets/items/hook_e2e_max_ms", "/h010_decision_envelope/h010_decision_body/platform_profiles/items/anchor_profile/fixture_budgets/items/cas_timeout_ms",
  "/h010_decision_envelope/h010_decision_body/platform_profiles/items/anchor_profile/fixture_budgets/items/ipc_timeout_ms", "/h010_decision_envelope/h010_decision_body/platform_profiles/items/anchor_profile/fixture_budgets/items/queue_wait_budget_ms",
  "/h010_decision_envelope/h010_decision_body/platform_profiles/items/anchor_profile/fixture_budgets/items/contention_total_budget_ms", "/h010_decision_envelope/h010_decision_body/platform_profiles/items/anchor_profile/fixture_budgets/items/contention_retry_limit_count",
  "/h010_decision_envelope/h010_decision_body/platform_profiles/items/no_block_profile/fixture_budgets/items/fixture_id", "/h010_decision_envelope/h010_decision_body/platform_profiles/items/no_block_profile/fixture_budgets/items/host_kind",
  "/h010_decision_envelope/h010_decision_body/platform_profiles/items/no_block_profile/fixture_budgets/items/installed_wrapper_path", "/h010_decision_envelope/h010_decision_body/platform_profiles/items/no_block_profile/fixture_budgets/items/workload_schedule_digest",
  "/h010_decision_envelope/h010_decision_body/platform_profiles/items/no_block_profile/fixture_budgets/items/runs", "/h010_decision_envelope/h010_decision_body/platform_profiles/items/no_block_profile/fixture_budgets/items/hook_e2e_p50_ms",
  "/h010_decision_envelope/h010_decision_body/platform_profiles/items/no_block_profile/fixture_budgets/items/hook_e2e_p95_ms", "/h010_decision_envelope/h010_decision_body/platform_profiles/items/no_block_profile/fixture_budgets/items/hook_e2e_p99_ms",
  "/h010_decision_envelope/h010_decision_body/platform_profiles/items/no_block_profile/fixture_budgets/items/hook_e2e_max_ms", "/h010_decision_envelope/signatures/items/signer_key_id",
  "/h010_decision_envelope/signatures/items/signature_algorithm", "/h010_decision_envelope/signatures/items/signature",
  "/perf/anchor/authority_base_body/approved_h010_schema_version", "/perf/anchor/authority_base_body/h010_decision_artifact_digest", "/perf/anchor/authority_base_body/evaluation_policy_digest", "/perf/anchor/authority_base_body/authoritative_policy_generation", "/perf/anchor/authority_base_body/policy_validity_evidence_digest",
  "/perf/anchor/authority_base_body/platform_launch_floor_attestation_digest", "/perf/anchor/authority_base_body/platform_launch_current_state_digest", "/perf/anchor/authority_base_body/current_platform_generation", "/perf/anchor/authority_base_body/backend_state_counter", "/perf/anchor/authority_base_body/monotonic_launch_floor", "/perf/anchor/authority_base_body/allowed_core_min_version", "/perf/anchor/authority_base_body/allowed_host_adapter_min_version", "/perf/anchor/authority_base_digest",
  "/perf/anchor/budget_body/authority_base_digest", "/perf/anchor/budget_body/fixture_id", "/perf/anchor/budget_body/platform_id", "/perf/anchor/budget_body/backend_profile_id", "/perf/anchor/budget_body/host_kind", "/perf/anchor/budget_body/installed_wrapper_path", "/perf/anchor/budget_body/workload_schedule_digest", "/perf/anchor/budget_body/runs", "/perf/anchor/budget_body/hook_e2e_p50_ms", "/perf/anchor/budget_body/hook_e2e_p95_ms", "/perf/anchor/budget_body/hook_e2e_p99_ms", "/perf/anchor/budget_body/hook_e2e_max_ms", "/perf/anchor/budget_body/cas_timeout_ms", "/perf/anchor/budget_body/ipc_timeout_ms", "/perf/anchor/budget_body/queue_wait_budget_ms", "/perf/anchor/budget_body/contention_total_budget_ms", "/perf/anchor/budget_body/contention_retry_limit_count", "/perf/anchor/budget_digest",
  "/perf/anchor/decision_body/authority_base_digest", "/perf/anchor/decision_body/budget_digest", "/perf/anchor/decision_body/fixture_id", "/perf/anchor/decision_body/anchor_enabled", "/perf/anchor/decision_body/surface", "/perf/anchor/decision_body/confirmation_policy", "/perf/anchor/decision_artifact_digest",
  "/perf/anchor/batch_body/phase", "/perf/anchor/batch_body/authority_base_digest", "/perf/anchor/batch_body/budget_digest", "/perf/anchor/batch_body/decision_artifact_digest", "/perf/anchor/batch_body/fixture_id", "/perf/anchor/batch_body/platform_id", "/perf/anchor/batch_body/backend_profile_id", "/perf/anchor/batch_body/host_kind", "/perf/anchor/batch_body/installed_wrapper_path", "/perf/anchor/batch_body/anchor_enabled", "/perf/anchor/batch_body/surface", "/perf/anchor/batch_body/runs", "/perf/anchor/batch_body/workload_schedule_digest", "/perf/anchor/batch_body/successor_baseline/from_leaf_state/per_leaf_authority_id", "/perf/anchor/batch_body/successor_baseline/from_leaf_state/leaf_counter", "/perf/anchor/batch_body/successor_baseline/from_leaf_state/leaf_value_digest", "/perf/anchor/batch_body/successor_baseline/target_leaf_counter", "/perf/anchor/batch_body/successor_baseline/target_leaf_digest", "/perf/anchor/batch_digest",
  "/perf/anchor/result_body/authority_base_body/approved_h010_schema_version", "/perf/anchor/result_body/authority_base_body/h010_decision_artifact_digest", "/perf/anchor/result_body/authority_base_body/evaluation_policy_digest", "/perf/anchor/result_body/authority_base_body/authoritative_policy_generation", "/perf/anchor/result_body/authority_base_body/policy_validity_evidence_digest", "/perf/anchor/result_body/authority_base_body/platform_launch_floor_attestation_digest", "/perf/anchor/result_body/authority_base_body/platform_launch_current_state_digest", "/perf/anchor/result_body/authority_base_body/current_platform_generation", "/perf/anchor/result_body/authority_base_body/backend_state_counter", "/perf/anchor/result_body/authority_base_body/monotonic_launch_floor", "/perf/anchor/result_body/authority_base_body/allowed_core_min_version", "/perf/anchor/result_body/authority_base_body/allowed_host_adapter_min_version", "/perf/anchor/result_body/authority_base_digest",
  "/perf/anchor/result_body/budget_body/authority_base_digest", "/perf/anchor/result_body/budget_body/fixture_id", "/perf/anchor/result_body/budget_body/platform_id", "/perf/anchor/result_body/budget_body/backend_profile_id", "/perf/anchor/result_body/budget_body/host_kind", "/perf/anchor/result_body/budget_body/installed_wrapper_path", "/perf/anchor/result_body/budget_body/workload_schedule_digest", "/perf/anchor/result_body/budget_body/runs", "/perf/anchor/result_body/budget_body/hook_e2e_p50_ms", "/perf/anchor/result_body/budget_body/hook_e2e_p95_ms", "/perf/anchor/result_body/budget_body/hook_e2e_p99_ms", "/perf/anchor/result_body/budget_body/hook_e2e_max_ms", "/perf/anchor/result_body/budget_body/cas_timeout_ms", "/perf/anchor/result_body/budget_body/ipc_timeout_ms", "/perf/anchor/result_body/budget_body/queue_wait_budget_ms", "/perf/anchor/result_body/budget_body/contention_total_budget_ms", "/perf/anchor/result_body/budget_body/contention_retry_limit_count", "/perf/anchor/result_body/budget_digest",
  "/perf/anchor/result_body/decision_body/authority_base_digest", "/perf/anchor/result_body/decision_body/budget_digest", "/perf/anchor/result_body/decision_body/fixture_id", "/perf/anchor/result_body/decision_body/anchor_enabled", "/perf/anchor/result_body/decision_body/surface", "/perf/anchor/result_body/decision_body/confirmation_policy", "/perf/anchor/result_body/decision_artifact_digest",
  "/perf/anchor/result_body/initial/phase", "/perf/anchor/result_body/initial/authority_base_digest", "/perf/anchor/result_body/initial/budget_digest", "/perf/anchor/result_body/initial/decision_artifact_digest", "/perf/anchor/result_body/initial/fixture_id", "/perf/anchor/result_body/initial/platform_id", "/perf/anchor/result_body/initial/backend_profile_id", "/perf/anchor/result_body/initial/host_kind", "/perf/anchor/result_body/initial/installed_wrapper_path", "/perf/anchor/result_body/initial/anchor_enabled", "/perf/anchor/result_body/initial/surface", "/perf/anchor/result_body/initial/runs", "/perf/anchor/result_body/initial/workload_schedule_digest", "/perf/anchor/result_body/initial/successor_baseline/from_leaf_state/per_leaf_authority_id", "/perf/anchor/result_body/initial/successor_baseline/from_leaf_state/leaf_counter", "/perf/anchor/result_body/initial/successor_baseline/from_leaf_state/leaf_value_digest", "/perf/anchor/result_body/initial/successor_baseline/target_leaf_counter", "/perf/anchor/result_body/initial/successor_baseline/target_leaf_digest", "/perf/anchor/result_body/initial_digest", "/perf/anchor/result_body/initial_breaches",
  "/perf/anchor/result_body/confirmation_applicability", "/perf/anchor/result_body/confirmation/phase", "/perf/anchor/result_body/confirmation/authority_base_digest", "/perf/anchor/result_body/confirmation/budget_digest", "/perf/anchor/result_body/confirmation/decision_artifact_digest", "/perf/anchor/result_body/confirmation/fixture_id", "/perf/anchor/result_body/confirmation/platform_id", "/perf/anchor/result_body/confirmation/backend_profile_id", "/perf/anchor/result_body/confirmation/host_kind", "/perf/anchor/result_body/confirmation/installed_wrapper_path", "/perf/anchor/result_body/confirmation/anchor_enabled", "/perf/anchor/result_body/confirmation/surface", "/perf/anchor/result_body/confirmation/runs", "/perf/anchor/result_body/confirmation/workload_schedule_digest", "/perf/anchor/result_body/confirmation/successor_baseline/from_leaf_state/per_leaf_authority_id", "/perf/anchor/result_body/confirmation/successor_baseline/from_leaf_state/leaf_counter", "/perf/anchor/result_body/confirmation/successor_baseline/from_leaf_state/leaf_value_digest", "/perf/anchor/result_body/confirmation/successor_baseline/target_leaf_counter", "/perf/anchor/result_body/confirmation/successor_baseline/target_leaf_digest", "/perf/anchor/result_body/confirmation_digest", "/perf/anchor/result_body/confirmation_breaches", "/perf/anchor/result_body/decision", "/perf/anchor/result_body_digest",
  "/perf/no_block/authority_base_body/approved_h010_schema_version", "/perf/no_block/authority_base_body/h010_decision_artifact_digest", "/perf/no_block/authority_base_body/global_platform_registry_entry_digest", "/perf/no_block/authority_base_body/no_block_release_profile_digest", "/perf/no_block/authority_base_body/no_block_installation_binding_digest", "/perf/no_block/authority_base_body/evaluation_policy_digest", "/perf/no_block/authority_base_body/authoritative_policy_generation", "/perf/no_block/authority_base_body/policy_validity_evidence_digest", "/perf/no_block/authority_base_digest",
  "/perf/no_block/budget_body/no_block_authority_base_digest", "/perf/no_block/budget_body/fixture_id", "/perf/no_block/budget_body/platform_id", "/perf/no_block/budget_body/host_kind", "/perf/no_block/budget_body/installed_wrapper_path", "/perf/no_block/budget_body/workload_schedule_digest", "/perf/no_block/budget_body/runs", "/perf/no_block/budget_body/hook_e2e_p50_ms", "/perf/no_block/budget_body/hook_e2e_p95_ms", "/perf/no_block/budget_body/hook_e2e_p99_ms", "/perf/no_block/budget_body/hook_e2e_max_ms", "/perf/no_block/budget_digest",
  "/perf/no_block/decision_body/no_block_authority_base_digest", "/perf/no_block/decision_body/no_block_budget_digest", "/perf/no_block/decision_body/fixture_id", "/perf/no_block/decision_body/authority_mode", "/perf/no_block/decision_body/anchor_enabled", "/perf/no_block/decision_body/surface", "/perf/no_block/decision_body/confirmation_policy", "/perf/no_block/decision_artifact_digest",
  "/perf/no_block/batch_body/phase", "/perf/no_block/batch_body/no_block_authority_base_digest", "/perf/no_block/batch_body/no_block_budget_digest", "/perf/no_block/batch_body/no_block_decision_artifact_digest", "/perf/no_block/batch_body/fixture_id", "/perf/no_block/batch_body/platform_id", "/perf/no_block/batch_body/host_kind", "/perf/no_block/batch_body/installed_wrapper_path", "/perf/no_block/batch_body/authority_mode", "/perf/no_block/batch_body/anchor_enabled", "/perf/no_block/batch_body/surface", "/perf/no_block/batch_body/runs", "/perf/no_block/batch_body/workload_schedule_digest", "/perf/no_block/batch_digest",
  "/perf/no_block/result_body/authority_base_body/approved_h010_schema_version", "/perf/no_block/result_body/authority_base_body/h010_decision_artifact_digest", "/perf/no_block/result_body/authority_base_body/global_platform_registry_entry_digest", "/perf/no_block/result_body/authority_base_body/no_block_release_profile_digest", "/perf/no_block/result_body/authority_base_body/no_block_installation_binding_digest", "/perf/no_block/result_body/authority_base_body/evaluation_policy_digest", "/perf/no_block/result_body/authority_base_body/authoritative_policy_generation", "/perf/no_block/result_body/authority_base_body/policy_validity_evidence_digest", "/perf/no_block/result_body/authority_base_digest",
  "/perf/no_block/result_body/budget_body/no_block_authority_base_digest", "/perf/no_block/result_body/budget_body/fixture_id", "/perf/no_block/result_body/budget_body/platform_id", "/perf/no_block/result_body/budget_body/host_kind", "/perf/no_block/result_body/budget_body/installed_wrapper_path", "/perf/no_block/result_body/budget_body/workload_schedule_digest", "/perf/no_block/result_body/budget_body/runs", "/perf/no_block/result_body/budget_body/hook_e2e_p50_ms", "/perf/no_block/result_body/budget_body/hook_e2e_p95_ms", "/perf/no_block/result_body/budget_body/hook_e2e_p99_ms", "/perf/no_block/result_body/budget_body/hook_e2e_max_ms", "/perf/no_block/result_body/budget_digest",
  "/perf/no_block/result_body/decision_body/no_block_authority_base_digest", "/perf/no_block/result_body/decision_body/no_block_budget_digest", "/perf/no_block/result_body/decision_body/fixture_id", "/perf/no_block/result_body/decision_body/authority_mode", "/perf/no_block/result_body/decision_body/anchor_enabled", "/perf/no_block/result_body/decision_body/surface", "/perf/no_block/result_body/decision_body/confirmation_policy", "/perf/no_block/result_body/decision_artifact_digest",
  "/perf/no_block/result_body/initial/phase", "/perf/no_block/result_body/initial/no_block_authority_base_digest", "/perf/no_block/result_body/initial/no_block_budget_digest", "/perf/no_block/result_body/initial/no_block_decision_artifact_digest", "/perf/no_block/result_body/initial/fixture_id", "/perf/no_block/result_body/initial/platform_id", "/perf/no_block/result_body/initial/host_kind", "/perf/no_block/result_body/initial/installed_wrapper_path", "/perf/no_block/result_body/initial/authority_mode", "/perf/no_block/result_body/initial/anchor_enabled", "/perf/no_block/result_body/initial/surface", "/perf/no_block/result_body/initial/runs", "/perf/no_block/result_body/initial/workload_schedule_digest", "/perf/no_block/result_body/initial_digest", "/perf/no_block/result_body/initial_breaches",
  "/perf/no_block/result_body/confirmation_applicability", "/perf/no_block/result_body/confirmation/phase", "/perf/no_block/result_body/confirmation/no_block_authority_base_digest", "/perf/no_block/result_body/confirmation/no_block_budget_digest", "/perf/no_block/result_body/confirmation/no_block_decision_artifact_digest", "/perf/no_block/result_body/confirmation/fixture_id", "/perf/no_block/result_body/confirmation/platform_id", "/perf/no_block/result_body/confirmation/host_kind", "/perf/no_block/result_body/confirmation/installed_wrapper_path", "/perf/no_block/result_body/confirmation/authority_mode", "/perf/no_block/result_body/confirmation/anchor_enabled", "/perf/no_block/result_body/confirmation/surface", "/perf/no_block/result_body/confirmation/runs", "/perf/no_block/result_body/confirmation/workload_schedule_digest", "/perf/no_block/result_body/confirmation_digest", "/perf/no_block/result_body/confirmation_breaches", "/perf/no_block/result_body/decision", "/perf/no_block/result_body_digest"
]
```

**Embedded-occurrence closure（必需，否则 pointer 集不是穷尽的）**：H-010 envelope 内嵌了完整的
`launch_authority_profile_body` 与 `launch_policy_body` 对象，但上表只登记了 standalone pointer 与内嵌
对象的 digest 字段。仅凭这些，required generator 无法为**内嵌**的 signer keys、quorum、validity/
lifetime bounds、approved binaries 等路径产生 one-field 或 cross-record mutation——被改写的内嵌字段
不在任何 mutation path 上。因此 pointer 集必须按下式闭包，且闭包结果参与 `exact_set_union`：

```text
EMBEDDED_PREFIXES = [
  "/h010_decision_envelope/h010_decision_body/platform_profiles/items/anchor_profile"
]
embedded_identity_schema_pointers = [
  prefix + suffix
  for prefix in EMBEDDED_PREFIXES
  for suffix in standalone_pointers_under("/launch_authority_profile_body")
              + standalone_pointers_under("/launch_policy_body")
]
all_identity_schema_pointers = exact_set_union(
  anchor_identity_schema_pointers,
  h010_identity_schema_pointers,
  atomic_annex.generated_atomic_launch_identity_schema_pointers,
  embedded_identity_schema_pointers)
```

atomic annex 的 `/launch_policy_body` root 同理：它只覆盖 standalone 出现，不覆盖 H-010 内嵌出现。
generator 必须断言闭包后的集合中，每个 standalone pointer 都存在对应的 embedded pointer；缺失即
pointer registry 未穷尽，validation 以 nonzero 退出，不得按 standalone 子集继续。
negative corpus 还必须逐项 mutate 每个 budget value、batch phase/runs/metric/timeout/error/breach path、
literal domain、outer schema version、signature/key 与 from/target leaf pairing。breach mirror fixtures
`one_sided_breach_change`、`one_sided_breach_delete`、`one_sided_breach_swap` 必须分别只改 top-level
或 nested `ordered_breaches` 并 nonzero；`nonempty_confirmation_breaches_with_null_confirmation` 也必须
nonzero。另覆盖 `refreshed_proof_same_state`、valid `unrelated_leaf_advance`、same-leaf unexpected successor
（`needs_repair`）、`forbidden_cross_release_mode_transition`、`duplicate_platform_across_releases`、
`two_release_whole_rollback`、`old_binary_prelaunch_rejected`、`unapproved_binary_above_minimum_rejected`、
`state_advance_before_atomic_launch_commit`、`replayed_consumed_launch_transaction` 与
`still_unexpired_attestation_replay_after_floor_advance`，并递归 mutate atomic annex 的六个 subdigest/domain/preimage、
named request/response conditional fields、tombstone retention/reuse guard 及 launch profile/policy/key/quorum/current-state。
fixture 必须证明旧 nonce/session/transaction 或 lower backend
counter/floor 即使 signature/expiry 仍有效也在 pre-hook 拒绝；no-block family 从首次验证 entry 的
conforming release 起保持 warn/off且禁止 migration，不声称抵抗 coherent whole-release rollback；active block platform rollback
到旧 Core/adapter 时在任何 hook 前 nonzero，不能执行 warn/off 或产生 decision。另须拒绝
duplicate/unsorted current profiles、pin mismatch、outer schema alias；
`no_block_status_without_backend` 断言 backend/root/leaf=`not_applicable`、global generation/install binding/
warn ceiling/stale 与 no-block result/CI identity 齐全，且 backend budget/provision/restart/CAS/IPC fields 全部 absent。
planned **tests/test_guard_pack_anchor.sh** owns schema/IPC/lifecycle/crash/concurrency fixtures；planned
**tests/perf_guard_pack_anchor.sh** 可保留 anchor fault attribution 专项，但不得自建发布 SLA gate。
canonical distribution/budget evidence 必须接入 `tests/bench_hook_latency.sh`，并由
`tests/test_hook_perf_contract.sh` 固定每个 mode 的 fixture、budget/batch/result/confirmation/CI contract。
`final_ci_authority_mode_branch` 要求 anchor-block 在每个 claimed platform 验证 pre-Core launch floor 并
运行真实 backend 或获批 fail-closed hardware/service fixture；no-block 只运行真实 installed zero-backend
hook、独立 schema/result/status gates，backend/hardware/service evidence 为 `not_applicable` 且不得成为 CI 前提。
本文不规定 backend 实现、平台支持集合、provision/reinstall/device-replacement policy、IPC peer
authentication 或 latency budget；这些必须由 product spec 的未批准 H-010 决定，并由
`tech.md` 的 manifest/verification matrix 证明后才可实现。
