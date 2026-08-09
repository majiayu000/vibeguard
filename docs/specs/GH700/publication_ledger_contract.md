# GH700 Publication Authority API, Delegated Values And Blocked-Attempt Contract

本文件与 [history](publication_history_contract.md)、[authority protocol](publication_authority_protocol_contract.md) 共同构成规范，唯一拥有 `client_api`/`control_api` wire、history委托 value sets及 B-029 ledger；其它文件只可引用，不得复制/覆盖字段、canonical bytes、retention或 fail-closed语义。

## Closed client API

[publication_authority_api.schema.json](publication_authority_api.schema.json) 是 client_api 与
control_api 的唯一 machine-facing source；[positive models](publication_authority_api.models.json)
按其声明的 deterministic fixture materialization 产生每个 method 的 request/success 正例；
[semantic verifier](verify_publication_authority_api.py) 必须对所有 normative request/response、authorization、
typed receipt、nested capsule/KMS、replay及 DAG digest重算为零 mismatch，并执行 negative fixtures。schema
根对象、所有 nested definitions、method/body/result branch、nullability、authorization、error与
replay object均 closed；unknown/extra/alias/cross-method/null-not-declared一律 invalid_request，
不得由本文或调用方补充兼容 spelling。

registry matrix exact 为 17 个 client method；实现须读 `x-gh700-method-registry.rows`，并要求 method、
request_ref、success_ref、authorization ref、frontier profile、error set、replay class与全部 model profile
一一对应且无 duplicate/dangling/omitted/unknown row、model、profile、relation或 path。`profiles`是 request、
authorization、time-bound、secret-channel、result与 response binding 的唯一 machine source，不得另建 method switch。
request envelope exact 由 client_request_envelope 定义，
包含 deployment policy_binding、authenticated principal、canonical 32-byte unpadded-base64url
request_nonce、两个显式 frontier-or-null 与 body。success/error分别只接受 client_success/client_error；
两者均回显 request digest及 client_request_nonce_digest并携 fresh response nonce，且不得
error/result并存。

所有 authority API digest的 exact domain、JCS preimage、wire consumer与无环 dependency只由 schema
`x-gh700-digest-formulas`/`x-gh700-digest-dag`拥有；本文不复制第二套公式。实现必须运行 semantic verifier，
不得以 schema shape/count通过代替 preimage重算；literal expected digest、all-zero digest或 mismatch均失败。

authority在任何 lookup、nonce/capsule、TSA、DB、broker或 provider I/O前重算 request identity。
永久 UNIQUE replay key exact (authority_id,repo_node_id,authenticated_principal_digest,request_nonce)，
row exact schema为 client_api_replay_row；首次 request须 FULL-fsync reserved。same key/same method/
same operation digest只恢复同一 durable effect及 byte-identical frozen response（含 response nonce）；
same key/different bytes/method/principal 永久 replay_conflict。response只有在 effect与result已
durable后写 response_frozen；ack-loss不得产生第二 effect、capsule、nonce、delivery或 response。

### Per-method CAS and authorization

P1/B1 表示对应 expected frontier必须 non-null、byte-equal authority strong-read current state及
method body/authorization中的 predecessor；P0/B0 表示该 envelope字段必须 literal null。
control的 body CAS由 registry的 BODY_P1_B1 标记，不复用 client envelope。

| client method | P | B | exact authorization |
| --- | --- | --- | --- |
| get_publication_head, get_blocked_attempt_frontier | 0 | 0 | none |
| claim_publication_owner, renew_publication_owner, takeover_publication_owner | 1 | 0 | publication_lease_authorization |
| append_publication_transition, plan_release_mutation, recover_release_mutation, plan_generated_pr, recover_generated_pr | 1 | 0 | append_authorization |
| deliver_release_mutation, deliver_generated_pr | 1 | 0 | delivery_authorization |
| append_blocked_attempt, commit_reconciliation_watermark | 0 | 1 | ledger_append_authorization |
| bind_blocked_attempt | 1 | 1 | ledger_append_authorization |
| list_blocked_attempts | 0 | 1 | authenticated read |
| read_secret_capsule | 1 | 0 | secret_channel_binding |

四种 authorization branch、各自 exact signing domain/preimage field list、canonical 64-byte signature、
manifest-pinned signing key ID/KeyMaterialId与 method-operation/frontier binding只由 schema
`$defs/authorization`及 `x-gh700-signing-preimages`拥有。authority须重算 signature/detached digest，
并要求 authenticated principal、policy、authorized method、operation/delivery ID、predecessor、
fence/lease与 expiry全部 byte-equal request及 committed plan/fold；refresh只改变 mutable
authorization bytes，不改变 immutable operation。wrong method/ID/frontier/principal或 cross-kind object在
任何 side effect前 unauthorized；delivery authorization只授权 committed plan的唯一 send-once ID。

active signing key由 `$defs/authority_signing_manifest`拥有：每个 authorization须 byte-equal
`authorization_signing_key_id`/`authorization_signing_key_material_id`，并用 manifest-pinned Ed25519
public key验证 exact signing-preimage digest。release identity attestation使用独立的
`release_identity_*` key、签名及 validity interval，二者不可互换。conformance gate使用 RFC 8032
公开测试向量执行真实签名验证，并拒绝 wrong-key、one-bit及 non-canonical signature。

### Time-bound operations, capsules and recovery

time_bound_intent、execution_identity、三个 client payload core及 proof-order仍由
[authority protocol](publication_authority_protocol_contract.md#authority-owned-time-bound-payload-cores)
和 history fold唯一解释。claim/heartbeat/takeover的 run tuple必须 byte-equal authenticated execution
identity；takeover core必须显式包含 new_owner_run_id/new_owner_run_attempt，且等于 request
run_id/run_attempt。client不得提交 trusted time、high-water、final payload或 authority evidence。
H-006 liveness policy必须 byte-equal authority signing manifest中的 maintainer-approved policy；wire上的
approval digest和各 interval不能自我批准，任一 drift在 operation digest或 side effect之前拒绝。

secret_channel_binding、capsule_source、capsule_receipt 与 authority_capsule_key_attestation exact schema
均只在 machine source。authority capsule key只来自 manifest-pinned exact KMS key ARN、authenticated
DescribeKey 64hex KeyMaterialId attestation及 byte-equal actual GenerateDataKey response；nested digest domain/preimage
只读 schema DAG并由 verifier重算，不存在 logical kms_key_version。
UNIQUE (repo_node_id,source_method,source_request_id,secret_slot_id) 保证 claim/mutation capsule只签发一次；
capsule_source同时绑定 source operation与 issuance channel；read confirmation须 byte-equal source request
ID、实际 read challenge raw-byte digest及当前 live exporter binding，返回的 capsule receipt还须回指同一
issuance operation/channel。missing/tampered attestation、ciphertext或 source为 not_found/hard failure，
绝不生成 replacement。

method-specific success的 receipt cardinality/nullability由 registry success_ref唯一决定。Release与
generated-PR send-once/recovery state、trusted-time durable preparation及 history operation-ID semantic
checks继续由下节和对应 history/protocol contract约束；machine schema提供 closed wire，不把 semantic
object ref变成 client truth。
### Release effective-request digest

`release_request_template` exact object为
`{v:"GH700:release-request-template:v1",endpoint,method,header_template,body_encoding,body_template,
secret_placeholder_kinds}`，`request_template_digest=SHA256(JCS(release_request_template))`。
`endpoint` exact为 `{scheme:"https",host_ascii,port,path_segments,query_pairs}`：host是 lowercase IDNA A-label，
port须 u16 `443`，path segments是 NFC UTF-8且不得为 empty/`.`/`..`或含 `/`，query pair exact
`{name,value}`且按 `(name,value)` UTF-8 bytes升序、name唯一；禁止 userinfo/fragment/ambient base URL。
唯一 origin-form request-target serializer先对每个 segment/query name/value取 NFC UTF-8 bytes，再仅保留
RFC3986 unreserved `ALPHA/DIGIT/-._~`，其它 byte用 uppercase `%HH`；禁止 `+`、已有 `%` escape、
decode/re-encode或其它 normalization。path exact为 `"/"+segments.join("/")`；empty query array不输出 `?`，
否则 exact为 `"?" + pairs.map(name+"="+value).join("&")`。serializer产物须是 ASCII bytes。
`method` exact union `{POST,PATCH,DELETE}`，applicability exact为
`draft_create:POST,draft_update:PATCH,draft_delete:DELETE,asset_upload:POST,asset_delete:DELETE,publish:PATCH`。

`header_template`是按 lowercase ASCII `name`升序且 name唯一的 non-empty array；entry exact
`{name,value_parts}`，part exact union为 `{part_kind:"literal_utf8",value}`或
`{part_kind:"secret_placeholder",placeholder_kind}`。literal须 NFC UTF-8且无 CR/LF/NUL或首尾 OWS。
`body_encoding` exact union `{jcs_json_v1,raw_bytes_v1,empty_v1}`；其 `body_template`分别 exact为
任意 JSON tree（secret leaf只可 exact `{"$gh700_secret_placeholder":placeholder_kind}`，literal object禁止
该 reserved key）、`{asset_bytes_digest}`或 `{}`。kind applicability exact为
`{draft_create:jcs_json_v1,draft_update:jcs_json_v1,draft_delete:empty_v1,asset_upload:raw_bytes_v1,
asset_delete:empty_v1,publish:jcs_json_v1}`。
`placeholder_kind` exact closed union为 `{mutation_nonce,draft_claim_nonce,authorization_credential}`；
`secret_placeholder_kinds`是按 UTF-8 bytes升序的 unique array且 byte-equal模板实际 placeholders：
六 kind都各含一次 mutation nonce与 authorization credential，只有 draft_create另含恰一次 draft-claim nonce。
authorization credential只可作为 `authorization` header的第二个且末尾 part，首 part须 exact literal
`"Bearer "`；mutation nonce只可作为 `x-vibeguard-mutation-nonce` header唯一 part；draft-claim nonce只可作为
`x-vibeguard-draft-claim` header唯一 part。其它 header只可 literal，所有 body须零 reserved placeholder；
secret不得出现在 endpoint/method/literal/raw asset/empty body，unknown/duplicate/missing/cross-location拒绝。

broker替换 exact typed secrets后构造 non-secret audit object
`release_effective_request={v:"GH700:release-effective-request:v1",repo_node_id,planned_operation_id,
mutation_slot_id,broker_delivery_id,request_template_digest,request_commitment,endpoint,method,
request_target_bytes_digest,effective_header_block_digest,authorization_context_digest,body_encoding,body_length,body_bytes_digest}`，并计算
`effective_request_digest=SHA256(JCS(release_effective_request))`；所有 digest编码 lowercase
`sha256:<64hex>`。

`endpoint/method`须 byte-equal plan；`request_target_bytes_digest=SHA256(exact serialized origin-form
request-target bytes)`，且 broker交给 HTTP client的 `:path` bytes须 byte-equal serializer产物。materialized `effective_header_block`是按 lowercase ASCII name升序且
name唯一的 exact array `{name,value_b64u}`；`value_b64u`是交给 HTTP client的 exact field-value bytes之
canonical unpadded base64url，禁止 CR/LF/NUL、ambient header及重复 name。
`effective_header_block_digest=SHA256(JCS(effective_header_block))`。raw block不持久化；仅保留 digest。
`authorization_context` exact为
`{v:"GH700:release-authorization-context:v1",credential_kind:"github_app_installation_token_v1",
issuer_identity_digest,app_node_id,installation_id,repository_node_id,permission_scopes,token_key_id,
issued_at_unix_seconds,expires_at_unix_seconds}`；permissions按 UTF-8 bytes升序去重，两个 times是
`gh700_uint64`且 issued<expires，App/installation/repo/scope须 byte-equal plan，
`authorization_context_digest=SHA256(JCS(authorization_context))`。raw Authorization不得持久化。
`body_bytes_digest=SHA256(exact body bytes)`，`body_length`是这些 bytes的 `gh700_uint64` count；
JCS body须 exact RFC8785 bytes，raw asset须 hash等于 template `asset_bytes_digest`，empty须 zero bytes。
TLS/HTTP2/HPACK bytes不作稳定 preimage；broker禁止 redirect、transparent retry/compression或任何
会改变 method/URL/header/body的自动重编码。protected broker须从 retained capsule/request material重算；
history/audit只留 digest而不泄漏 raw secrets。任一 endpoint/method/header/body/auth/template/commitment
mismatch在 send前拒绝，send-once audit、postcheck、recovery必须重算同一 object。

`recover_generated_pr.recovery_state` exact closed union为 `{bound_existing,merged_existing,not_applied,blocked}`；
`transition_receipts`按 committed successor顺序排列且不得为空。`bound_existing`、`not_applied`、`blocked`分别要求
exact一张 `{generated_pr_bound}`、`{generated_pr_not_applied}`、`{corresponding_pr_recovery_blocked}` receipt。
`merged_existing`要求 exact两张 `[generated_pr_bound,generated_pr_merged]` receipts：authority在一个
recovery orchestration中串行执行两个完整 successor cycles：先 append/backup/anchor/read-confirm
`generated_pr_bound`，再以其 confirmed successor与 operation ID为 predecessor/`bound_operation_id`
append/backup/anchor/read-confirm `generated_pr_merged`；两张 receipt都确认后才返回。永久 checkpoint exact 为
`{planned_operation_id,generated_pr_delivery_id,checkpoint_state,bound_operation_id_or_null,
bound_anchor_receipt_digest_or_null,merged_operation_id_or_null,merged_anchor_receipt_digest_or_null}`，state closed
union为 `{planned,bound_anchor_confirmed,merged_anchor_confirmed}`且只可按该顺序 transaction+FULL fsync推进；任一
`*_confirmed`只可在对应 EPOCH+HEAD strong-read确认后写入。global `anchor_commit_gate`保证任一时刻最多一个 pending
cycle：bound DB commit/backup/CAS任一点 crash或 ack丢失都恢复同一 pending anchor，确认后才写 bound checkpoint；
其后 crash只从该 anchored successor构造 merged cycle。merged DB commit/backup/CAS任一点 crash或 ack丢失同理只恢复
同一 merged anchor；确认后写 final checkpoint。response loss按 `planned_operation_id`返回 checkpoint绑定的原 ordered
receipts，不重新发送、重写第一条或签新 anchor；single merged receipt、跳过 bound、顺序/PR identity不一致、
checkpoint/anchor不等或任一 cycle未确认均 `internal_durability_failure`且不释放 owner。

## Closed control API

machine registry exact 5 methods为 prepare_bootstrap_trusted_time、bootstrap、migrate、recover、ready；
每项的 request/success ref、role、policy branch、body CAS、error set与 replay class均由
[publication_authority_api.schema.json](publication_authority_api.schema.json) `x-gh700-method-registry.rows`唯一拥有。
control envelope包含 canonical 32-byte request nonce、authenticated principal与 repo identity。
control request/operation/result/response digest不在本文复制公式；exact surface domain、preimage与 consumer
同样只读 schema digest metadata并由 semantic verifier逐个重算。
永久 replay key同样绑定 authority/repo/principal/nonce；same bytes恢复同一 response，different bytes报
replay_conflict，任何 state-changing method在副作用前 FULL-fsync reserved row。

policy_binding 是 closed tagged union：

- prepare_bootstrap_trusted_time 只接受 prebootstrap_policy_binding =
  {binding_kind:"prebootstrap_projection",subject_policy_epoch,projection_digest,
  prebootstrap_time_approval_digest} 与 requested_peer_role=prebootstrap_time_operator；
- 其余四 method只接受 deployment_policy_binding =
  {binding_kind:"deployment_policy",policy_epoch,policy_bundle_digest}，role依次 exact 为
  bootstrap_operator、migration_operator、recovery_operator、readiness_observer。

pre-bootstrap branch不声明、伪造或别名 deployment policy bundle；projection及 approval digest从同一
closed bootstrap-time projection重算。DB/anchor任一存在即拒绝 prepare。release identity signature/root/
process/key先验验证；quorum形成后还必须要求 trusted_lower_bound >= valid_from_unix_seconds 且
trusted_upper_bound <= valid_until_unix_seconds，失败不得 freeze proof，host time不是替代品。
initial_time_proof_bundle只使用 trusted_time_nonce_digest；request_nonce_digest不是允许 alias。

bootstrap、migrate、recover各自 exact body/result及 receipt cardinality由 registry refs定义；deployment、
approval、migration/recovery manifest、bootstrap genesis/database/backup/anchor及 ready semantic object的
closed canonical bytes继续由 [history](publication_history_contract.md) 与
[authority protocol](publication_authority_protocol_contract.md) 唯一定义。migrate/recover body中的两
expected frontier必须 non-null并 strong-read byte-equal；bootstrap是 genesis-only，ready只读。
client transport identity不得调用 control surface；control peer也不得借 role调用未分配 method。

success与error均回显 operation request digest及 control_request_nonce_digest、携 frozen response nonce，
并签 response_digest。method-specific allowed error code取 registry row与 wire_error交集；
outcome_uncertain只可 same_request_read_confirm_only，unknown method/code/retry class、wrong policy branch、
role/body/result错配或 error/result并存均 fail closed。
## History-delegated trust revocation values

history contract仍唯一拥有 `trust_key_revoked` record/payload字段；本节唯一拥有
`revocation_reason_code` value set及 `replacement_key_or_bundle_digest_or_null` applicability。
reason exact closed union为
`{confirmed_key_compromise,suspected_key_compromise,key_material_unavailable,
signer_authorization_withdrawn,signer_decommissioned,cryptographic_profile_deprecated,
scheduled_replacement,superseded_by_rotation}`。前五种 removal-only reason要求 replacement literal null；
后三种 replacement reason要求 non-null。

fold须证明 `revoked_key_id`在 current epoch恰一 active且未 revoked，并非 bootstrap governance root/roster、
release-identity root或 break-glass root；这些 bootstrap-pinned identity只走 emergency contract。
non-null replacement须与 revoked key不同且不复用 key ID/version/SPKI；leaf只接受 next-epoch leaf
certificate digest，root/threshold signer只接受 next-epoch trust-bundle digest，且 normal approval/cutover后
维持 eligible signer threshold。null只在 removal后的 next state仍满足完整 threshold、class及独立管理域时
有效，否则须先完成 approved replacement rotation或走 emergency cutover。compromise/loss不得伪装成
scheduled/superseded reason；unknown/alias、wrong nullability/class、same-key replacement、quorum下降或
已 revoked key均拒绝。

## Ledger authorization and receipts

outer `ledger_append_authorization`与 method result中的 typed ledger/frontier/enumeration receipts只由
machine schema `$defs/authorization`、`$defs/typed_receipt`及各 registry `success_ref`拥有；本文不得复制字段清单、
签名 preimage或 receipt wire。其 semantic binding仍要求独立 ledger fence、exact blocked predecessor、
derived operation ID、authenticated principal与 policy byte-equal request/current fold；publication owner/fence不得
替代。receipt missing/extra field、wrong method/kind/cardinality/frontier或 verifier digest mismatch均拒绝。

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
terminal_listing_proof_capsules,terminal_attempt_reconciliations,reconciliation_watermarks}`、bootstrap/migration/recovery。两域共用 DB/WAL/FULL fsync、process lock、
snapshot与 external anchor，但使用独立 repository-ledger lease/fence、operation ID/index。

ledger frontier exact 为 `{repo_node_id,ledger_length,ledger_root,full_prefix_digest}`。record exact top-level
object为 `{schema_version,attempt_record_kind,repo_node_id,source_identity_key,run_id,run_attempt,
predecessor_frontier,payload}`；`attempt_record_kind` exact closed union为
`{candidate_failure,pipeline_interrupted,pipeline_interrupted_pre_attestation,
publication_recovery_binding}`。
`schema_version`必须 exact `GH700:blocked-attempt-record:v1`。
每个 frontier successor只 hash exact `ledger_leaf={schema_version,ledger_leaf_kind,repo_node_id,
predecessor_frontier,body}`，schema version exact `GH700:blocked-attempt-ledger-leaf:v1`且
`ledger_leaf_kind={attempt_record,reconciliation_watermark}`。attempt branch的 `body` byte-equal上述完整
attempt record且两个 repo/predecessor byte-equal；watermark branch的 `body` exact 为
`{terminal_listing_proof_digest,terminal_attempt_reconciliations,reconciliation_watermark}`，
reconciliations按 `terminal_attempt_key_digest` bytes升序。`record_digest=SHA256(JCS(ledger_leaf))`，编码为
lowercase `sha256:<64hex>`，并 byte-equal frontier receipt字段；binding receipt digest取其 attempt leaf
record digest。unknown leaf kind/body、attempt record直接绕过 envelope或 watermark不入 leaf均拒绝。

- `candidate_failure.payload` exact 为
  `{candidate_identity,failure_scope,target_or_null,required_platforms_or_null,
  failed_summary_digest_or_null,failure_manifest_jcs,failure_manifest_digest,bundle_digest,
  selected_policy,effective_action,closed_reason_code}`；`failure_scope={target,release}`，target branch要求
  non-null `target`且两个 release字段为 null，release branch反之。
- `pipeline_interrupted.payload` exact 为
  `{candidate_identity,staged_provenance_digest,interruption_conclusion,interruption_stage,
  publication_history_frontier,stage_operation_id,publish_sentinel_audit_digest,missing_evidence,
  selected_policy,effective_action,failure_manifest_jcs,failure_manifest_digest}`。
- `pipeline_interrupted_pre_attestation.payload` exact 为
  `{workflow_id,head_sha,server_ref_type,server_ref_name,event,conclusion,early_attempt_key,
  candidate_identity_or_null,selected_policy_or_null,staged_provenance_digest_or_null,
  evidence_identities_or_null,interruption_stage,missing_evidence,failure_manifest_jcs,failure_manifest_digest}`，
  四个 `*_or_null`字段必须 literal null。
- `publication_recovery_binding.payload` exact 为
  `{candidate_identity,publication_history_operation_id,publication_history_frontier,
  recovered_outcome_digest,binding_evidence_kind,terminal_attempt_key,terminal_listing_proof_digest,
  bound_attempt_record_digests}`。

unknown kind/field、missing/extra/null-not-declared或 alias拒绝。

下列 value sets同时约束 record、terminal listing与 watermark，不得由调用方扩展或建立 alias。
`candidate_failure`与`pipeline_interrupted`的 `selected_policy` exact closed union为
`{block_release,publish_nonvalid}`，`effective_action` exact singleton为 `block_release`；
pre-attestation的 `selected_policy_or_null`保持 literal null。其它值、两字段缺失、把 selected policy当作
effective action或在 pre-attestation填充值均 schema-invalid。
`terminal_conclusion` exact 为 `{failure,cancelled,timed_out}`，适用于
`pipeline_interrupted.interruption_conclusion`、`pipeline_interrupted_pre_attestation.conclusion`及
`terminal_attempt_key.conclusion`。`candidate_failure`只可对应 conclusion `failure`；两种 interruption
record的 conclusion必须 byte-equal terminal key。`publication_recovery_binding`可对应三种 conclusion，
但其 history outcome必须证明同一 terminal attempt。其它 provider conclusion保持 unreconciled并 fail closed。

`candidate_failure.closed_reason_code`按 `failure_scope`使用互斥 closed subsets。`target` exact 为
`{process_tree_unconfirmed,report_write_failed,report_schema_invalid,cleanup_failed,interrupted,
preflight_unavailable,report_provenance_invalid,evidence_schema_invalid,evidence_provenance_invalid,
checksum_invalid,effectiveness_unavailable,effectiveness_inconclusive,latency_unavailable,
latency_inconclusive}`；`release` exact 为
`{required_platform_input_missing,required_platform_input_invalid,required_platform_decision_mismatch,
summary_schema_invalid,summary_provenance_invalid,summary_aggregation_failed}`。scope/code交叉使用非法；同一
manifest命中多个 predicate时，primary code须取对应 subset上述书写顺序中第一个命中值，完整 manifest仍保留全部
closed categories。payload reason必须 byte-equal `failure_manifest_jcs`，不得创建 alias。

`interruption_stage` exact 为
`{pre_attestation,owner_claimed,draft_create_pending,draft_bound,prepared,decurrent_pr_pending,
valid_decurrent_pr_cancel_pending,valid_rollback_pending}`。`pipeline_interrupted_pre_attestation`只允许
`pre_attestation`；`pipeline_interrupted`禁止该值并须取 terminal event时 folded history的最后一个
effect-relevant pre-intent phase。heartbeat/takeover不改变 stage；`intent_written`及任何 post-intent phase
不可写 interruption，只可走 `recovered_publication`或`release_recovery_blocked`。

`missing_evidence`是以 `missing_evidence_kind`判别的 exact union：
`{missing_evidence_kind:"sealed_stage_evidence_missing",report_identity_or_null:null,
evidence_identity_or_null:null,checksum_identity_or_null:null,
missing_fields:["report_identity","evidence_identity","checksum_identity"]}`或
`{missing_evidence_kind:"pre_attestation_identity_missing",candidate_identity_or_null:null,
selected_policy_or_null:null,staged_provenance_digest_or_null:null,evidence_identities_or_null:null,
missing_fields:["candidate_identity","selected_policy","staged_provenance_digest","evidence_identities"]}`。
前者只用于 `pipeline_interrupted`，后者只用于 pre-attestation；数组 bytes、顺序、null与 payload中对应
字段必须 exact，missing/extra/duplicate/alias均 schema-invalid，并 byte-equal `failure_manifest_jcs`对应对象。

`failure_manifest_jcs`的 wire type是包含 UTF-8、无 BOM/尾换行 exact JCS bytes的 JSON string；
decoded object exact 为
`{schema_version,attempt_record_kind,repo_node_id,source_identity_key,run_id,run_attempt,payload_core,
reason_predicates}`，schema version exact `GH700:blocked-attempt-failure-manifest:v1`。
`payload_core` byte-equal attempt payload删除 `failure_manifest_jcs`与`failure_manifest_digest`后的 object；
对 `candidate_failure`还必须删除 `bundle_digest`，避免 manifest/bundle digest自引用。manifest完成后 outer
attempt payload的 `bundle_digest`单向绑定包含该 exact manifest bytes/digest的 immutable bundle，且不得回填
manifest或 predicate preimage。
candidate-failure的 `reason_predicates`是适用 scope上述 reason codes按书写顺序的完整 array，每项 exact
`{reason_code,matched,predicate_receipt_or_null,predicate_receipt_digest_or_null}`。
`reason_predicate_receipt` exact 为
`{schema_version,receipt_core,issuer_key_id,issuer_key_version,signature_b64url}`，schema version exact
`GH700:reason-predicate-receipt:v1`；`receipt_core` exact 为
`{repo_node_id,source_identity_key,run_id,run_attempt,predicate_subject_digest,reason_code,predicate_id,
matched,predicate_definition_digest,evaluator_identity_digest}`。
`predicate_subject_digest=SHA256(JCS({v:"GH700:reason-predicate-subject:v1",repo_node_id,
source_identity_key,run_id,run_attempt,candidate_identity,failure_scope,target_or_null,
required_platforms_or_null,failed_summary_digest_or_null,selected_policy,effective_action}))`。
`predicate_id`必须 byte-equal `reason_code`，且 target/release branch分别使用上述对应 closed reason subset，
形成逐 code 一一映射；不得使用 generic/alias predicate。receipt的 reason/predicate/definition/evaluator/
issuer ID/key version须 byte-equal deployment manifest exact `predicate_evaluator_roster`中的唯一 active entry；
签名 algorithm、message digest与 encoding只取该 roster的 singleton `signature_profile`，不得协商或 fallback。
`signature_b64url`须按该 profile为 RFC 4648 URL-safe、无 padding的 canonical Ed25519 signature bytes，并由
对应 roster entry的 `issuer_key_id/issuer_key_version/public_key_spki_der_b64url` decoded key验证，且重算
SPKI SHA-256 byte-equal `public_key_spki_sha256`，再验证
`SHA256(JCS({v:"GH700:reason-predicate-receipt-signature:v1",receipt_core}))`。
`predicate_receipt_digest=SHA256(JCS(reason_predicate_receipt))`并编码 lowercase `sha256:<64hex>`。
matched true iff对应 receipt的 core/signature/trust root、subject/code/policy全部验证且 `matched=true`，
此时 `predicate_receipt_or_null`须嵌入完整 exact receipt bytes且 digest字段须 byte-equal重算值；
false时两个 `*_or_null`都为 literal null。receipt bytes随 manifest永久保存，无外部 bundle/API依赖；
closed reason必须是第一个 matched code。两种 interruption的 array exact `[]`。manifest JSON paths固定为
`/payload_core/closed_reason_code`、`/payload_core/interruption_conclusion`、
`/payload_core/interruption_stage`、`/payload_core/missing_evidence`与 pre-attestation-only
`/payload_core/conclusion`；不适用 path必须 absent。
`failure_manifest_digest=SHA256(exact decoded JCS bytes)`并编码 lowercase `sha256:<64hex>`；payload相关字段
必须 byte-equal对应 path。unknown/乱序/缺 predicate、receipt/boolean不一致或 digest mismatch拒绝。

`pipeline_interrupted.interruption_stage`从其 signed `publication_history_frontier` fold exhaustive投影，且
`stage_operation_id`必须是该 frontier中建立投影状态的 exact latest effect-relevant operation：

- `owner_claimed`：claim/heartbeat/takeover phase且无 draft-create slot/effect；
- `draft_create_pending`：存在未闭合 draft-create planned/recovery slot或 claim-nonce draft尚未 bind；
- `draft_bound`：exact draft bound且未 prepared；
- `prepared`：prepared/zero-receipt phase，且无 effective de-current plan/bound/merge；
- `decurrent_pr_pending`：prepared后存在未关闭 de-current generated-PR planned/bound；
- `valid_decurrent_pr_cancel_pending`：latest effect phase是同名 committed record；
- `valid_rollback_pending`：de-current已 merged或 latest effect phase是同名 committed record。

generated-PR not-applied/revoked回到 `prepared`；任何 recovery-blocked、intent或 post-intent phase不能投影为
interruption。authority必须复算 frontier签名、operation membership与投影；并要求 frontier的
`repo_node_id`、fold重算的 source identity、current owner的 `run_id/run_attempt/candidate_identity`分别
byte-equal attempt top-level `repo_node_id/source_identity_key/run_id/run_attempt`及 payload candidate，
`stage_operation_id`须属于该 exact frontier、same owner generation与 same run/candidate chain且是 latest
effect-relevant operation。任一 cross-repo/source/run/attempt/candidate/owner-generation引用均拒绝；
client label不是真源。

## Subject identity and binding

pre-attestation identity只使用下列 domain-separated canonical派生：
`source_identity_key=SHA256(JCS({v:"GH700:source-identity:v1",repo_node_id,workflow_id,head_sha,
server_ref_type,server_ref_name}))`；
`early_attempt_key=SHA256(JCS({v:"GH700:early-attempt:v1",source_identity_key,run_id,run_attempt,event}))`。
结果都编码为 lowercase `sha256:<64hex>`；tuple不同却 digest相同永久冲突，调用方提交的 key只作
byte-equal assertion，不能成为 authority输入真源。

authority从 submitted blocked-attempt record内的 closed `attempt_subject`派生
`attempt_subject_key=SHA256(JCS({v:"GH700:attempt-subject:v1",attempt_record_kind,
candidate_identity_or_null,failure_scope_or_null,target_or_null,early_attempt_key_or_null}))`。
`candidate_failure`写 candidate+scope及 target-or-null；`pipeline_interrupted`与
`publication_recovery_binding`写 candidate且其余 null；pre-attestation kind只写 early-attempt key。
record `object_digest`覆盖该 subject；`append_blocked_attempt.expected_attempt_subject_key`必须
byte-equal重算值。不存在与 submitted record并列的独立 subject authority输入。

binding_intent及其 binding_evidence exact closed union由 machine schema定义：

- authenticated_terminal_recovery 携 terminal attempt/proof digest及 expected/current/predecessor三个
  blocked frontier，明确禁止 enumeration snapshot与 source record list；
- source_attempt_records 另必须携 enumeration snapshot receipt digest、snapshot frontier及按 bytes
  升序 distinct、non-empty的 source record digests。

两 branch都要求 body expected/current/predecessor三 frontier与 request envelope
expected_blocked_attempt_frontier_or_null byte-equal。仅 source_attempt_records branch再要求
snapshot_frontier与这四者 byte-equal；authenticated_terminal_recovery不得读取、合成或验证不存在的
enumeration snapshot。任一 current推进都在同一 BEGIN IMMEDIATE transaction报 stale_frontier。
source branch须完整分页证明 digest list byte-equal该 tuple全部 eligible、unbound
failure/interruption records而非 subset/superset；terminal branch只在 exact tuple不存在任何 eligible
source truth时允许。

两 branch都须验证 terminal proof全分页、server-auth/ref-aligned，terminal key恰一存在且
source/run/candidate/conclusion byte-equal intent；strong-read并 anchor-verify history frontier，证明
operation exact 为同 candidate/run intent chain的 recovered_publication，并重算 domain-separated
recovered outcome digest。
authority只按 intent构造 `publication_recovery_binding`。authenticated-terminal branch的
`bound_attempt_record_digests=[]`；source-record branch byte-equal intent digest list。两者都写
`binding_evidence_kind`、terminal key与 `terminal_listing_proof_digest=SHA256(JCS(terminal_listing_proof))`。
若 tuple已有 eligible failure/interruption truth，必须走 source-record branch。任一
`terminal_attempt_reconciliation`存在后，`append_blocked_attempt`对该 tuple只可 same-existing-record幂等返回，
任何新增或 different bytes failure/interruption永久冲突；direct/source binding后的 late append都拒绝。
任何 already-bound、cross-source/candidate/conclusion、missing、unanchored或 ambiguous evidence拒绝。
client不得提交 record body或 subject key。

`terminal_attempt_reconciliation` exact 为
`{terminal_attempt_key_digest,terminal_listing_proof_digest,resolution_kind,resolution_record_digests,
source_record_set_digest_or_null,publication_history_operation_id_or_null}`；
`resolution_kind={failure_record_set,publication_recovery_binding}`。
failure branch的 record list是该 terminal attempt全部 eligible target/release/interruption records按 digest bytes
升序去重后的非空完整集合，source-set digest non-null、history op null；recovery branch恰含一个 binding
record digest、history op non-null，authenticated-terminal branch source-set null，source-attempt-records
branch source-set non-null且 byte-equal其 bound digest list的重算值。永久 unique index
`(repo_node_id,source_identity_key,run_id,run_attempt)`使 same bytes幂等、different candidate/conclusion/
record set/history op冲突。proof capsule、binding/reconciliation record、frontier与 anchor在同一事务提交。

## Stable enumeration

第一页要求 `page_cursor_or_null=null`；authority在同一 committed ledger frontier创建
`enumeration_snapshot_receipt={repo_node_id,query_digest,snapshot_frontier,snapshot_record_set_digest,
page_size,issuer_key_id,signature_digest}`。`enumeration_query` exact 为
`{repo_node_id,source_identity_key,candidate_identity_or_null,run_id_or_null,run_attempt_or_null,
attempt_record_kind_or_null,attempt_subject_key_or_null}`；
`query_digest=SHA256(JCS({v:"GH700:blocked-attempt-enumeration-query:v1",enumeration_query}))`；
`snapshot_record_set_digest=SHA256(JCS(record_digest bytes升序、去重的该 query在 snapshot frontier全部
matching records数组))`。两个 digest编码 lowercase `sha256:<64hex>`，receipt signature覆盖除
`signature_digest`外的 exact fields。`page_cursor`是 store-signed opaque token，内部绑定该 receipt digest、
下一 canonical record key与 expiry policy digest；后续页必须使用同 snapshot frontier/query/page size。
`attempt_records`按 `(source_identity_key,run_id,run_attempt,attempt_record_kind,attempt_subject_key,record_digest)`
bytewise排序。任一页缺失、重复、cursor/query/frontier drift或无法完成全分页使 completeness证明失败。

## Terminal listing proof and reconciliation watermark

`terminal_attempt_key` exact 为
`{workflow_id,run_id,run_attempt,event,conclusion,source_identity_key,candidate_identity_or_null}`，其中
`conclusion={failure,cancelled,timed_out}`且 byte-equal前述 `terminal_conclusion`；列表按
`(workflow_id,run_id,run_attempt,event)`升序且无重复。
`terminal_attempt_key_digest=SHA256(JCS(terminal_attempt_key))`；
`source_record_set_digest=SHA256(JCS(digest-bytes升序、去重的 exact source record digest array))`；
`recovered_publication_payload_digest=SHA256(JCS(exact recovered_publication payload))`；三者都编码为
lowercase `sha256:<64hex>`。`terminal_listing_proof` exact 为
`{schema_version,provider,repo_node_id,source_identity_key,candidate_identity_or_null,server_query_digest,
page_receipt_digests,terminal_attempt_keys,terminal_attempt_keys_digest}`，其中 provider exact 为
`github_actions_server_terminal_runs_v1`；page receipt按 server page顺序保留，且
`terminal_attempt_keys_digest=SHA256(JCS(terminal_attempt_keys))`。proof capsule必须保存全部 authenticated
server response bytes/digests、pagination completion、permissions与 ref alignment。`server_query_plan` exact 为
`{schema_version,provider,repo_node_id,source_identity_key,candidate_identity_or_null,terminal_streams,
conclusion_audit}`，schema version exact `GH700:terminal-listing-query-plan:v1`。
`terminal_streams` exact 为按 ASCII固定顺序 `[cancelled,failure,timed_out]` 的三项 array，每项 exact
`{conclusion,request_jcs,request_digest,page_receipt_digests,pagination_completion_digest}`；decoded
`request_jcs` exact 为 `{provider,repo_node_id,source_identity_key,candidate_identity_or_null,conclusion,
page_size}`且 filter由 server-side执行，`request_digest=SHA256(exact JCS bytes)`。
`conclusion_audit` exact 为
`{request_jcs,unfiltered_request_digest,page_receipt_digests,pagination_completion_digest,
observed_conclusions}`，其 decoded request object与 stream相同但无 `conclusion`，digest同样从 exact bytes重算；
observed array按 ASCII升序去重。`server_query_digest=SHA256(JCS(server_query_plan))`并编码 lowercase
`sha256:<64hex>`；proof keys只能来自三条完整 terminal streams。closed nonblocking conclusion仅
`{success,skipped}`，它们不进 proof/count/max/set且不阻塞；audit发现 `neutral`、unknown或其它表外值，
任一 stream/audit分页不完整、filter/query/receipt drift均 fail closed。workflow input/artifact/free text、
client-side过滤或省略 audit均无效。
proof schema version exact `GH700:terminal-listing-proof:v1`。
`terminal_listing_proof_digest=SHA256(JCS(terminal_listing_proof))`。durable
`terminal_listing_proof_capsule` exact 为
`{terminal_listing_proof_digest,provider_response_capsule_id,provider_response_bytes_digest,
server_query_plan_jcs,server_query_plan_digest,combined_page_receipt_digests,pagination_completion_digest,
permissions_digest,ref_alignment_digest}`。plan字段保存 exact UTF-8 JCS bytes且重算 digest须 byte-equal
proof的 `server_query_digest`；combined receipts exact 为
`cancelled pages || failure pages || timed_out pages || conclusion-audit pages`并 byte-equal proof的
`page_receipt_digests`。每个 request digest均从 plan内保存的 exact request bytes重算。capsule ID只定位同
transaction持久化的 encrypted exact response bytes，不能替代 digest/bytes。proof、capsule、response bytes及
KMS retention refs无 TTL，并由 watermark/binding digest引用。

`reconciliation_watermark` exact 为
`{schema_version,repo_node_id,source_identity_key,candidate_identity_or_null,terminal_listing_proof_digest,
max_terminal_run_id,max_terminal_run_attempt,terminal_attempt_count,covered_record_digests,
covered_record_set_digest,prior_watermark_digest_or_null}`。`covered_record_digests`按 digest bytes升序、去重；
schema version exact `GH700:reconciliation-watermark:v1`；
`covered_record_set_digest=SHA256(JCS(covered_record_digests))`；
`watermark_digest=SHA256(JCS(reconciliation_watermark))`。两个 digest 都编码为 lowercase
`sha256:<64hex>`。max tuple是按 unsigned numeric
`(run_id,run_attempt)`按解码后的 unsigned logical values排序后的最后一项；空 terminal listing禁止 commit watermark。

authority提交 watermark前必须：

1. 重算并验证 server query plan、三条 terminal streams与 unfiltered conclusion audit，证明 listing proof是
   三种 terminal conclusion的全分页 server-authenticated exact集合、candidate/source exact且 digest匹配，
   且 observed conclusions除这三种与 `{success,skipped}`外为空；
2. 重算 proof中每个 `terminal_attempt_key_digest`；要求 reconciliation array无重复，
   `terminal_attempt_reconciliations.length == terminal_attempt_count == terminal_attempt_keys.length`，
   reconciliation key digest set与 proof key digest set byte-exact相等、无 missing/extra；watermark字段与
   watermark leaf外层 proof digest须 byte-equal当前 `SHA256(JCS(terminal_listing_proof))`。每个 reconciliation
   的创建时 `terminal_listing_proof_digest`须指向可永久读取并验证的 proof capsule，且该旧 proof恰含同一个
   terminal key；不得要求旧 proof digest等于当前增量 listing proof。failure resolution可对应同一 matrix
   attempt的多个 target-scoped records或一个 release/interruption record；recovery resolution对应一个
   binding，并须读取该 binding payload，重算其 `terminal_attempt_key_digest`且要求 key/proof digest分别
   byte-equal reconciliation key与该 reconciliation的创建时 proof digest；当前 proof只需包含 byte-equal同 key。
   每个 resolution record的 repo/source/run tuple、candidate与 terminal outcome须 byte-equal该 key；
3. 证明 `covered_record_digests`与所有 reconciliation的 `resolution_record_digests`完整 union相等，而非
   subset/superset，且每个 record只计一次；binding的 source records不重复计入 recovery resolution；
4. 重算 count、max tuple、record-set digest，并以 CAS验证 latest watermark digest；
5. 在同一 transaction写 proof capsule/response bytes、reconciliations、watermark、frontier successor与 permanent
   indexes，FULL fsync并完成 external anchor。

terminal listing/permanent record不可用、存在未 reconciled attempt、内容冲突、旧 max tuple、subset watermark、
candidate/source歧义或 anchor ack不确定均 fail closed；新 attempt及 publish gate不能越过失败 watermark。

## Durability and retention

append在同一 `BEGIN IMMEDIATE` transaction验证 expected frontier、ledger lease/fence，并以永久 unique index
`(repo_node_id,source_identity_key,run_id,run_attempt,attempt_record_kind,attempt_subject_key)`做 same-bytes幂等、
different-bytes冲突。完整 canonical manifest bytes、record、binding/reconciliation/proof capsule/frontier/
watermark写入后 FULL fsync，且同一
frontier CAS external anchor成功或 read-confirm exact ack后才返回 signed receipt。

records/manifest bytes/frontiers/bindings/reconciliations/terminal proof capsules+response bytes/watermarks无
TTL、无 delete/truncate/overwrite；artifact retention、
owner terminal、candidate publish或 schema migration均不缩短 retention。snapshot/WAL restore必须达到 external
anchor的 `blocked_attempt_ledger_frontier`，重放全部 records/unique indexes/bindings/reconciliations/proof
capsules/response bytes/watermarks并核对 full-prefix。
缺 manifest bytes、older/forked frontier或未闭合 terminal attempt时 authority non-ready且 publish gate blocked。
真实 durable-volume fixture须覆盖 concurrent append、same-key different bytes、pagination snapshot drift、subset
watermark、multi-target complete-set、direct-recovery/late-failure冲突、proof-capsule/response deletion、
max-run rollback、crash/fsync/disk-full、artifact deletion、snapshot rollback与 exact manifest恢复；mock不算通过。
