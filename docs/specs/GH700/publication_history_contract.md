# GH700 Publication History Contract

本文件与 [publication authority API / blocked-attempt contract](publication_ledger_contract.md) 及
[publication conformance vectors](publication_conformance_vectors.md) 共同构成 `product.md` B-017/B-018
与 `tech.md` publication machine 的规范性组成部分，隔离 publication ownership、mutation-secret、
append-only history、trusted time、trust/fold 与 owner-liveness 概念边界。引用方可以通过链接或行为场景引用这里已经定义的 identifier，
但不得复制、改名或局部覆盖这里的字段集合、枚举、canonical bytes、secret boundary
或 fail-closed 语义；冲突时三份 contract各自拥有的 exact machine-facing identifiers为唯一真源。

## Concrete durable authority

唯一 production backend 是 `publication_authority_sqlite_v1`，由计划中的
`vibeguard-runtime/src/publication_authority/{mod.rs,store.rs,broker.rs,recovery.rs,restore_anchor.rs,backup_store.rs,anchor_signer.rs,governance_recovery.rs}` 与
`vibeguard-runtime/src/main.rs` 的 `publication-authority serve|recover` 命令实现；publication
client、workflow、benchmark code 均不得另建 store、直接打开数据库或以内存/mock/checkout/
Actions artifact降级。environment-protected service以单 active replica运行在独立于 runner、
checkout、Release artifact与 owner lifecycle 的 durable volume；signed deployment manifest的
closed planned **schemas/publication_authority_deployment.schema.json** 固定
`{authority_id,backend,authority_identity_digest,policy_epoch,policy_bundle_digest,client_api,control_api,
publication_store_path,publication_store_lock_path,volume_identity,kms_key_id,retention_policy_digest,
trust_bundle_digest,blocked_attempt_ledger,trusted_time_service,bootstrap_governance,break_glass_governance,
restore_anchor_service,restore_backup_service,anchor_signing_policy,predicate_evaluator_roster}`；
backend必须 exact 为 `publication_authority_sqlite_v1`。
`predicate_evaluator_roster` exact 为 `{schema_version,signature_profile,entries}`，schema version exact
`GH700:predicate-evaluator-roster:v1`；profile exact 为 `{algorithm:"ed25519",message_digest:"sha256_jcs_v1",
signature_encoding:"base64url_nopad_v1",key_version_policy:"manifest_pinned_v1"}`。entries按
`(reason_code,predicate_id,issuer_key_id,issuer_key_version)` UTF-8 bytes升序去重，每项 exact 为
`{reason_code,predicate_id,predicate_definition_digest,evaluator_identity_digest,issuer_key_id,
issuer_key_version,public_key_spki_der_b64url,public_key_spki_sha256}`；key version是非零 u64，SPKI字段是 RFC 5280
Ed25519 DER的 RFC 4648 URL-safe无 padding编码且 decoded SHA-256须 byte-equal hash，所有 digest/hash为
lowercase `sha256:<64hex>`并禁止 ambient lookup。reason/predicate闭集只由 [publication_ledger_contract.md](publication_ledger_contract.md)拥有；empty/duplicate/unknown/profile drift使 authority non-ready。
`client_api` 与 `control_api` 是同一 authority 每次启动同时绑定的 required objects，不是 union/alias/fallback。
`client_api` exact 为 `{endpoint,transport,api_version,server_identity_bundle_digest,client_auth_policy_digest}`：endpoint是 manifest-pinned absolute HTTPS origin+path且禁 redirect/userinfo/query/fragment，transport exact `tls13_mtls_http2_jcs_v1`，API version exact `GH700:publication-authority-client-api:v1`。`control_api` exact 为 `{socket_path,transport,api_version,server_process_identity_digest,peer_auth_policy_digest}`：socket是 manifest-pinned absolute
Unix path，transport exact `unix_peercred_jcs_v1`，API version exact
`GH700:publication-authority-control-api:v1`，只开放 bootstrap/migrate/recover/ready 方法且永不监听网络。
两个 API 的每个 request/response/startup receipt都必须绑定相同 top-level `authority_id`、
`authority_identity_digest`、strictly monotonic `policy_epoch` 与 `policy_bundle_digest`；该 bundle同时
digest method partition、两端 auth policy、server identities及完整 `predicate_evaluator_roster`。client server bundle由 authority外的
release-identity root锚定 exact service ID/issuer/SPKI；client auth policy闭合 repo/workflow/
environment/ref/run/actor、cert issuer、role与允许 method；control peer policy闭合 executable digest、
code-sign identity、uid/gid及允许 method。任一 API缺失、单边 rotation、四个 shared值不等、bundle
内外不一致或 policy epoch回退使整个 authority non-ready；rotation必须由一份 signed manifest原子
切换两端，旧新组合无 grace/fallback。每个 request还绑定对应 API version、frontier、operation/request
digest及 anti-replay nonce。unknown endpoint/socket、ambient discovery/proxy/DNS trust、redirect、wrong
transport/version/server/client/peer identity或 policy drift均拒绝。store path是唯一 absolute
canonical SQLite file且必须位于该 volume，禁止默认/相对/temp路径。KMS policy由 manifest钉住；
reconciler/workflow GitHub token始终 read-only，target write credential只存在于 authority sole broker的
environment secret provider，client绝不接收、转发或记录它。

`client_api` 的 method/request/result/error exact wire contract只由
[publication_ledger_contract.md](publication_ledger_contract.md)定义；本文件只定义 authority transport、
publication history与 shared durability boundary，不复制 method schema。

service启动先取得同 manifest钉住的 process lock，验证 volume支持 kernel lock与 durable `fsync`，再以 SQLite WAL、`journal_mode=WAL`、`synchronous=FULL`、foreign keys及
`BEGIN IMMEDIATE`运行。history head/leaf、operation/rotation/slot unique indexes、owner/fence、
capsule ciphertext metadata、broker outbox/delivery/send-once audit与 completed receipt须在一个
事务中验证和提交；任何 lock/busy timeout、WAL/fsync/checkpoint、disk-full或 KMS error都使
authority non-ready并 fail closed，不得返回成功 receipt。首次 database/WAL/lock 创建与 migration
commit后还须 fsync file及 parent directory；禁止 destructive migration、truncate或 silent rebuild。
authority-owned durable persistence是 exact closed inventory：signed deployment manifest与 bootstrap/
migration/governance receipts；SQLite database/WAL/checkpoint及 history/blocked-attempt/operation/rotation/
slot/owner/fence/delivery/terminal-reconciliation unique indexes；完整 attempt manifest/record/binding/
terminal-listing proof capsule+encrypted provider bytes/reconciliation/watermark、RFC3161 token proof capsules、
trusted-time preparations与 time high water；capsule ciphertext metadata与 KMS retained-key/version/retention
references；broker outbox、delivery/send-once audit与 completed receipts；external restore anchor/epoch/two frontiers、每个 encrypted
snapshot/manifest/WAL immutable backup object/version/AEAD header/retained wrapped key、backup confirmation、
online-quorum signature及 restore/recovery/break-glass receipts。其外 cache/temp/log不得参与恢复或授权，
inventory内任一缺失/不一致均 blocked。

唯一 bootstrap owner 是 SP700-T3 的 publication-authority store/deployment single writer，经计划中的
**.github/workflows/publication-authority-deploy.yml** 调用
**scripts/ci/bootstrap_publication_authority.py**：只可在不存在 database时写入 independently signed
length-zero genesis/trust bundle并签发 bootstrap receipt，已存在时必须 byte/digest-match或拒绝。
唯一 crash/restore authority 是同一 protected service的 `recover` 命令，在 exclusive process lock下
replay WAL、校验 `integrity_check`、全量重放 signed history/unique indexes/outbox/capsule metadata并
重新签发 exact-head recovery receipt。唯一 production external anchor backend/service是
`publication_restore_anchor_dynamodb_v1`：独立 maintainer-governance AWS account/region中的单一
DynamoDB table，以 strongly-consistent `GetItem` 和 `TransactWriteItems`保存不可变
`EPOCH#<restore_epoch>` rows及唯一 mutable `HEAD` row；transaction须同时以
`attribute_not_exists(epoch row)` append epoch并按 expected prior anchor digest条件更新 HEAD，禁
`PutItem` overwrite、eventual read、batch/write fallback。table开启 deletion protection、PITR与独立
KMS key；manifest钉住 `{aws_account_id,region,table_arn,table_id,table_creation_time,kms_key_arn}`，
restore到新表、删表重建或 resource identity drift均不得替换 production table。

`restore_anchor_service` exact 为 `{backend,endpoint,transport,api_version,server_identity_bundle_digest,
client_auth_policy_digest,credential_provider_identity,resource_identity,bootstrap_epoch,schema_version}`；backend exact
为 `publication_restore_anchor_dynamodb_v1`，endpoint exact 为 manifest-pinned regional DynamoDB HTTPS
endpoint且禁 redirect/proxy/ambient endpoint discovery，transport exact
`aws_dynamodb_json_1_0_https_sigv4_v1`，API version exact
`GH700:publication-restore-anchor-api:v1`。server trust验证 public CA bundle digest、AWS partition/
service=`dynamodb`与 TLS hostname；client policy exact只允许 authority workload role对钉住 region/account/
table执行 `DescribeTable`、strongly-consistent `GetItem`与上述 `TransactWriteItems`。`credential_provider_identity`只接受
environment-protected OIDC→STS short-lived role session，绑定 repo/environment/workflow/ref/audience、
role ARN/session policy digest并禁 static/ambient credentials；该 role没有 Create/Update/DeleteTable、
backup/restore、KMS administration或 policy mutation权限，authority SQLite/KMS account亦无 anchor admin。
`resource_identity` digest上述 table/KMS identity，任何 endpoint/trust/auth/resource/bootstrap drift拒绝。

唯一 production recovery-byte backend是独立 backup-governance AWS account的
`publication_restore_backup_s3_object_lock_v1`。`restore_backup_service` exact 为
`{backend,endpoint,transport,api_version,resource_identity,writer_auth_policy_digest,recovery_auth_policy_digest,
retention_class,minimum_retention_seconds,encryption_contract,data_key_wrap_contract}`；`data_key_wrap_contract`
exact 为 `{provider:"aws_kms_v1",operation:"GenerateDataKey",key_spec:"AES_256",
kms_key_arn,encryption_context_schema:"GH700:backup-data-key-context:v1"}`。manifest钉住 account/region/bucket ARN+name+
creation time、versioning/Object-Lock enabled、独立 KMS key ARN/key ID与 public-CA/server identity，禁 ambient
endpoint/proxy/credential。retention exact `permanent_no_ttl_legal_hold_v1`：每个 version以 Compliance mode至少
100年且开启 legal hold，无 lifecycle/overwrite/delete；governance须在不足10年剩余窗口前 threshold批准延长，
否则 authority non-ready。writer的短期 OIDC→STS role只允许 S3 `PutObject`/`GetObjectVersion`/读 retention/hold，
及 exact KMS key上的 `kms:GenerateDataKey`，且 IAM/key policy以 encryption-context conditions绑定下述 exact字段；
显式无 `kms:Decrypt`/`Encrypt`/`ReEncrypt*`/key administration、S3 delete/overwrite/解除 hold/lifecycle权限。
protected recovery role只在 threshold-approved restore中读 exact versions并以同 context调用 pinned KMS decrypt。

每个 committed successor先生成 exact `backup_set_core={backup_id,resource_identity,snapshot_object_key,
snapshot_version_id,snapshot_ciphertext_digest,manifest_object_key,manifest_version_id,
manifest_ciphertext_digest,wal_object_key,wal_version_id,wal_ciphertext_digest,kms_key_arn,kms_key_version,
wrapped_data_key_set_digest,aead_contract_digest,retention_until,legal_hold_status}`，其中 `wrapped_data_key_set_digest=SHA256(JCS([{object_kind:"snapshot",wrapped_data_key_digest},{object_kind:"recovery_manifest",wrapped_data_key_digest},{object_kind:"wal",wrapped_data_key_digest}]))` 且数组顺序固定、每个 digest 取对应 immutable object header 中 exact wrapped-key bytes 的 SHA256；及
`backup_set_core_digest=SHA256(JCS(backup_set_core))`。detached `backup_confirmation` exact 为
`{backup_set_core_digest,snapshot_get_receipt_digest,manifest_get_receipt_digest,wal_get_receipt_digest,
retention_receipt_digest,legal_hold_receipt_digest}`，`backup_confirmation_digest=SHA256(JCS(backup_confirmation))`，
`backup_set_ref={backup_set_core,backup_set_core_digest,backup_confirmation_digest}`；三者都不包含自己的 digest。SQLite snapshot、
recovery manifest和 WAL（包括 canonical empty WAL）分别使用 fresh 256-bit data key与 96-bit nonce执行
`aes_256_gcm_siv_v1` authenticated encryption。`successor_frontiers={publication_history_frontier,blocked_attempt_frontier}` exact，两个 frontier都含 full-prefix且来自同一 successor；
`successor_frontiers_digest=SHA256(JCS(successor_frontiers))`并编码 lowercase `sha256:<64hex>`。每个 object先构造 exact KMS context
`{schema_version:"GH700:backup-data-key-context:v1",authority_id,repo_node_id,backup_id,object_kind,
successor_frontiers_digest,prior_anchor_digest}`，再调用一次 `GenerateDataKey(KeyId=manifest exact ARN,
KeySpec="AES_256",EncryptionContext=exact context)`；只接受32-byte plaintext与对应 `CiphertextBlob`，plaintext只在
内存完成该 object加密后立即清零且绝不落盘/上传，wrapped data-key bytes exact 为 `CiphertextBlob`。immutable
object header保留 nonce、exact KMS context、wrapped data-key bytes、tag和
`AAD=JCS({authority_id,repo_node_id,backup_id,object_kind,successor_frontiers,time_high_water,plaintext_digest,
prior_anchor_digest})`；encrypt及 restore/decrypt都从 AAD exact frontiers重算 digest并要求 byte-equal KMS context字段，三者禁止明文或 unauthenticated compression。上传后须 exact-version strong GET，重算
ciphertext/header/wrapped-key digest并确认 retention+legal hold；wrong key ARN/spec/context、重复 data key、
plaintext残留或任何对象未确认都不能签 anchor或释放 receipt。

DB successor transaction 只固化 exact `anchor_plan_core={authority_id,authority_identity_digest,policy_epoch,
repo_node_id,anchor_schema_version,restore_epoch,latest_frontier,blocked_attempt_ledger_frontier,time_high_water,
time_proof_digest,transition_class,prior_anchor_digest,backup_id,anchor_plan_id}` 及
`anchor_plan_core_digest=SHA256(JCS(anchor_plan_core))`；core 禁止包含任何 snapshot/WAL digest、object version、
`backup_set_ref*`、confirmation、final payload/request ID。exact-version backup 确认后才构造 final anchor payload
`{anchor_plan_core,anchor_plan_core_digest,snapshot_digest,wal_digest,backup_resource_identity,backup_set_ref,
backup_set_ref_digest,anchor_request_id}`，其中 `backup_set_ref_digest=SHA256(JCS(backup_set_ref))`且
`anchor_request_id=SHA256(JCS({v:"GH700:anchor-request:v1",anchor_plan_core_digest,backup_set_ref_digest}))`。
两个 frontier 含 exact `full_prefix_digest`；external HEAD/epoch row保留完整 object keys/version IDs/crypto+retention locator而非只留 digest，
snapshot/WAL plaintext digests必须与该已确认 encrypted set一致。
`anchor_signing_policy` exact 为 `{routine_policy,privileged_policy}`。routine class仅
`{publication,blocked_attempt,trusted_time,owner_heartbeat}`，由至少3个不同管理域/account的 pinned
KMS-backed online signer服务取 distinct threshold>=2；每个 signer manifest固定 endpoint/mTLS server identity、
non-exportable key ARN+version、allowed class/repo/authority/schema、prior→next epoch only policy与5分钟 client
credential TTL。signer各自 strong-read HEAD，验证 exact prior、successor/backup confirmation及无 schema/policy/root
变化后只签 domain-separated `routine_anchor_advance_v1` digest；它不能写 DynamoDB/S3、签 bootstrap/restore/
governance/emergency或取得 maintainer key。OIDC→mTLS credential绑定 workload/environment/request digest且单次使用；
key启用/轮换/撤销需 privileged threshold批准、manifest epoch提升、old+new quorum overlap receipt及历史 public key永久
保留，expired/revoked key不得签新请求。privileged class仅 `{bootstrap,migration,restore,governance,
emergency_root_cutover}`，继续要求独立 maintainer或 break-glass threshold离线批准；两类 signature不可互换。
每个 committed history/attempt/time successor须在释放成功 receipt或允许 broker write前，以 prior digest+epoch作为
conditional CAS推进 anchor。ack丢失只可
strong-read同 epoch row+HEAD并 byte/digest-match同 request ID确认，不得重写；并发/stale CAS只能一胜，
loser重读后若不是其 exact payload即 blocked。authority DB commit后/anchor CAS前 crash可在独占恢复中
以 committed successor重试同 CAS，但 broker仍禁写；anchor CAS后/本地 receipt前 crash只可按上述
read-confirm补 receipt。任何成功 receipt必须携 DynamoDB transaction request digest、signed payload、
epoch row/HEAD exact digest与 strong-read confirmation，形成 DB committed frontier→encrypted backup confirmation→
class-correct quorum signature→conditional transaction→service response/read-back→authority receipt 的端到端 CAS proof。

所有 successor共用 repository-global durable `anchor_commit_gate`，不得只依赖已释放的 SQLite write lock。
在 gate fence下，首个 transaction append successor并写唯一 `db_committed_anchor_pending` row，只固定 prior anchor、
`anchor_plan_core`/digest、backup ID和签名 class后 commit+fsync；该 row 所在 snapshot 因而不含尚未产生的
snapshot digest、object version、backup confirmation或 final payload。该 pending未完成时所有其它 successor transaction
在写 DB前拒绝。gate跨 snapshot/WAL/manifest加密上传、exact-version确认、quorum签名、DynamoDB CAS/read-confirm
保持逻辑独占，但不跨网络持有 SQLite transaction。backup 确认后一个 short transaction 以
`anchor_plan_core_digest` CAS 同一 pending row，写入 detached confirmation、final payload/request ID；任何 core/backup drift均 blocked。
CAS确认后下一 transaction才写 immutable
`anchor_confirmed` proof/成功 receipt、清 pending并 fsync，然后释放 gate；client receipt与 broker write此前均禁止。
crash recovery只可 higher-fence接管同一 pending row；plan-only phase 只可从同一 core/backup ID 完成并固化
detached confirmation，finalized phase 复用 byte-identical payload/request/backup versions/signatures：
未发 CAS则发送一次，response/ack丢失则 strong-read exact epoch+HEAD确认，已确认但本地未记账则补写同 confirmation；
任何 non-match、无法证明未发送或 backup/signature drift均保持 pending并使 authority blocked，禁止 rollback/truncate、
生成下一 successor或返回“可能成功”。

唯一 bootstrap/migration/restore implementation owner是 SP700-T3：计划中的
**.github/workflows/publication-restore-anchor-deploy.yml** 与
**scripts/ci/bootstrap_publication_restore_anchor.py** 在 environment protection及 governance threshold
批准后创建/核验空表、以 `restore_epoch=0` conditional transaction写 genesis并把 receipt并入 authority
bootstrap；migration只可 append higher schema epoch且不得改写旧 epoch。snapshot+WAL restore须先
strong-read production HEAD，以更大 `restore_epoch`获 threshold批准，证明 restored history与 blocked-attempt
prefix均不少于且 exact包含 anchored two frontiers/full-prefix、restored time high water不低于 anchor，完成
从 HEAD绑定的 exact `backup_set_ref`强读三个 immutable versions、验证 bucket/KMS identity、Object Lock/hold、
AEAD header/tag/AAD及 ciphertext/plaintext digests后才解密并 replay；recovery manifest必须逐项证明 DB/WAL/schema/
indexes/outbox/capsules/time/history/ledger与 anchor一致。完成 replay/recovery receipt后，以新的 encrypted backup set
和 privileged restore approval CAS新 anchor；T3执行，独立
maintainer governance持 approval/admin role，二者不得互换。missing/stale/equal-or-lower epoch、older/
forked prefix、wrong table/service identity、CAS conflict、unprovable ack或 KMS不可解封均拒绝。T10只消费
认证 client API，不拥有 authority/anchor backend、write/admin credential或 bootstrap/migration/recovery authority。

端到端证明必须在真实 durable-volume fixture对每个 transaction boundary注入 kill/power-loss、并发
claim/slot/delivery、WAL/checkpoint失败、disk-full、KMS unavailable、runner/checkout删除、owner
terminal与 authenticated encrypted snapshot+manifest+WAL restore；重启后只允许 exact committed state或未提交状态，绝无
双 owner、双 send、丢 leaf/index/capsule/outbox或 unsigned frontier。anchor integration fixture须对真实
DynamoDB隔离 non-production-account test table及 Object-Lock test bucket验证 concurrent single-winner、stale prior/
epoch、pending-gate serialization、ack loss read-confirm、DB-commit↔backup↔anchor-CAS每侧 crash、wrong table/
bucket/version/KMS/credential/trust、missing/tampered ciphertext/tag/AAD/manifest/WAL、PITR新表替换、bootstrap replay、
routine signer loss/rotation/revocation与 privileged signed restore；mock/in-memory结果不能作为通过证据。

## Blocked-attempt ledger boundary

B-029 的 backend、record union、binding、pagination、terminal completeness watermark、retention、restore 与
client API 只由 [publication_ledger_contract.md](publication_ledger_contract.md) 定义。它与 publication
history 共用 durable DB/backup/anchor gate，但 authorization domain、frontier、fence与 operation index保持独立。

## Rollback-resistant trusted time

host wall clock、process monotonic clock、client timestamp、GitHub event time与 unsigned HTTP `Date` 均不授权
expiry/takeover。deployment manifest 的 `trusted_time_service` exact 为
`{backend,api_version,threshold,sources,max_accuracy_seconds,proof_retention_policy_digest}`，backend/API exact
为 `rfc3161_tsa_quorum_v1` / `GH700:trusted-time-api:v1`；`sources` 是至少三项按 `source_id` canonical排序的
`{source_id,endpoint,transport,tsa_policy_oid,signer_bundle_digest,server_identity_bundle_digest,
client_auth_policy_digest}`，endpoint为无 redirect/query/fragment的 manifest-pinned HTTPS path，transport
exact `tls13_mtls_rfc3161_sha256_v1`，threshold至少二且不超过 source数。source须独立 administration/
signing root；ambient DNS/proxy/CA、TOFU、同 root重复 signer、unknown policy/algorithm均拒绝。

T10只提交 ledger contract的 proof-free `time_bound_intent/client_payload_core`与可重算
`time_bound_request_id`。T3验证 method/kind/exact predecessor并从 signed fold取 prior high water；
`owner_claimed`以 `claim_pre_nonce_core_digest` durable reserve operation为 `claim_reserved`，再按 operation ID
幂等签发并 FULL-fsync唯一 draft nonce/capsule为 `claim_capsule_frozen`。三种 transition的
`publication_payload_core`均由 authority构造：删除 final payload的 trusted-time-produced字段、保留 fold-owned
high water，claim core另含 frozen capsule四字段；client hash/preimage不含 authority字段。然后生成 fresh
256-bit trusted-time nonce，`nonce_b64u` 是其32 bytes的 canonical
unpadded base64url encoding，并计算
`nonce_digest=SHA256(JCS({v:"GH700:trusted-time-nonce:v1",authority_id,repo_node_id,
owner_generation,run_id,run_attempt,transition_slot,record_kind,nonce_b64u}))`，再计算
`trusted_time_proof_request_id=SHA256(JCS({v:"GH700:trusted-time-proof-request:v1",authority_id,repo_node_id,
owner_generation,run_id,run_attempt,transition_slot,predecessor_frontier,record_kind,
publication_payload_core_digest,prior_time_high_water,nonce_digest}))`；它与 payload core 先按下述 closed derivation
生成 `transition_operation_id`，之后才请求每个 TSA 对
`SHA256(JCS({v:"GH700:trusted-time-proof:v1",authority_id,repo_node_id,transition_operation_id,
trusted_time_proof_request_id,predecessor_frontier,nonce_b64u}))` 签 RFC3161 token。验证 distinct threshold signer、message imprint、policy OID、
certificate chain、`gen_time`与 accuracy后，将各 interval `[gen_time-accuracy,gen_time+accuracy]` 求交；无交集、
accuracy超限、token replay或 signer不足即拒绝。`trusted_lower_bound`取交集下界，`trusted_upper_bound`取上界；
只有 `trusted_lower_bound >= prior_time_high_water` 才接受，`accepted_at=trusted_upper_bound` 且
`new_time_high_water=trusted_upper_bound`。claim/heartbeat/expiry/takeover payload或 committed envelope exact绑定
`{trusted_time_proof_digest,trusted_lower_bound,trusted_upper_bound,prior_time_high_water,new_time_high_water}`及
全部 token bytes/digests的 durable proof capsule；SQLite transaction提交 transition与新 high water后，释放
receipt或 takeover权限前还须 CAS external anchor同一 high water/proof digest。restore不得回退它。

heartbeat only-if-alive 判定要求 `trusted_upper_bound < prior lease_expires_at`；takeover only-if-expired判定要求
`trusted_lower_bound > lease_expires_at`，边界相等或 uncertainty跨 expiry均拒绝。lease expiry仍按获批 H-006
由 `accepted_at`计算。proof unavailable、anchor CAS不确定、source/policy/threshold drift、high-water rollback/
fork或 SQLite↔anchor mismatch使所有 time-dependent transition fail closed；绝不 clamp到 host time、猜 expiry或
以 job absence接管。T3独占 `trusted_time.rs` client/proof/high-water persistence及
[client API contract](publication_ledger_contract.md)定义的 crash-safe preparation；T10只能提交 method-specific
non-authoritative time-bound request；
T12须用真实 RFC3161-compatible independent test signers覆盖 host forward/backward jump、replay、quorum split、
accuracy overlap、restart/snapshot rollback、heartbeat-vs-takeover race与 anchor ack-loss。

## Bootstrap governance and first frontier

deployment manifest 的 `bootstrap_governance` exact 为
`{bootstrap_version,release_identity_root_digest,governance_roster_digest,governance_threshold,
governance_signer_key_ids,initial_trust_bundle_digest,initial_trust_epoch,first_frontier,
first_blocked_attempt_frontier,initial_time_high_water,initial_time_proof_digest}`。
release-identity root在 store/history/AWS accounts之外，
签 roster attestation并把 canonical distinct signer key IDs、`1 <= threshold <= signer_count`、repo/purpose、
initial trust root/leaf certificates与 epoch钉住。`bootstrap_manifest_core_digest` exact 为
`SHA256(JCS(deployment_manifest_core))`，core 是完整 closed deployment manifest payload 且不含任何
signature/attestation/approval envelope。detached `bootstrap_approval` exact 为
`{bootstrap_manifest_core_digest,release_identity_attestation_digest,governance_roster_digest,
governance_threshold,signer_key_ids,threshold_signatures}`；roster 中 distinct threshold signers 只签
`SHA256(JCS({v:"GH700:bootstrap-manifest-approval:v1",bootstrap_manifest_core_digest}))`，
`bootstrap_approval_digest=SHA256(JCS(bootstrap_approval))` 仅进入 receipt/anchor，不回填 manifest core。
self-signed/TOFU、重复 signer、阈值不足、core/signature/root/roster/epoch drift均拒绝。

`first_frontier` 唯一为 length zero：`repo_node_id` exact，`history_length=0`，`history_root` exact 为
`SHA256(JCS({v:"GH700:history-empty-root:v1",repo_node_id}))`，`full_prefix_digest` exact 为
`SHA256(JCS({v:"GH700:history-empty-prefix:v1",repo_node_id}))`。
`first_blocked_attempt_frontier` 同样固定 `ledger_length=0`，root/full-prefix分别由
`GH700:blocked-attempt-empty-root:v1` / `GH700:blocked-attempt-empty-prefix:v1` 加 `repo_node_id` 做 JCS SHA-256。

history 与 blocked-attempt ledger 共享下列唯一 successor framing，其中
`domain∈{history,blocked-attempt}`；history 的 `leaf_bytes=JCS(exact closed history top-level record)`，
blocked-attempt 的 `leaf_bytes=JCS(exact ledger_leaf envelope)`（envelope exact 结构见
`publication_ledger_contract.md`）；`u64be` 是 unsigned 64-bit big-endian，`digest_bytes` 只解码
canonical lowercase `sha256:<64hex>`：
`leaf_hash=SHA256(UTF8("GH700:"+domain+"-leaf:v1")||0x00||u64be(len(leaf_bytes))||leaf_bytes)`；
`next_length=prior_length+1`；
`next_root=SHA256(UTF8("GH700:"+domain+"-root:v1")||0x00||digest_bytes(prior_root)||leaf_hash||u64be(next_length))`；
`next_full_prefix_digest=SHA256(UTF8("GH700:"+domain+"-prefix:v1")||0x00||
digest_bytes(prior_full_prefix_digest)||u64be(len(leaf_bytes))||leaf_bytes)`。结果统一编码为 lowercase
`sha256:<64hex>`；length overflow、non-canonical digest/record bytes或任一重算不等均拒绝。
下列 framing-only golden 使用 `repo_node_id="R_kgDOGH700"`、上述 length-zero frontier 与
`leaf_bytes=7b7d` (`{}`，仅隔离验证 hash primitive，record schema 仍必须拒绝它)：

| domain | `leaf_hash` | successor root | successor `full_prefix_digest` |
| --- | --- | --- | --- |
| `history` | `sha256:f846a7690345ef0b8217076e8a5b960ed0394701191ea3f497a25a7083304ac1` | `sha256:0781fb121749d9247a26f74f34449715311cf09511ec81ab0103c0b758583bc3` | `sha256:e73400b4b88aa43e6500ab69b4bafee6693cc2a0c733d0228e3e41a3701b6d76` |
| `blocked-attempt` | `sha256:86a1d6dedf4fb174dee3f38281770624896176b1a89b244b4c0ecf3ca5a07b1c` | `sha256:1ab51f4579df55ede8eb606fd2558a0ebfd4364de7016e16c31dbfc0a71f4153` | `sha256:24c3426a0db6999dc2c3e1dd610bb62ce321fa8fb743237edf0e6306c0bc488f` |

T3 bootstrap只在 DB/anchor均不存在时，以
threshold approval、RFC3161 quorum initial-time proof和外部 release-identity attestation原子创建 SQLite
genesis/trust state，再以 DynamoDB epoch-zero conditional transaction锚定 first frontier、zero blocked-ledger
frontier及 initial time high water；两侧任一已存在只可 byte/digest match，不能重置。bootstrap receipt exact
绑定 `bootstrap_manifest_core_digest`/`bootstrap_approval_digest`、root/roster/threshold/signer set、first frontier、trust epoch、time proof与 anchor transaction。

deployment manifest同时必须有独立 `break_glass_governance={recovery_root_digest,recovery_roster_digest,
recovery_threshold,recovery_signer_key_ids,allowed_causes,minimum_audit_delay_seconds,recovery_policy_digest}`。
recovery root/roster在 authority/history/anchor/backup/routine-signer accounts之外，由至少3名 cold offline
signer组成且 threshold>=2；key/approval不能与 routine online quorum或 current trust bundle复用，allowed causes只含
`{active_leaf_expired,active_root_expired,current_threshold_unavailable,current_threshold_revoked}`。bootstrap
approval同时签该 exact recovery contract；缺失、阈值不足、同管理域或未经 bootstrap root验签即 publication unavailable。

当 normal leaf/root rotation因 active key过期/撤销或 current threshold不可达而不可能满足 pre-state trust时，唯一
恢复路径是 `trust_emergency_root_cutover`。authority先冻结 publication/broker与 normal governance，strong-read
DynamoDB HEAD和其 exact encrypted backup set，完成 restore-grade AEAD/full-prefix/time-high-water验证；rollback、
fork、pending anchor或 backup缺失时不得开始。然后构造 exact
`incident_open_intent={schema_version:"GH700:break-glass-incident-open:v1",repo_node_id,recovery_incident_id,cause,
current_anchor_digest,current_frontier,current_trust_epoch,recovery_policy_digest}`，`incident_open_intent_digest=SHA256(JCS(incident_open_intent))`；T3以 normal RFC3161 quorum生成
incident-open proof及 interval，并 conditional anchor immutable `INCIDENT#<recovery_incident_id>` row。exact
`incident_open_receipt={incident_open_intent_digest,trusted_time_proof_digest,trusted_lower_bound,
trusted_upper_bound,prior_time_high_water,new_time_high_water,anchor_epoch,anchor_transaction_digest}`，其 `incident_open_receipt_digest=SHA256(JCS(incident_open_receipt))`；same incident same bytes幂等，异值冲突。

cutover须取得另一个 fresh trusted-time proof，exact
`audit_delay_evidence={incident_open_receipt_digest,incident_open_trusted_upper_bound,
cutover_trusted_lower_bound,minimum_audit_delay_seconds,cutover_trusted_time_proof_digest}`；intent digest须重算且 byte-equal anchored receipt字段，evidence的 receipt digest/upper bound须 byte-equal该 receipt，cutover lower bound/proof digest须 byte-equal fresh verified proof，minimum须 byte-equal manifest的 governance值，且 only-if
`cutover_trusted_lower_bound >= incident_open_trusted_upper_bound + minimum_audit_delay_seconds`；等式允许，
`audit_delay_evidence_digest=SHA256(JCS(audit_delay_evidence))`；interval overlap、host/client time、未 anchored
open receipt、pre-state drift或 time-high-water rollback均拒绝。
distinct recovery threshold signer只对含 `{incident_open_receipt_digest,audit_delay_evidence_digest}`的
`{repo_node_id,cause,evidence_digest,current_anchor_digest,current_frontier,current_trust_epoch,new_bundle_digest,
next_trust_epoch,recovery_incident_id,audit_log_digest,incident_open_receipt_digest,audit_delay_evidence_digest}`
做 domain-separated offline approval；new bundle须有全新 root、
满足正常 threshold的 signer roster、单调 next epoch与 release-identity attestation。special envelope只接受该
bootstrap-pinned recovery chain，不要求已失效 old key；它 append exact-predecessor emergency record，再将新的 encrypted
backup、完整 break-glass audit和 privileged `emergency_root_cutover` signature CAS到更高 external anchor epoch。
anchor确认前 old state仍 active且零 write/receipt；确认后只从 anchored successor启用 new root。approval、incident/
cause证据、参与 signer、incident-open/cutover trusted-time proofs与 intervals、backup/anchor request/read-back及 cutover receipt永久保留且可独立审计；
不能改写旧 history、降低 time/frontier、重置 bootstrap或跳过 external anchor。recovery roster本身不足 threshold时
系统保持 blocked，只能通过另一个已 bootstrap-pinned recovery threshold，绝无单人/admin/manual DB bypass。

first history record的 predecessor必须是 first frontier并由 initial trusted leaf签名，或按上述 special envelope
执行 exact emergency cutover；其后 `{trust_leaf_rotated,trust_root_rotated,trust_key_revoked,
trust_emergency_root_cutover}` 可在首次 eligible valid publication之前按各自 normal/emergency authorization追加。
前三者使用独立 governance lease/fence/threshold。`genesis_zero` fold把这些验签、phase-neutral且 publication-state-neutral
的 records与 terminal non-valid/no-publication records一并忽略，只要求从 first frontier到本次 exact prepared
owner之间从未出现 eligible valid publication/current marker restoration；它们不使 genesis失效。bootstrap
root/roster不能由 history rotation替换；rotation只按 current trust chain推进，recovery必须从 manifest-pinned
first frontier重放完整 prefix、验证每个 cutover/threshold signer及 external anchored latest frontier，缺 first
frontier/bootstrap receipt、未知 signer、rotation gap/fork或 rollback一律拒绝。

## Ownership 与 lock order

所有会公开 Release/README 的分支都先按唯一顺序取得
source/candidate、repository-ledger、repository-publication 执行 lease，再做
default-branch CAS；禁止反向或持后序 lease 再取前序 lease。完整重验 local assets、
summary、policy 与 exact human-reviewed README patches 后，且在首次 Release API mutation、
generated PR、marker/Release/README 动作前，必须在受认证、retention-independent、
append-only `publication_history` 中 fenced-CAS append durable `owner_claimed`，绑定
server-authenticated `repo_node_id`/workflow/run/attempt/ref、candidate/tag/source、永不复用的
`owner_generation`、
summary/policy/asset-manifest/base/review/marker-plan digest、`liveness_policy_digest` 与
`draft_claim_nonce_digest`。它不需要 draft ID但立即成为 active owner。只有该 owner 可携
claim nonce 创建 exact private draft；服务端返回后、任何 asset upload 前必须 append
`draft_bound`（release node ID/tag/target/source/claim digest），全部上传并重验后才 CAS
`prepared`。短 lease 可在等待 review 时释放，active owner 仍阻断其它 candidate；
恢复时按同一顺序重取 lease并提升 fence。
## Candidate tag 与 mutation slot

claim 还必须绑定 immutable `candidate_tag_identity`：repo、canonical
`refs/tags/<name>`、ref node/OID、annotated tag object与完整 peel chain、peeled commit
（必须等于 source）及 effective tag-protection/ruleset digest。official 候选必须已有受保护、
不可更新/删除且无 actor/App bypass 的 tag；Release API 不得隐式创建或移动 tag。所有
normal/recovery Release 写使用同一 closed slot machine，payload 字段 `mutation_kind∈{draft_create,
draft_update,draft_delete,asset_upload,asset_delete,publish}`。远程调用前须 fenced-CAS append
`record_kind=release_mutation_planned`（payload携 `mutation_kind,transition_slot`），绑定 repo/tag identity/owner generation/
mutation kind/slot/predecessor/stable mutation slot ID/plan-core digest、`mutation_nonce_digest`+opaque `mutation_nonce_capsule_id`/`broker_delivery_id`、trusted App/installation、exact pre-state/public non-secret request
template/expected post-state digests及完整 kind tuple。`draft_create` 另绑定
`draft_claim_nonce_digest`、draft-claim capsule identity、tag/source/public metadata；其它 kind
绑定各自 full pre/post tuple。
history中的 `request_commitment` 只对 public template、mutation nonce digest/capsule identity及
draft-create专用 claim nonce digest/capsule identity做 JCS hash。构造顺序固定且无环：先冻结不含
nonce/capsule/commitment/ciphertext/final payload digest/operation ID的 non-secret plan core，
再计算 `plan_core_digest`及 `mutation_slot_id=H(v,repo_node_id,owner_generation,mutation_kind,
transition_slot,predecessor,plan_core_digest)`并选择 opaque `mutation_nonce_capsule_id`。store/HSM CSPRNG为 slot
签发 fresh mutation nonce及 typed digest `mutation_nonce_digest = SHA256(JCS({v:"GH700:release-mutation-nonce:v1",
repo_node_id,owner_generation,mutation_kind,transition_slot,mutation_slot_id,nonce_b64u}))`；
随后计算 request commitment并以 `(repo,owner,mutation_kind,transition_slot,mutation_slot_id,
request_commitment)` 作 capsule AAD/index，最后把 ciphertext digest/KMS version纳入 final
payload并计算 payload digest与 generic transition operation ID。capsule持久化与 planned append
同事务；same operation replay只返原 plan/capsule，跨 slot/kind/owner/slot-ID/operation替换拒绝。
六种 mutation均拒绝 raw mutation nonce、含它的 request bytes及可逆编码进入 template/commitment
preimage/intent/history/operation ID/log/report/receipt；raw draft-claim nonce同样只可在 authorize后
经 authenticated secret channel解封，并由 broker在内存物化 wire request。mutable fence/lease只在 authorization envelope。
只有 planned state可经 environment-protected sole broker调用；pre-call guard authorization
绑定 current tag/ruleset、owner、actual fence/frontier、plan digest与 `broker_delivery_id`，
broker须按 plan解封 exact mutation capsule及 draft-create的 exact claim capsule、重算各 typed
digest、plan-core/slot-ID/final payload/operation derivation，并证明 canonical template对每个
declared secret恰有一个 typed placeholder且无其它
placeholder；只允许替换这些位置并使用 plan-pinned endpoint/method。signed send-once audit
绑定 plan/request commitment、`mutation_nonce_capsule_id`/draft-claim capsule IDs+ciphertext
digests、endpoint/method、`mutation_slot_id`/`broker_delivery_id`、`effective_request_digest`与 delivery outcome，不含 raw secret；restart/takeover复用 same capsule/delivery，store/
broker拒绝 same slot/delivery第二次 send。该 audit不证明 remote commit。normal response后
重取 server state，只有 postcheck通过才 append
`release_mutation_bound`与 completed guard receipt，绑定 `request_commitment`、`broker_delivery_id`、
response/resource IDs、pre/post tag+ruleset tuples、owner/fence/frontier。
send/response/postcheck/bind任一不确定时禁止重发，先进入 `release_mutation_recovery_pending`，
重取 lease/fence/frontier并按 immutable plan完整分页枚举 Release/all states/assets及 broker
outbox/delivery/audit：唯一 exact post-state、正确 tag/source/App/delivery且无 extra时以 fresh
discovery/postcheck receipt恢复 bound；exact pre-state加 authenticated exhaustive negative
且 broker证明 request quiescent/not-in-flight时 append `release_mutation_not_applied`，之后才可
新 slot；zero但仍 in-flight不得重发。partial/conflicting/multiple state只能先 append
`compensation_planned`，其远程补偿本身也是新 planned/guarded/bound slot，完整证明恢复
pre-state且无 extra后才 `compensated`。blocked-kind precedence唯一为：`mutation_kind=draft_create`
的 permission/pagination/audit/rate-limit/5xx或任何不可证明 outcome只进入 `draft_recovery_blocked`，
此时 `release_mutation_recovery_blocked` schema-invalid；generic blocked kind仅适用于
`{draft_update,draft_delete,asset_upload,asset_delete,publish}` 的不可逆/不可证明 outcome、tag move/
delete/recreate、peel/source/ruleset/bypass drift，并保留 owner。takeover只能引用旧 plan并 fresh authorize。
`draft_bound`/`prepared`/publish/cleanup/terminal/`recovered_publication` 只能在所有 predecessor
slots进入 closed terminal set `{bound,not_applied,compensated}` 后推进；每个 not-applied须携
exact-pre-state+exhaustive-negative+broker-quiescence receipt，每个 intended phase effect须由
恰一 later/effective bound slot满足或由 compensated显式恢复，且无 pending/blocked/in-flight/
extra resource。final recovery还须 fresh
finalization receipt绑定 current tag tuple与完整 slot chain。任何窗口 drift不写 recovered/README。
`owner_claimed` append request须通过 authenticated secret channel另交由 store/HSM CSPRNG
为该 proposed generation签发的 uniform 256-bit one-time nonce；未消费的 issuance不授权任何
Release/PR/draft mutation。nonce跨 repo/candidate/generation全局不得复用，且不进入 JCS
intent、operation ID、history payload、日志或报告。store以永久 unique index拒绝复用，并在
同一事务验证 `draft_claim_nonce_digest = SHA256(JCS({v:
"GH700:draft-claim-nonce:v1", repo_node_id, owner_generation, nonce_b64u}))`及 issuance
attestation；schema固定字段类型/Unicode normalization，`nonce_b64u`只能是32-byte nonce的
unpadded base64url canonical encoding，任何替代边界/编码均拒绝。随后以 KMS/HSM封装到 retention-independent secret
capsule，key为 `(repo_node_id, owner_generation, transition_operation_id)`；committed
envelope只绑定 opaque `nonce_capsule_id`、ciphertext digest与 KMS key version。capsule与
对应历史解密 key须保留到整个 candidate publication ownership successor chain terminal及
获批的 recovery/audit retention window结束，绝不能在旧 generation被 takeover/terminal时
提前销毁；key rotation不能破坏 active recovery。
unwrap还须提交 current repository-publication lease scope/token、latest signed frontier与
server-authenticated actor；store必须核对 actor 的 repo/workflow/App/installation/run identity
是 exact current owner，或是在 trusted-proof-derived store-auth expiry 后由 exact-frontier takeover record建立的
同 candidate successor，并验证 current fence。公开的 fence/generation/capsule ID本身都不是
credential，不能授权读取/解封。解封后重验 digest；restart发生在
claim commit后、draft create前时必须复用该 nonce；capsule缺失、越权、密文/key-version/
digest不符或 KMS不可用均进入 `draft_recovery_blocked`，不得生成新 nonce、重写 claim或创建
第二个 draft。

## Generated PR、documentation 与 publication states

所有 generated PR及 replacement统一使用
`record_kind=generated_pr_planned → record_kind=generated_pr_bound`，两者 payload的 `pr_kind ∈
{decurrent,rollback,new_current,nonvalid_row,invalidate_current}`。planned必须早于首次
head-ref/commit/PR mutation，绑定 repo/owner generation/kind/candidate、base ref/OID、head
repo/ref、expected tree/OID、patch/nonce/ruleset digest、trusted App/installation identity及
replacement chain；nonce必须进入受保护 deterministic ref/commit/check identity，不能只放可编辑
PR metadata。create/bind response loss须完整分页枚举 draft/open/closed/merged/queued PR与 head
ref并核对完整 tuple：唯一 active match在重读 latest signed frontier/fence/ruleset后 CAS bound；
唯一 merged match按 kind进入 receipt/rollback/marker/row恢复；closed match先 revoke再
replacement。ordinary/stale zero保留 owner且不得重发 non-idempotent create；仅同一线性化快照
覆盖 PR+ref的 authenticated exhaustive negative receipt及 broker quiescence可证明不存在，此时 append
`generated_pr_not_applied`后才可 new slot。多匹配、tuple/creator
不符、分页/权限不全、rate-limit/5xx/timeout或无强一致 absence API，按 kind进入对应 recovery
blocked variant。旧 fence late bind、reopen/ref ABA、stale check/review与 ruleset bypass均由
latest-frontier merge gate拒绝。

generated PR nonce由 mutation broker/HSM签发为 uniform 256-bit one-time value，`nonce_b64u`只能是
32-byte nonce的 canonical unpadded base64url。唯一公开承诺为
`head_ref_nonce_digest=SHA256(JCS({v:"GH700:generated-pr-head-nonce:v1",repo_node_id,
owner_generation,pr_kind,transition_slot,nonce_b64u}))`；raw nonce不得进入 history、commit、check、
PR metadata、日志或报告。`owner_generation_digest=SHA256(JCS(owner_generation))`，exact ref为
`refs/heads/vibeguard/gh700/<owner_generation_digest>/<pr_kind>/<transition_slot_decimal>/
<head_ref_nonce_digest>`；两 digest path component均为 lowercase 64-hex且不带 `sha256:`。
`generated_pr_review_core` exact object为 `{v:"GH700:generated-pr-review-core:v1",repo_node_id,
owner_generation,pr_kind,transition_slot,base_ref_oid,head_repo_node_id,head_ref,
head_ref_nonce_digest,expected_tree_digest,patch_digest,merge_method,ruleset_digest,
trusted_app_identity_digest,trusted_installation_identity_digest,replacement_chain_digest_or_null}`，其
`review_core_digest=SHA256(JCS(generated_pr_review_core))`。reviewed commit必须只有一个 exact trailer
`VibeGuard-Generated-PR-Review-Core: <review_core_digest>`，commit OID/tree/ref与 core逐字段一致。
`generated_pr_check_identity` exact object为 `{v:"GH700:generated-pr-check-identity:v1",
repo_node_id,owner_generation,pr_kind,transition_slot,head_repo_node_id,head_ref,head_oid,
review_core_digest,trusted_app_identity_digest,trusted_installation_identity_digest,ruleset_digest}`，其
`check_identity_digest=SHA256(JCS(generated_pr_check_identity))`；required check的 `external_id`必须 exact
等于该 digest，且 check App/installation/head SHA/ref均匹配。ref、commit trailer、check三者任一缺失或
不一致均不能 bind/merge；每次 replacement必须新 slot、nonce、ref、review core、commit与 check identity。

planned transition提交并得到 `planned_operation_id`后，authority exact 派生
`generated_pr_delivery_id=SHA256(JCS({v:"GH700:generated-pr-delivery-id:v1",repo_node_id,
planned_operation_id}))`，wire编码为 lowercase `sha256:<64hex>`；它不进入 planned payload或 operation-ID
preimage，故无自引用。planned append同一事务创建永久 outbox mapping与
`UNIQUE(repo_node_id,planned_operation_id)`、`UNIQUE(repo_node_id,generated_pr_delivery_id)`：same plan/same
ID只返回原 state/audit，same plan/different ID或 same ID/different plan永久冲突。首次网络发送前须 durable
CAS `send_started`并 FULL fsync；response loss、restart、takeover、restore都复用同一 ID且只走 recovery，
不得第二次 send，terminal/migration不得删除或重写 mapping。PR/ref discovery、broker quiescence与
send-once audit均按该 ID检索。

`required_documentation_surfaces`是 protocol批准的稳定闭集；每项只绑定
`surface_id`、canonical repo-relative path、locale/marker grammar、renderer logical ID/version/
artifact digest与 output schema，不绑定 mutable default-ref/live blob OID。owner claim冻结的
`documentation_surface_plan_digest`绑定 protocol digest、observed default ref OID及每个 surface
的 `{surface_id,path,base_blob_oid,base_blob_sha256,marker_before_identity,
marker_before_cardinality,renderer_digest,expected_after_blob_digest,
expected_after_tree_digest,patch_digest}`。每个 generated plan/replacement再绑定 exact current
base ref/OID与完整 tuple；gate紧邻 mutation重取 default ref/all blobs，任一 drift撤销旧 gate并用
新 slot/nonce/head、fresh render/review重规划。stable path/renderer改变才要求 protocol bump；
receipt绑定 per-attempt plan/base blobs。

valid documentation plan是 exact closed union：

- `rollover_one`：CAS证明每个 required surface恰有一个 eligible current valid row/marker，所有
  surface绑定同一 current release/version/summary identity且无 missing/duplicate/extra marker/
  locale drift；以 `record_kind=generated_pr_planned, pr_kind=decurrent` 创建并 bind一次原子更新全部 surfaces的
  PR identity。merge gate按 latest signed frontier验证 owner generation、committed envelope
  actual fence及 PR/head/base；合并后、publication intent前持久化 merge SHA与 before/after blob
  digest receipt。
- `genesis_zero`：CAS证明全部 required surfaces为零 marker、history没有 eligible valid publication，
  且除本次 exact current prepared owner tuple外无 active owner；authorization fence只取 committed
  store envelope。intent前持久化绑定 history frontier、surface set与 base blobs的 zero-marker
  receipt，不制造 no-op PR。
- `post_invalidation_zero`：全部 surfaces为零 marker，最后一次 current-valid publication已有
  terminal invalidation receipt，之后 suffix满足本 contract的 exact closed union。intent前 append
  `post_invalidation_zero_receipt`，绑定 current frontier、invalidation-receipt digest、exact owner
  与全部 current surface blobs，不制造 no-op de-current PR。

mixed zero/one、跨 surface version/summary不一致、缺 surface、闭集外 current marker、历史 valid却
缺 exact terminal invalidation/fresh zero receipt及其它 zero-marker state均 fail closed。
`intent_written`须绑定对应 plan receipt与已 human-approved的 exact new-current patch/review/base
digest；base/CAS变化即重审。valid ownership以 fenced CAS推进
`genesis_zero_receipt|post_invalidation_zero_receipt → intent_written →
release_committed_valid_marker_pending`，或以 committed
`generated_pr_merged(pr_kind=decurrent)` rollover receipt进入同一 intent。Release commit后
worker消失时，reconciler只从 existing prepared owner+intent+public sentinel幂等补齐。

de-current PR未 merge时取消须先以 higher-fence CAS进入
`valid_decurrent_pr_cancel_pending`，撤销 merge authorization、disable auto-merge/dequeue、关闭
exact PR、compare-delete head ref并取得 server-authenticated revocation receipt，证明 PR closed/
unmerged、queue/head absent、default branch/marker unchanged且无 ruleset bypass，之后才可清理 draft
并 terminal；竞争中已 merge转 `valid_rollback_pending`。candidate继续时，rejected/closed/stalled/
drift plan须先 revoke旧 gate/queue/PR/head并取得 receipt，再以新 fence/head/PR/nonce重新
planned/bound与 review；original/replacement不能同时获 merge authorization。任一证明失败进入
`decurrent_pr_recovery_blocked`。已 merge且 intent前取消只允许恢复 receipt绑定旧 marker的
reviewed rollback PR；rollback/new-current PR失败或 response loss时，current generation可在重取
lease/fence后恢复 same-candidate/exact-patch human-reviewed replacement。新 generation takeover
只能在 trusted-proof-derived store-auth expiry后 higher-fence exact-frontier CAS；无获批 replacement时进入相应
recovery-blocked record并保留 owner。只有 rollback+draft cleanup或 new-current merge完成才 terminal。

`publish_nonvalid`也必须从 prepared owner先 CAS至 `intent_written`，且只有该状态可推进
`release_committed_nonvalid_row_pending`；它不改 current marker，只能合并同 summary的
human-reviewed unmarked row。其 PR recovery使用同一 higher-fence replacement/review machine；
无获批 replacement为 `nonvalid_row_recovery_blocked`。exact unmarked row merge后才 terminal。

已公开 current valid的 invalidation只能由 `invalidate_current` PR原子更新全部 required surfaces：
移除 exact current marker、将 exact row标为 invalid并绑定 approved reason/evidence。planned/bound
envelope绑定 latest frontier、base/head ref+OID、reviewed commit、expected head/default tree、
patch、merge method/ruleset与逐 surface expected-after blobs；schema禁止 future merge commit
OID/timestamp/server output。server确认 merge后才 append terminal
`invalidate_current_merged_receipt`，绑定 actual merge commit OID/PR node/method、default-ref
before/after OIDs、actual tree、逐 surface before/after blobs、owner/fence/frontier与 evidence。
merge response loss须发现 exact merged PR/default ref并核对 actual tuple；receipt缺失/不匹配、
stale frontier、partial surface update、新 current或 concurrent CAS failure进入
`invalidation_recovery_blocked`并保留 owner。

intent后 exact draft缺失/不匹配且没有 matching public Release只能进入
`release_recovery_blocked`并保留 active owner。claim后 draft-create response丢失只可按 claim
nonce+exact repo/tag/source发现：唯一匹配先 higher-fence bind后 cleanup；普通 zero保持 owner并
恢复，只有 authenticated exhaustive/complete-page consistent negative receipt可 terminal。API无法
提供此证明、stale zero、分页/权限裁剪、multiple/mismatch、rate-limit/5xx均进入
`draft_recovery_blocked`；deadline/heartbeat不得推断从未创建。无 durable claim的
pre-attestation interruption必须证明零 Release mutation。

## Frontier、trust 与 deterministic fold

canonical frontier 是 `(repo_node_id, history_length, history_root,
full_prefix_digest)`。维护者批准的 length-zero genesis 只能在 store 尚无 head 的首次
初始化使用；此后上一 release frontier 仅作下界，reader 必须取得 store 签名的最新单调
current-head receipt、重放 prefix并证明精确结束于该 head。所有 receipt/envelope 只信
maintainer-approved、versioned、digest-pinned `publication_history_trust_bundle`：genesis
bundle须由 store/history之外、release-identity trust root验签的 maintainer-governance
attestation锚定 exact bundle digest、repo/purpose与 length-zero genesis frontier；缺失或替换
都拒绝。bundle 本身绑定
`repo_node_id`、purpose、allowed algorithms、root key IDs、threshold 与单调 epoch，禁止
TOFU、checkout anchor 或网络自报 root。committed envelope 绑定 bundle digest、leaf key/
epoch 与 certificate-chain digest；leaf rotation 由 trusted root 授权并绑定 old/new key与无环
`rotation_cutover={activation_predecessor_frontier,activation_successor_history_length,
next_trust_epoch}`，其中 successor length exact 为 predecessor length+1；新 key不得提前、旧 key不得
延后签名。root bundle rotation必须 old+new threshold共同签名，绑定 previous bundle digest与同一 cutover
与独立 governance attestation，history/store 不得自授权；历史 bundle/cert/key保留以验证
旧 receipt。unknown/self-signed/wrong repo或purpose、epoch rollback/fork/gap、algorithm
downgrade、expired/revoked或缺 rotation chain 均 fail closed；唯一例外是按 bootstrap-pinned
break-glass chain验证且完成 external anchor确认的 `trust_emergency_root_cutover` special envelope。
history append authorization 是 closed union：publication transition须 current owner
generation/publication lease/fence；`{trust_leaf_rotated,trust_root_rotated,trust_key_revoked}`
是 phase-neutral governance transition，不含 owner generation，使用独立 repository-governance
lease/fence、authenticated governance actor及 threshold approval，因此 prior owner terminal/
no active owner时仍可轮换，active owner期间也不伪造 takeover或改变其 phase/liveness。
`trust_emergency_root_cutover`同样 phase-neutral，但只接受前述 frozen break-glass authorization、exact anchored
predecessor与 privileged anchor class，普通 governance/routine signer/fence不能生成或批准它。
rotation 构造顺序唯一且无环。三种 normal kind 的 `rotation_core` 分别 exact 为
`trust_leaf_rotated:{current_trust_epoch,next_trust_epoch,old_leaf_key_id,new_leaf_key_id,new_leaf_certificate_digest}`、
`trust_root_rotated:{current_trust_epoch,next_trust_epoch,old_bundle_digest,new_bundle_digest,
old_threshold_signature_digest,new_threshold_signature_digest}` 及
`trust_key_revoked:{current_trust_epoch,next_trust_epoch,revoked_key_id,revocation_reason_code,
replacement_key_or_bundle_digest_or_null}`。先计算 `rotation_core_digest=SHA256(JCS(rotation_core))`；detached
normal approval exact 签 `SHA256(JCS({v:"GH700:normal-rotation-approval:v1",repo_node_id,purpose,
record_kind,rotation_core_digest}))` 并产生 `approval_digest`；再计算
`rotation_id=SHA256(JCS({v:"GH700:rotation-id:v1",repo_node_id,purpose,record_kind,
rotation_core_digest,approval_digest}))`。emergency kind 以其 final payload 去掉
`{rotation_id,recovery_threshold_signature_digest,rotation_cutover_certificate_digest}` 作 `rotation_core`，将前述
detached break-glass approval envelope digest 作 `approval_digest`，使用同一 rotation-ID 式。最后才以 core+
rotation ID+approval digest+cutover certificate digest 构造 closed record payload；任何 derived field 都禁止
进入自己的 core/preimage。rotation ID/approval 不含 predecessor/fence。store先查永久
`(repo_node_id,rotation_id)`：same core/approval 已提交则返原 receipt，异值冲突；absent才验 governance
domain/fence/actor/threshold/current epoch/exact predecessor并 append。每次 append的
`rotation_cutover_certificate` 另绑定 rotation ID/approval digest、exact predecessor、successor ordinal与
next epoch，但绝不含 successor root/full-prefix/receipt digest。publication suffix抢先时保留相同 rotation
ID/payload/approval并为 new predecessor/op重签 cutover certificate；store用 pre-state trust验证后 append，
复算 actual successor并核对 ordinal，在 receipt中绑定 actual successor frontier。new trust只接受以该
actual successor为 predecessor的后续 record。governance suffix只改变 trust epoch/state；active publication
owner重放 suffix并从新 predecessor重规划，两个 authorization fence绝不可互换。store 对
`(expected_length, expected_root, expected_full_prefix_digest, current_fence)` 原子 CAS，
复算并签发 successor frontier。每次 transition 分为 immutable intent、mutable append
authorization envelope与 store-signed committed envelope/receipt。`transition_operation_id` 是覆盖 39 kinds 的
closed derivation：`owner_claimed` exact 为
`SHA256(JCS({v:"GH700:claim-operation-id:v1",repo_node_id,owner_generation,run_id,run_attempt,
transition_slot,predecessor_frontier,record_kind:"owner_claimed",claim_pre_nonce_core_digest,
time_bound_request_id}))`；该 ID在 draft nonce/capsule签发前保留，client core/request ID均不含 authority字段。
其余 publication-domain 34 kinds exact 为
`SHA256(JCS({v:"GH700:publication-operation-id:v1",repo_node_id,owner_generation,run_id,run_attempt,
transition_slot,predecessor_frontier,record_kind,publication_payload_core_digest,
trusted_time_proof_request_id_or_null}))`；non-time kind 以完整 payload 作 core 且 request ID 为 literal null，
heartbeat/takeover以上述 authority core/request ID构造 operation ID；三种 time-dependent kind都在取得 proof后才生成 final payload/payload digest/intent digest。三种 normal governance kinds exact 为
`SHA256(JCS({v:"GH700:governance-operation-id:v1",repo_node_id,purpose,record_kind,rotation_id,
predecessor_frontier,rotation_cutover_certificate_digest}))`；`trust_emergency_root_cutover` exact 为
`SHA256(JCS({v:"GH700:emergency-governance-operation-id:v1",repo_node_id,purpose,record_kind,rotation_id,
recovery_incident_id,predecessor_frontier,rotation_cutover_certificate_digest}))`。三个分支均不含任何
authorization fence/lease；unknown branch/field 或交叉使用拒绝。`owner_generation` 永不复用，首条 claim由 server-auth run tuple+frozen plan生成。
intent 固化 schema/canonicalization version、operation ID、owner generation、run/slot、exact
predecessor/prior phase、`record_kind` 与 payload digest，`intent_digest=SHA256(JCS(intent))`；
retry复用同一 intent bytes/digest。append request另携当前 `authorization_fence`、lease
scope/token与 authenticated actor。store先查同事务永久唯一索引
`(repo_node_id, transition_operation_id)`：同 intent/payload digest已存在直接返回原 receipt且不重新验 fence/append，
异 digest永久冲突；不存在才原子验证 current owner generation/fence/lease/exact predecessor，
append并签发 envelope/receipt，绑定 actual accepted fence、intent/store-envelope digest、
predecessor/successor与 issuer/key version。stale fence对新 mutation失败，但已提交 old op
只能取回原 receipt。
`owner_claimed` 是唯一的 publication-domain absent-owner 创建 transition；独立 governance
transition按上述规则不创建 owner或授权 Release/PR mutation。claim intent声明 fresh、全局永不复用的
`owner_generation`，store仅在 exact predecessor fold 证明 length-zero/no owner 或 prior
owner terminal、repository publication lease/current fence有效、server-auth run/candidate/
frozen-plan tuple、nonce capsule与 predecessor frontier匹配时，才在同一事务创建 generation、
消费/激活 exact `claim_capsule_frozen`、history append及 committed envelope；不得重新创建 capsule。已有 active owner必须走 takeover，不能再 claim。并发 claim只能一个
成功；stale lease/fence、复用 generation或错误 predecessor均拒绝。
ack不确定时重放 signed latest prefix：已提交 exact op接受 receipt及合法 suffix fold；未提交
old fence失败，同 owner generation取得新 fence后以相同 intent重新授权；head advanced禁止
rebase，按 takeover/terminal suffix恢复，仍需 transition则从新 predecessor/new generation
或 slot规划 new op。takeover前未提交的旧 generation intent永久失效；takeover前已提交则先
接受 receipt再 fold suffix。same ID异 digest/重复、receipt/index/envelope不一致、
incompatible successor、fork/截断/不完整 replay或 fence/generation复用均 blocked；完整
frontier防 ABA。

## Complete `record_kind` union

record schema是 versioned closed union。每条 history leaf exact top-level object为
`{schema_version,record_kind,repo_node_id,transition_operation_id,predecessor_frontier,payload}`，无其它字段；
`schema_version`必须 exact `GH700:publication-history-record:v1`。
authorization fence/lease/actor只在 append envelope，committed receipt只在 envelope inventory，不得塞入
immutable leaf。唯一 discriminator是 `record_kind`；`kind`/`type`/`record_type`/alias/unknown均拒绝。
frontier字段唯一为 `{repo_node_id,history_length,history_root,full_prefix_digest}`，canonical digest使用
`jcs-rfc8785-v1`。exact union只有下表 39 kinds；payload列是 closed required field set，missing/extra field
一律 schema-invalid，nullable字段仅在显式写 `*_or_null` 时允许 canonical null。

| `record_kind` | exact `payload` fields |
| --- | --- |
| `owner_claimed` | `{owner_generation,run_id,run_attempt,candidate_tag_identity_digest,frozen_plan_digest,liveness_policy_digest,draft_claim_nonce_digest,nonce_capsule_id,capsule_ciphertext_digest,kms_key_version,trusted_time_proof_digest,prior_time_high_water,new_time_high_water,claim_accepted_at,lease_expires_at}` |
| `owner_heartbeat` | `{owner_generation,heartbeat_sequence,prior_liveness_operation_id,liveness_policy_digest,trusted_time_proof_digest,prior_time_high_water,new_time_high_water,accepted_at,lease_expires_at}` |
| `publication_owner_taken_over` | `{candidate_tag_identity_digest,prior_owner_generation,new_owner_generation,prior_owner_terminal_or_expiry_evidence_digest,slot_chain_digest,trusted_time_proof_digest,prior_time_high_water,new_time_high_water,accepted_at,lease_expires_at}` |
| `draft_bound` | `{owner_generation,release_node_id,tag_identity_digest,target_commit_oid,draft_claim_nonce_digest,release_mutation_operation_id}` |
| `prepared` | `{owner_generation,draft_bound_operation_id,asset_manifest_digest,checksums_digest,summary_digest,closed_slot_set_digest}` |
| `genesis_zero_receipt` | `{owner_generation,first_frontier,verified_prefix_digest,zero_marker_surface_digest,bootstrap_receipt_digest,governance_suffix_digest}` |
| `post_invalidation_zero_receipt` | `{owner_generation,invalidation_receipt_operation_id,invalidation_suffix_digest,zero_marker_surface_digest,terminal_chain_digest,governance_suffix_digest}` |
| `intent_written` | `{owner_generation,intent_kind,prepared_operation_id,zero_marker_receipt_operation_id_or_null,rollover_receipt_operation_id_or_null,new_current_pr_plan_digest_or_null,unmarked_row_plan_digest_or_null,summary_digest,release_manifest_digest}` |
| `release_committed_valid_marker_pending` | `{owner_generation,intent_operation_id,release_node_id,published_release_digest,new_current_pr_plan_digest}` |
| `release_committed_nonvalid_row_pending` | `{owner_generation,intent_operation_id,release_node_id,published_release_digest,nonvalid_row_pr_plan_digest}` |
| `valid_decurrent_pr_cancel_pending` | `{owner_generation,decurrent_pr_bound_operation_id,higher_fence_receipt_digest,cancel_plan_digest}` |
| `valid_rollback_pending` | `{owner_generation,decurrent_pr_merged_operation_id,rollback_pr_plan_digest,prior_marker_digest}` |
| `invalidate_current_merged_receipt` | `{owner_generation,generated_pr_merged_operation_id,evidence_digest,invalidated_release_identity,zero_marker_surface_digest}` |
| `recovered_publication` | `{owner_generation,intent_operation_id,recovery_truth_branch,release_node_id,generated_pr_chain_digest,finalization_receipt_digest}` |
| `publication_terminal_no_publication` | `{candidate_tag_identity_digest,terminal_owner_generation,complete_generation_chain_digest,closed_slot_chain_digest,draft_cleanup_evidence,exhaustive_negative_discovery_digest}` |
| `publication_terminal` | `{owner_generation,terminal_kind,release_identity_or_null,generated_pr_chain_digest,closed_slot_chain_digest,finalization_receipt_digest}` |
| `release_mutation_planned` | `{owner_generation,mutation_kind,transition_slot,mutation_slot_id,plan_core_digest,request_commitment,mutation_nonce_digest,mutation_nonce_capsule_id,broker_delivery_id,capsule_ciphertext_digest,kms_key_version,tag_identity_digest,pre_state_digest,request_template_digest,expected_post_state_digest}` |
| `release_mutation_bound` | `{owner_generation,mutation_kind,mutation_slot_id,planned_operation_id,request_commitment,broker_delivery_id,effective_request_digest,response_resource_digest,post_state_digest,completed_guard_receipt_digest}` |
| `release_mutation_recovery_pending` | `{owner_generation,mutation_kind,mutation_slot_id,planned_operation_id,broker_delivery_id,uncertain_outcome_code,send_once_audit_digest}` |
| `release_mutation_not_applied` | `{owner_generation,mutation_kind,mutation_slot_id,recovery_pending_operation_id,exact_pre_state_digest,exhaustive_negative_discovery_digest,broker_quiescence_receipt_digest}` |
| `compensation_planned` | `{owner_generation,source_mutation_kind,source_mutation_slot_id,compensation_mutation_kind,compensation_slot,compensation_plan_digest,required_pre_state_digest}` |
| `compensated` | `{owner_generation,compensation_planned_operation_id,compensation_mutation_bound_operation_id,restored_pre_state_digest,no_extra_resource_receipt_digest}` |
| `generated_pr_planned` | `{owner_generation,pr_kind,transition_slot,base_ref_oid,head_repo_node_id,head_ref,head_ref_nonce_digest,review_core_digest,check_identity_digest,reviewed_commit_oid,expected_tree_digest,patch_digest,merge_method,ruleset_digest,trusted_app_identity_digest,trusted_installation_identity_digest,replacement_chain_digest_or_null}` |
| `generated_pr_bound` | `{owner_generation,pr_kind,planned_operation_id,pr_node_id,head_ref,head_oid,base_oid,queue_identity_digest,review_digest}` |
| `generated_pr_not_applied` | `{owner_generation,pr_kind,planned_operation_id,head_ref_nonce_digest,exhaustive_pr_ref_negative_discovery_digest,broker_quiescence_receipt_digest,default_unchanged_receipt_digest}` |
| `generated_pr_revoked` | `{owner_generation,pr_kind,planned_operation_id,bound_operation_id,pr_node_id,queue_absent_receipt_digest,head_absent_receipt_digest,default_unchanged_receipt_digest,exhaustive_negative_discovery_digest,broker_quiescence_receipt_digest}` |
| `generated_pr_merged` | `{owner_generation,pr_kind,bound_operation_id,pr_node_id,actual_merge_oid,default_before_oid,default_after_oid,actual_tree_digest,surface_blobs_digest}` |
| `release_mutation_recovery_blocked` | `{owner_generation,mutation_kind,mutation_slot_id,plan_digest,blocked_reason_code,evidence_digest,retain_owner}` |
| `draft_recovery_blocked` | `{owner_generation,draft_claim_nonce_digest,draft_create_mutation_slot_id,blocked_reason_code,evidence_digest,retain_owner}` |
| `decurrent_pr_recovery_blocked` | `{owner_generation,generated_pr_plan_operation_id,blocked_reason_code,evidence_digest,retain_owner}` |
| `rollback_recovery_blocked` | `{owner_generation,generated_pr_plan_operation_id,blocked_reason_code,evidence_digest,retain_owner}` |
| `marker_recovery_blocked` | `{owner_generation,generated_pr_plan_operation_id,blocked_reason_code,evidence_digest,retain_owner}` |
| `nonvalid_row_recovery_blocked` | `{owner_generation,generated_pr_plan_operation_id,blocked_reason_code,evidence_digest,retain_owner}` |
| `invalidation_recovery_blocked` | `{owner_generation,generated_pr_plan_operation_id,blocked_reason_code,evidence_digest,retain_owner}` |
| `release_recovery_blocked` | `{owner_generation,intent_operation_id,release_discovery_digest,blocked_reason_code,evidence_digest,retain_owner}` |
| `trust_leaf_rotated` | `{rotation_id,current_trust_epoch,next_trust_epoch,old_leaf_key_id,new_leaf_key_id,new_leaf_certificate_digest,approval_digest,rotation_cutover_certificate_digest}` |
| `trust_root_rotated` | `{rotation_id,current_trust_epoch,next_trust_epoch,old_bundle_digest,new_bundle_digest,old_threshold_signature_digest,new_threshold_signature_digest,approval_digest,rotation_cutover_certificate_digest}` |
| `trust_key_revoked` | `{rotation_id,current_trust_epoch,next_trust_epoch,revoked_key_id,revocation_reason_code,replacement_key_or_bundle_digest_or_null,approval_digest,rotation_cutover_certificate_digest}` |
| `trust_emergency_root_cutover` | `{rotation_id,recovery_incident_id,cause,evidence_digest,current_anchor_digest,current_trust_epoch,next_trust_epoch,old_bundle_digest,new_bundle_digest,recovery_roster_digest,recovery_threshold_signature_digest,audit_log_digest,incident_open_receipt_digest,audit_delay_evidence_digest,trusted_time_proof_digest,backup_set_ref_digest,rotation_cutover_certificate_digest}` |

closed enums exact 为 `intent_kind={publish_valid,publish_nonvalid}`、
`pr_kind={decurrent,rollback,new_current,nonvalid_row,invalidate_current}`、
`terminal_kind={published_valid,published_nonvalid,rollback_restored,invalidation_completed}`及
`recovery_truth_branch={matching_public_release,matching_intent_bound_draft}`；`retain_owner`必须 literal `true`。
`intent_written(intent_kind=publish_valid)`须在 publish前以 non-null `new_current_pr_plan_digest_or_null`绑定 human-reviewed exact base/patch/review，且 `unmarked_row_plan_digest_or_null`为 null；`publish_nonvalid`反之，两者同时 null/non-null或 commit后才出现 plan均 invalid。
valid intent还须在 `zero_marker_receipt_operation_id_or_null`与`rollover_receipt_operation_id_or_null`中恰一 non-null；nonvalid两者均 null，rollover只能引用同 owner/prepared/frontier的 committed `generated_pr_merged(pr_kind=decurrent)` receipt。
`release_mutation_recovery_blocked.mutation_kind`只允许
`{draft_update,draft_delete,asset_upload,asset_delete,publish}`，`draft_create`只允许
`draft_recovery_blocked`。`blocked_reason_code` 是下列逐 kind 闭集：`draft_recovery_blocked` 仅 `{permission_denied,pagination_incomplete,broker_audit_unavailable,rate_limited,remote_5xx,remote_timeout,ambiguous_remote_effect,tag_identity_drift,source_drift,ruleset_drift,bypass_drift,capsule_unavailable,capsule_integrity_failed,kms_unavailable}`；`release_mutation_recovery_blocked` 仅前集合去掉三个 capsule/KMS code；`{decurrent_pr_recovery_blocked,rollback_recovery_blocked,marker_recovery_blocked,nonvalid_row_recovery_blocked,invalidation_recovery_blocked}` 仅 `{permission_denied,pagination_incomplete,rate_limited,remote_5xx,remote_timeout,ambiguous_remote_effect,multiple_matches,identity_mismatch,ruleset_drift,bypass_drift}`；`release_recovery_blocked` 仅 `{permission_denied,pagination_incomplete,rate_limited,remote_5xx,remote_timeout,release_truth_ambiguous,multiple_matches,identity_mismatch}`，表外 code 一律 schema-invalid。broker audit、capsule、KMS refs、external anchor、time proof、PR/Release discovery与
generated patch是由 payload digest引用的 durable typed objects，不是额外 record kinds。非法 transition/
fence/owner、缺失/截断/fork、过期 fence、checkout anchor或表外 kind均 fail closed。
`publication_terminal_no_publication.payload.draft_cleanup_evidence`是以 `cleanup_kind`判别的 exact
closed union，且整个 payload恰有一个 branch：

- `{cleanup_kind:"draft_never_existed",draft_create_slot_closure_digest,
  broker_quiescence_receipt_digest,no_effect_receipt_digest}`；
- `{cleanup_kind:"draft_deleted",draft_identity_digest,draft_preimage_digest,
  deletion_or_compensation_receipt_digest,post_delete_discovery_digest,
  broker_quiescence_receipt_digest}`。

两 branch都禁止 extra/null字段。`draft_never_existed`不得携 draft identity/preimage/deletion/
compensation字段；`draft_deleted`不得缺任一 deletion branch字段。外层
`exhaustive_negative_discovery_digest`仍须绑定同一线性化快照的 Release/draft/PR/current-marker
全量发现，不能由 nested evidence替代。
`generated_pr_planned` response loss只允许下列 closed recovery：唯一 exact active PR/ref match写
`generated_pr_bound`；唯一 merged match须在同一 recovery orchestration串行完成两个完整
DB→backup→anchor→read-confirm cycles：先写 `generated_pr_bound`，再以 confirmed operation ID作
`bound_operation_id`写 `generated_pr_merged`，两者间 crash只补第二 successor，并按 ledger contract返回/
永久索引两张 ordered receipts；同一 authenticated exhaustive snapshot
证明 PR/ref/queue均无 effect，且 broker quiescent、default unchanged时写 `generated_pr_not_applied`；其余
ambiguous结果写对应 PR recovery-blocked record。`generated_pr_not_applied`是 terminal slot closure，不能
rebind/reopen；继续尝试只能从 fresh transition slot、nonce、ref、review core、commit与 check identity创建
replacement。`generated_pr_revoked`只关闭已 bound且确认未 merge的 PR，不得代替 no-effect proof。
允许的 phase grammar对 folded publication phase 闭合：在任一尚有 non-terminal current owner 的
frontier，`owner_heartbeat` 与 `publication_owner_taken_over` 都是 phase-neutral liveness edge。heartbeat
只可由当前 generation 在 expiry 前追加；`heartbeat_sequence=1` 的 `prior_liveness_operation_id` 必须是建立该 generation 的 `owner_claimed` 或 `publication_owner_taken_over`，后续 sequence 必须引用同 generation 紧邻的 sequence-1 heartbeat；takeover 只可在 expiry 后以 new generation 追加；两者均保留
candidate、publication phase、slot/pending/blocked state，其 successor 继续按该被保留 phase 的 edge 校验。
terminal/no-owner frontier 不允许二者。除这两种 liveness edge 及下述 phase-neutral governance edge 外，
`owner_claimed` 后只可 mutation plan 链或 `draft_bound`；`draft_bound`后闭合 upload/update slots才可 `prepared`。
prepared valid只有两条互斥 pre-intent路径：`genesis_zero_receipt|post_invalidation_zero_receipt`→`intent_written(intent_kind=publish_valid,zero receipt non-null)`，或 rollover-one的
`generated_pr_planned(pr_kind=decurrent)`→`generated_pr_bound`→`generated_pr_merged`→`intent_written(intent_kind=publish_valid,rollover receipt non-null)`；后者仅在 exact receipt提交且 fresh fold证明旧 current被原子移除后可写。
planned无 effect只可 `generated_pr_not_applied`后以 new slot/head/nonce fresh-reviewed replacement，bound失败
只可 revoke后 replacement或 `decurrent_pr_recovery_blocked`；merged取消只走 `valid_rollback_pending`，且最多
一个未撤销 gate。prepared non-valid直接接 `intent_written(intent_kind=publish_nonvalid)`；intent后 publish slot
bound才可相应 committed-pending，再经 generated PR链到 `record_kind=publication_terminal`。pre-intent cleanup
只以 `publication_terminal_no_publication` 结束；invalidation只以 planned→bound→merged→
`invalidate_current_merged_receipt`→`record_kind=publication_terminal, terminal_kind=invalidation_completed`结束。
recovery pending只可到 bound/not-applied/compensation/对应 blocked；八 blocked kinds均保留 owner且非 terminal。
四种 governance kinds可插入任一 frontier但只改变 trust state；emergency kind另须满足 special authorization。
任何未列 edge或跳过 predecessor均拒绝。
`post_invalidation_zero` 的 invalidation suffix fold是 exact closed union：terminal non-valid
publication、current prepared owner、下述 authenticated terminal no-publication attempt chain及已验签的
phase-neutral `{trust_leaf_rotated,trust_root_rotated,trust_key_revoked,trust_emergency_root_cutover}`。no-publication chain从同
candidate的 `owner_claimed` 开始，可含 exact-predecessor `publication_owner_taken_over` successor、
heartbeat、private-draft/asset cleanup及其 closed mutation slots，且必须以 store-signed
`publication_terminal_no_publication` 结束；terminal receipt须绑定整条 generation/slot chain、
exhaustive Release/draft/PR/current-marker negative discovery、无 pending/blocked/in-flight mutation，
并携带下列 exact tagged closed union中的恰一 `draft_cleanup_evidence`：

- `draft_never_existed`：整个 owner/takeover chain均无 bound或 recovered draft；认证发现须穷尽
  Release all states、draft与 assets，证明 broker outbox/delivery quiescent/no-effect，并证明所有
  draft-create slot不存在或已 closed not-applied。该分支不得伪造 delete/compensation receipt。
- `draft_deleted`：绑定 exact bound/recovered draft identity与 preimage；携带已 closed 的 guarded
  delete或 compensation receipt，并以 post-delete exhaustive discovery证明该 draft/assets不存在且
  broker quiescent。

缺 terminal/negative receipt、缺失/unknown/wrong cleanup branch、无 draft却声称 deleted、已有 bound/
recovered draft却声称 never-existed、伪造/未闭合 deletion evidence、wrong candidate/predecessor/fence、
forged takeover、`intent_written`、public Release、current restoration或其它 owner均拒绝。governance record必须经独立
governance domain/fence/threshold及上述 trust cutover验证，且 fold后 publication owner/phase/
liveness不变；closed union外 record均拒绝。

## Conformance vectors

所有 named vector的 canonical fixture object、exact JCS bytes、SHA-256、path与 accept/reject oracle只在
[publication_conformance_vectors.md](publication_conformance_vectors.md)定义；调用方不得复制或改写。

## Owner liveness

长时间等待人工 review 以 durable `owner_heartbeat` renewal record续活：immutable
intent只绑定 stable owner generation、单调 heartbeat sequence/transition slot与
`liveness_policy_digest`，不得绑定 client timestamp/deadline或 authorization fence；
`owner_claimed`、`publication_owner_taken_over`与`owner_heartbeat`的 store-signed committed envelope均按获批 H-006
写入 RFC3161 quorum-authenticated `claim_accepted_at`/`accepted_at`、`trusted_time_proof_digest`、
prior/new time high water、`lease_expires_at`、actual fence、owner generation与 heartbeat sequence。只有尚未
terminal 的 current generation持 current fence且在 store
认证 expiry 前可 append；fold只从建立 current generation 的 claim/takeover及其 heartbeat committed envelopes导出 liveness，
不信任 host/client时钟、job presence或自报 deadline。`generation_origin_accepted_at` 对 claim generation取 `claim_accepted_at`、对 takeover generation取 takeover `accepted_at`；`previous_accepted_at` 对 sequence 1 取该 origin，之后取前一 heartbeat的 `accepted_at`。store 只接受 prior
expiry 前、距 `previous_accepted_at` 至少 `min_renewal_interval_seconds` 且严格延长 expiry 的 renewal，并以
`min(accepted_at+ttl_seconds, generation_origin_accepted_at+max_generation_age_seconds)` 计算 expiry；
protocol scheduler按 `heartbeat_period_seconds` 请求，到 generation age cap 后禁止续租。
重复 heartbeat按同一 operation的
idempotency规则取回 receipt，异 digest/sequence冲突拒绝。takeover仅可在 trusted lower bound严格超过
store-auth expiry且 high-water CAS成功后用 higher-fence exact-frontier CAS：heartbeat先提交则 takeover predecessor/fence失败并
重读，takeover先提交则旧 generation/fence heartbeat失败；ack丢失仍按 signed receipt恢复。
heartbeat append失败时 owner保持 active直至 store expiry，不能因 worker/job消失推断过期。
