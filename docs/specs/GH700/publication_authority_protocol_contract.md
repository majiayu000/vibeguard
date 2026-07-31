# GH700 Publication Authority Protocol Contract

本文件与 [publication history contract](publication_history_contract.md)、
[client API / blocked-attempt contract](publication_ledger_contract.md) 及
[publication conformance vectors](publication_conformance_vectors.md) 共同构成 GH700 publication machine 的
规范性 contract。本文件唯一拥有 authority-owned trusted-time proof profiles；client/control wire、
Release effective-request及 trust-revocation applicability只由
[authority API contract](publication_ledger_contract.md)拥有，history operation-ID normalization只由
[history contract](publication_history_contract.md)拥有。其它文件不得复制或局部覆盖本文件的 trusted-time
identifier；unknown/extra/alias/null-not-declared一律拒绝。

## Ownership boundary

Closed `client_api`/`control_api` request、response、peer authorization、approval、receipt及 replay schema只由
[authority API contract](publication_ledger_contract.md#closed-control-api)定义。本文件不声明兼容 alias或
第二套 wire；trusted-time proof的 transport-independent subject/replay/profile从下节开始。

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

proof request冻结后，publication branch才按 [history contract](publication_history_contract.md#frontiertrust-与-deterministic-fold)公式派生 `transition_operation_id`；incident/cutover没有 history
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

## Cross-contract routing

History operation-ID normalization由 [history contract](publication_history_contract.md#frontiertrust-与-deterministic-fold)
唯一拥有。Release effective-request digest与 trust-revocation applicability分别由
[authority API contract](publication_ledger_contract.md#release-effective-request-digest)及其
[history-delegated values](publication_ledger_contract.md#history-delegated-trust-revocation-values)唯一拥有。
本文件不为这些 identifier提供兼容 alias、fallback或第二套 canonical bytes。
