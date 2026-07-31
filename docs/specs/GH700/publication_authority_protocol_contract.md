# GH700 Publication Authority Protocol Contract

本文件与 [publication history contract](publication_history_contract.md)、
[client API / blocked-attempt contract](publication_ledger_contract.md) 及
[publication conformance vectors](publication_conformance_vectors.md) 共同构成 GH700 publication machine 的
规范性 contract。本文件唯一拥有 `control_api` wire schema、authority-owned trusted-time proof profiles、
history operation-ID normalization、Release broker effective-request digest及 trust-revocation applicability；
其它文件只能链接这些 identifier，不得复制、改名或局部覆盖。unknown/extra/alias/null-not-declared一律拒绝。

## Closed control API

deployment manifest的 `control_api` exact 为
`{socket_path,transport,api_version,server_process_identity_digest,peer_auth_policy_digest}`；socket是 manifest-pinned
absolute Unix path，transport exact `unix_peercred_jcs_v1`，API version exact
`GH700:publication-authority-control-api:v1`，永不监听网络。method exact closed union为
`{bootstrap,migrate,recover,ready}`。

`control_request_core` exact 为
`{api_version,method,authority_id,authority_identity_digest,policy_epoch,policy_bundle_digest,request_nonce,body}`；
`request_nonce`是调用方 CSPRNG 生成的32-byte canonical unpadded base64url。`control_request_id` exact 为
`SHA256(JCS({v:"GH700:control-request:v1",control_request_core}))`。`peer_authorization` exact 为
`{peer_role,peer_process_identity_digest,executable_digest,code_sign_identity_digest,uid,gid,
peer_auth_policy_digest,authorized_method,authorized_control_request_id}`；`uid/gid`是 canonical unsigned 32-bit
JSON integer，`peer_role` exact closed union为 `{deployer,migrator,recovery_operator,readiness_probe}`。
request envelope exact 为 `{control_request_core,control_request_id,peer_authorization}`；authority从 core重算 ID，
并要求 authorization的 method/ID、process identity、peer policy与 Unix peer credentials byte-equal live channel及 manifest。

| method | required `peer_role` | exact `body` | exact success `result` |
| --- | --- | --- | --- |
| `bootstrap` | `deployer` | `{repo_node_id,deployment_manifest_digest,bootstrap_manifest_core_digest,bootstrap_approval_digest,expected_database_absent,expected_anchor_absent}` | `{bootstrap_receipt,ready_receipt}` |
| `migrate` | `migrator` | `{repo_node_id,from_schema_version,to_schema_version,migration_plan_digest,migration_approval_digest,expected_store_generation}` | `{migration_receipt,ready_receipt}` |
| `recover` | `recovery_operator` | `{repo_node_id,recovery_mode,expected_anchor_digest,backup_set_ref_digest_or_null,restore_approval_digest_or_null,recovery_plan_digest}` | `{recovery_receipt,ready_receipt}` |
| `ready` | `readiness_probe` | `{repo_node_id_or_null,expected_policy_epoch,expected_policy_bundle_digest}` | `{ready_receipt}` |

booleans `expected_database_absent/expected_anchor_absent`必须 literal true。`recovery_mode` exact union为
`{wal_replay,anchored_restore}`：`wal_replay`要求两个 restore `*_or_null` literal null且只重放已认证 local WAL；
`anchored_restore`要求二者 non-null并 byte-equal HEAD-bound backup/privileged approval。migration只允许 manifest批准的
strictly increasing schema version与 current store generation；ready不得写 state或触发 bootstrap/migration/recovery。

receipts exact 为：

- `bootstrap_receipt={repo_node_id,control_request_id,deployment_manifest_digest,bootstrap_manifest_core_digest,bootstrap_approval_digest,database_identity_digest,genesis_frontier_digest,anchor_transaction_digest}`；
- `migration_receipt={repo_node_id,control_request_id,from_schema_version,to_schema_version,migration_plan_digest,migration_approval_digest,prior_store_generation,new_store_generation,migration_transaction_digest}`；
- `recovery_receipt={repo_node_id,control_request_id,recovery_mode,recovery_plan_digest,prior_store_generation,new_store_generation,restored_anchor_digest,recovery_transaction_digest}`；
- `ready_receipt={authority_id,authority_identity_digest,policy_epoch,policy_bundle_digest,repo_node_id_or_null,store_generation_or_null,current_anchor_digest_or_null,ready_state,evidence_digest}`，其中 `ready_state` exact `{ready,not_ready}`。

success response exact 为
`{api_version,method,authority_id,authority_identity_digest,policy_epoch,policy_bundle_digest,control_request_id,
response_nonce,result}`；error response为相同公共字段加
`{error:{code,retry_class,evidence_digest_or_null}}`且无 result。`response_nonce`是 authority生成的 fresh 32-byte
canonical unpadded base64url。code exact closed union为
`{invalid_request,unauthenticated,unauthorized,wrong_authority,policy_drift,method_not_allowed,operation_conflict,
dependency_unavailable,outcome_uncertain,authority_non_ready,internal_durability_failure}`；retry class exact 为
`{never,after_policy_refresh,same_request_read_confirm_only}`，`outcome_uncertain`只配 read-confirm。

authority永久 UNIQUE `(peer_process_identity_digest,request_nonce)`及 `(method,control_request_id)`。same nonce或 ID/
same canonical bytes只返回原 durable response；same key/different bytes永久 `operation_conflict`。三个 mutating method在
首次 filesystem/cloud I/O前 transaction+FULL fsync request/core/auth与单调 state，crash/ack-loss只恢复同一 operation；
bootstrap的 absent条件、migration generation及 recover anchor条件均在副作用 transaction重新验证。ready是 authenticated
read-only snapshot；重复请求返回同 snapshot receipt，不得延长授权或改变 state。unknown method/body/result、role/method
错配、nonce replay、peer drift或 response request-ID mismatch fail closed。

## Trusted-time proof profiles

`trusted_time_purpose` exact closed union为
`{owner_claim,owner_heartbeat,owner_takeover,break_glass_incident_open,break_glass_cutover}`。purpose与 subject branch
exact mapping为前三者→`publication_transition`，其余分别→`incident_open`/`emergency_cutover`；交叉使用拒绝。
`trusted_time_subject` exact tagged union为：

- `publication_transition`：`{subject_kind:"publication_transition",execution_identity,owner_generation,record_kind,predecessor_frontier,publication_payload_core_digest,time_bound_request_id}`；
- `incident_open`：`{subject_kind:"incident_open",recovery_incident_id,incident_open_intent_digest,current_anchor_digest,current_publication_frontier,current_blocked_attempt_frontier}`；
- `emergency_cutover`：`{subject_kind:"emergency_cutover",recovery_incident_id,incident_open_receipt_digest,audit_delay_evidence_core_digest,current_anchor_digest,current_publication_frontier,current_blocked_attempt_frontier,next_trust_epoch,new_bundle_digest}`。

`owner_claim/owner_heartbeat/owner_takeover`只接受对应 `{owner_claimed,owner_heartbeat,
publication_owner_taken_over}` record kind。`execution_identity`沿用 client contract exact schema；takeover subject的
`owner_generation`必须为 `new_owner_generation`。incident/cutover两个 current frontier均须 byte-equal strong-read HEAD。

authority先计算 `subject_digest=SHA256(JCS(trusted_time_subject))`及
`trusted_time_replay_identity=SHA256(JCS({v:"GH700:trusted-time-replay-identity:v1",authority_id,repo_node_id,
purpose,subject_digest}))`。然后只为该 replay identity生成一次 fresh 256-bit nonce；`nonce_b64u`是32 bytes的 canonical
unpadded base64url，`trusted_time_nonce_digest=SHA256(JCS({v:"GH700:trusted-time-nonce:v2",authority_id,
repo_node_id,purpose,trusted_time_replay_identity,nonce_b64u}))`。proof request exact 为
`trusted_time_proof_request_id=SHA256(JCS({v:"GH700:trusted-time-proof-request:v2",authority_id,repo_node_id,
purpose,trusted_time_replay_identity,subject_digest,prior_time_high_water,trusted_time_nonce_digest}))`。

proof request冻结后，publication branch才按下节公式派生 `transition_operation_id`；incident/cutover没有 history
operation ID。RFC3161 `messageImprint.hashAlgorithm`必须 SHA-256，`hashedMessage`必须 exact 32 bytes
`SHA256(JCS({v:"GH700:trusted-time-message-imprint:v1",authority_id,repo_node_id,purpose,
trusted_time_replay_identity,trusted_time_proof_request_id,subject_digest,transition_operation_id_or_null,nonce_b64u}))`；
publication要求该字段 non-null且为刚派生的 exact ID，incident/cutover要求 literal null。TSA token的 imprint、policy OID
及 signer chain必须 byte-equal request/manifest；RFC3161 request/token nonce extension必须 absent。`trusted_time_proof_digest` exact 为
`SHA256(JCS({v:"GH700:trusted-time-proof-capsule:v1",purpose,trusted_time_replay_identity,
trusted_time_proof_request_id,message_imprint_sha256,ordered_token_digests,trusted_lower_bound,trusted_upper_bound}))`，
token digest按 manifest `source_id` ASCII排序。

永久 replay row exact 为
`{authority_id,repo_node_id,purpose,trusted_time_replay_identity,subject_digest,prior_time_high_water,
trusted_time_nonce_digest,trusted_time_proof_request_id,transition_operation_id_or_null,message_imprint_sha256,
proof_state,proof_capsule_digest_or_null}`，
state只可 `reserved→requested→proof_frozen→anchor_confirmed`。UNIQUE `(authority_id,repo_node_id,purpose,
trusted_time_replay_identity)`；same identity/same subject从 durable state恢复，different subject冲突。任一 nonce/request/
message imprint/token capsule不得跨 purpose或 replay identity复用；crash/ack-loss不得生成第二 nonce或 TSA request。

token验证对 distinct threshold signer的 intervals求交；无交集、accuracy超限、signer不足、imprint/purpose/replay mismatch
或 token replay拒绝。`trusted_lower_bound`/`trusted_upper_bound`取交集边界且 lower必须 `>=prior_time_high_water`；
accepted/new high water取 upper并随 DB successor及 external anchor持久化。host/client/GitHub time不参与授权。

incident-open必须以 `purpose=break_glass_incident_open`先完成并锚定 receipt。cutover另取
`purpose=break_glass_cutover`的 fresh replay identity/nonce/request/token；其
`audit_delay_evidence_core={incident_open_receipt_digest,incident_open_trusted_upper_bound,
minimum_audit_delay_seconds,current_anchor_digest,current_publication_frontier,current_blocked_attempt_frontier}`，digest exact
`SHA256(JCS(audit_delay_evidence_core))`。final evidence仍 exact
`{incident_open_receipt_digest,incident_open_trusted_upper_bound,cutover_trusted_lower_bound,
minimum_audit_delay_seconds,cutover_trusted_time_proof_digest}`；仅当 cutover lower
`>= incident_open upper + minimum_audit_delay_seconds`接受。incident receipt、cutover subject/core、offline approval与
emergency record的 anchor/frontiers必须 byte-equal；任一 pre-state drift必须新建 incident，不得复用 proof。

## History operation-ID normalization

`owner_claimed` operation ID保持 exact
`SHA256(JCS({v:"GH700:claim-operation-id:v1",repo_node_id,owner_generation,run_id,run_attempt,transition_slot,
predecessor_frontier,record_kind:"owner_claimed",claim_pre_nonce_core_digest,time_bound_request_id}))`。

其余 publication-domain kinds先从 immutable intent构造 exact
`normalized_publication_identity={owner_generation,execution_identity}`。`publication_owner_taken_over`的
`owner_generation`必须取 payload `new_owner_generation`；`publication_terminal_no_publication`必须取 payload
`terminal_owner_generation`；其它 branch必须取 payload exact `owner_generation`。`execution_identity` exact 取 intent的
`{run_id,run_attempt,transition_slot}`；time-bound branch还须 byte-equal client wire/preparation，terminal branch须 byte-equal
该 terminal generation的 authenticated run tuple。然后 operation ID exact 为
`SHA256(JCS({v:"GH700:publication-operation-id:v1",repo_node_id,owner_generation,
run_id,run_attempt,transition_slot,predecessor_frontier,record_kind,publication_payload_core_digest,
trusted_time_proof_request_id_or_null}))`，其中各 scalar从 normalized identity展开。non-time kind以完整 payload作 core且
proof request ID literal null；三种 time kind绑定本文件对应 proof request。payload缺 branch source、混用 prior/new/
terminal generation、intent tuple不等或 ambient default一律拒绝。

三种 normal governance kinds operation ID exact 为
`SHA256(JCS({v:"GH700:governance-operation-id:v1",repo_node_id,purpose,record_kind,rotation_id,
predecessor_frontier,rotation_cutover_certificate_digest}))`；emergency exact 为
`SHA256(JCS({v:"GH700:emergency-governance-operation-id:v1",repo_node_id,purpose,record_kind,rotation_id,
recovery_incident_id,predecessor_frontier,rotation_cutover_certificate_digest}))`。所有分支排除 mutable fence/lease；
unknown/cross-branch field拒绝。

## Release effective-request digest

broker只接受 plan-pinned canonical absolute HTTPS endpoint与 uppercase method。header name先 ASCII lowercase；值只删除
leading/trailing optional whitespace并拒绝 obs-fold/control bytes；duplicate header name拒绝，unique entries按 name ASCII排序。
每项 exact framing为 `u64be(len(name_bytes))||name_bytes||u64be(len(value_bytes))||value_bytes`，连接后得到
`canonical_headers_bytes`。`body_bytes`是 typed placeholder替换后、交给 pinned HTTP client的 exact body；禁止再次
re-encode/compress。`transmitted_request_bytes` exact 为
`u64be(len(method_bytes))||method_bytes||u64be(len(endpoint_bytes))||endpoint_bytes||
u64be(len(canonical_headers_bytes))||canonical_headers_bytes||u64be(len(body_bytes))||body_bytes`。

ephemeral `effective_request_preimage` exact 为
`{v:"GH700:release-effective-request:v1",endpoint,method,canonical_headers_digest,body_digest,
transmitted_bytes_digest}`，三个 digest分别是上述 exact bytes的 lowercase SHA-256；
`effective_request_digest=SHA256(JCS(effective_request_preimage))`。broker在 send前从实际将发送的 endpoint/method/
headers/body重算全部 bytes/digests，并在 send-once audit中只持久化 preimage、final digest及 byte lengths；raw authorization、
nonce、headers/body/transmitted bytes不得落 history/log/receipt。send后 adapter报告的 emitted-byte digest必须 byte-equal
precomputed transmitted digest，否则 outcome uncertain并进入 recovery，不得重发。

## Trust-revocation applicability

`revocation_reason_code` exact closed union为
`{key_compromise,algorithm_retired,certificate_expired,signer_replaced,signer_removed}`。
`replacement_key_or_bundle_digest_or_null` applicability exact：前四种必须 non-null且绑定 manifest批准的 higher-version
replacement key/bundle；`signer_removed`必须 literal null，authority须从 manifest roster移除 revoked key后重算
distinct valid signer count并要求仍满足 current threshold，且 approval signatures只可来自未撤销 signer。
replacement不得 byte-equal revoked key/bundle、降 version或复用 compromised material。
unknown reason、missing/extra replacement、nullability mismatch、threshold不足或 reason/evidence不符均在 append前拒绝。
