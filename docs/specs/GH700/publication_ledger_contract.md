# GH700 Publication Authority API, Delegated Values And Blocked-Attempt Contract

本文件是 [publication_history_contract.md](publication_history_contract.md) 与
[publication_authority_protocol_contract.md](publication_authority_protocol_contract.md) 的规范性组成部分，唯一拥有
`client_api`/`control_api` wire schema、history显式委托的 value sets与 B-029 blocked-attempt ledger。product/tech/tasks只可链接或引用这里的
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
| `deliver_release_mutation` | `{planned_operation_id,broker_delivery_id,delivery_authorization}` | `{delivery_state,transition_receipt,send_once_audit_digest}` |
| `recover_release_mutation` | `{planned_operation_id,recovery_query_digest,append_authorization}` | `{recovery_state,transition_receipt}` |
| `plan_generated_pr` | `{intent,append_authorization}` | `{planned_transition_receipt,generated_pr_delivery_id}` |
| `deliver_generated_pr` | `{planned_operation_id,generated_pr_delivery_id,delivery_authorization}` | `{delivery_state,transition_receipt_or_null,send_once_audit_digest}` |
| `recover_generated_pr` | `{planned_operation_id,recovery_query_digest,append_authorization}` | `{recovery_state,transition_receipts}` |
| `append_blocked_attempt` | `{attempt_record,expected_attempt_subject_key,ledger_append_authorization}` | `{attempt_record_receipt,blocked_attempt_frontier_receipt}` |
| `bind_blocked_attempt` | `{binding_intent,ledger_append_authorization}` | `{binding_record_receipt,blocked_attempt_frontier_receipt}` |
| `list_blocked_attempts` | `{source_identity_key,candidate_identity_or_null,run_id_or_null,run_attempt_or_null,attempt_record_kind_or_null,attempt_subject_key_or_null,page_cursor_or_null,page_size}` | `{attempt_records,next_page_cursor_or_null,enumeration_snapshot_receipt}` |
| `commit_reconciliation_watermark` | `{reconciliation_watermark,terminal_listing_proof,ledger_append_authorization}` | `{watermark_receipt,blocked_attempt_frontier_receipt}` |
| `get_blocked_attempt_frontier` | `{}` | `{blocked_attempt_frontier_receipt}` |

`time_bound_intent` exact 为 `{record_kind,execution_identity,client_payload_core,predecessor_frontier}`；
`execution_identity` exact 为 `{run_id,run_attempt,transition_slot}`：`run_id`须是
`1..9007199254740991`、`run_attempt`须是 `1..4294967295`、`transition_slot`须是
`0..9007199254740991` 的 canonical JSON integer。负数、float、`-0`、越界值、decimal string、alias或额外字段
均拒绝；上游 u64 identity超过 safe-integer上限时 publication为 `unavailable`，不得 lossy转换或进入 digest。method与
`record_kind`只允许 `{claim_publication_owner:owner_claimed,renew_publication_owner:owner_heartbeat,
takeover_publication_owner:publication_owner_taken_over}`。client计算
`time_bound_request_id=SHA256(JCS({v:"GH700:time-bound-request:v1",repo_node_id,method,
time_bound_intent}))`，authority须在任何 nonce issuance前从 wire bytes重算。request envelope的
`expected_publication_frontier_or_null`必须 non-null且 byte-equal
`time_bound_intent.predecessor_frontier`；任一 null/mismatch报 `invalid_request`。

`secret_channel_binding` exact 为
`{schema_version:"GH700:secret-channel-binding:v1",channel_kind:"authority_mtls_exporter_v1",authority_id,
repo_node_id,method,secret_channel_request_core_digest,peer_identity_digest,server_identity_digest,
tls_exporter_context_digest,tls_exporter_keying_material_digest,secret_slot_ids}`。先从 request envelope删除
`operation_request_digest`，并从 body删除 `secret_channel_binding`，得到 exact
`secret_channel_request_core`；core不得保留占位 null，digest exact 为
`SHA256(JCS({v:"GH700:secret-channel-request-core:v1",request:secret_channel_request_core}))`。
TLS exporter label exact `EXPORTER-GH700-secret-channel-v1`，context bytes是
`JCS({v:"GH700:secret-channel-exporter-context:v1",authority_id,repo_node_id,method,
secret_channel_request_core_digest,peer_identity_digest,server_identity_digest})`，两个 exporter digest分别是
context bytes与 exact 32-byte exporter output的 SHA-256。peer/server identity须从当前 verified mTLS session与 manifest
重算，不能信任 wire。claim的 `secret_slot_ids` exact 为 `["draft_claim_nonce"]`，plan Release mutation exact 为
`["mutation_nonce"]`；其它 method禁止该字段。binding只授权同一 session返回对应 opaque capsule，不含 raw secret；
same binding/same request幂等恢复，跨 method/request/session/peer/server重放或 non-mTLS/empty exporter在 nonce
issuance前报 `unauthenticated`。最终 `operation_request_digest`才覆盖含完整 binding的 envelope。

`publication_lease_authorization` exact 为
`{lease_scope,lease_token_digest,publication_fence,authenticated_actor_digest,authorization_policy_digest,
authorized_method,authorized_time_bound_request_id,execution_identity}`；`lease_scope`必须 exact
`repository_publication_owner_v1`，其 detached digest exact 为
`SHA256(JCS({v:"GH700:publication-lease-authorization:v1",repo_node_id,publication_lease_authorization}))`。
`authorized_method`、`authorized_time_bound_request_id`与 `execution_identity`必须分别 byte-equal wire method、
authority重算的 request ID与 `time_bound_intent.execution_identity`；missing/extra/alias、scope/fence/actor/policy
不符都在 nonce/TSA/append前拒绝。claim/takeover core中的同名 run tuple/slot必须 byte-equal该 identity；heartbeat
的 run tuple由 identity唯一提供。三种 time-dependent operation ID、preparation、nonce/proof request与 final intent
只能从该 identity派生，禁止从 mutable authorization envelope、ambient run或 payload alias另取值。

`client_payload_core`是 method-tagged closed union：claim exact
`{owner_generation,run_id,run_attempt,transition_slot,candidate_tag_identity_digest,frozen_plan_digest,
liveness_policy_digest}`；heartbeat exact
`{owner_generation,heartbeat_sequence,prior_liveness_operation_id,transition_slot,liveness_policy_digest}`；
takeover exact `{run_id,run_attempt,transition_slot,candidate_tag_identity_digest,prior_owner_generation,
new_owner_generation,liveness_policy_digest}`。claim branch同时定义
`claim_pre_nonce_core_digest=SHA256(JCS({v:"GH700:claim-pre-nonce-core:v1",repo_node_id,
time_bound_request_id,client_payload_core,predecessor_frontier}))`。client不得提交 prior/new high water、
draft-claim nonce/capsule、trusted-time nonce/proof/interval/accepted time、expiry/slot-chain evidence或其它
authority字段；T3从 signed fold独占派生 prior high water、current owner/run/lease/slot、expiry/slot-chain
evidence。三种 method除 claim独有 `secret_channel_binding`外使用同一 proof-ownership boundary；
unknown/extra/cross-branch field一律拒绝。
takeover request的 `run_id/run_attempt`必须 byte-equal最终 history payload的
`new_owner_run_id/new_owner_run_attempt`；terminal cleanup的 run tuple不得接受 client truth，必须由 signed
fold中 terminal generation-origin唯一派生。任一 request/payload/fold替换在 operation-ID lookup前拒绝。

上述三个 request 都不是 immutable history intent。client不得提交 final intent/payload/digest/operation ID、
TSA endpoint/policy/signer配置、takeover expiry/slot-chain evidence或任何 authority-only字段。authority验证
auth/frontier/request后，从 signed fold读取 owner/run/lease/slot/high-water state，并按
[authority protocol](publication_authority_protocol_contract.md#authority-owned-time-bound-payload-cores)的 exact schema/order
派生 claim operation→reserve/capsule→core→proof request，或 heartbeat/takeover core→proof request→operation；
TSA unavailable时零 transition且不得回退 host/client time。authority-owned preparation exact 为
`trusted_time_preparation={authority_id,repo_node_id,method,operation_request_digest,predecessor_frontier,
time_bound_request_id,record_kind,owner_generation,run_id,run_attempt,transition_slot,claim_pre_nonce_core_digest_or_null,
publication_payload_core_digest_or_null,prior_time_high_water,claim_nonce_digest_or_null,
claim_nonce_capsule_id_or_null,claim_capsule_ciphertext_digest_or_null,claim_kms_key_version_or_null,
trusted_time_nonce_digest_or_null,trusted_time_nonce_capsule_id_or_null,
trusted_time_capsule_ciphertext_digest_or_null,trusted_time_kms_key_version_or_null,
trusted_time_proof_request_id_or_null,transition_operation_id,preparation_state,proof_capsule_digest_or_null,
final_payload_digest_or_null,final_intent_digest_or_null,committed_receipt_digest_or_null,
anchor_receipt_digest_or_null}`。claim state exact 单调为
`claim_reserved→claim_capsule_frozen→prepared→proof_frozen→transition_committed→anchor_confirmed`；
heartbeat/takeover从 `prepared`开始。claim须在任何 draft nonce/capsule生成前，以 operation/request/pre-nonce
identity写 `claim_reserved`并 FULL fsync；nonce issuance keyed by `transition_operation_id`且只允许一次，完整
nonce/capsule bytes/digests/KMS refs原子写入并 FULL fsync成 `claim_capsule_frozen`。崩溃重试只能取回同一
frozen capsule；之后 T3按 authority protocol加入 fold-owned high water/evidence构造 publication core与 trusted-time nonce/proof
request，并在首次 TSA I/O 前 FULL fsync成 `prepared`。所有 `*_or_null`只可按顺序 null→non-null且不得覆写，
非 claim的全部 `claim_*_or_null`必须 literal null。TSA验证后须在 append前原子持久化完整 token proof capsule、
final payload/intent bytes及 digests并 FULL fsync成 `proof_frozen`；commit与 anchor各自再 durable推进。
same request重试先查 request/operation：
anchor-confirmed返原 receipt；committed恢复同一 anchor；proof-frozen续同一 append；prepared续同一 proof request；
claim-capsule-frozen续同一 trusted preparation；claim-reserved续同一 capsule issuance；只有尚未提交且
predecessor被其它 operation推进才 deterministic stale-frontier。不得签发第二 capsule/nonce/request/operation/
proof/final payload。preparation中的 `run_id/run_attempt/transition_slot`必须 byte-equal `execution_identity`；
authority不得在 fold、authorization refresh或 retry时改写它们。
authority须永久 UNIQUE `(repo_node_id,method,time_bound_request_id)`并保存
`trusted_time_reauthorization_index(operation_request_digest→time_bound_request_id)`。fresh lease/fence
authorization先重算同一 time-bound ID：same ID/same intent只把新 authorization envelope digest映射到原 preparation，
从其 durable state恢复；same ID/different intent永久 `operation_conflict`。不得因
`operation_request_digest`变化建立第二 preparation/capsule/nonce/proof/operation。

method partition exact：`owner_claimed`只可由 `claim_publication_owner`、`owner_heartbeat`只可由
`renew_publication_owner`、`publication_owner_taken_over`只可由 `takeover_publication_owner`构造；
`append_publication_transition`遇到三者必须在 proof/TSA/append前报 `method_not_allowed`，不能接受 client final intent。

`deliver_generated_pr.generated_pr_delivery_id`只是 client assertion；authority必须按 root contract从已提交
`planned_operation_id`重算并要求 byte-equal，mismatch在 broker enqueue前报 `invalid_request`。
same plan/different ID或 same ID/different plan报 `operation_conflict`；uncertain delivery只能 read-confirm/recover，
不得以 fresh ID再次发送。

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

`deliver_generated_pr.delivery_state` exact closed union为 `{bound,recovery_required}`。
`bound`要求 `transition_receipt_or_null` non-null且 exact 为 anchored `generated_pr_bound`；
`recovery_required`要求 literal null，只能在 send-once audit已 durable且 authenticated send可能生效、但唯一 exact
PR/ref尚不能 read-confirm并提交 bound successor时返回。两种 state的 `send_once_audit_digest`都须 non-null并绑定同一
plan/delivery ID；replay只返原 state/result，`recovery_required`后只可调用 `recover_generated_pr`，不得再次 deliver。
若可能 send却连 send-once audit都不能 durable证明，返回 `outcome_uncertain` error而非 success。unknown state、
wrong nullability、bound未 anchor或 recovery-required夹带 receipt均 schema-invalid。

`deliver_release_mutation.delivery_state` exact closed union为 `{bound,recovery_pending}`。
`bound`要求 singular `transition_receipt` exact 为 `release_mutation_bound`；`recovery_pending`要求 exact 为
`release_mutation_recovery_pending`。successful response不存在 null receipt；若 authenticated send后连 pending
transition都无法 durable commit/anchor，返回 `outcome_uncertain` error而非 success。replay只返回原
state/receipt/audit且不得第二次 send；`recovery_pending`只允许 read-confirm/recover，不得调用 deliver重发。

`recover_release_mutation.recovery_state` exact closed union为
`{bound,recovery_pending,not_applied,compensated,blocked}`，其 singular `transition_receipt` applicability exact 为：
`bound→release_mutation_bound`、`recovery_pending→release_mutation_recovery_pending`、
`not_applied→release_mutation_not_applied`、`compensated→compensated`；`blocked`在原
`mutation_kind=draft_create`时只可 `draft_recovery_blocked`，其它五 kind只可
`release_mutation_recovery_blocked`。compensation中断只能恢复原 operation chain；成功只返回最终
`compensated` receipt并由 operation-ID refs证明链。bound只接受唯一 exact post-state，not-applied只接受
exact pre-state+exhaustive-negative+broker-quiescence；pending/in-flight不得伪装 not-applied，
partial/multiple/conflicting state不得伪装 bound。unknown state、wrong/null/extra receipt或交叉 kind均拒绝。

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
issued_at_unix_seconds,expires_at_unix_seconds}`；permissions按 UTF-8 bytes升序去重，两个 times是 nonnegative
u64且 issued<expires，App/installation/repo/scope须 byte-equal plan，
`authorization_context_digest=SHA256(JCS(authorization_context))`。raw Authorization不得持久化。
`body_bytes_digest=SHA256(exact body bytes)`，`body_length`是这些 bytes的 nonnegative u64 count；
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

`control_api.method` exact closed union为 `{bootstrap,migrate,recover,ready}`。request envelope exact 为
`{api_version,method,authority_id,authority_identity_digest,policy_epoch,policy_bundle_digest,request_nonce,
requested_peer_role,operation_request_digest,body}`；`operation_request_digest`是删除自身字段后完整 envelope
的 JCS SHA-256并编码 lowercase `sha256:<64hex>`。request nonce须为 fresh 32-byte CSPRNG value的
canonical unpadded base64url；response nonce同格式且由 authority独立生成。

| method | exact request `body` | exact success `result` |
| --- | --- | --- |
| `bootstrap` | `{control_operation_id,deployment_manifest,bootstrap_approval,release_identity_attestation,initial_time_proof_bundle}` | `{control_operation_receipt,bootstrap_receipt,ready_receipt}` |
| `migrate` | `{control_operation_id,target_deployment_manifest,migration_plan,migration_approval,expected_schema_version,expected_publication_frontier,expected_blocked_attempt_frontier}` | `{control_operation_receipt,migration_receipt,ready_receipt}` |
| `recover` | exact `recovery_request` tagged union | `{control_operation_receipt,recovery_receipt,ready_receipt}` |
| `ready` | `{minimum_schema_version,expected_policy_epoch_or_null}` | `{ready_result}` |

`deployment_manifest`/`target_deployment_manifest`与 `bootstrap_approval` exact复用 history contract的 closed
deployment/bootstrap objects，不存在 `bootstrap_manifest_approval` alias。
`deployment_manifest_digest=SHA256(JCS(deployment_manifest))`且 bootstrap时须 byte-equal history的
`bootstrap_manifest_core_digest`；target manifest同式重算。
manifest `control_api.response_signing_key` exact为
`{signature_profile:"ed25519_sha256_jcs_v1",key_id,key_version,public_key_spki_der_b64u,
public_key_spki_sha256}`；version是 nonzero u64，SPKI是 canonical unpadded base64url的 RFC5280 Ed25519
DER且 decoded SHA-256须 byte-equal digest。`response_signing_key_digest=SHA256(JCS(response_signing_key))`。
`release_identity_attestation` exact为
`{schema_version:"GH700:release-identity-attestation:v1",release_identity_root_digest,authority_id,
authority_identity_digest,server_process_identity_digest,response_signing_key_digest,
valid_from_unix_seconds,valid_until_unix_seconds,issuer_key_id,issuer_key_version,signature_b64u}`；
签名 profile exact `ed25519_sha256_jcs_v1`，签删除 `signature_b64u`后的 object之
`SHA256(JCS({v:"GH700:release-identity-attestation-signature:v1",attestation_core}))`，两 times为 u64且
from<until；root/authority/process/response key须 byte-equal manifest。
`release_identity_attestation_digest=SHA256(JCS(release_identity_attestation))`。
`initial_time_proof_bundle` exact为
`{schema_version:"GH700:initial-time-proof-bundle:v1",repo_node_id,quorum_policy_digest,proofs,
trusted_lower_bound_unix_seconds,trusted_upper_bound_unix_seconds,initial_time_high_water}`；proofs按
`(tsa_endpoint_identity_digest,token_digest)` UTF-8 bytes升序、distinct quorum且每项 exact
`{purpose:"bootstrap_initial_time",trusted_time_replay_identity,trusted_time_proof_request_id,
message_imprint_sha256,tsa_endpoint_identity_digest,policy_oid,request_nonce_digest,token_der_b64u,token_digest,
lower_bound_unix_seconds,upper_bound_unix_seconds}`，token digest须等于 DER bytes SHA-256且所有 purpose/subject/
nonce/request/imprint/interval/quorum/high-water须按
[authority protocol](publication_authority_protocol_contract.md#trusted-time-proof-profiles)重算。
`initial_time_proof_bundle_digest=SHA256(JCS(initial_time_proof_bundle))`。

`migration_plan` exact为
`{schema_version:"GH700:authority-migration-plan:v1",authority_id,source_schema_version,
target_schema_version,source_deployment_manifest_digest,target_deployment_manifest_digest,
expected_publication_frontier,expected_blocked_attempt_frontier,schema_artifact_digest,
migration_executable_digest,expected_post_state_digest}`，只允许 target version严格更高且 append-only；
`migration_plan_digest=SHA256(JCS(migration_plan))`，body中三 expected字段须 byte-equal plan。
manifest `control_approval_policy` exact为
`{schema_version:"GH700:control-approval-policy:v1",entries}`；entries按 approval kind UTF-8 bytes升序且
恰好覆盖 `{migration,anchored_snapshot_restore,break_glass_restore}`，entry exact为
`{approval_kind,signer_class,roster_digest,threshold,signers}`，signer exact为
`{key_id,key_version,public_key_spki_der_b64u,public_key_spki_sha256,management_domain_digest}`并按
`(key_id,key_version)`排序 distinct；threshold为 nonzero u64且不大于 signer count。signer class分别 exact
`{migration_maintainer,restore_maintainer,cold_break_glass_recovery}`；三个 roster/key/management-domain set
互不重叠，break-glass entry的 roster/threshold/key IDs须 byte-equal history `break_glass_governance`。
`control_approval_policy_digest=SHA256(JCS(control_approval_policy))`并由 bootstrap approval随 manifest签入。
`control_approval` exact为
`{schema_version:"GH700:control-approval:v1",approval_kind,approved_core_digest,approver_roster_digest,
threshold,signer_key_ids,threshold_signatures}`；approval kind exact union
`{migration,anchored_snapshot_restore,break_glass_restore}`，signer IDs按 UTF-8 bytes升序 distinct，
signature entry exact `{signer_key_id,signer_key_version,signature_b64u}`且同序，exact threshold个
manifest-pinned eligible signer使用 `ed25519_sha256_jcs_v1`签
`SHA256(JCS({v:"GH700:control-approval-signature:v1",authority_id,approval_kind,
approved_core_digest}))`。roster/threshold/key versions须 byte-equal该 kind唯一 policy entry且 signer
management domains distinct；cross-kind roster/key/class复用拒绝。`migration_approval`须为该 object且
kind=migration、core digest等于 plan digest。

`recovery_request` exact tagged union为
`{control_operation_id,recovery_kind:"restart_replay",deployment_manifest,recovery_manifest,expected_anchor_head_digest}`、
`{control_operation_id,recovery_kind:"anchored_snapshot_restore",deployment_manifest,recovery_manifest,
expected_anchor_head_digest,backup_set_ref,restore_approval}`或
`{control_operation_id,recovery_kind:"break_glass_restore",deployment_manifest,recovery_manifest,
expected_anchor_head_digest,backup_set_ref,recovery_incident_id,break_glass_recovery_approval}`。
`recovery_manifest` exact为
`{schema_version:"GH700:authority-recovery-manifest:v1",recovery_kind,authority_id,
deployment_manifest_digest,expected_anchor_head_digest,expected_publication_frontier,
expected_blocked_attempt_frontier,expected_time_high_water,backup_set_core_digest_or_null,
snapshot_plaintext_digest_or_null,wal_plaintext_digest_or_null,recovery_executable_digest,
expected_recovered_state_digest,recovery_incident_id_or_null}`，其 digest exact `SHA256(JCS(recovery_manifest))`。
restart branch的三个 backup/snapshot/WAL nullable字段及 incident须全 null；anchored restore的前三者
non-null而 incident须 null；break-glass四者须全 non-null且 incident byte-equal request及 anchored
history incident-open receipt。两个 restore branch的 backup字段须
byte-equal history-defined `backup_set_ref`及 decrypt/replay结果。request的 kind/manifest/anchor/backup须逐字段
byte-equal；`restore_approval`/`break_glass_recovery_approval`分别是 `control_approval`且 approval kind对应、
approved core digest等于含 incident字段的 recovery-manifest digest；unknown/wrong-nullability/cross-approval拒绝。

`control_operation_receipt` exact为
`{authority_id,method,control_operation_id,operation_request_digest,body_core_digest,
pre_state_digest,post_state_digest,method_result_core_digest,durable_sequence,fsync_receipt_digest,
anchor_receipt_digest}`；sequence是 nonnegative u64且 anchor digest必须 non-null canonical digest。
method result core是 success result删除 `control_operation_receipt`后的 exact object，其 digest为 JCS SHA-256，
从而无自引用。`bootstrap_receipt` outer wire exact为
`{bootstrap_manifest_core_digest,bootstrap_approval_digest,release_identity_attestation_digest,
initial_time_proof_bundle_digest,database_identity_digest,bootstrap_genesis_state_preimage,
bootstrap_genesis_state_digest,bootstrap_database_commit_receipt,bootstrap_database_commit_digest,
bootstrap_anchor_capsule,bootstrap_anchor_capsule_digest,bootstrap_anchor_transaction_digest,
bootstrap_anchor_receipt,bootstrap_anchor_receipt_digest}`；所有 nested subobject/digest只由
[authority protocol](publication_authority_protocol_contract.md#bootstrap-genesis-and-anchor-evidence)定义。
`control_operation_receipt.anchor_receipt_digest`必须 byte-equal `bootstrap_anchor_receipt_digest`；同 result的
`ready_receipt`须 byte-equal HEAD中的 frontiers/time/trust，`anchor_head_digest=bootstrap_head_row_digest`，且
`evaluated_state_digest=jcs_sha256({v:"GH700:bootstrap-ready-state:v1",bootstrap_anchor_receipt_digest,
publication_frontier,blocked_attempt_frontier,time_high_water,trust_epoch,anchor_head_digest})`。
`migration_receipt` exact为
`{migration_plan_digest,source_schema_version,target_schema_version,prior_publication_frontier,
prior_blocked_attempt_frontier,successor_publication_frontier,successor_blocked_attempt_frontier,
post_state_digest,anchor_transaction_digest}`。`recovery_receipt` exact为
`{recovery_manifest_digest,recovery_kind,prior_anchor_head_digest,recovered_publication_frontier,
recovered_blocked_attempt_frontier,recovered_time_high_water,recovered_state_digest,
backup_set_core_digest_or_null,anchor_transaction_digest}`，nullability按 recovery kind同 manifest。
`ready_receipt` exact为
`{authority_id,authority_identity_digest,policy_epoch,policy_bundle_digest,schema_version,
publication_frontier,blocked_attempt_frontier,time_high_water,trust_epoch,anchor_head_digest,
pending_anchor_operation_id_or_null,evaluated_state_digest}`；ready state要求 pending literal null且所有
manifest/store/anchor/trust/time等式通过。

`ready_result` exact union为 `{ready_state:"ready",ready_receipt}`或
`{ready_state:"not_ready",non_ready_reason_code,evidence_digest}`；reason exact closed union为
`{manifest_invalid,policy_drift,store_unavailable,migration_required,recovery_required,anchor_mismatch,
backup_unavailable,time_unavailable,trust_invalid,pending_anchor}`。

`control_peer_auth_policy` exact为 `{schema_version,entries}`，schema version exact
`GH700:publication-authority-control-peer-auth-policy:v1`；entry exact为
`{peer_role,uid,gid,executable_digest,code_sign_identity_digest,environment_protection_digest,
allowed_method_selectors}`；selectors按 UTF-8 bytes升序 unique，其 exact union为
`{bootstrap,migrate,recover_restart_replay,recover_anchored_snapshot_restore,
recover_break_glass_restore,ready}`。role/selectors partition exact 为：
`bootstrap_operator→{bootstrap}`、`migration_operator→{migrate}`、
`recovery_operator→{recover_restart_replay}`、`restore_operator→{recover_anchored_snapshot_restore}`、
`break_glass_operator→{recover_break_glass_restore}`、`readiness_probe→{ready}`。
server须从 Unix peer credentials与打开的 peer process image重算
`{pid,uid,gid,executable_digest,code_sign_identity_digest,observed_environment_protection}`，不得信任 wire assertion。
后者 exact tagged union为 Darwin
`{platform:"darwin",hardened_runtime,entitlements_digest,sandbox_profile_digest,launchd_job_digest}`或 Linux
`{platform:"linux",no_new_privs,namespace_set_digest,seccomp_filter_digest,cgroup_policy_digest,
systemd_unit_digest}`，全部从已打开 process handle的 kernel/code-sign state及 manifest-pinned launcher
receipt重算；`observed_environment_protection_digest=SHA256(JCS(observed_environment_protection))`须
byte-equal policy entry，缺 kernel evidence或仅从 policy回填拒绝。
`requested_peer_role`须恰一匹配 policy entry及 method partition。root/uid-only wildcard、ambient executable
lookup、path-only identity、role fallback或交叉授权均拒绝。signed deployment manifest的
`control_api.peer_auth_policy`携完整 bytes且 `peer_auth_policy_digest=SHA256(JCS(peer_auth_policy))`；
bootstrap前从该 manifest重算并验证 socket/server/peer policy，不依赖 DB或 ambient file。

`peer_authentication_receipt` exact为
`{socket_identity_digest,server_process_identity_digest,peer_pid,peer_uid,peer_gid,peer_executable_digest,
peer_code_sign_identity_digest,peer_environment_protection_digest,peer_role,peer_auth_policy_digest,
operation_request_digest}`。success response exact为
`{api_version,method,authority_id,authority_identity_digest,policy_epoch,policy_bundle_digest,
operation_request_digest,response_nonce,peer_authentication_receipt,result,authority_signature}`。error response exact为
`{api_version,method,authority_id,authority_identity_digest,policy_epoch,policy_bundle_digest,
operation_request_digest,response_nonce,peer_authentication_receipt_or_null,
error:{code,retry_class,evidence_digest_or_null},authority_signature}`；peer receipt只在
`unauthenticated_peer`时 literal null，
其它 error须 non-null；code exact为
`{invalid_request,unauthenticated_peer,unauthorized_peer,wrong_authority,policy_drift,replay_conflict,
operation_conflict,precondition_failed,dependency_unavailable,outcome_uncertain,authority_non_ready,
internal_durability_failure}`，retry class exact为
`{never,after_fresh_read,after_new_approval,same_operation_read_confirm_only}`，`outcome_uncertain`只可配
`same_operation_read_confirm_only`。
`authority_signature` exact为
`{signature_profile:"ed25519_sha256_jcs_v1",issuer_key_id,issuer_key_version,signature_b64u}`并以
manifest `control_api.response_signing_key`签，issuer ID/version及 decoded SPKI须 byte-equal该 key并由
release-identity attestation覆盖；签
`SHA256(JCS({v:"GH700:control-response-signature:v1",response_core}))`，其中 response core是删除
`authority_signature`后的完整 response。client须在消费 result/ready/error前验证签名、request digest、
response nonce、authority/policy identity；key rotation只可随 signed manifest提升 policy epoch原子切换，
old key仅验证其永久 replay的 old response，不能签新 bytes；replacement、missing/unknown signer或 unsigned result拒绝。

mutating method的 `control_operation_id`须由 authority重算为
`SHA256(JCS({v:"GH700:control-operation:v1",authority_id,method,body_core}))`，其中 `body_core`是对应
body删除 `control_operation_id`后的 exact object。永久 unique `(authority_id,method,control_operation_id)`：
`body_core_digest=SHA256(JCS(body_core))`且须 byte-equal control receipt。
same ID/same core只恢复原 durable state/result，same ID/different core报 `operation_conflict`；
`control_peer_identity_digest=SHA256(JCS({v:"GH700:control-peer-identity:v1",peer_uid,peer_gid,
peer_executable_digest,peer_code_sign_identity_digest,peer_environment_protection_digest,peer_role}))`；
永久 unique `(authority_id,control_peer_identity_digest,request_nonce)`跨 policy epoch保留。same key/same
request bytes返回原 byte-identical signed response，same key/different bytes报 `replay_conflict`；policy
rotation后旧 response仍只可原样返回，caller须因 policy epoch不符拒绝并使用 fresh nonce。
response loss/restart/takeover不得重执行 mutation；ready以 nonce为 challenge并重放原 signed result。
bootstrap在首次 DB建立前先写 manifest-pinned durable bootstrap journal并 fsync，导入 DB后永久保留；
bootstrap twice、stale migrate frontier、wrong backup/anchor、approval drift都在 mutation前拒绝。

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
`{binding_record_digest,binding_evidence_kind,bound_attempt_record_digests,terminal_attempt_key_digest,
terminal_listing_proof_digest,candidate_identity,source_identity_key,run_id,run_attempt,successor_frontier,
store_envelope_digest}`。
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

authority从 closed payload派生
`attempt_subject_key=SHA256(JCS({v:"GH700:attempt-subject:v1",attempt_record_kind,
candidate_identity_or_null,failure_scope_or_null,target_or_null,early_attempt_key_or_null}))`。
`candidate_failure`写 candidate+scope及 target-or-null；`pipeline_interrupted`与
`publication_recovery_binding`写 candidate且其余 null；pre-attestation kind只写 early-attempt key。
`append_blocked_attempt.expected_attempt_subject_key`必须 byte-equal重算值，不能作为 authority输入真源。

`binding_intent` exact 为
`{source_identity_key,run_id,run_attempt,candidate_identity,binding_evidence,
publication_history_operation_id,publication_history_frontier,recovered_outcome_digest}`。
`binding_evidence`是 exact tagged union：

- `{binding_evidence_kind:"authenticated_terminal_recovery",terminal_attempt_key,terminal_listing_proof}`；
- `{binding_evidence_kind:"source_attempt_records",terminal_attempt_key,terminal_listing_proof,
  enumeration_snapshot_receipt,source_attempt_record_digests}`，digest list按 bytes升序、去重且非空。

第一 branch禁止 source digest/snapshot字段；第二 branch须逐项读取永久 record并证明它们共享 exact
`repo_node_id/source_identity_key/run_id/run_attempt`，pre-attestation server ref/tag/source须与 candidate
匹配，并在 snapshot frontier完整分页证明 digest list byte-equal该 tuple全部 eligible、unbound
failure/interruption records，不能是 subset/superset。bind request的
`expected_blocked_attempt_frontier_or_null`必须 non-null；authority在同一 `BEGIN IMMEDIATE` transaction要求
`enumeration_snapshot_receipt.snapshot_frontier`、该 expected frontier、当前 ledger frontier与 binding
attempt leaf的 `predecessor_frontier`四者 byte-equal，任一推进报 `stale_frontier`，不得在更新 frontier上
使用旧 snapshot。两 branch都须验证 terminal proof全分页、
server-auth/ref-aligned，terminal key恰一存在且 source/run/
candidate/conclusion byte-equal intent；strong-read并 anchor-verify history frontier，证明 operation exact 为
同 candidate/run intent chain的 `recovered_publication`，并以 domain-separated
`SHA256(JCS({v:"GH700:recovered-outcome:v1",terminal_attempt_key_digest,
publication_history_operation_id,publication_history_frontier,recovered_publication_payload_digest,
finalization_receipt_digest}))`重算 outcome digest。

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
`(run_id,run_attempt)`排序后的最后一项；空 terminal listing禁止 commit watermark。

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
