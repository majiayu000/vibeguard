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
| `claim_publication_owner` | `{time_bound_intent,time_bound_request_id,publication_lease_authorization,secret_channel_binding}` | `{transition_receipt,nonce_capsule_receipt}` |
| `renew_publication_owner` | `{time_bound_intent,time_bound_request_id,publication_lease_authorization}` | `{transition_receipt}` |
| `takeover_publication_owner` | `{time_bound_intent,time_bound_request_id,publication_lease_authorization}` | `{transition_receipt}` |
| `append_publication_transition` | `{intent,append_authorization}` | `{transition_receipt}` |
| `plan_release_mutation` | `{intent,append_authorization,secret_channel_binding}` | `{planned_transition_receipt,mutation_capsule_receipt}` |
| `deliver_release_mutation` | `{planned_operation_id,broker_delivery_id,delivery_authorization}` | `{delivery_state,transition_receipt_or_null,send_once_audit_digest}` |
| `recover_release_mutation` | `{planned_operation_id,recovery_query_digest,append_authorization}` | `{recovery_state,transition_receipt}` |
| `plan_generated_pr` | `{intent,append_authorization}` | `{planned_transition_receipt,generated_pr_delivery_id}` |
| `deliver_generated_pr` | `{planned_operation_id,generated_pr_delivery_id,delivery_authorization}` | `{delivery_state,transition_receipt_or_null,send_once_audit_digest}` |
| `recover_generated_pr` | `{planned_operation_id,recovery_query_digest,append_authorization}` | `{recovery_state,transition_receipts}` |
| `append_blocked_attempt` | `{attempt_record,expected_attempt_subject_key,ledger_append_authorization}` | `{attempt_record_receipt,blocked_attempt_frontier_receipt}` |
| `bind_blocked_attempt` | `{binding_intent,ledger_append_authorization}` | `{binding_record_receipt,blocked_attempt_frontier_receipt}` |
| `list_blocked_attempts` | `{source_identity_key,candidate_identity_or_null,run_id_or_null,run_attempt_or_null,attempt_record_kind_or_null,attempt_subject_key_or_null,page_cursor_or_null,page_size}` | `{attempt_records,next_page_cursor_or_null,enumeration_snapshot_receipt}` |
| `commit_reconciliation_watermark` | `{reconciliation_watermark,terminal_listing_proof,ledger_append_authorization}` | `{watermark_receipt,blocked_attempt_frontier_receipt}` |
| `get_blocked_attempt_frontier` | `{}` | `{blocked_attempt_frontier_receipt}` |

`time_bound_intent` exact 为 `{record_kind,client_payload_core,predecessor_frontier}`；method与
`record_kind`只允许 `{claim_publication_owner:owner_claimed,renew_publication_owner:owner_heartbeat,
takeover_publication_owner:publication_owner_taken_over}`。client计算
`time_bound_request_id=SHA256(JCS({v:"GH700:time-bound-request:v1",repo_node_id,method,
time_bound_intent}))`，authority须在任何 nonce issuance前从 wire bytes重算。

`client_payload_core`是 method-tagged closed union。claim branch即 `claim_pre_nonce_core`，exact 为
`{owner_generation,run_id,run_attempt,candidate_tag_identity_digest,frozen_plan_digest,liveness_policy_digest,
prior_time_high_water}`；它等于 final `owner_claimed` payload删除 authority-only `{draft_claim_nonce_digest,
nonce_capsule_id,capsule_ciphertext_digest,kms_key_version}`及 trusted-time-produced fields。heartbeat/takeover branch
则是 final payload只删除 trusted-time-produced fields后的 proof-free object。client不得提交上述 claim authority
fields、trusted-time nonce/`nonce_digest`、TSA request/token、proof/interval、accepted time、expiry或 high-water
result。T3先以 client-known core保留 special claim operation identity，再签发 draft nonce/capsule并构造
`publication_payload_core`；之后才构造 trusted-time request/proof及 final payload。三种 method除 claim独有的
`secret_channel_binding`外使用同一 proof-ownership boundary；unknown/extra/cross-branch field一律拒绝。

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

`plan_generated_pr` success中的 `generated_pr_delivery_id`必须按 history contract从 committed
`planned_operation_id`及其 exact plan identity唯一重算。authority在同一 plan transaction建立永久 unique index
`(repo_node_id,generated_pr_delivery_id)`，值绑定 `{planned_operation_id,plan_record_digest,
generated_pr_delivery_state}`；same ID/same plan只返原 receipt，same ID/different plan永久冲突。
`deliver_generated_pr`须 byte-equal该 index ID，broker outbox、delivery attempt、send-once audit与 recovery均以该
ID作唯一 key；首次 authenticated send后任何重放只可 read-confirm，不得以新 ID再次 create。missing index、
caller-chosen ID、plan mismatch、第二次 send或 index/outbox/audit不一致均 `operation_conflict`并保留 owner；
`recover_generated_pr`必须从 `planned_operation_id`反查同一 index/ID，不能建立 replacement delivery identity。

`recover_generated_pr.recovery_state` exact closed union为 `{bound_existing,merged_existing,not_applied,blocked}`；
`transition_receipts`按 committed successor顺序排列且不得为空。`bound_existing`、`not_applied`、`blocked`分别要求
exact一张 `{generated_pr_bound}`、`{generated_pr_not_applied}`、`{corresponding_pr_recovery_blocked}` receipt。
`merged_existing`要求 exact两张 `[generated_pr_bound,generated_pr_merged]` receipts：authority在一个
`BEGIN IMMEDIATE`/anchor unit中先从同一 authenticated merged discovery构造并持久化 bound operation，再构造
以该 operation ID为 `bound_operation_id`的 merged operation；两个 operation/index/envelope/receipt均须永久保存。
response loss按 `planned_operation_id`返回原 ordered receipts；single merged receipt、跳过 bound、顺序/PR identity
不一致或只持久化其中一条均 `internal_durability_failure`且不释放 owner。

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
`{binding_record_digest,binding_kind,bound_attempt_record_digests,
post_intent_success_proof_digest_or_null,candidate_identity,source_identity_key,run_id,run_attempt,
successor_frontier,store_envelope_digest}`。
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
  `{binding_kind,candidate_identity,publication_history_operation_id,publication_history_frontier,
  recovered_outcome_digest,bound_attempt_record_digests,post_intent_success_proof_digest_or_null}`。

unknown kind/field、missing/extra/null-not-declared或 alias拒绝。

blocked-attempt value schema也是 closed contract：`selected_policy={block_release,publish_nonvalid}`，
`effective_action={block_release,publish_nonvalid}`；两者通常相等，只有 selected `publish_nonvalid` 的
prerequisite失败允许 effective `block_release`。下列四字段 exact 为：

- `closed_reason_code={required_target_missing,report_schema_invalid,evidence_schema_invalid,
  checksum_missing_or_mismatch,provenance_invalid,summary_unavailable,summary_invalid,policy_unapproved,
  publication_prerequisite_failed}`。`failure_scope=target`只允许前五项且 target non-null；`release`只允许
  后四项且 `required_platforms_or_null`/`failed_summary_digest_or_null` non-null。`policy_unapproved`只配
  effective `block_release`；`publication_prerequisite_failed`只配 selected `publish_nonvalid`、effective
  `block_release`；其余 code要求 selected/effective相等。
- `interruption_conclusion={cancelled,timed_out,failure}`；只适用于 `pipeline_interrupted`，且
  `pipeline_interrupted_pre_attestation.conclusion`必须使用同一 union。
- `interruption_stage={owner_claimed_no_draft,draft_bound_cleanup,prepared_cleanup,
  decurrent_pr_revocation,rollback_cleanup,mutation_compensation,cleanup_finalization}`；它只适用于
  `pipeline_interrupted`且必须匹配 history fold中最后一个已验证 phase/cleanup receipt。
- `missing_evidence` exact object为 `{schema_version,missing_field_codes}`，schema version exact
  `GH700:missing-evidence:v1`；`missing_field_codes`是 UTF-8 bytewise升序、去重、非空 array，item closed union为
  `{candidate_identity,selected_policy,staged_provenance,evidence_identities,report_identity,
  evidence_identity,checksum_identity,summary_digest,publish_sentinel_receipt}`。
  `pipeline_interrupted`只允许后五项；`pipeline_interrupted_pre_attestation`没有该 payload field，但其
  `failure_manifest_jcs`内的 exact `missing_evidence`必须是前四项全量集合
  `["candidate_identity","evidence_identities","selected_policy","staged_provenance"]`。

unknown/alias/inapplicable enum value、wrong order、duplicate/empty missing list或表外 field均 schema-invalid。

## Subject identity and binding

authority从 closed payload派生
`attempt_subject_key=SHA256(JCS({v:"GH700:attempt-subject:v1",attempt_record_kind,
candidate_identity_or_null,failure_scope_or_null,target_or_null,early_attempt_key_or_null}))`。
`candidate_failure`写 candidate+scope及 target-or-null；`pipeline_interrupted`与
`publication_recovery_binding`写 candidate且其余 null；pre-attestation kind只写 early-attempt key。
`append_blocked_attempt.expected_attempt_subject_key`必须 byte-equal重算值，不能作为 authority输入真源。

`binding_intent` exact 为
`{binding_kind,source_identity_key,run_id,run_attempt,candidate_identity,source_attempt_record_digests,
post_intent_success_proof_or_null,publication_history_operation_id,publication_history_frontier,
recovered_outcome_digest}`，其中 `binding_kind={source_attempt_records,post_intent_success}`。
`source_attempt_record_digests`始终按 digest bytes升序且去重。

`source_attempt_records` branch要求该 list非空、proof为 null。authority逐项读取永久 record，证明共享 exact
`repo_node_id/source_identity_key/run_id/run_attempt`；pre-attestation record的 server ref/tag/source必须与
`candidate_identity`精确匹配，任何 already-bound、cross-source/candidate、missing或 ambiguous record拒绝。

`post_intent_success` branch要求 list exact `[]`且 proof non-null。proof exact object为
`{schema_version,repo_node_id,source_identity_key,run_id,run_attempt,candidate_identity,
terminal_attempt_key,recovered_publication_operation_id,predecessor_intent_operation_id,
publication_history_frontier,recovered_outcome_digest,server_terminal_receipt_digest,
zero_source_attempt_snapshot_receipt_digest}`，schema version exact
`GH700:post-intent-success-binding-proof:v1`。authority须验 server-auth terminal attempt与 outer tuple exact，
stable ledger enumeration snapshot证明该 tuple没有 failure/interruption record，并从 signed history重放证明
`predecessor_intent_operation_id`是同 candidate owner chain的 committed `intent_written`，
`recovered_publication_operation_id`是其合法 terminal recovery successor，frontier/outcome digest exact。
只有 matching public Release或 matching intent-bound draft完成的 post-intent success可走此 branch；blocked、
pre-intent cleanup或 ambiguous truth不得伪装 success。

authority只按 validated branch构造 `attempt_record_kind=publication_recovery_binding`：payload
`bound_attempt_record_digests` byte-equal intent list；success branch另写
`post_intent_success_proof_digest_or_null=SHA256(JCS(post_intent_success_proof))`，source branch写 null。
top-level source/run tuple来自已验证 records或 proof，不能只信 client。binding record、proof capsule、unique index与
frontier在同一事务提交；client不得提交另一个 record body或选择不同 subject key。success binding本身就是该
terminal attempt的 canonical permanent reconciliation record，watermark不再要求虚构 failure record。

## Stable enumeration

第一页要求 `page_cursor_or_null=null`；authority在同一 committed ledger frontier创建
`enumeration_snapshot_receipt={repo_node_id,query_digest,snapshot_frontier,snapshot_record_set_digest,
page_size,issuer_key_id,signature_digest}`。`page_cursor`是 store-signed opaque token，内部绑定该 receipt digest、
下一 canonical record key与 expiry policy digest；后续页必须使用同 snapshot frontier/query/page size。
`attempt_records`按 `(source_identity_key,run_id,run_attempt,attempt_record_kind,attempt_subject_key,record_digest)`
bytewise排序。任一页缺失、重复、cursor/query/frontier drift或无法完成全分页使 completeness证明失败。

## Terminal listing proof and reconciliation watermark

`terminal_attempt_key` exact 为
`{workflow_id,run_id,run_attempt,event,conclusion,source_identity_key,candidate_identity_or_null}`，其中
`conclusion={failure,cancelled,timed_out}`；列表按
`(workflow_id,run_id,run_attempt,event)`升序且无重复。`terminal_listing_proof` exact 为
`{schema_version,provider,repo_node_id,source_identity_key,candidate_identity_or_null,server_query_digest,
page_receipt_digests,terminal_attempt_keys,terminal_attempt_keys_digest}`，其中 provider exact 为
`github_actions_server_terminal_runs_v1`；page receipt按 server page顺序保留，且
`terminal_attempt_keys_digest=SHA256(JCS(terminal_attempt_keys))`。proof capsule必须保存全部 authenticated
server response bytes/digests、pagination completion、permissions与 ref alignment。`server_query_digest`必须绑定
server-side exact conclusion filter `{failure,cancelled,timed_out}`及完整 pagination；ordinary `success`、`skipped`、
`neutral`或 unknown conclusion不得进入 proof/count/max/set，也不要求 failure/binding record且不阻塞后续 attempt。
workflow input/artifact/free text或 client-side过滤均无效。

`reconciliation_watermark` exact 为
`{schema_version,repo_node_id,source_identity_key,candidate_identity_or_null,terminal_listing_proof_digest,
max_terminal_run_id,max_terminal_run_attempt,terminal_attempt_count,covered_record_digests,
covered_record_set_digest,prior_watermark_digest_or_null}`。`covered_record_digests`按 digest bytes升序、去重；
`covered_record_set_digest=SHA256(JCS(covered_record_digests))`。max tuple是按 unsigned numeric
`(run_id,run_attempt)`排序后的最后一项；空 terminal listing禁止 commit watermark。

authority提交 watermark前必须：

1. 验证 terminal listing proof 是上述三种 conclusion的全分页 server-authenticated exact集合、candidate/source exact且 digest匹配；
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
