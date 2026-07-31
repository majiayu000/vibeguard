# GH700 Publication History Contract

本文件是 `product.md` B-017/B-018 与 `tech.md` publication machine 的规范性组成部分，
隔离完整 publication ownership、mutation-secret、append-only history、blocked-attempt ledger、trusted time、trust/fold 与
owner-liveness 概念边界。引用方可以通过链接或行为场景引用这里已经定义的 identifier，
但不得复制、改名或局部覆盖这里的字段集合、枚举、canonical bytes、secret boundary
或 fail-closed 语义；冲突时本文件的 exact machine-facing identifiers为唯一真源。

## Concrete durable authority

唯一 production backend 是 `publication_authority_sqlite_v1`，由计划中的
`vibeguard-runtime/src/publication_authority/{mod.rs,store.rs,broker.rs,recovery.rs}` 与
`vibeguard-runtime/src/main.rs` 的 `publication-authority serve|recover` 命令实现；publication
client、workflow、benchmark code 均不得另建 store、直接打开数据库或以内存/mock/checkout/
Actions artifact降级。environment-protected service以单 active replica运行在独立于 runner、
checkout、Release artifact与 owner lifecycle 的 durable volume；signed deployment manifest的
closed planned **schemas/publication_authority_deployment.schema.json** 固定
`{authority_id,backend,authority_identity_digest,policy_epoch,policy_bundle_digest,client_api,control_api,
publication_store_path,publication_store_lock_path,volume_identity,kms_key_id,retention_policy_digest,
trust_bundle_digest,blocked_attempt_ledger,trusted_time_service,bootstrap_governance,restore_anchor_service}`；
backend必须 exact 为 `publication_authority_sqlite_v1`。
`client_api` 与 `control_api` 是同一 authority 每次启动同时绑定的两个 required objects，不是 union、
alias或 fallback。`client_api` exact 为 `{endpoint,transport,api_version,
server_identity_bundle_digest,client_auth_policy_digest}`：endpoint是 manifest-pinned absolute HTTPS
origin+path且禁 redirect/userinfo/query/fragment，transport exact `tls13_mtls_http2_jcs_v1`，API version
exact `GH700:publication-authority-client-api:v1`。`control_api` exact 为 `{socket_path,transport,
api_version,server_process_identity_digest,peer_auth_policy_digest}`：socket是 manifest-pinned absolute
Unix path，transport exact `unix_peercred_jcs_v1`，API version exact
`GH700:publication-authority-control-api:v1`，只开放 bootstrap/migrate/recover/ready 方法且永不监听网络。
两个 API 的每个 request/response/startup receipt都必须绑定相同 top-level `authority_id`、
`authority_identity_digest`、strictly monotonic `policy_epoch` 与 `policy_bundle_digest`；该 bundle同时
digest method partition、两端 auth policy及 server identities。client server bundle由 authority外的
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

service启动先取得同 manifest钉住的 process lock，验证 volume支持 kernel lock与 durable
`fsync`，再以 SQLite WAL、`journal_mode=WAL`、`synchronous=FULL`、foreign keys及
`BEGIN IMMEDIATE`运行。history head/leaf、operation/rotation/slot unique indexes、owner/fence、
capsule ciphertext metadata、broker outbox/delivery/send-once audit与 completed receipt须在一个
事务中验证和提交；任何 lock/busy timeout、WAL/fsync/checkpoint、disk-full或 KMS error都使
authority non-ready并 fail closed，不得返回成功 receipt。首次 database/WAL/lock 创建与 migration
commit后还须 fsync file及 parent directory；禁止 destructive migration、truncate或 silent rebuild。
authority-owned durable persistence是 exact closed inventory：signed deployment manifest与 bootstrap/
migration/governance receipts；SQLite database/WAL/checkpoint及 history/blocked-attempt/operation/rotation/
slot/owner/fence unique indexes；完整 attempt manifest/record/binding/watermark、RFC3161 token proof capsules与
time high water；capsule ciphertext metadata与 KMS retained-key/version/retention references；broker outbox、
delivery/send-once audit与 completed receipts；external restore anchor/epoch/two frontiers、snapshot/WAL digests及
restore/recovery receipts。其外 cache/temp/log不得参与恢复或授权，inventory内任一缺失/不一致均 blocked。

唯一 bootstrap owner 是 SP700-T3 的 publication-authority store/deployment single writer，经计划中的
**.github/workflows/publication-authority-deploy.yml** 调用
**scripts/ci/bootstrap_publication_authority.py**：只可在不存在 database时写入 independently signed
length-zero genesis/trust bundle并签发 bootstrap receipt，已存在时必须 byte/digest-match或拒绝。
唯一 crash/restore authority 是同一 protected service的 `recover` 命令，在 exclusive process lock下
replay WAL、校验 `integrity_check`、全量重放 signed history/unique indexes/outbox/capsule metadata并
重新签发 exact-head recovery receipt。唯一 production external backend/service是
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

anchor exact payload为 `{authority_id,authority_identity_digest,policy_epoch,repo_node_id,anchor_schema_version,restore_epoch,
latest_frontier,blocked_attempt_ledger_frontier,time_high_water,time_proof_digest,snapshot_digest,wal_digest,
prior_anchor_digest,anchor_request_id}`，其中两个 frontier
含 exact `full_prefix_digest`；payload由 governance threshold签名。每个 committed history/attempt/time successor须在释放成功
receipt或允许 broker write前，以 prior digest+epoch作为 conditional CAS推进 anchor。ack丢失只可
strong-read同 epoch row+HEAD并 byte/digest-match同 request ID确认，不得重写；并发/stale CAS只能一胜，
loser重读后若不是其 exact payload即 blocked。authority DB commit后/anchor CAS前 crash可在独占恢复中
以 committed successor重试同 CAS，但 broker仍禁写；anchor CAS后/本地 receipt前 crash只可按上述
read-confirm补 receipt。任何成功 receipt必须携 DynamoDB transaction request digest、signed payload、
epoch row/HEAD exact digest与 strong-read confirmation，形成 DB committed frontier→signed anchor payload→
conditional transaction→service response/read-back→authority receipt 的端到端 CAS proof。

唯一 bootstrap/migration/restore implementation owner是 SP700-T3：计划中的
**.github/workflows/publication-restore-anchor-deploy.yml** 与
**scripts/ci/bootstrap_publication_restore_anchor.py** 在 environment protection及 governance threshold
批准后创建/核验空表、以 `restore_epoch=0` conditional transaction写 genesis并把 receipt并入 authority
bootstrap；migration只可 append higher schema epoch且不得改写旧 epoch。snapshot+WAL restore须先
strong-read production HEAD，以更大 `restore_epoch`获 threshold批准，证明 restored history与 blocked-attempt
prefix均不少于且 exact包含 anchored two frontiers/full-prefix、restored time high water不低于 anchor，完成
replay/recovery receipt后 CAS新 anchor；T3执行，独立
maintainer governance持 approval/admin role，二者不得互换。missing/stale/equal-or-lower epoch、older/
forked prefix、wrong table/service identity、CAS conflict、unprovable ack或 KMS不可解封均拒绝。T10只消费
认证 client API，不拥有 authority/anchor backend、write/admin credential或 bootstrap/migration/recovery authority。

端到端证明必须在真实 durable-volume fixture对每个 transaction boundary注入 kill/power-loss、并发
claim/slot/delivery、WAL/checkpoint失败、disk-full、KMS unavailable、runner/checkout删除、owner
terminal与 signed snapshot+WAL restore；重启后只允许 exact committed state或未提交状态，绝无
双 owner、双 send、丢 leaf/index/capsule/outbox或 unsigned frontier。anchor integration fixture须对真实
DynamoDB隔离 non-production-account test table验证 concurrent
single-winner、stale prior/epoch、ack loss read-confirm、DB-commit↔anchor-CAS两侧 crash、wrong table ID/
credential/trust、PITR新表替换、bootstrap replay与 signed restore；mock/in-memory结果不能作为通过证据。

## Concrete blocked-attempt ledger

B-029 唯一 production backend 是同一 authority database 内的
`blocked_attempt_ledger_sqlite_v1` namespace，由计划中的
planned **vibeguard-runtime/src/publication_authority/blocked_attempt_ledger.rs** 实现；它不是
`publication_history` alias，也不能降级为 Actions artifact、attestation pointer、job summary或 checkout
JSON。deployment manifest 的 `blocked_attempt_ledger` exact 为
`{backend,namespace,api_version,retention_class}`，值 exact 为
`{backend:"blocked_attempt_ledger_sqlite_v1",namespace:"blocked_attempt_v1",
api_version:"GH700:blocked-attempt-ledger-api:v1",retention_class:"permanent_no_ttl_v1"}`。
T3 store/deployment single writer独占 planned **schemas/blocked_attempt_ledger.schema.json**、SQLite
tables `{blocked_attempt_records,blocked_attempt_unique_keys,blocked_attempt_bindings,
blocked_attempt_frontiers,reconciliation_watermarks}`、bootstrap/migration/recovery；T10 completion client只可
经 `client_api` 调 exact methods `{append_blocked_attempt,bind_blocked_attempt,
list_blocked_attempts,commit_reconciliation_watermark,get_blocked_attempt_frontier}`。两域共用 DB/WAL/fsync、
process lock、snapshot与 external anchor但使用独立 repository-ledger lease/fence、operation ID/index，
publication owner/fence绝不授权 ledger append，ledger fence也绝不授权 publication mutation。

ledger frontier exact 为 `{repo_node_id,ledger_length,ledger_root,full_prefix_digest}`。record exact top-level
object为 `{schema_version,attempt_record_kind,repo_node_id,source_identity_key,run_id,run_attempt,
predecessor_frontier,payload}`，闭集 `attempt_record_kind` 仅为
`{candidate_failure,pipeline_interrupted,pipeline_interrupted_pre_attestation,
publication_recovery_binding}`：`candidate_failure.payload` exact 为
`{candidate_identity,failure_scope,target_or_null,required_platforms_or_null,failed_summary_digest_or_null,
failure_manifest_jcs,failure_manifest_digest,bundle_digest,selected_policy,effective_action,closed_reason_code}`；
`failure_scope` exact 为 `{target,release}`；target branch要求 non-null `target`且两个 release字段为 null，
release branch反之。`pipeline_interrupted.payload` exact 为
`{candidate_identity,staged_provenance_digest,interruption_conclusion,interruption_stage,publish_sentinel_audit_digest,
missing_evidence,failure_manifest_jcs,failure_manifest_digest}`；
`pipeline_interrupted_pre_attestation.payload` exact 为 `{workflow_id,head_sha,server_ref_type,server_ref_name,
event,conclusion,early_attempt_key,candidate_identity_or_null,selected_policy_or_null,
staged_provenance_digest_or_null,evidence_identities_or_null,failure_manifest_jcs,failure_manifest_digest}`且四个
`*_or_null`字段必须 literal null；`publication_recovery_binding.payload` exact 为
`{candidate_identity,publication_history_operation_id,publication_history_frontier,recovered_outcome_digest,
bound_attempt_record_digests}`。unknown kind/field、missing/extra/null-not-declared或 alias拒绝。

append 在同一 `BEGIN IMMEDIATE` transaction验证 expected frontier、ledger lease/fence，并以永久 unique
index `(repo_node_id,source_identity_key,run_id,run_attempt,attempt_record_kind)` 做 same-bytes幂等、different-
bytes冲突；写入完整 canonical manifest bytes、record、binding/frontier/watermark后 FULL fsync，并以同一
frontier CAS external anchor成功或 read-confirm exact ack后才返回 signed receipt。records/manifest
bytes/frontiers/bindings/watermarks无 TTL、无 delete/truncate/overwrite；artifact
retention、owner terminal、candidate publish或 schema migration均不缩短 retention。snapshot/WAL restore必须
同时达到 external anchor的 `blocked_attempt_ledger_frontier`，重放全部 records/unique indexes/bindings/
watermarks并核对 full-prefix；缺 manifest bytes、older/forked frontier或未闭合 terminal attempt时 authority
non-ready且 publish gate blocked。真实 durable-volume fixture须覆盖 concurrent append、same-key different
bytes、crash/fsync/disk-full、artifact deletion、snapshot rollback与 exact manifest恢复；mock不算通过。

## Rollback-resistant trusted time

host wall clock、process monotonic clock、client timestamp、GitHub event time与 unsigned HTTP `Date` 均不授权
expiry/takeover。deployment manifest 的 `trusted_time_service` exact 为
`{backend,api_version,threshold,sources,max_accuracy_seconds,proof_retention_policy_digest}`，backend/API exact
为 `rfc3161_tsa_quorum_v1` / `GH700:trusted-time-api:v1`；`sources` 是至少三项按 `source_id` canonical排序的
`{source_id,endpoint,transport,tsa_policy_oid,signer_bundle_digest,server_identity_bundle_digest,
client_auth_policy_digest}`，endpoint为无 redirect/query/fragment的 manifest-pinned HTTPS path，transport
exact `tls13_mtls_rfc3161_sha256_v1`，threshold至少二且不超过 source数。source须独立 administration/
signing root；ambient DNS/proxy/CA、TOFU、同 root重复 signer、unknown policy/algorithm均拒绝。

每个 time-dependent transition生成 fresh 256-bit nonce并请求每个 TSA 对
`SHA256(JCS({v:"GH700:trusted-time-proof:v1",authority_id,repo_node_id,transition_operation_id,
predecessor_frontier,nonce_b64u}))` 签 RFC3161 token。验证 distinct threshold signer、message imprint、policy OID、
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
以 job absence接管。T3独占 `trusted_time.rs` client/proof/high-water persistence，T10只能提交 time-bound intent；
T12须用真实 RFC3161-compatible independent test signers覆盖 host forward/backward jump、replay、quorum split、
accuracy overlap、restart/snapshot rollback、heartbeat-vs-takeover race与 anchor ack-loss。

## Bootstrap governance and first frontier

deployment manifest 的 `bootstrap_governance` exact 为
`{bootstrap_version,release_identity_root_digest,governance_roster_digest,governance_threshold,
governance_signer_key_ids,initial_trust_bundle_digest,initial_trust_epoch,first_frontier,
first_blocked_attempt_frontier,initial_time_high_water,initial_time_proof_digest,bootstrap_approval_digest}`。
release-identity root在 store/history/AWS accounts之外，
签 roster attestation并把 canonical distinct signer key IDs、`1 <= threshold <= signer_count`、repo/purpose、
initial trust root/leaf certificates与 epoch钉住；bootstrap approval须由 roster中 distinct threshold signers共同
签 exact manifest digest。self-signed/TOFU、重复 signer、阈值不足、root/roster/epoch drift均拒绝。

`first_frontier` 唯一为 length zero：`repo_node_id` exact，`history_length=0`，`history_root` exact 为
`SHA256(JCS({v:"GH700:history-empty-root:v1",repo_node_id}))`，`full_prefix_digest` exact 为
`SHA256(JCS({v:"GH700:history-empty-prefix:v1",repo_node_id}))`。
`first_blocked_attempt_frontier` 同样固定 `ledger_length=0`，root/full-prefix分别由
`GH700:blocked-attempt-empty-root:v1` / `GH700:blocked-attempt-empty-prefix:v1` 加 `repo_node_id` 做 JCS SHA-256。
T3 bootstrap只在 DB/anchor均不存在时，以
threshold approval、RFC3161 quorum initial-time proof和外部 release-identity attestation原子创建 SQLite
genesis/trust state，再以 DynamoDB epoch-zero conditional transaction锚定 first frontier、zero blocked-ledger
frontier及 initial time high water；两侧任一已存在只可 byte/digest match，不能重置。bootstrap receipt exact
绑定 manifest/root/roster/threshold/signer set、first frontier、trust epoch、time proof与 anchor transaction。

first history record的 predecessor必须是 first frontier并由 initial trusted leaf签名；其后
`{trust_leaf_rotated,trust_root_rotated,trust_key_revoked}` 可在首次 eligible valid publication之前按独立
governance lease/fence/threshold追加。`genesis_zero` fold把这些验签、phase-neutral且 publication-state-neutral
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
`generated_pr_planned(kind) → generated_pr_bound(kind)`，其中 `kind ∈
{decurrent,rollback,new_current,nonvalid_row,invalidate_current}`。planned必须早于首次
head-ref/commit/PR mutation，绑定 repo/owner generation/kind/candidate、base ref/OID、head
repo/ref、expected tree/OID、patch/nonce/ruleset digest、trusted App/installation identity及
replacement chain；nonce必须进入受保护 deterministic ref/commit/check identity，不能只放可编辑
PR metadata。create/bind response loss须完整分页枚举 draft/open/closed/merged/queued PR与 head
ref并核对完整 tuple：唯一 active match在重读 latest signed frontier/fence/ruleset后 CAS bound；
唯一 merged match按 kind进入 receipt/rollback/marker/row恢复；closed match先 revoke再
replacement。ordinary/stale zero保留 owner且不得重发 non-idempotent create；仅同一线性化快照
覆盖 PR+ref的 authenticated exhaustive negative receipt可证明不存在。多匹配、tuple/creator
不符、分页/权限不全、rate-limit/5xx/timeout或无强一致 absence API，按 kind进入对应 recovery
blocked variant。旧 fence late bind、reopen/ref ABA、stale check/review与 ruleset bypass均由
latest-frontier merge gate拒绝。

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
  locale drift；以 `generated_pr_planned(decurrent)` 创建并 bind一次原子更新全部 surfaces的
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
`publish_intent`须绑定对应 plan receipt与已 human-approved的 exact new-current patch/review/base
digest；base/CAS变化即重审。valid ownership以 fenced CAS推进
`valid_zero_marker → intent_written → release_committed_valid_marker_pending`。Release commit后
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
只能在 store-auth expiry后 higher-fence exact-frontier CAS；无获批 replacement时进入相应
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
downgrade、expired/revoked或缺 rotation chain 均 fail closed。
history append authorization 是 closed union：publication transition须 current owner
generation/publication lease/fence；`{trust_leaf_rotated,trust_root_rotated,trust_key_revoked}`
是 phase-neutral governance transition，不含 owner generation，使用独立 repository-governance
lease/fence、authenticated governance actor及 threshold approval，因此 prior owner terminal/
no active owner时仍可轮换，active owner期间也不伪造 takeover或改变其 phase/liveness。
immutable rotation payload绑定 repo/purpose/current→next epoch、old/new key或bundle/cert/
approval digests，stable `rotation_id=H(repo,purpose,current_epoch,next_epoch,kind,payload_digest,
approval_digest)` 不含 predecessor/fence。store先查永久 `(repo_node_id,rotation_id)`：same
payload/approval返原 receipt，异值冲突；absent才验 governance domain/fence/actor/threshold/
current epoch/exact predecessor并 append。stable approval/canonical payload不含 predecessor；每次 append的
`rotation_cutover_certificate` 另绑定 rotation ID/approval digest、exact predecessor、successor ordinal与
next epoch，但绝不含 successor root/full-prefix/receipt digest。publication suffix抢先时保留相同 rotation
ID/payload/approval并为 new predecessor/op重签 cutover certificate；store用 pre-state trust验证后 append，
复算 actual successor并核对 ordinal，在 receipt中绑定 actual successor frontier。new trust只接受以该
actual successor为 predecessor的后续 record。governance suffix只改变 trust epoch/state；active publication
owner重放 suffix并从新 predecessor重规划，两个 authorization fence绝不可互换。store 对
`(expected_length, expected_root, expected_full_prefix_digest, current_fence)` 原子 CAS，
复算并签发 successor frontier。每次 transition 分为 immutable intent、mutable append
authorization envelope与 store-signed committed envelope/receipt。publication transition的跨进程稳定
`transition_operation_id = H(repo_node_id, owner_generation, run_id, run_attempt,
transition_slot, predecessor_frontier, record_kind, payload_digest)`，不得包含 authorization
fence；`owner_generation` 永不复用，首条 claim由 server-auth run tuple+frozen plan生成。
intent 固化 schema/canonicalization version、operation ID、owner generation、run/slot、exact
predecessor/prior phase、`record_kind` 与 payload digest，`intent_digest=SHA256(JCS(intent))`；
retry复用同一 intent bytes/digest。append request另携当前 `authorization_fence`、lease
scope/token与 authenticated actor。store先查同事务永久唯一索引
`(repo_node_id, operation_id)`：同 digest已存在直接返回原 receipt且不重新验 fence/append，
异 digest永久冲突；不存在才原子验证 current owner generation/fence/lease/exact predecessor，
append并签发 envelope/receipt，绑定 actual accepted fence、intent/store-envelope digest、
predecessor/successor与 issuer/key version。stale fence对新 mutation失败，但已提交 old op
只能取回原 receipt。
`owner_claimed` 是唯一的 publication-domain absent-owner 创建 transition；独立 governance
transition按上述规则不创建 owner或授权 Release/PR mutation。claim intent声明 fresh、全局永不复用的
`owner_generation`，store仅在 exact predecessor fold 证明 length-zero/no owner 或 prior
owner terminal、repository publication lease/current fence有效、server-auth run/candidate/
frozen-plan tuple、nonce capsule与 predecessor frontier匹配时，才在同一事务创建 generation、
secret capsule、history append及 committed envelope；已有 active owner必须走 takeover，不能再 claim。并发 claim只能一个
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
authorization fence/lease/actor只在 append envelope，committed receipt只在 envelope inventory，不得塞入
immutable leaf。唯一 discriminator是 `record_kind`；`kind`/`type`/`record_type`/alias/unknown均拒绝。
frontier字段唯一为 `{repo_node_id,history_length,history_root,full_prefix_digest}`，canonical digest使用
`jcs-rfc8785-v1`。exact union只有下表 37 kinds；payload列是 closed required field set，missing/extra field
一律 schema-invalid，nullable字段仅在显式写 `*_or_null` 时允许 canonical null。

| `record_kind` | exact `payload` fields |
| --- | --- |
| `owner_claimed` | `{owner_generation,run_id,run_attempt,candidate_tag_identity_digest,frozen_plan_digest,liveness_policy_digest,draft_claim_nonce_digest,nonce_capsule_id,capsule_ciphertext_digest,kms_key_version,trusted_time_proof_digest,prior_time_high_water,new_time_high_water,claim_accepted_at,lease_expires_at}` |
| `owner_heartbeat` | `{owner_generation,heartbeat_sequence,prior_heartbeat_operation_id,liveness_policy_digest,trusted_time_proof_digest,prior_time_high_water,new_time_high_water,accepted_at,lease_expires_at}` |
| `publication_owner_taken_over` | `{candidate_tag_identity_digest,prior_owner_generation,new_owner_generation,prior_owner_terminal_or_expiry_evidence_digest,slot_chain_digest,trusted_time_proof_digest,prior_time_high_water,new_time_high_water,accepted_at,lease_expires_at}` |
| `draft_bound` | `{owner_generation,release_node_id,tag_identity_digest,target_commit_oid,draft_claim_nonce_digest,release_mutation_operation_id}` |
| `prepared` | `{owner_generation,draft_bound_operation_id,asset_manifest_digest,checksums_digest,summary_digest,closed_slot_set_digest}` |
| `genesis_zero_receipt` | `{owner_generation,first_frontier,verified_prefix_digest,zero_marker_surface_digest,bootstrap_receipt_digest,governance_suffix_digest}` |
| `post_invalidation_zero_receipt` | `{owner_generation,invalidation_receipt_operation_id,invalidation_suffix_digest,zero_marker_surface_digest,terminal_chain_digest,governance_suffix_digest}` |
| `intent_written` | `{owner_generation,intent_kind,prepared_operation_id,zero_marker_receipt_operation_id_or_null,unmarked_row_plan_digest_or_null,summary_digest,release_manifest_digest}` |
| `release_committed_valid_marker_pending` | `{owner_generation,intent_operation_id,release_node_id,published_release_digest,new_current_pr_plan_digest}` |
| `release_committed_nonvalid_row_pending` | `{owner_generation,intent_operation_id,release_node_id,published_release_digest,nonvalid_row_pr_plan_digest}` |
| `valid_decurrent_pr_cancel_pending` | `{owner_generation,decurrent_pr_bound_operation_id,higher_fence_receipt_digest,cancel_plan_digest}` |
| `valid_rollback_pending` | `{owner_generation,decurrent_pr_merged_operation_id,rollback_pr_plan_digest,prior_marker_digest}` |
| `invalidate_current_merged_receipt` | `{owner_generation,generated_pr_merged_operation_id,evidence_digest,invalidated_release_identity,zero_marker_surface_digest}` |
| `recovered_publication` | `{owner_generation,intent_operation_id,recovery_truth_branch,release_node_id,generated_pr_chain_digest,finalization_receipt_digest}` |
| `publication_terminal_no_publication` | `{candidate_tag_identity_digest,terminal_owner_generation,complete_generation_chain_digest,closed_slot_chain_digest,draft_deletion_receipt_digest,exhaustive_negative_discovery_digest}` |
| `publication_terminal` | `{owner_generation,terminal_kind,release_identity_or_null,generated_pr_chain_digest,closed_slot_chain_digest,finalization_receipt_digest}` |
| `release_mutation_planned` | `{owner_generation,mutation_kind,transition_slot,mutation_slot_id,plan_core_digest,request_commitment,mutation_nonce_digest,mutation_nonce_capsule_id,broker_delivery_id,capsule_ciphertext_digest,kms_key_version,tag_identity_digest,pre_state_digest,request_template_digest,expected_post_state_digest}` |
| `release_mutation_bound` | `{owner_generation,mutation_kind,mutation_slot_id,planned_operation_id,request_commitment,broker_delivery_id,effective_request_digest,response_resource_digest,post_state_digest,completed_guard_receipt_digest}` |
| `release_mutation_recovery_pending` | `{owner_generation,mutation_kind,mutation_slot_id,planned_operation_id,broker_delivery_id,uncertain_outcome_code,send_once_audit_digest}` |
| `release_mutation_not_applied` | `{owner_generation,mutation_kind,mutation_slot_id,recovery_pending_operation_id,exact_pre_state_digest,exhaustive_negative_discovery_digest,broker_quiescence_receipt_digest}` |
| `compensation_planned` | `{owner_generation,source_mutation_kind,source_mutation_slot_id,compensation_mutation_kind,compensation_slot,compensation_plan_digest,required_pre_state_digest}` |
| `compensated` | `{owner_generation,compensation_planned_operation_id,compensation_mutation_bound_operation_id,restored_pre_state_digest,no_extra_resource_receipt_digest}` |
| `generated_pr_planned` | `{owner_generation,pr_kind,transition_slot,base_ref_oid,reviewed_commit_oid,expected_tree_digest,patch_digest,merge_method,ruleset_digest}` |
| `generated_pr_bound` | `{owner_generation,pr_kind,planned_operation_id,pr_node_id,head_ref,head_oid,base_oid,queue_identity_digest,review_digest}` |
| `generated_pr_revoked` | `{owner_generation,pr_kind,bound_operation_id,pr_node_id,queue_absent_receipt_digest,head_absent_receipt_digest,default_unchanged_receipt_digest}` |
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

closed enums exact 为 `intent_kind={publish_valid,publish_nonvalid}`、
`pr_kind={decurrent,rollback,new_current,nonvalid_row,invalidate_current}`、
`terminal_kind={published_valid,published_nonvalid,rollback_restored,invalidation_completed}`及
`recovery_truth_branch={matching_public_release,matching_intent_bound_draft}`；`retain_owner`必须 literal `true`。
`release_mutation_recovery_blocked.mutation_kind`只允许
`{draft_update,draft_delete,asset_upload,asset_delete,publish}`，`draft_create`只允许
`draft_recovery_blocked`。broker audit、capsule、KMS refs、external anchor、time proof、PR/Release discovery与
generated patch是由 payload digest引用的 durable typed objects，不是额外 record kinds。非法 transition/
fence/owner、缺失/截断/fork、过期 fence、checkout anchor或表外 kind均 fail closed。
允许的 phase grammar也闭合：`owner_claimed` 后只可 heartbeat、mutation plan链、`draft_bound`或 takeover；
`draft_bound`后闭合 upload/update slots才可 `prepared`；prepared valid先接 exact zero receipt再
`intent_written(intent_kind=publish_valid)`，prepared non-valid直接接
`intent_written(intent_kind=publish_nonvalid)`；intent后 publish slot bound才可相应 committed-pending，
再经 generated PR planned→bound→merged/revoked/replacement链到 `record_kind=publication_terminal`。pre-intent cleanup
只以 `publication_terminal_no_publication` 结束；invalidation只以 planned→bound→merged→
`invalidate_current_merged_receipt`→`record_kind=publication_terminal, terminal_kind=invalidation_completed`结束。
recovery pending只可到 bound/not-applied/compensation/对应 blocked；八 blocked kinds均保留 owner且非 terminal。
三种 governance kinds可插入任一 frontier但只改变 trust state。任何未列 edge或跳过 predecessor均拒绝。
`post_invalidation_zero` 的 invalidation suffix fold是 exact closed union：terminal non-valid
publication、current prepared owner、下述 authenticated terminal no-publication attempt chain及已验签的
phase-neutral `{trust_leaf_rotated,trust_root_rotated,trust_key_revoked}`。no-publication chain从同
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

本 contract拥有 Rust/Python/shell共用的 machine-facing vectors；调用方只引用这些 fixture，
不得各自复制 enum、字段集合或 canonical bytes：

- `frontier_valid_v1` 的 exact JCS bytes为
  `{"full_prefix_digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","history_length":7,"history_root":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","repo_node_id":"R_kgDOGH700"}`，
  SHA-256为 `e52c3472ae93b565704e4f26a97f02260e7c9d2c724b8add3350a7f7317edf73`；
  frontier/discriminator/mutation aliases均为 negative vectors。
- `blocked_record_kinds_valid_v1`逐一覆盖 closed blocked union；unknown/alias逐条 reject。
  mutation secret-boundary vectors逐 kind验证唯一 digest、opaque capsule/delivery、template/effective
  digests，并拒绝 raw/reversible nonce、secret-bearing request/history bytes、错误 placeholder 数量、
  capsule/slot/operation替换及二次 send。
- `post_invalidation_suffix_no_draft_v1`是 terminal no-publication positive vector，使用
  `draft_never_existed`及完整 negative/quiescence/not-applied evidence；同一场景改为缺失、unknown、
  wrong tag、带 bound/recovered draft、带 publish intent/public Release或任一 pending/blocked/in-flight
  slot时逐项 reject。
- `post_invalidation_suffix_draft_deleted_v1`是另一个 positive vector，使用 `draft_deleted`及 exact
  bound/recovered draft、closed delete/compensation receipt、post-delete absence/quiescence evidence；
  缺失、伪造、未闭合、wrong-draft deletion evidence或实际无 draft时逐项 reject。
- 其余 suffix vectors逐一覆盖获验签的 phase-neutral governance record与 same-candidate takeover，
  并拒绝 forged/nonterminal/cross-candidate takeover、wrong governance evidence、owner/phase/liveness
  mutation、current restoration、其它 owner与 unknown record。

## Owner liveness

长时间等待人工 review 以 durable `owner_heartbeat` renewal record续活：immutable
intent只绑定 stable owner generation、单调 heartbeat sequence/transition slot与
`liveness_policy_digest`，不得绑定 client timestamp/deadline或 authorization fence；
`owner_claimed` 与 `owner_heartbeat` 的 store-signed committed envelope均按获批 H-006
写入 RFC3161 quorum-authenticated `claim_accepted_at`/`accepted_at`、`trusted_time_proof_digest`、
prior/new time high water、`lease_expires_at`、actual fence、owner generation与 heartbeat sequence。只有尚未
terminal 的 current generation持 current fence且在 store
认证 expiry 前可 append；fold只从最新 claim/heartbeat committed envelope导出 liveness，
不信任 host/client时钟、job presence或自报 deadline。`previous_accepted_at` 对 sequence 1 是 claim
envelope的 `claim_accepted_at`，之后是前一 heartbeat的 `accepted_at`。store 只接受 prior
expiry 前、距 `previous_accepted_at` 至少 `min_renewal_interval_seconds` 且严格延长 expiry 的 renewal，并以
`min(accepted_at+ttl_seconds, claim_accepted_at+max_generation_age_seconds)` 计算 expiry；
protocol scheduler按 `heartbeat_period_seconds` 请求，到 generation age cap 后禁止续租。
重复 heartbeat按同一 operation的
idempotency规则取回 receipt，异 digest/sequence冲突拒绝。takeover仅可在 trusted lower bound严格超过
store-auth expiry且 high-water CAS成功后用 higher-fence exact-frontier CAS：heartbeat先提交则 takeover predecessor/fence失败并
重读，takeover先提交则旧 generation/fence heartbeat失败；ack丢失仍按 signed receipt恢复。
heartbeat append失败时 owner保持 active直至 store expiry，不能因 worker/job消失推断过期。
