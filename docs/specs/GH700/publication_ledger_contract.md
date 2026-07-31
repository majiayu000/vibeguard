# GH700 Publication Authority API And Blocked-Attempt Contract

本文件是 [publication_history_contract.md](publication_history_contract.md) 的规范性组成部分，唯一拥有
`client_api` wire schema与 B-029 blocked-attempt ledger。product/tech/tasks只可链接或引用这里的
machine-facing identifier，不得复制、改名或局部覆盖字段集、canonical bytes、retention或 fail-closed语义。

## Closed client API

`client_api.method` exact closed union为
`{get_publication_head,claim_publication_owner,renew_publication_owner,takeover_publication_owner,
append_publication_transition,plan_release_mutation,deliver_release_mutation,recover_release_mutation,
plan_generated_pr,deliver_generated_pr,recover_generated_pr,append_blocked_attempt,bind_blocked_attempt,
list_blocked_attempts,commit_reconciliation_watermark,get_blocked_attempt_frontier}`。

request envelope exact 为
`{api_version,method,authority_id,authority_identity_digest,policy_epoch,policy_bundle_digest,repo_node_id,
request_nonce,expected_publication_frontier_or_null,expected_blocked_attempt_frontier_or_null,
operation_request_digest,body}`；`operation_request_digest` 是删除自身后整个 envelope 的 JCS SHA-256。

| method | exact request `body` | exact success `result` |
| --- | --- | --- |
| `get_publication_head` | `{}` | `{current_head_receipt}` |
| `claim_publication_owner` | `{intent,publication_lease_authorization,secret_channel_binding}` | `{transition_receipt,nonce_capsule_receipt}` |
| `renew_publication_owner` | `{intent,publication_lease_authorization,trusted_time_proof_request}` | `{transition_receipt}` |
| `takeover_publication_owner` | `{intent,publication_lease_authorization,trusted_time_proof_request}` | `{transition_receipt}` |
| `append_publication_transition` | `{intent,append_authorization}` | `{transition_receipt}` |
| `plan_release_mutation` | `{intent,append_authorization,secret_channel_binding}` | `{planned_transition_receipt,mutation_capsule_receipt}` |
| `deliver_release_mutation` | `{planned_operation_id,broker_delivery_id,delivery_authorization}` | `{delivery_state,transition_receipt_or_null,send_once_audit_digest}` |
| `recover_release_mutation` | `{planned_operation_id,recovery_query_digest,append_authorization}` | `{recovery_state,transition_receipt}` |
| `plan_generated_pr` | `{intent,append_authorization}` | `{planned_transition_receipt}` |
| `deliver_generated_pr` | `{planned_operation_id,generated_pr_delivery_id,delivery_authorization}` | `{delivery_state,transition_receipt_or_null,send_once_audit_digest}` |
| `recover_generated_pr` | `{planned_operation_id,recovery_query_digest,append_authorization}` | `{recovery_state,transition_receipt}` |
| `append_blocked_attempt` | `{attempt_record,expected_attempt_subject_key,ledger_append_authorization}` | `{attempt_record_receipt,blocked_attempt_frontier_receipt}` |
| `bind_blocked_attempt` | `{binding_intent,ledger_append_authorization}` | `{binding_record_receipt,blocked_attempt_frontier_receipt}` |
| `list_blocked_attempts` | `{source_identity_key,candidate_identity_or_null,run_id_or_null,run_attempt_or_null,attempt_record_kind_or_null,attempt_subject_key_or_null,page_cursor_or_null,page_size}` | `{attempt_records,next_page_cursor_or_null,enumeration_snapshot_receipt}` |
| `commit_reconciliation_watermark` | `{reconciliation_watermark,terminal_listing_proof,ledger_append_authorization}` | `{watermark_receipt,blocked_attempt_frontier_receipt}` |
| `get_blocked_attempt_frontier` | `{}` | `{blocked_attempt_frontier_receipt}` |

success response exact 为
`{api_version,method,authority_id,authority_identity_digest,policy_epoch,policy_bundle_digest,
operation_request_digest,response_nonce,result}`；error response exact 为相同公共字段加
`{error:{code,retry_class,evidence_digest_or_null}}`且无 `result`。response的
`operation_request_digest`必须 byte-equal request字段。`code` exact 为
`{invalid_request,unauthenticated,unauthorized,wrong_authority,policy_drift,method_not_allowed,
stale_frontier,stale_fence,lease_expired,operation_conflict,dependency_unavailable,outcome_uncertain,
authority_non_ready,internal_durability_failure}`；`retry_class` exact 为
`{never,after_fresh_read,after_new_authorization,same_request_read_confirm_only}`。
`outcome_uncertain`只配 `same_request_read_confirm_only`；unknown method/code/field、method/body/result
错配、null-not-declared或 error/result并存均拒绝，不得 fallback。

## Ledger authorization and receipts

`ledger_append_authorization` exact 为
`{lease_scope,lease_token_digest,ledger_fence,authenticated_actor_digest,authorization_policy_digest}`；
`lease_scope`必须 exact `repository_blocked_attempt_ledger_v1`。publication owner/fence不得替代它。

`blocked_attempt_frontier_receipt` exact 为
`{authority_id,repo_node_id,predecessor_frontier,successor_frontier,ledger_operation_id,
accepted_ledger_fence,record_digest,store_envelope_digest,anchor_receipt_digest,issuer_key_id}`。
`attempt_record_receipt` exact 为
`{record_digest,attempt_subject_key,source_identity_key,run_id,run_attempt,attempt_record_kind,
successor_frontier,store_envelope_digest}`。
`binding_record_receipt` exact 为
`{binding_record_digest,bound_attempt_record_digests,candidate_identity,source_identity_key,run_id,
run_attempt,successor_frontier,store_envelope_digest}`。
`watermark_receipt` exact 为
`{watermark_digest,terminal_listing_proof_digest,max_terminal_run_id,max_terminal_run_attempt,
terminal_attempt_count,covered_record_set_digest,prior_watermark_digest_or_null,successor_frontier,
store_envelope_digest}`。receipt missing/extra field、frontier不等或 digest mismatch均拒绝。

## Concrete blocked-attempt ledger

B-029 唯一 production backend 是同一 authority database 内的
`blocked_attempt_ledger_sqlite_v1` namespace，由计划中的
**vibeguard-runtime/src/publication_authority/blocked_attempt_ledger.rs** 实现；它不是
`publication_history` alias，也不能降级为 Actions artifact、attestation pointer、job summary或 checkout JSON。
deployment manifest 的 `blocked_attempt_ledger` exact 为
`{backend,namespace,api_version,retention_class}`，值 exact 为
`{backend:"blocked_attempt_ledger_sqlite_v1",namespace:"blocked_attempt_v1",
api_version:"GH700:blocked-attempt-ledger-api:v1",retention_class:"permanent_no_ttl_v1"}`。

T3独占 planned **schemas/blocked_attempt_ledger.schema.json**、SQLite tables
`{blocked_attempt_records,blocked_attempt_unique_keys,blocked_attempt_bindings,blocked_attempt_frontiers,
reconciliation_watermarks}`、bootstrap/migration/recovery。两域共用 DB/WAL/FULL fsync、process lock、
snapshot与 external anchor，但使用独立 repository-ledger lease/fence、operation ID/index。

ledger frontier exact 为 `{repo_node_id,ledger_length,ledger_root,full_prefix_digest}`。record exact top-level
object为 `{schema_version,attempt_record_kind,repo_node_id,source_identity_key,run_id,run_attempt,
predecessor_frontier,payload}`；`attempt_record_kind` exact closed union为
`{candidate_failure,pipeline_interrupted,pipeline_interrupted_pre_attestation,
publication_recovery_binding}`。

- `candidate_failure.payload` exact 为
  `{candidate_identity,failure_scope,target_or_null,required_platforms_or_null,
  failed_summary_digest_or_null,failure_manifest_jcs,failure_manifest_digest,bundle_digest,
  selected_policy,effective_action,closed_reason_code}`；`failure_scope={target,release}`，target branch要求
  non-null `target`且两个 release字段为 null，release branch反之。
- `pipeline_interrupted.payload` exact 为
  `{candidate_identity,staged_provenance_digest,interruption_conclusion,interruption_stage,
  publish_sentinel_audit_digest,missing_evidence,failure_manifest_jcs,failure_manifest_digest}`。
- `pipeline_interrupted_pre_attestation.payload` exact 为
  `{workflow_id,head_sha,server_ref_type,server_ref_name,event,conclusion,early_attempt_key,
  candidate_identity_or_null,selected_policy_or_null,staged_provenance_digest_or_null,
  evidence_identities_or_null,failure_manifest_jcs,failure_manifest_digest}`，四个 `*_or_null`字段必须 literal null。
- `publication_recovery_binding.payload` exact 为
  `{candidate_identity,publication_history_operation_id,publication_history_frontier,
  recovered_outcome_digest,bound_attempt_record_digests}`。

unknown kind/field、missing/extra/null-not-declared或 alias拒绝。

## Subject identity and binding

authority从 closed payload派生
`attempt_subject_key=SHA256(JCS({v:"GH700:attempt-subject:v1",attempt_record_kind,
candidate_identity_or_null,failure_scope_or_null,target_or_null,early_attempt_key_or_null}))`。
`candidate_failure`写 candidate+scope及 target-or-null；`pipeline_interrupted`与
`publication_recovery_binding`写 candidate且其余 null；pre-attestation kind只写 early-attempt key。
`append_blocked_attempt.expected_attempt_subject_key`必须 byte-equal重算值，不能作为 authority输入真源。

`binding_intent` exact 为
`{source_identity_key,run_id,run_attempt,candidate_identity,source_attempt_record_digests,
publication_history_operation_id,publication_history_frontier,recovered_outcome_digest}`。
`source_attempt_record_digests`按 digest bytes升序、去重且非空。authority必须逐项读取永久 record，证明它们
共享 exact `repo_node_id/source_identity_key/run_id/run_attempt`；pre-attestation record的 server ref/tag/source
必须与 `candidate_identity`精确匹配，任何 already-bound、cross-source/candidate、missing或 ambiguous record拒绝。
authority只按该 intent构造 `attempt_record_kind=publication_recovery_binding`：top-level source/run tuple来自
已验证共同 tuple，payload的 `bound_attempt_record_digests` byte-equal intent列表，其余四字段 byte-equal intent。
binding record与索引/frontier在同一事务提交；client不得提交另一个 record body或选择不同 subject key。

## Stable enumeration

第一页要求 `page_cursor_or_null=null`；authority在同一 committed ledger frontier创建
`enumeration_snapshot_receipt={repo_node_id,query_digest,snapshot_frontier,snapshot_record_set_digest,
page_size,issuer_key_id,signature_digest}`。`page_cursor`是 store-signed opaque token，内部绑定该 receipt digest、
下一 canonical record key与 expiry policy digest；后续页必须使用同 snapshot frontier/query/page size。
`attempt_records`按 `(source_identity_key,run_id,run_attempt,attempt_record_kind,attempt_subject_key,record_digest)`
bytewise排序。任一页缺失、重复、cursor/query/frontier drift或无法完成全分页使 completeness证明失败。

## Terminal listing proof and reconciliation watermark

`terminal_attempt_key` exact 为
`{workflow_id,run_id,run_attempt,event,conclusion,source_identity_key,candidate_identity_or_null}`；列表按
`(workflow_id,run_id,run_attempt,event)`升序且无重复。`terminal_listing_proof` exact 为
`{schema_version,provider,repo_node_id,source_identity_key,candidate_identity_or_null,server_query_digest,
page_receipt_digests,terminal_attempt_keys,terminal_attempt_keys_digest}`，其中 provider exact 为
`github_actions_server_terminal_runs_v1`；page receipt按 server page顺序保留，且
`terminal_attempt_keys_digest=SHA256(JCS(terminal_attempt_keys))`。proof capsule必须保存全部 authenticated
server response bytes/digests、pagination completion、permissions与 ref alignment；workflow input/artifact/free text无效。

`reconciliation_watermark` exact 为
`{schema_version,repo_node_id,source_identity_key,candidate_identity_or_null,terminal_listing_proof_digest,
max_terminal_run_id,max_terminal_run_attempt,terminal_attempt_count,covered_record_digests,
covered_record_set_digest,prior_watermark_digest_or_null}`。`covered_record_digests`按 digest bytes升序、去重；
`covered_record_set_digest=SHA256(JCS(covered_record_digests))`。max tuple是按 unsigned numeric
`(run_id,run_attempt)`排序后的最后一项；空 terminal listing禁止 commit watermark。

authority提交 watermark前必须：

1. 验证 terminal listing proof 全分页、server-authenticated、candidate/source exact且 digest匹配；
2. 对每个 terminal attempt key找到恰一 permanent failure record或 exact `publication_recovery_binding`，
   record的 run tuple/terminal outcome必须一致；
3. 证明 `covered_record_digests`与上述一一映射的完整 record set相等，而非 subset/superset；
4. 重算 count、max tuple、record-set digest，并以 CAS验证 latest watermark digest；
5. 在同一 transaction写 watermark、frontier successor与 permanent indexes，FULL fsync并完成 external anchor。

terminal listing/permanent record不可用、存在未 reconciled attempt、内容冲突、旧 max tuple、subset watermark、
candidate/source歧义或 anchor ack不确定均 fail closed；新 attempt及 publish gate不能越过失败 watermark。

## Durability and retention

append在同一 `BEGIN IMMEDIATE` transaction验证 expected frontier、ledger lease/fence，并以永久 unique index
`(repo_node_id,source_identity_key,run_id,run_attempt,attempt_record_kind,attempt_subject_key)`做 same-bytes幂等、
different-bytes冲突。完整 canonical manifest bytes、record、binding/frontier/watermark写入后 FULL fsync，且同一
frontier CAS external anchor成功或 read-confirm exact ack后才返回 signed receipt。

records/manifest bytes/frontiers/bindings/watermarks无 TTL、无 delete/truncate/overwrite；artifact retention、
owner terminal、candidate publish或 schema migration均不缩短 retention。snapshot/WAL restore必须达到 external
anchor的 `blocked_attempt_ledger_frontier`，重放全部 records/unique indexes/bindings/watermarks并核对 full-prefix。
缺 manifest bytes、older/forked frontier或未闭合 terminal attempt时 authority non-ready且 publish gate blocked。
真实 durable-volume fixture须覆盖 concurrent append、same-key different bytes、pagination snapshot drift、subset
watermark、max-run rollback、crash/fsync/disk-full、artifact deletion、snapshot rollback与 exact manifest恢复；mock不算通过。
