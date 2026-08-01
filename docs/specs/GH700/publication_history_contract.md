# GH700 Publication History Contract

本文件与 [authority API / blocked-attempt contract](publication_ledger_contract.md)、[authority protocol](publication_authority_protocol_contract.md) 及
[conformance vectors](publication_conformance_vectors.md) 共同构成 `product.md` B-017/B-018与 `tech.md` publication machine 的规范性组成部分，隔离 ownership、mutation-secret、append-only history、trusted time、trust/fold与 owner-liveness。
引用方不得复制、改名或局部覆盖字段、枚举、canonical bytes、secret boundary或 fail-closed语义；冲突时四份 contract各自拥有的 exact machine-facing identifiers为唯一真源。

## Concrete durable authority

唯一 production backend `publication_authority_sqlite_v1`由计划中的 `vibeguard-runtime/src/publication_authority/{mod.rs,store.rs,broker.rs,recovery.rs,restore_anchor.rs,backup_store.rs,anchor_signer.rs,governance_recovery.rs}` 与 `vibeguard-runtime/src/main.rs` 的 `publication-authority serve|recover`实现；client/workflow/benchmark不得另建 store、直接开库或降级到 memory/mock/checkout/Actions artifact。
environment-protected service以单 active replica运行在独立于 runner/checkout/Release artifact/owner lifecycle的 durable volume；signed deployment manifest的 closed planned **schemas/publication_authority_deployment.schema.json** 固定
`{authority_id,backend,authority_identity_digest,policy_epoch,policy_bundle_digest,client_api,control_api,control_approval_policy,publication_store_path,publication_store_lock_path,volume_identity,kms_key_id,retention_policy_digest,trust_bundle_digest,blocked_attempt_ledger,trusted_time_service,bootstrap_governance,break_glass_governance,restore_anchor_service,restore_backup_service,anchor_signing_policy,predicate_evaluator_roster}`。
`predicate_evaluator_roster` exact `{schema_version,signature_profile,entries}`，version `GH700:predicate-evaluator-roster:v1`；profile exact `{algorithm:"ed25519",message_digest:"sha256_jcs_v1",signature_encoding:"base64url_nopad_v1",key_version_policy:"manifest_pinned_v1"}`。
entries按 `(reason_code,predicate_id,issuer_key_id,issuer_key_version)` UTF-8升序去重，每项 exact `{reason_code,predicate_id,predicate_definition_digest,evaluator_identity_digest,issuer_key_id,issuer_key_version,public_key_spki_der_b64url,public_key_spki_sha256}`；version是 `gh700_uint64_nonzero`，SPKI为 RFC5280 Ed25519 DER的 unpadded base64url且 decoded hash须等，digest/hash均 lowercase `sha256:<64hex>`并禁 ambient lookup。
reason/predicate闭集只由 ledger contract拥有；empty/duplicate/unknown/profile drift使 authority non-ready。
`client_api` 与 `control_api` 是同一 authority 每次启动同时绑定的 required objects，不是 union/alias/fallback。
`client_api` exact `{endpoint,transport,api_version,server_identity_bundle_digest,client_auth_policy_digest}`：manifest-pinned absolute HTTPS origin+path禁 redirect/userinfo/query/fragment，transport/version exact `tls13_mtls_http2_jcs_v1`/`GH700:publication-authority-client-api:v1`。`control_api` exact `{socket_path,transport,api_version,server_process_identity_digest,response_signing_key,peer_auth_policy,peer_auth_policy_digest}`：manifest-pinned absolute Unix path，transport/version exact `unix_peercred_jcs_v1`/`GH700:publication-authority-control-api:v1`，只开放 ledger闭集方法且不监听网络。
两个 API 的 request/response/startup receipt绑定相同 `authority_id`、`authority_identity_digest`、strictly monotonic `policy_epoch`、`policy_bundle_digest`；bundle同时 digest method partition、auth/approval policy、server/response-key identities与 roster。client server bundle由外部 release-identity root锚定；两端 policy闭合 repo/workflow/environment/ref/run/actor/cert/role或 executable/code-sign/uid/gid及 method。
任一 API缺失、单边 rotation、shared值/内外 bundle不等或 epoch回退使 authority non-ready；rotation由一份 signed manifest原子切换且无 grace。request还绑定 API version/frontier/operation/request digest/anti-replay nonce；unknown/ambient endpoint/socket/proxy/DNS/identity/policy均拒绝。
store path是 volume内唯一 absolute canonical SQLite file，禁 default/relative/temp；KMS policy由 manifest钉住。reconciler/workflow GitHub token始终 read-only，target write credential只在 authority sole broker secret provider，client不得接收/转发/记录。

client/control method wire只由 [publication_ledger_contract.md](publication_ledger_contract.md)定义；authority-owned
trusted-time proof profile只由 [publication_authority_protocol_contract.md](publication_authority_protocol_contract.md)定义；本文件只定义 history与 shared durability。

四份 normative contract 的所有 digest-bearing/wire JSON共享唯一 integer profile。`gh700_integer`逻辑值在
`[-9007199254740991,9007199254740991]`内必须是无 fraction/exponent的 canonical JSON number，绝对值更大必须是
canonical base-10 string（负数仅一个 leading `-`；禁止 `+`、leading zero、`-0`、whitespace）；safe值的 string与
unsafe值的 JSON number均拒绝。`gh700_uint{16,32,64}`及 `_nonzero`先按该唯一表示解码，再验证对应 unsigned
bit range/zero规则；times、length/count、threshold、key version、sequence/frontier/epoch/fence/run/slot均不得局部重定义。
`u64be`仅是已验证 logical uint64的八字节 binary framing，不是 JSON替代编码；numeric comparison/sort按解码值。

service启动先取得同 manifest钉住的 process lock，验证 volume支持 kernel lock与 durable `fsync`，再以 SQLite WAL、`journal_mode=WAL`、`synchronous=FULL`、foreign keys及
`BEGIN IMMEDIATE`运行。history head/leaf、operation/rotation/slot unique indexes、owner/fence、
capsule ciphertext metadata、broker outbox/delivery/send-once audit与 completed receipt须在一个
事务中验证和提交；任何 lock/busy timeout、WAL/fsync/checkpoint、disk-full或 KMS error都使
authority non-ready并 fail closed，不得返回成功 receipt。首次 database/WAL/lock 创建与 migration
commit后还须 fsync file及 parent directory；禁止 destructive migration、truncate或 silent rebuild。
authority-owned durable persistence是 exact closed inventory：signed manifest及 bootstrap/migration/governance receipts；
pre-bootstrap ceremony journal/events/request bytes/tokens；SQLite DB/WAL/checkpoint及 history/blocked/operation/rotation/slot/owner/fence/delivery/reconciliation indexes；完整 attempt、RFC3161 preparation/proof/high-water、capsule ciphertext/KMS refs/read audits、broker outbox/audit/receipts；
external anchor/epoch/frontiers、encrypted snapshot/manifest/WAL immutable versions/AEAD header/wrapped key、每项 AWS KMS material attestation、backup confirmation、quorum signatures及 restore/recovery/break-glass receipts。其外 cache/temp/log不得参与恢复或授权，
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
retention_class,minimum_retention_seconds,encryption_contract,data_key_wrap_contract}`；`data_key_wrap_contract` exact 为
`{provider:"aws_kms_v1",operation:"GenerateDataKey",key_spec:"AES_256",kms_key_arn,kms_key_id,
require_key_material_id:true,encryption_context_schema:"GH700:backup-data-key-context:v1"}`。按 AWS KMS API，preflight
`DescribeKey(KeyId=kms_key_arn)`只验证 response `KeyMetadata.{Arn,KeyId,Enabled,KeyUsage,KeySpec,Origin}`匹配 manifest且
可用；`GetKeyRotationStatus`只验证 rotation readiness，二者都不作为某次 wrap的 material source。每次无 `Recipient`
的 `GenerateDataKey` response必须有 `KeyId==kms_key_arn`、32-byte Plaintext、CiphertextBlob及 exact 64位 lowercase-hex
`KeyMaterialId`；该 response的 KeyId是 ARN，不与 manifest UUID `kms_key_id`混淆。actual `KeyMaterialId`是该 wrapped key
唯一权威 material identity；Describe eventual-consistent current material、alias、rotation日期或 local counter不得替代。
manifest钉住 account/region/bucket ARN+name+
creation time、versioning/Object-Lock enabled、独立 KMS key ARN/key ID与 public-CA/server identity，禁 ambient
endpoint/proxy/credential。retention exact `permanent_no_ttl_legal_hold_v1`：每个 version以 Compliance mode至少
100年且开启 legal hold，无 lifecycle/overwrite/delete；governance须在不足10年剩余窗口前 threshold批准延长，
否则 authority non-ready。writer的短期 OIDC→STS role只允许 S3 `PutObject`/`GetObjectVersion`/读 retention/hold，
及 exact KMS key上的 `kms:GenerateDataKey`，且 IAM/key policy以 encryption-context conditions绑定下述 exact字段；
显式无 `kms:Decrypt`/`Encrypt`/`ReEncrypt*`/key administration、S3 delete/overwrite/解除 hold/lifecycle权限。
protected recovery role只在 threshold-approved restore中读 exact versions并以同 context调用 pinned KMS decrypt。

每个 committed successor先生成 exact `backup_set_core={backup_id,resource_identity,snapshot_object_key,
snapshot_version_id,snapshot_ciphertext_digest,manifest_object_key,manifest_version_id,
manifest_ciphertext_digest,wal_object_key,wal_version_id,wal_ciphertext_digest,kms_key_arn,
kms_data_key_attestation_set_digest,wrapped_data_key_set_digest,aead_contract_digest,retention_until,legal_hold_status}`；
`backup_set_core_digest=SHA256(JCS(backup_set_core))`。detached `backup_confirmation` exact 为
`{backup_set_core_digest,snapshot_get_receipt_digest,manifest_get_receipt_digest,wal_get_receipt_digest,
retention_receipt_digest,legal_hold_receipt_digest}`，`backup_confirmation_digest=SHA256(JCS(backup_confirmation))`，
`backup_set_ref={backup_set_core,backup_set_core_digest,backup_confirmation_digest}`；三者都不包含自己的 digest。SQLite snapshot、
recovery manifest和 WAL（包括 canonical empty WAL）分别用 fresh 256-bit data key与96-bit nonce执行 `aes_256_gcm_siv_v1`。
canonical ordered preimage exact 为 `successor_frontiers_preimage={v:"GH700:successor-frontiers:v1",frontiers:
[{frontier_kind:"publication_history",frontier:{repo_node_id,history_length,history_root,full_prefix_digest}},
{frontier_kind:"blocked_attempt_ledger",frontier:{repo_node_id,ledger_length,ledger_root,full_prefix_digest}}]}`；array顺序
固定、两个 frontier来自同一 successor；`successor_frontiers_digest=SHA256(JCS(successor_frontiers_preimage))`编码
lowercase `sha256:<64hex>`。每个 object先构造 exact KMS context `{schema_version:"GH700:backup-data-key-context:v1",
authority_id,repo_node_id,backup_id,object_kind,successor_frontiers_digest,prior_anchor_digest}`及 request
`{KeyId:kms_key_arn,KeySpec:"AES_256",EncryptionContext:kms_context}`；`kms_generate_data_key_request_digest=
SHA256(JCS({v:"GH700:kms-generate-data-key-request:v1",request}))`。authenticated AWS response立即规范化为 exact
`kms_data_key_attestation={schema_version:"GH700:kms-data-key-attestation:v1",object_kind,
kms_generate_data_key_request_digest,aws_request_id,response_key_arn,key_material_id,ciphertext_blob_digest}`，其中
response ARN/actual material分别 byte-equal `KeyId`/`KeyMaterialId`，`ciphertext_blob_digest=SHA256(CiphertextBlob raw bytes)`；digest exact
`kms_data_key_attestation_digest=SHA256(JCS(kms_data_key_attestation))`。immutable object header保留 nonce、exact KMS
context、wrapped data-key bytes、attestation+digest、tag和
`AAD=JCS({authority_id,repo_node_id,backup_id,object_kind,successor_frontiers_preimage,time_high_water,plaintext_digest,
prior_anchor_digest_or_null,prior_anchor_binding_digest})`。non-genesis时 AAD两个字段分别是 actual prior anchor与
同一 digest，KMS context的 `prior_anchor_digest`也等于它；epoch-zero时 AAD前者 literal null，后者及 KMS
context字段都必须 exact sentinel `sha256:c1d48a89bbaafb77b7af9c4913cd8e660e73f1278c9e9d5211b1535799faa8aa`，
其唯一 preimage是 `{v:"GH700:genesis-prior-anchor:v1",prior_anchor:null}`。sentinel禁用于非 genesis，空串、
zero digest或 synthetic anchor均拒绝。encrypt及 restore/decrypt都从 AAD exact frontiers重算 digest并要求
byte-equal context；禁止明文或
unauthenticated compression。`kms_data_key_attestation_set`是按 `snapshot,recovery_manifest,wal`固定顺序的三项 exact
`{object_kind,kms_data_key_attestation_digest,key_material_id}`，其 digest为 JCS SHA-256；`wrapped_data_key_set`同序且每项 exact
`{object_kind,wrapped_data_key_digest,kms_data_key_attestation_digest,key_material_id}`，`wrapped_data_key_set_digest=SHA256(JCS(wrapped_data_key_set))`；每个 wrapped digest取 exact
CiphertextBlob。上传后 exact-version strong GET并重算 ciphertext/header/wrapped-key/attestation digests及确认 retention+
legal hold；missing/malformed `KeyMaterialId`、wrong ARN/request/context/blob binding、重复 data key、plaintext残留或任一对象未确认都不能签 anchor或释放 receipt。
DB successor transaction只固化 exact `anchor_plan_core={authority_id,authority_identity_digest,policy_epoch,repo_node_id,
anchor_schema_version,restore_epoch,latest_frontier,blocked_attempt_ledger_frontier,time_high_water,time_proof_digest,
transition_class,privileged_transition_or_null,prior_anchor_digest,backup_id,anchor_plan_id}` 及其 JCS SHA-256；core禁止包含
snapshot/WAL digest、object version、`backup_set_ref*`、confirmation、final payload/request ID。exact-version backup确认
后才构造 final anchor payload `{anchor_plan_core,anchor_plan_core_digest,snapshot_digest,wal_digest,
backup_resource_identity,backup_set_ref,backup_set_ref_digest,anchor_request_id}`，其中
`backup_set_ref_digest=SHA256(JCS(backup_set_ref))`且
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
break_glass_incident_open,emergency_root_cutover}`，继续要求独立 maintainer或 break-glass threshold离线批准；两类 signature不可互换。`privileged_transition_or_null`仅在 `transition_class=break_glass_incident_open`时 non-null且 exact
`{transition_kind:"break_glass_incident_open",recovery_incident_id,incident_open_intent_digest,trusted_time_replay_identity,trusted_time_proof_request_id,trusted_time_proof_digest,trusted_lower_bound,trusted_upper_bound,prior_time_high_water,new_time_high_water,current_publication_frontier,current_blocked_attempt_frontier}`；其 proof/replay/interval/high-water/frontiers须 byte-equal protocol proof、intent及 anchor core，任何其它 transition class必须 literal null。
`transition_class`由 authority按 successor强制唯一映射，caller不得选择：`owner_claimed`/`publication_owner_taken_over`→`trusted_time`，`owner_heartbeat`→`owner_heartbeat`，`{trust_leaf_rotated,trust_root_rotated,trust_key_revoked}`→`governance`，`trust_emergency_root_cutover`→`emergency_root_cutover`，其余 history record→`publication`；blocked-attempt leaf/reconciliation/watermark→`blocked_attempt`；
control bootstrap/migration/anchored-snapshot restore分别→`bootstrap`/`migration`/`restore`；restart replay不得创建新 class，只能恢复原 pending anchor的 frozen class；incident-open/break-glass restore cutover分别→`break_glass_incident_open`/`emergency_root_cutover`，ready无 successor。同一 successor匹配零项或多项、wire class assertion mismatch、routine/privileged signer交叉使用均在 signer request前拒绝。
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

host/process/client/GitHub/HTTP time均不授权 expiry或 takeover。deployment manifest的 closed
trusted_time_service、maximum_tsa_accuracy_ns、independent source quorum与 policy digest由
[authority protocol](publication_authority_protocol_contract.md#trusted-time-proof-profiles)唯一解释；
旧 max_accuracy_seconds、ambient endpoint/proxy/CA、TOFU、同 root重复 signer或 policy drift均拒绝。

T10只提交 [machine client schema](publication_authority_api.schema.json) 的 proof-free time-bound request。
T3从 signed fold取 prior high water，按 protocol构造 subject、replay identity、nonce、proof request、
RFC3161 imprint与 inclusive interval intersection；proof capsule/high-water与 successor/anchor原子持久化，
crash/ack-loss只恢复同一 replay row。heartbeat要求 trusted_upper_bound < lease_expires_at；
takeover要求 trusted_lower_bound > lease_expires_at；相等或 interval跨 expiry均拒绝。unavailable、
quorum/accuracy/policy drift、rollback/fork或 SQLite↔anchor mismatch使 time-dependent operation fail closed，
不 clamp host time、不以 job absence接管。

## Bootstrap governance and first frontier

deployment bootstrap_governance闭合绑定 release-identity root、distinct threshold roster、initial trust
bundle/epoch、两个 length-zero frontier及 initial trusted-time proof/high-water。bootstrap manifest core不含
signature envelope；detached threshold approval签 GH700:bootstrap-manifest-approval:v1 的 core digest。
self-sign/TOFU、duplicate/insufficient signer或 root/roster/epoch/core drift均拒绝。control wire、
prebootstrap policy branch、release-identity attestation validity与 genesis/database/backup/anchor receipts分别由
[machine API](publication_authority_api.schema.json) 和
[authority protocol](publication_authority_protocol_contract.md#bootstrap-genesis-and-anchor-evidence)拥有。

first publication frontier exact length zero：history_root/full_prefix分别为
SHA256(JCS({v:"GH700:history-empty-root:v1",repo_node_id})) 与
SHA256(JCS({v:"GH700:history-empty-prefix:v1",repo_node_id}))；blocked frontier同理使用
GH700:blocked-attempt-empty-root:v1 / GH700:blocked-attempt-empty-prefix:v1。successor唯一 framing：
leaf_hash=SHA256(UTF8("GH700:"+domain+"-leaf:v1") || 0x00 || u64be(len(leaf_bytes)) || leaf_bytes)；
next_root=SHA256(UTF8("GH700:"+domain+"-root:v1") || 0x00 || digest_bytes(prior_root) ||
leaf_hash || u64be(prior_length+1))；next prefix同域 prefix:v1，连接 prior prefix、leaf length及 bytes。
domain仅 history/blocked-attempt，leaf分别为 exact closed history record/ledger envelope JCS bytes；
overflow、noncanonical digest/bytes或重算不等拒绝。framing golden与 nested hash由
[conformance vectors](publication_conformance_vectors.md)锁定，不在本文复制第二份值。

T3只在 DB/anchor均不存在时，以 threshold approval、initial RFC3161 quorum及 release-identity attestation
创建 SQLite genesis，再以 conditional epoch-zero transaction写 EPOCH#0/HEAD；任一已存在只允许 exact
read-confirm，不能 reset。genesis backup AAD保持 prior_anchor_digest_or_null=null，而 KMS context使用 protocol
定义的 genesis sentinel；first frontier、blocked frontier、time/trust state与所有 receipts须 cross-bind。

manifest另闭合 break_glass_governance：外部 cold recovery root/roster至少3、threshold至少2，与 routine
signer及 authority/anchor/backup administration隔离；allowed cause仅 active leaf/root expiry、current threshold
unavailable/revoked。normal trust不可授权时，authority先冻结 mutation，strong-read HEAD并验证 exact encrypted
backup/full prefixes/high-water，再以 protocol的 incident_open与 cutover两个独立 trusted-time replay identity
建立 anchored incident receipt及 fresh audit-delay evidence。cutover lower必须 >= incident upper + approved delay；
host time、proof复用、pre-state drift、rollback/fork/pending anchor均拒绝。

distinct recovery threshold只签 incident receipt、delay evidence、current anchor/frontiers/trust epoch、fresh
bundle/next epoch与 audit digest；new bundle须新 root及正常 threshold roster。global anchor gate仍执行
DB→encrypted exact-version backup→privileged signature→epoch append/HEAD CAS→strong-read；确认前零 write
authorization/receipt，确认后只启用 anchored new root。incident/proofs/approval/backup/read-back永久保留。
recovery roster自身不足 threshold时保持 blocked，无 single-admin/manual-DB bypass。

first history predecessor必须是 verified first frontier；其后 normal rotation/revocation或上述 emergency cutover
均是 phase-neutral signed record。genesis-zero fold只忽略验签 governance与 terminal non-valid/no-publication，
仍须证明没有 eligible valid publication/current restoration。bootstrap root/roster不可由 history rotation替换；
restore须从 first frontier重放完整 prefix并验证每个 trust edge及 external latest anchor。

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

claim冻结 candidate tag identity（repo、canonical tag ref、ref/tag object、完整 peel chain、source commit及
effective no-bypass protection）。Release不得隐式创建/移动 tag。六种 mutation kind、plan/slot/request
commitment、secret placeholder、effective-request digest、append/delivery authorization与每个 method的 CAS/
success/recovery wire均由 [API contract](publication_ledger_contract.md#release-effective-request-digest)及
[machine schema](publication_authority_api.schema.json)唯一拥有。

无环顺序固定：冻结不含 secret/ciphertext/final digest/operation ID的 public plan core；派生 plan digest、
stable mutation slot及 authority-owned broker delivery ID；KMS/HSM只签发一次 mutation nonce并产生
actual key ARN/material attestation；随后计算 request commitment/capsule receipt、final payload与 generic
operation ID并在同一 transaction提交 planned successor/outbox。draft_create另绑定 original claim capsule。
raw secret只在 authenticated broker memory中替换 typed placeholder；不得进入 template、history、ID、log或
report。same request恢复同一 capsule/delivery，cross owner/kind/slot/plan替换永久冲突。

broker在 send前验证 current owner/fence/frontier、delivery authorization、tag/ruleset、committed plan、
capsule attestations与 exact effective request；FULL-fsync send_started/audit后只发送一次。normal response须
fresh postcheck exact effect才 bind。response loss、restart/takeover/restore均复用原 delivery ID并只可
read-confirm/recover：唯一 post-state→bound；exact pre-state + exhaustive negative + broker quiescence→
not_applied；partial/conflicting/multiple→planned compensation；不可证明→kind-specific recovery_blocked。
任何 pending/blocked/in-flight slot阻止 prepared/publish/cleanup/terminal/recovered_publication。

draft claim nonce同样是 canonical 32-byte base64url、repo/candidate/generation全局 unique，先在
claim_reserved durable冻结 operation identity，再只生成一次 capsule。committed claim及 planned mutation
payload都绑定 capsule ciphertext、kms_key_arn、kms_key_material_id与 key_attestation_digest；logical
kms_key_version不存在。unwrap须 fresh authenticated current owner/fence/frontier，且验证 retained capsule及
actual KMS attestation。missing/tampered/unauthorized/KMS unavailable进入 draft_recovery_blocked，不生成
replacement nonce、claim或 draft。

## Generated PR、documentation 与 publication states

generated PR统一 planned→bound，pr_kind闭集为 decurrent、rollback、new_current、nonvalid_row、
invalidate_current。planned须早于 ref/commit/PR mutation并绑定 owner/kind/candidate、base/head、expected
tree/patch、ruleset、trusted App/installation、replacement chain及 fresh 32-byte head nonce commitment。
review core进入唯一 commit trailer，check identity进入 required check external_id；ref、commit、tree、check、
App/installation/ruleset任一不等不能 bind/merge。replacement必须 fresh slot/nonce/ref/review/check，且旧 gate/
queue/PR/head先有 authenticated revocation receipt。

planned commit后 authority按 API contract唯一派生 generated_pr_delivery_id，transaction内建立 plan↔delivery
双 UNIQUE outbox。send前 FULL-fsync send_started；ack-loss/restart/takeover/restore只按原 ID discovery/recover，
不第二次 create。exact one match才 bind/merge-recover；authenticated exhaustive negative + broker quiescence
才 not_applied；multiple、identity/creator drift、分页/权限/remote uncertainty进入对应 recovery-blocked。
closed request/success state及 nullability由 [machine schema](publication_authority_api.schema.json)唯一拥有。

required_documentation_surfaces是 protocol批准闭集，surface plan冻结 path、marker grammar、renderer digest、
base blob及 expected after blob/tree/patch。stable path/renderer改变要求 protocol bump；mutable base/default ref
变化要求 fresh render、human review、slot及 plan。三种 valid pre-intent branch：

- rollover_one：全部 surface恰一且同 current identity，先完成 atomic decurrent PR及 merge receipt；
- genesis_zero：全部零 marker且 history无 eligible valid publication，写 genesis_zero_receipt，无 no-op PR；
- post_invalidation_zero：全部零 marker且有 exact terminal invalidation suffix，写
  post_invalidation_zero_receipt，无 no-op PR。

mixed/missing/duplicate/extra marker、cross-surface identity drift或缺 required zero receipt均 fail closed。
intent_written必须绑定 human-approved exact plan/base/patch/review。valid publication只可从相应 zero receipt或
committed decurrent merge进入 intent，再到 release_committed_valid_marker_pending及 reviewed new-current；
publish_nonvalid从 prepared→intent→release_committed_nonvalid_row_pending，只合并 unmarked row且不改 current。
worker loss只允许 reconciler从 committed owner/intent/public truth恢复。

decurrent未 merge的取消须 higher-fence CAS、revoke authorization、dequeue/close、compare-delete head并证明
default branch/marker unchanged；竞争 merge转 rollback_pending。已 merge且 intent前取消只恢复 reviewed
rollback；继续发布则 revoked old plan后 fresh replacement。rollback/new-current/nonvalid-row任一无法取得
approved exact replacement即写对应 recovery-blocked并保留 owner；只有 effect closed与 cleanup完成才 terminal。

current-valid invalidation只能用 invalidate_current PR原子更新所有 surface，移除 exact marker并绑定 approved
reason/evidence。merge后 receipt绑定 actual PR/merge/default-ref/tree及每个 before/after blob；response loss只
接受发现的唯一 exact merged tuple。partial/stale/concurrent/new-current drift进入
invalidation_recovery_blocked。intent后 draft/Release不匹配、claim-draft discovery不完整或 remote effect不明
分别进入 release_recovery_blocked/draft_recovery_blocked；deadline或 heartbeat不能证明从未创建。

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
replacement_key_or_bundle_digest_or_null}`；reason union与 replacement applicability只由
[authority API contract](publication_ledger_contract.md#history-delegated-trust-revocation-values)定义。先计算 `rotation_core_digest=SHA256(JCS(rotation_core))`；detached
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
其余 publication-domain 34 kinds先规范化 operation identity：takeover取 `(new_owner_generation,new_owner_run_id,new_owner_run_attempt)`，terminal-no-publication取 `(terminal_owner_generation,terminal_owner_run_id,terminal_owner_run_attempt)`，其它 kind取 payload `owner_generation`及 signed fold中该 generation-origin的 `run_id/run_attempt`；`transition_slot`来自 immutable intent且 fold-valid。payload/request/fold任一不等须在 operation-ID lookup/append前拒绝。随后 exact 为
`SHA256(JCS({v:"GH700:publication-operation-id:v1",repo_node_id,owner_generation,run_id,run_attempt,
transition_slot,predecessor_frontier,record_kind,publication_payload_core_digest,
trusted_time_proof_request_id_or_null}))`；non-time kind以完整 payload作 core且 request ID为 literal null，
heartbeat/takeover以 [authority protocol](publication_authority_protocol_contract.md#authority-owned-time-bound-payload-cores)的 exact core/request ID构造；三种 time-dependent kind在 proof后才生成 final payload/digest/intent。三种 normal governance kinds exact 为
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
| `owner_claimed` | `{owner_generation,run_id,run_attempt,candidate_tag_identity_digest,frozen_plan_digest,liveness_policy_digest,draft_claim_nonce_digest,nonce_capsule_id,capsule_ciphertext_digest,kms_key_arn,kms_key_material_id,key_attestation_digest,trusted_time_proof_digest,prior_time_high_water,new_time_high_water,claim_accepted_at,lease_expires_at}` |
| `owner_heartbeat` | `{owner_generation,heartbeat_sequence,prior_liveness_operation_id,liveness_policy_digest,trusted_time_proof_digest,prior_time_high_water,new_time_high_water,accepted_at,lease_expires_at}` |
| `publication_owner_taken_over` | `{candidate_tag_identity_digest,prior_owner_generation,new_owner_generation,new_owner_run_id,new_owner_run_attempt,prior_owner_terminal_or_expiry_evidence_digest,slot_chain_digest,trusted_time_proof_digest,prior_time_high_water,new_time_high_water,accepted_at,lease_expires_at}` |
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
| `publication_terminal_no_publication` | `{candidate_tag_identity_digest,terminal_owner_generation,terminal_owner_run_id,terminal_owner_run_attempt,complete_generation_chain_digest,closed_slot_chain_digest,draft_cleanup_evidence,exhaustive_negative_discovery_digest}` |
| `publication_terminal` | `{owner_generation,terminal_kind,release_identity_or_null,generated_pr_chain_digest,closed_slot_chain_digest,finalization_receipt_digest}` |
| `release_mutation_planned` | `{owner_generation,mutation_kind,transition_slot,mutation_slot_id,plan_core_digest,request_commitment,mutation_nonce_digest,mutation_nonce_capsule_id,broker_delivery_id,capsule_ciphertext_digest,kms_key_arn,kms_key_material_id,key_attestation_digest,tag_identity_digest,pre_state_digest,request_template_digest,expected_post_state_digest}` |
| `release_mutation_bound` | `{owner_generation,mutation_kind,mutation_slot_id,planned_operation_id,request_commitment,broker_delivery_id,effective_request_digest,response_resource_digest,post_state_digest,completed_guard_receipt_digest}` |
| `release_mutation_recovery_pending` | `{owner_generation,mutation_kind,mutation_slot_id,planned_operation_id,broker_delivery_id,effective_request_digest,uncertain_outcome_code,send_once_audit_digest}` |
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
| `trust_key_revoked` | `{rotation_id,current_trust_epoch,next_trust_epoch,revoked_key_id,revocation_reason_code,replacement_key_or_bundle_digest_or_null,approval_digest,rotation_cutover_certificate_digest}`；reason/replacement applicability只由 [authority API contract](publication_ledger_contract.md#history-delegated-trust-revocation-values)定义 |
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
`owner_claimed` 后只可 mutation plan 链或 `draft_bound`；唯一直接 generated-PR edge是 folded claim phase（仅可夹 phase-neutral heartbeat/takeover/governance）到 `generated_pr_planned(pr_kind=invalidate_current)`，且 fresh predecessor须证明同一 current-valid release/surfaces byte-equal non-null invalidation context、同 owner/fence/run且无 draft/release-mutation/其它 generated-PR slot；其它直接 PR kind拒绝，最终 invalidation receipt的 identity/evidence须 byte-equal该 context。`draft_bound`后闭合 upload/update slots才可 `prepared`。
prepared valid只有两条互斥 pre-intent路径：`genesis_zero_receipt|post_invalidation_zero_receipt`→`intent_written(intent_kind=publish_valid,zero receipt non-null)`，或 rollover-one的
`generated_pr_planned(pr_kind=decurrent)`→`generated_pr_bound`→`generated_pr_merged`→`intent_written(intent_kind=publish_valid,rollover receipt non-null)`；后者仅在 exact receipt提交且 fresh fold证明旧 current被原子移除后可写。
planned无 effect只可 `generated_pr_not_applied`后以 new slot/head/nonce fresh-reviewed replacement，bound失败
只可 revoke后 replacement或 `decurrent_pr_recovery_blocked`；merged取消只走 `valid_rollback_pending`，且最多
一个未撤销 gate。prepared non-valid直接接 `intent_written(intent_kind=publish_nonvalid)`；intent后 publish slot
bound才可相应 committed-pending，再经 generated PR链到 `record_kind=publication_terminal`。pre-intent cleanup
只以 `publication_terminal_no_publication`结束。invalidation exact edge为 `owner_claimed→generated_pr_planned
(pr_kind=invalidate_current)→generated_pr_bound→generated_pr_merged→invalidate_current_merged_receipt→
publication_terminal(terminal_kind=invalidation_completed)`；planned no-effect只可 not-applied后以 fresh slot/head/nonce/
review replacement，bound failure只可 revoke+replacement或 `invalidation_recovery_blocked`，merged ack-loss按同一
planned ID恢复 exact ordered bound/merged receipts；不得插入 draft/Release mutation或跳过 terminal。
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
