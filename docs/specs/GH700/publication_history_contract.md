# GH700 Publication History Contract

本文件是 `product.md` B-017/B-018 与 `tech.md` publication machine 的规范性组成部分，
隔离完整 publication ownership、mutation-secret、append-only history、trust/fold 与
owner-liveness 概念边界。引用方不得复制、改名或局部覆盖这里的字段、枚举、secret boundary
或 fail-closed 语义；冲突时本文件的 exact machine-facing identifiers为唯一真源。

## Concrete durable authority

唯一 production backend 是 `publication_authority_sqlite_v1`，由计划中的
`vibeguard-runtime/src/publication_authority/{mod.rs,store.rs,broker.rs,recovery.rs}` 与
`vibeguard-runtime/src/main.rs` 的 `publication-authority serve|recover` 命令实现；publication
client、workflow、benchmark code 均不得另建 store、直接打开数据库或以内存/mock/checkout/
Actions artifact降级。environment-protected service以单 active replica运行在独立于 runner、
checkout、Release artifact与 owner lifecycle 的 durable volume；signed deployment manifest的
closed planned **schemas/publication_authority_deployment.schema.json** 固定
`{authority_id,backend,publication_store_path,publication_store_lock_path,volume_identity,kms_key_id,
retention_policy_digest,trust_bundle_digest}`；backend必须 exact 为 `publication_authority_sqlite_v1`，
store path是唯一 absolute canonical SQLite file且必须位于该 volume，禁止默认路径、相对路径或
临时目录。KMS key/ciphertext retention policy同样由 manifest钉住，credential只从 environment
secret provider取得。

service启动先取得同 manifest钉住的 process lock，验证 volume支持 kernel lock与 durable
`fsync`，再以 SQLite WAL、`journal_mode=WAL`、`synchronous=FULL`、foreign keys及
`BEGIN IMMEDIATE`运行。history head/leaf、operation/rotation/slot unique indexes、owner/fence、
capsule ciphertext metadata、broker outbox/delivery/send-once audit与 completed receipt须在一个
事务中验证和提交；任何 lock/busy timeout、WAL/fsync/checkpoint、disk-full或 KMS error都使
authority non-ready并 fail closed，不得返回成功 receipt。首次 database/WAL/lock 创建与 migration
commit后还须 fsync file及 parent directory；禁止 destructive migration、truncate或 silent rebuild。

唯一 bootstrap owner 是 SP700-T3 的 publication-authority store/deployment single writer，经计划中的
**.github/workflows/publication-authority-deploy.yml** 调用
**scripts/ci/bootstrap_publication_authority.py**：只可在不存在 database时写入 independently signed
length-zero genesis/trust bundle并签发 bootstrap receipt，已存在时必须 byte/digest-match或拒绝。
唯一 crash/restore authority 是同一 protected service的 `recover` 命令，在 exclusive process lock下
replay WAL、校验 `integrity_check`、全量重放 signed history/unique indexes/outbox/capsule metadata并
重新签发 exact-head recovery receipt；snapshot+WAL restore还须 governance threshold批准、单调
restore epoch及 KMS可解封证明。T10只消费认证 API，不拥有 backend或 recovery authority。

端到端证明必须在真实 durable-volume fixture对每个 transaction boundary注入 kill/power-loss、并发
claim/slot/delivery、WAL/checkpoint失败、disk-full、KMS unavailable、runner/checkout删除、owner
terminal与 signed snapshot+WAL restore；重启后只允许 exact committed state或未提交状态，绝无
双 owner、双 send、丢 leaf/index/capsule/outbox或 unsigned frontier。

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
`release_mutation_planned(mutation_kind,transition_slot)`，绑定 repo/tag identity/owner generation/
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
pre-state且无 extra后才 `compensated`。不可逆或不可证明的 publish/update/delete、权限/分页/
audit不全、rate-limit/5xx、tag move/delete/recreate、peel/source/ruleset/bypass drift均进入
`release_mutation_recovery_blocked`并保留 owner；takeover只能引用旧 plan并 fresh authorize。
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
是 exact current owner，或是在 store-auth expiry 后由 exact-frontier takeover record建立的
同 candidate successor，并验证 current fence。公开的 fence/generation/capsule ID本身都不是
credential，不能授权读取/解封。解封后重验 digest；restart发生在
claim commit后、draft create前时必须复用该 nonce；capsule缺失、越权、密文/key-version/
digest不符或 KMS不可用均进入 `draft_recovery_blocked`，不得生成新 nonce、重写 claim或创建
第二个 draft。
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
epoch 与 certificate-chain digest；leaf rotation 由 trusted root 授权并绑定 old/new key、
activation frontier 与递增 epoch，新 key 不得提前、旧 key 不得延后签名。root bundle
rotation 必须 old+new threshold共同签名，绑定 previous bundle digest、activation frontier
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
current epoch/exact predecessor并 append。publication suffix抢先时以相同 rotation ID/payload/
approval、new predecessor/op重规划；rotation由 pre-state trust验证，activation固定为其 successor
frontier，之后只接受 new trust。governance suffix只改变 trust epoch/state；active publication
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
frontier防 ABA。record schema 是 versioned closed union，唯一 top-level discriminator 是
`record_kind`；`kind`/`type`/`record_type`/alias/unknown均拒绝。frontier字段唯一为
`{repo_node_id,history_length,history_root,full_prefix_digest}`，canonical digest使用
`jcs-rfc8785-v1`。union覆盖 exact owner/draft/prepared/generated-PR/receipt/intent/commit/takeover、
`{release_mutation_recovery_blocked,draft_recovery_blocked,decurrent_pr_recovery_blocked,
rollback_recovery_blocked,marker_recovery_blocked,nonvalid_row_recovery_blocked,
invalidation_recovery_blocked,release_recovery_blocked}`、`recovered_publication`与 terminal；非法
transition/fence/owner、缺失、截断、fork、过期 fence或 checkout anchor均 fail closed。
`post_invalidation_zero` 的 invalidation suffix fold是 exact closed union：terminal non-valid
publication、current prepared owner及已验签的 phase-neutral
`{trust_leaf_rotated,trust_root_rotated,trust_key_revoked}`。governance record必须经独立 governance
domain/fence/threshold及上述 trust cutover验证，且 fold后 current publication仍 absent、publication
owner/phase/liveness不变；任何其它 record、current restoration或其它 owner均拒绝。

## Owner liveness

长时间等待人工 review 以 durable `owner_heartbeat` renewal record续活：immutable
intent只绑定 stable owner generation、单调 heartbeat sequence/transition slot与
`liveness_policy_digest`，不得绑定 client timestamp/deadline或 authorization fence；
`owner_claimed` 与 `owner_heartbeat` 的 store-signed committed envelope均按获批 H-006
写入 server-authenticated `claim_accepted_at`/`accepted_at`、
`lease_expires_at`、actual fence、owner generation与 heartbeat sequence。只有尚未
terminal 的 current generation持 current fence且在 store
认证 expiry 前可 append；fold只从最新 claim/heartbeat committed envelope导出 liveness，
不信任客户端时钟、job presence或自报 deadline。`previous_accepted_at` 对 sequence 1 是 claim
envelope的 `claim_accepted_at`，之后是前一 heartbeat的 `accepted_at`。store 只接受 prior
expiry 前、距 `previous_accepted_at` 至少 `min_renewal_interval_seconds` 且严格延长 expiry 的 renewal，并以
`min(accepted_at+ttl_seconds, claim_accepted_at+max_generation_age_seconds)` 计算 expiry；
protocol scheduler按 `heartbeat_period_seconds` 请求，到 generation age cap 后禁止续租。
重复 heartbeat按同一 operation的
idempotency规则取回 receipt，异 digest/sequence冲突拒绝。takeover仅可在 store-auth expiry
后用 higher-fence exact-frontier CAS：heartbeat先提交则 takeover predecessor/fence失败并
重读，takeover先提交则旧 generation/fence heartbeat失败；ack丢失仍按 signed receipt恢复。
heartbeat append失败时 owner保持 active直至 store expiry，不能因 worker/job消失推断过期。
