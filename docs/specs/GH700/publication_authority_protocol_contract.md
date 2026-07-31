# GH700 Publication Authority Protocol Contract

本文件与 [publication history contract](publication_history_contract.md)、
[client API / blocked-attempt contract](publication_ledger_contract.md) 及
[publication conformance vectors](publication_conformance_vectors.md) 共同构成 GH700 publication machine 的
规范性 contract。本文件唯一拥有 authority-owned time-bound `publication_payload_core`、trusted-time proof profiles
及 bootstrap genesis/anchor evidence subobjects；client/control wire、
Release effective-request及 trust-revocation applicability只由
[authority API contract](publication_ledger_contract.md)拥有，history operation-ID normalization只由
[history contract](publication_history_contract.md)拥有。其它文件不得复制或局部覆盖本文件的 trusted-time
identifier；unknown/extra/alias/null-not-declared一律拒绝。

## Ownership boundary

Closed `client_api`/`control_api` request、response、peer authorization、approval、outer receipt及 replay schema只由
[authority API contract](publication_ledger_contract.md#closed-control-api)定义。本文件不声明兼容 alias或
第二套 wire；该 wire只可引用本文件的 exact payload-core与 bootstrap evidence subobjects。

## Authority-owned time-bound payload cores

本文件新增公式中的 `JCS_BYTES(x)` exact 为 RFC 8785 canonical JSON的 UTF-8 bytes；
`jcs_sha256(x)` exact 为 lowercase `sha256:<64hex>`，hex等于 `SHA256(JCS_BYTES(x))`。三种
`publication_payload_core`均由 authority从 authenticated request与 signed predecessor fold构造，client不得提交。
exact closed schema分别为：

- `owner_claimed`：`{owner_generation,run_id,run_attempt,candidate_tag_identity_digest,frozen_plan_digest,
  liveness_policy_digest,draft_claim_nonce_digest,nonce_capsule_id,capsule_ciphertext_digest,kms_key_version,
  prior_time_high_water}`；
- `owner_heartbeat`：`{owner_generation,heartbeat_sequence,prior_liveness_operation_id,liveness_policy_digest,
  prior_time_high_water}`；
- `publication_owner_taken_over`：`{candidate_tag_identity_digest,prior_owner_generation,new_owner_generation,
  prior_owner_terminal_or_expiry_evidence_digest,slot_chain_digest,prior_time_high_water}`。

每个 branch 的 `publication_payload_core_bytes=JCS_BYTES(publication_payload_core)`，
`publication_payload_core_digest=jcs_sha256(publication_payload_core)`；RFC8785 key lexicographic ordering是唯一
byte顺序，文档展示顺序不参与编码。missing/extra/alias/cross-branch字段、client-supplied authority field、
fold/request mismatch或非 canonical scalar一律在 trusted-time nonce前拒绝。

claim exact顺序为：重算 `time_bound_request_id`与 `claim_pre_nonce_core_digest`；按 history special formula先派生
`transition_operation_id`；FULL fsync `claim_reserved`（payload core/capsule/proof字段仍 null）；以该 operation ID
只签发一次 draft nonce/capsule并 FULL fsync `claim_capsule_frozen`；加入 capsule字段与 fold-owned
`prior_time_high_water`构造 claim core/bytes/digest；再构造 trusted-time subject→replay identity→trusted-time nonce→
proof request→message imprint/TSA proof；最后把 proof outputs填入 history-owned final payload/intent并 commit/anchor。
operation ID不含 capsule/core/proof request，core不含 trusted-time proof/output，因此不存在回边。

heartbeat/takeover exact顺序为：验证 request/auth/frontier并 strong-fold current liveness；构造各自
core/bytes/digest；构造 subject→replay identity→trusted-time nonce→proof request；再按 history generic formula派生
operation ID；将 core/proof request/operation ID及 replay row FULL fsync为 `prepared` 后才构造 message imprint并访问
TSA。proof验证后才把 `{trusted_time_proof_digest,new_time_high_water,accepted_at,lease_expires_at}`与 core字段组合成
history-owned exact final payload。same request/crash/ack-loss只可恢复同一 durable state；不得换 core、nonce、capsule、
proof request、operation ID或 final payload。

## Trusted-time proof profiles

`trusted_time_purpose` exact closed union为
`{bootstrap_initial_time,owner_claim,owner_heartbeat,owner_takeover,break_glass_incident_open,
break_glass_cutover}`。purpose与 subject branch exact mapping为 bootstrap→`bootstrap_initial_time`、三个 owner
purpose→`publication_transition`，其余分别→`incident_open`/`emergency_cutover`；交叉使用拒绝。
`trusted_time_subject` exact tagged union为：

- `bootstrap_initial_time`：`{subject_kind:"bootstrap_initial_time",authority_id,authority_identity_digest,
  repo_node_id,policy_epoch,bootstrap_version,release_identity_root_digest,initial_trust_bundle_digest,
  initial_trust_epoch,first_frontier,first_blocked_attempt_frontier,governance_roster_digest,
  governance_threshold,governance_signer_key_ids,quorum_policy_digest}`；
- `publication_transition`：`{subject_kind:"publication_transition",execution_identity,owner_generation,record_kind,predecessor_frontier,publication_payload_core_digest,time_bound_request_id}`；
- `incident_open`：`{subject_kind:"incident_open",recovery_incident_id,incident_open_intent_digest,current_anchor_digest,current_publication_frontier,current_blocked_attempt_frontier}`；
- `emergency_cutover`：`{subject_kind:"emergency_cutover",recovery_incident_id,incident_open_receipt_digest,audit_delay_evidence_core_digest,current_anchor_digest,current_publication_frontier,current_blocked_attempt_frontier,next_trust_epoch,new_bundle_digest}`。

bootstrap subject字段来自待批准 deployment core删除两个 proof-produced
`bootstrap_governance.initial_time_high_water/initial_time_proof_digest`后的 exact closed projection；两个 frontier必须
是按 history root contract重算的 length-zero full frontiers，signer IDs按 UTF-8 bytes升序 distinct，quorum policy须
byte-equal manifest钉住的 RFC3161 policy。该 projection不含 proof/bundle/manifest/approval/control-operation digest，
因此 proof→manifest→approval无自引用；任何 caller-supplied digest或 nonzero pre-state拒绝。
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
bootstrap的 `prior_time_high_water`须 literal `0`；其它 purpose从已验证 predecessor/anchor读取，client不得提交。

proof request冻结后，heartbeat/takeover才按 [history contract](publication_history_contract.md#frontiertrust-与-deterministic-fold)
generic公式派生 operation ID；claim special operation ID已在 capsule前冻结，bootstrap/incident/cutover没有 history operation ID。
RFC3161 `messageImprint.hashAlgorithm`必须 SHA-256，`hashedMessage`必须 exact 32 bytes
`SHA256(JCS({v:"GH700:trusted-time-message-imprint:v1",authority_id,repo_node_id,purpose,
trusted_time_replay_identity,trusted_time_proof_request_id,subject_digest,transition_operation_id_or_null,nonce_b64u}))`；
publication要求该字段 non-null且为刚派生的 exact ID，bootstrap/incident/cutover要求 literal null。TSA token的 imprint、policy OID
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

每个 token 的 DER `TSTInfo.genTime`只接受 UTC `YYYYMMDDhhmmss[.fraction]Z`；fraction为1–9位且末位非零，
解析为 exact signed Unix nanoseconds `gen_time_ns`，leap second、offset、本地时区、超过 nanosecond精度或
overflow拒绝。RFC3161 `accuracy`必须存在且至少一个 component nonzero：`seconds`为 nonnegative safe integer，
`millis/micros`若存在分别须 `1..999`；`accuracy_ns=seconds*10^9+millis*10^6+micros*10^3`使用 checked integer
arithmetic，missing accuracy不得按 zero解释。manifest exact `maximum_tsa_accuracy_ns`须为 nonnegative safe integer，
且每个 `accuracy_ns<=maximum_tsa_accuracy_ns`。

token inclusive interval exact 为 `[gen_time_ns-accuracy_ns,gen_time_ns+accuracy_ns]`；wire second bounds分别取
mathematical floor(lower/10^9)与 ceiling(upper/10^9)，不得 truncate toward zero。token内任何
`lower_bound_unix_seconds/upper_bound_unix_seconds`只作 assertion并须 byte-equal重算值。distinct threshold signer
interval求交 exact 为 `trusted_lower_bound=max(token lowers)`、
`trusted_upper_bound=min(token uppers)`；无交集、accuracy缺失/超限、signer不足、imprint/purpose/replay mismatch或
token replay拒绝。lower必须 `>=prior_time_high_water`；accepted/new high water取 upper并随 DB successor及 external
anchor持久化。host/client/GitHub time不参与授权。

incident-open必须以 `purpose=break_glass_incident_open`先完成并锚定 receipt。cutover另取
`purpose=break_glass_cutover`的 fresh replay identity/nonce/request/token；其
`audit_delay_evidence_core={incident_open_receipt_digest,incident_open_trusted_upper_bound,
minimum_audit_delay_seconds,current_anchor_digest,current_publication_frontier,current_blocked_attempt_frontier}`，digest exact
`SHA256(JCS(audit_delay_evidence_core))`。final evidence仍 exact
`{incident_open_receipt_digest,incident_open_trusted_upper_bound,cutover_trusted_lower_bound,
minimum_audit_delay_seconds,cutover_trusted_time_proof_digest}`；仅当 cutover lower
`>= incident_open upper + minimum_audit_delay_seconds`接受。incident receipt、cutover subject/core、offline approval与
emergency record的 anchor/frontiers必须 byte-equal；任一 pre-state drift必须新建 incident，不得复用 proof。

## Bootstrap genesis and anchor evidence

`initial_time_proof_bundle`只能由同一 `bootstrap_initial_time` subject/replay identity下 frozen proof capsules构造。
bundle的 repo/quorum、每项 endpoint/policy/nonce/request/imprint/token digest与重算 proof必须 byte-equal，bundle
lower/upper须 byte-equal上述 interval intersection，`initial_time_high_water`须 byte-equal upper；
`initial_time_proof_bundle_digest=SHA256(JCS(bundle))`。随后 deployment core的两个 initial-time输出必须分别
byte-equal该 high water与 bundle digest，bootstrap approval才可签完整 manifest core；cross-bootstrap replay、
proof后替换 manifest projection、缺 accuracy或任一 digest/interval drift均拒绝。

bootstrap genesis preimage exact 为
`bootstrap_genesis_state_preimage={v:"GH700:bootstrap-genesis-state:v1",authority_id,
authority_identity_digest,policy_epoch,repo_node_id,schema_version,store_generation:0,database_identity_digest,
publication_frontier,blocked_attempt_frontier,time_state,trust_state,roster_state}`。两个 frontier分别为 history与
blocked-attempt ledger的 exact length-zero full frontier；`time_state={initial_time_high_water,
initial_time_proof_bundle_digest}`；`trust_state={initial_trust_epoch,initial_trust_bundle_digest}`；
`roster_state={governance_roster_digest,governance_threshold,governance_signer_key_ids}`，signer IDs按 UTF-8 bytes
升序且 distinct。`bootstrap_genesis_state_bytes=JCS_BYTES(bootstrap_genesis_state_preimage)`，
`bootstrap_genesis_state_digest=jcs_sha256(bootstrap_genesis_state_preimage)`；所有 nested值须 byte-equal verified
manifest/approval、重算的 zero frontiers及 initial-time bundle。

SQLite commit evidence exact 为
`bootstrap_database_commit_receipt={v:"GH700:bootstrap-database-commit:v1",control_operation_id,
database_identity_digest,bootstrap_genesis_state_digest,transaction_kind:"bootstrap_genesis",store_generation:0,
sqlite_transaction_sequence,wal_frame_end,commit_state:"committed",database_file_fsync:true,wal_fsync:true,
parent_directory_fsync:true}`；两个 sequence是 unsigned 64-bit JSON integer。
`bootstrap_database_commit_digest=jcs_sha256(bootstrap_database_commit_receipt)`；commit或任一 fsync未完成不得 backup/
sign/anchor。

genesis backup使用 history-owned exact `backup_set_ref`，其 digest exact
`backup_set_ref_digest=jcs_sha256(backup_set_ref)`。anchor capsule core exact 为
`bootstrap_anchor_capsule_core={v:"GH700:bootstrap-anchor-capsule-core:v1",authority_id,
authority_identity_digest,policy_epoch,repo_node_id,control_operation_id,deployment_manifest_digest,
bootstrap_manifest_core_digest,bootstrap_approval_digest,release_identity_attestation_digest,
initial_time_proof_bundle_digest,database_identity_digest,bootstrap_database_commit_digest,
bootstrap_genesis_state_digest,backup_set_ref,backup_set_ref_digest,restore_epoch:0,
prior_anchor_digest_or_null:null,transition_class:"bootstrap"}`；
`bootstrap_anchor_capsule_core_digest=jcs_sha256(bootstrap_anchor_capsule_core)`，privileged signers只签
`bootstrap_anchor_signature_request_digest=jcs_sha256({v:"GH700:bootstrap-anchor-signature:v1",
bootstrap_anchor_capsule_core_digest})`。`bootstrap_anchor_signature_set`是按 `(signer_key_id,signer_key_version)`
UTF-8 bytes升序的 distinct closed array项
`{signer_key_id,signer_key_version,signer_domain_id,algorithm,signature_b64u}`；algorithm/key须 manifest-pinned，
signature为 canonical unpadded base64url并验证同一 request digest。
`bootstrap_anchor_signature_set_digest=jcs_sha256({v:"GH700:bootstrap-anchor-signature-set:v1",
bootstrap_anchor_signature_request_digest,signatures:bootstrap_anchor_signature_set})`。capsule exact 为
`bootstrap_anchor_capsule={bootstrap_anchor_capsule_core,bootstrap_anchor_capsule_core_digest,
bootstrap_anchor_signature_request_digest,bootstrap_anchor_signature_set,
bootstrap_anchor_signature_set_digest}`，其 digest exact
`bootstrap_anchor_capsule_digest=jcs_sha256({v:"GH700:bootstrap-anchor-capsule:v1",
bootstrap_anchor_capsule})`。

epoch row exact 为 `bootstrap_epoch_row={row_kind:"restore_epoch",restore_epoch:0,
bootstrap_anchor_capsule,bootstrap_anchor_capsule_digest}`；HEAD exact 为
`bootstrap_head_row={row_kind:"head",restore_epoch:0,bootstrap_anchor_capsule_digest,
bootstrap_genesis_state_digest,publication_frontier,blocked_attempt_frontier,time_high_water,trust_epoch,
governance_roster_digest}`，其 state须 byte-equal genesis preimage。row digests exact 为
`bootstrap_epoch_row_digest=jcs_sha256({v:"GH700:bootstrap-epoch-row:v1",row:bootstrap_epoch_row})`及
`bootstrap_head_row_digest=jcs_sha256({v:"GH700:bootstrap-head-row:v1",row:bootstrap_head_row})`。
`bootstrap_anchor_transaction_token` exact 为
`lowercase_hex(SHA256(JCS_BYTES({v:"GH700:bootstrap-anchor-transaction-token:v1",
bootstrap_anchor_capsule_digest})))[0:32]`。transaction preimage exact 为
`bootstrap_anchor_transaction_preimage={v:"GH700:bootstrap-anchor-transaction:v1",
backend:"publication_restore_anchor_dynamodb_v1",anchor_resource_identity_digest,
client_request_token:bootstrap_anchor_transaction_token,operations:[{ordinal:0,operation:"PutItem",key:"EPOCH#0",
condition:"attribute_not_exists(pk)",item:bootstrap_epoch_row},{ordinal:1,operation:"PutItem",key:"HEAD",
condition:"attribute_not_exists(pk)",item:bootstrap_head_row}]}`；operation顺序固定，digest exact
`bootstrap_anchor_transaction_digest=jcs_sha256(bootstrap_anchor_transaction_preimage)`。

成功 response exact 规范化为 `bootstrap_transaction_service_receipt={http_status:200,aws_request_id}`，
`bootstrap_transaction_service_receipt_digest=jcs_sha256({v:"GH700:bootstrap-anchor-transaction-service-receipt:v1",
bootstrap_anchor_transaction_digest,
bootstrap_transaction_service_receipt})`。随后分别 strong-read EPOCH与HEAD；confirmation exact 为
`bootstrap_strong_read_confirmation={anchor_resource_identity_digest,reads:[{ordinal:0,key:"EPOCH#0",
consistent_read:true,item:bootstrap_epoch_row,aws_request_id},{ordinal:1,key:"HEAD",consistent_read:true,
item:bootstrap_head_row,aws_request_id}]}`，顺序固定；digest exact
`bootstrap_strong_read_confirmation_digest=jcs_sha256({v:"GH700:bootstrap-anchor-strong-read:v1",
confirmation:bootstrap_strong_read_confirmation})`。anchor receipt exact 为
`bootstrap_anchor_receipt={bootstrap_anchor_capsule_digest,bootstrap_anchor_transaction_digest,
bootstrap_transaction_service_receipt,bootstrap_transaction_service_receipt_digest,bootstrap_epoch_row_digest,
bootstrap_head_row_digest,bootstrap_strong_read_confirmation,bootstrap_strong_read_confirmation_digest}`；
`bootstrap_anchor_receipt_digest=jcs_sha256({v:"GH700:bootstrap-anchor-receipt:v1",
bootstrap_anchor_receipt})`。任一 genesis/database/backup/signature/capsule/transaction/EPOCH/HEAD/strong-read
cross-binding不等，或 ack-loss read-back不是 exact rows，均不得构造 outer bootstrap/ready/control receipt。

## Cross-contract routing

History operation-ID normalization由 [history contract](publication_history_contract.md#frontiertrust-与-deterministic-fold)
唯一拥有。Release effective-request digest与 trust-revocation applicability分别由
[authority API contract](publication_ledger_contract.md#release-effective-request-digest)及其
[history-delegated values](publication_ledger_contract.md#history-delegated-trust-revocation-values)唯一拥有。
本文件不为这些 identifier提供兼容 alias、fallback或第二套 canonical bytes。
