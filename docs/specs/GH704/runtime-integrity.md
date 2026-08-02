# Runtime Integrity Contract — 可信身份与持久化投影

## Status and authority

本文件是 GH-704 Recommended proposal（仍未批准）中 **trusted execution identity、cache/
eligibility binding、group commit、bounded reconciliation 与 derived global projection** 的唯一
规范性子协议。它不批准 product 的 H-001–H-020，不创建 implementation tasks。若
[`tech.md`](tech.md) 的摘要与本文件冲突，以本文件为准；修改任一身份字段、状态边或 I/O
上限公式时必须同时更新 product invariant、planned-changes manifest 与 focused proof。

## 1. One trusted execution identity

一次 L2 请求先构造 closed、versioned `TrustedExecutionIdentity`，再允许读取 semantic cache、
启动 provider 或写 semantic state：

```text
TrustedExecutionIdentity {
  canonical_project_identity,
  trusted_session_identity,
  approved_policy_digest,
  detector_and_model_identity,
  sidecar_artifact_identity,
  trusted_git_executable_identity,
  host_and_trigger_identity
}
  → execution_identity_digest
  → eligibility / cache / result / precision / audit
```

任一 required field 缺失、冲突、不可验证或 drift，必须在 cache/provider/metrics 前返回 closed
`unavailable/error`。payload、环境变量、PATH 与 model output 都是不可信声明，只能与 trusted
identity 比较，不能选择 identity 或 cache partition。

### 1.1 Trusted session identity

`trusted_session_identity` 只能来自 host/runtime ownership boundary：

- direct installed hook 使用 OS-authenticated parent process identity，加 runtime-owned、不可由
  inherited environment 选择的 session epoch/nonce；
- Codex app-server 使用 server-owned `SessionState` 中当前 thread session，并在 owning Rust
  process 内直接调用 semantic Core；typed capability 只在内存调用栈传递，不导出给 Bash
  hook、stdin JSON、env、cwd 或文件。child hook 只运行 legacy L1；payload/env 中的 session
  ID 只作 correlation echo，不能授权 child 运行 L2；
- host 没有可验证 session source 时，整个 L2 在 cache/provider/state 前返回
  `unavailable`；不得执行 uncached L2，也不得退回 inherited `VIBEGUARD_SESSION_ID`、
  per-invocation random value、空值、process cwd 或相邻 session partition。

`VIBEGUARD_SESSION_ID` 或 payload echo 若存在，必须 constant-time 比较 trusted value；不匹配
在任何 cache lookup、provider start、journal/status read 前 fail visible。相同 untrusted env
不能使两个 OS/app-server session 读取彼此 result。fixture 必须覆盖 env spoof、missing trusted
source、app-server echo conflict、session rotation、captured env/payload direct-process replay 与
same-input cross-session cache miss。

### 1.2 Trusted Git executable identity

project discovery 不得调用 `Command::new("git")`、`git` basename、shell、`env` 或 inherited
`PATH`。installer/release payload 必须给 runtime 一个 absolute Git executable capability，绑定：

```text
canonical absolute path + no-follow file identity + digest/signature + release receipt + platform
```

Unix 优先从 verified descriptor 以 `fexecve`/`execveat` 执行；平台不支持时只能在保持
deny-write/identity handle 的情况下 `execve` 已复核 absolute path。Windows 使用拒绝替换的
file handle 与 file ID，创建 process 后再次核对 executable image identity。执行环境从 closed
allowlist 重建，并删除 inherited `PATH`、`GIT_*`、`PWD`、`CDPATH`。identity 在 verify 与 exec
之间改变、receipt revoked、symlink/reparse/non-regular、hostile PATH fake Git 或 absolute file
被替换时全部 fail visible，且零 config/cache/provider/metrics。

调用 Git 前还必须 no-follow 打开 payload directory，并保持 directory handle/capability 到 root
acceptance 与 config open；Unix 以 retained fd/fchdir，Windows 以 retained handle + child cwd
volume/file-ID handshake 让 Git 从该对象启动，禁止只把 mutable pathname 交给 `-C`。Git 返回后
重开 root handle，做 stable-ID/component containment，并复核 path 仍指 retained payload。
rename/swap（含执行中换入再换回）、同 path 新建、A/B replacement 任一发生都 fail visible；
canonical pathname 字符串相同不能证明同一 project。

### 1.3 Sidecar artifact identity

`sidecar_artifact_identity` 是实际将被执行的 artifact，而不是 model alias 或 provider kind：

```text
artifact digest + exact version + target triple + protocol digest + payload manifest digest
+ signature/attestation + release receipt/revoke state
```

runtime 必须从 verified executable capability 取得并重新核对该 identity。approval/policy join、
request/result schema、cache key、precision/eval scope、event/status/doctor 与 release evidence 都
绑定同一 identity；sidecar byte、version、target、protocol、manifest、attestation 或 revoke
状态任一改变，eligibility evidence 与 cache 同时失效。禁止继续沿用旧 precision、旧 result、
同名 binary 或旧 executable handle。

## 2. One durable project state machine

current payload project 的 typed journal 是 GH-704 唯一 semantic authority；WAL 只负责 recovery。
`runtime_signal` coordinator 是唯一 group-state writer，consumer 只能写 group data/receipt。closed
graph 固定为：

```text
prepared → journaled → staged → commit_prepared → activating[bitmap]
  → projection_prepared → all_activated → projection_queued → done → projection_done
before all_activated: * → abort_prepared → aborted
```

每条 transition 含 previous digest；group digest 覆盖 schema、execution identity、event/pending、
decision、ordered stage receipts 与 expected activation receipts。三个 consumer 以
`(group,event,consumer,digest)` 幂等写不可见 staged/provisional version。`commit_prepared` 保存
完整 barrier body/digest 与 expected journal offset；partial activation 只按 exact key/digest
补齐，或在 durable `abort_prepared` 后回滚整个 group。barrier 后只允许向前恢复。

canonical project journal 另有一个所有 writer 共用的 deadline-bounded append lease。semantic
coordinator 的固定锁序是 project lock → canonical journal append lease，并从读取 authoritative
journal tail、写/fsync recovery WAL `prepared` 与 queue metadata，一直持有到 WAL `journaled`
transition durable；`hook_checks_common.rs`、`log_append.rs` 与 shell
`log_write.sh` 的普通 L1 writer 也必须在任何 append 前取得同一 lease，但不得取得 project lock。
因此 WAL 中的 expected offset 在事务中不会被 legacy event 占用；lease timeout 在任何 WAL/journal
write 前 fail visible，任一 writer 不得绕过 lease 或使用平行 lock。

任何 writer 在 materialize journal row **之前**必须 durable fsync
`prepared_intent {resource_token_id,exact_offset,row_digest,max_bytes}`。recovery 只在 exact offset bytes
与 digest/prefix proof 一致时 roll-forward manifest/root publish；partial 或 mismatch 必须保持 entitlement
并进入 `needs_repair`，或仅在 runtime 持有 exact-offset cleanup capability 时 truncate/tombstone，随后
file fsync、parent-directory fsync 与 materialized retirement receipt，才允许 release。prepared intent、
row write/fsync、publish、mismatch 与 cleanup 的完整 branch/fault DAG 只由
[`resource_ledger_model.json`](resource_ledger_model.json) 的 L1 selector 定义。

### W-02 integrity/retention machine authority

[`integrity_retention_model.json`](integrity_retention_model.json) 是 W-02 hypothesis、fix-attempt、fresh-failure、
reset 与 retention-tombstone evidence 的唯一 machine authority；它不重定义 ResourceLedger capacity。
每个 policy epoch 封存 finite、closed、digest-bound source/project membership，tuple templates 对 membership
确定性展开，materialized exact tuple set 必须与重算结果双射且有限完备，所以新增任意有限 runtime inventory
只生成新 epoch instance，不改 spec。每个 edge transition 都有关系化 binding，verifier 对每个 applicable
tuple 展开 `(edge_id,tuple_id,selector_id,transition_id)`，并逐 step 证明 crash-before/crash-after、逐非法
from-state 证明 no-write rejection；仅验证 ID 存在不算通过。W-02 L1 publication 的 exact partial order 是
`prepared_write → prepared_fsync → row_write → row_fsync → manifest_publish`；publish 直接依赖 prepared 或绕过
任一 write/fsync 必须拒绝。schema 与 stdlib validator 分别是
[`integrity_retention_model.schema.json`](integrity_retention_model.schema.json) 与
[`verify_integrity_retention_model.py`](verify_integrity_retention_model.py)，Markdown 不维护第二份 W-02 表。

### ResourceLedger：唯一容量与所有权状态机

[`resource_ledger_model.json`](resource_ledger_model.json) 是 closed 13-kind inventory、policy-epoch
source/project templates、finite exact tuples、tuple sets、same-root live→scratch pairs、root components/
physical domains/maxima、edge registry、root Cartesian cases、13 selectors 与 versioned boundary DAG 的唯一
machine authority；schema 与 verifier 分别是
[`resource_ledger_model.schema.json`](resource_ledger_model.schema.json) 和
[`verify_resource_ledger_model.py`](verify_resource_ledger_model.py)。每个 policy epoch 先封存 digest-bound
finite source/project inventory，再由 versioned templates 确定性展开 tuple、component、root 与 legal pair；
alpha/beta 只是 schema-valid example epoch，不是 production inventory 上限，新增有限 member 生成新 epoch
instance 而不修改 template contract。本 Markdown 只解释不变量，不再维护第二份 kind/partition/edge 表。
policy epoch 必须持久化 model 中的 exact tuple set 与六维 maxima；任何
placeholder、wildcard、pipe alternative、pseudo-N/A、boolean maximum 或 symbolic-all 都在 root CAS 前拒绝。
旧称 “allocator WAL” 仅是 model 中 fixed A/B checksummed metadata root components，不是 resource kind 或
可增长 append log。

每个 token 的 closed schema 至少是
`{resource_token_id,resource_kind,scope_id,quota_partition_id,entries,bytes,segments,segment_bytes,
per_source_quota,physical_bytes,
exact_object_key,owner_authority_id,owner_state_digest,reservation_bundle_id,
reservation_bundle_digest,generation,state,transition_nonce,predecessor_receipt_digest}`；不适用的
count 是显式 `0`，不得缺字段或使用 wildcard。唯一合法 ownership graph 是
`free → reserved → live`，以及从 `reserved|live` 开始的
`transfer_prepared → target_durable(target_receipt_digest) → transferred`，或
`retirement_pending → released(release_receipt_digest)`。`resource_kind` 从 token 创建到 release **不可变**；
transfer 只能在同 kind 中改变 owner/object authority，禁止 scratch→live 或任何未声明 kind edge。
materialized object 的 standalone retirement receipt 必须绑定 exact tombstone/unlink + parent-directory fsync proof；
compaction scratch 只能由下述 composite receipt 把 target authority 原子交给 retained live units 后 release；从未
materialize 的 cancel item 只能走显式 `reserved → retirement_pending {absent_object_proof,
committed_root_snapshot_digest} → released`，其中 snapshot 同时证明 exact object key 从未进入 live/target-
durable authority。两种 release edge 不可互换。`released` 才产生一次可再 admission 的 credit；publish/
CAS、逻辑删除、retention expiry 或“稍后 cleanup”都不能提前 credit。每个非 terminal token 在任一
committed root 恰有一个 owner；旧 owner、新 owner、staged file 或 receipt 不能同时计 live，也不能无人负责。

tuple `(resource_kind,scope_id,quota_partition_id)` 从 token 创建到 `released` 全寿命不可变；split、transfer、
retirement、rebind、off 与 compaction 都不能改写或跨 tuple 借用。每个 committed root、tuple 与维度 `d`
必须满足 `free[d]+reserved[d]+live[d]+transfer_or_retirement[d]=M[tuple,d]`，并同时满足
`sum(all tuple physical_bytes + allocator fixed-A/B metadata bytes) <= root_physical_max_bytes`；root physical
bound 不能因 partition 内守恒而省略。L1 `l1_floor` 与 adoption scratch A/B maxima 独立预留，任何 L2、live-admin、
GC 或相邻 source 都不得借用。每次 admission 原子创建 `reservation_bundle {reservation_bundle_id,ordered_items,
reservation_bundle_digest}`；ordered item 对 closed inventory 中每个已预留 kind 固定 exact token、owner、
entries/bytes/segments/quota 与 terminal policy。任何 cancel、abort、ack、off、rebind、discard、expiry、GC
或 compaction terminal root 必须提交 **terminal totality map**：bundle 中每项恰好一次标为
`released(release_receipt)`、`transferred(target_token,target_receipt)` 或
`retained(owner_state_digest,reason,next_edge)`；遗漏、重复、unknown kind、owner mismatch 或 receipt digest
不匹配使整个 root commit nonzero 拒绝。retry/lost response 只按 `(bundle,item,transition_nonce,receipt)`
返回既有结果，不再次 credit。由此强制五个全局不变量：conservation、single-owner、no-early-credit、
terminal completeness、idempotence；同时每个 capacity=1 合法 terminal edge 都必须有不借用 live capacity
的 forward path，保证 admission feasibility/liveness，而不是只证明“不超限”。

`compaction_exchange` 是上述唯一 ownership graph 的 composite edge，不是 graph 外 exception：

```text
{old_live:live, scratch:reserved} → optional_exact_split(parent:split_consumed_no_credit, children:live)
  → compaction_staging → target_durable → published_authority
  → ordered_old_retirement[i] → compaction_exchange_committed
  → {retained_live_units:live@new_key, reclaimed_live_units:released, scratch:released}
```

若一个 old-live token 同时含 retained/reclaimed dimensions，必须在 publish 前用 exact split receipt 把 parent
置为 `split_consumed_no_credit` 并拆成同 tuple、
同 predecessor 的 ordered units，逐维总和与 parent 完全相等；publish 后禁止再 split。final receipt 必须绑定
ordered before/after units 的全部 tuple、六维 counts、old/new exact keys、target-durable 与逐 old-unit tombstone/
directory-fsync proofs、split receipt、transaction nonce、root before/after digest 与 predecessor receipt。retain
all/partial/zero 都必须可表达；payload retained live units 在 zero-retain 时可以逐项为 `0`，但 fixed
empty-root manifest/checkpoint 是 model 声明的 positive physical-byte metadata components，仍须在同一 root
aggregate 中守恒。final composite receipt 必须分别覆盖 `payload_accounting` 与
`root_metadata_accounting`，不得要求整个 after root 六维全零。只有 after state 明确为
`released` 的 reclaimed units 和 scratch units 分别向原 live/scratch tuple 产生 credit；retarget、publish、proof 或
partial cleanup 均不产生 credit，lost response 只重放同一 receipt。

Review closure 必须落到 model 已声明的 exact tuple set、edge 与 selector，禁止用局部 prose exception、
新增 alias 或第二份 mapping table 绕开统一 reducer。verifier 必须展开并验证 project WAL、canonical
journal、derived log、admin adoption、success history、reservation terminal-totality 与 L1 materialized
recovery 的完整 coverage。

全部 activation receipts 匹配后，coordinator 在仍持有 project lock 时取得 deadline-bounded
global registration lease，先证明 live slot、per-source frozen-lag quota，以及 independently bounded
global administrative plane 的一条 closed-max entry + bytes 均有容量，再由一个 global metadata
root 原子发布 registry subgeneration 中的 unique live slot + reserved
`frozen_lag_token_id/exact_frozen_lag_identity/global_admin_entry_token_id/global_admin_reserved_bytes`，
并 fsync inert `projection_prepared {source_route,queue_key,bounded_derived_body,barrier_digest,
record_digest,eligibility_epoch,canonical_event_timestamp,retention_bucket,global_lag_offset,
query_scope_digest,source_root_deletion_anchor_digest}`。runtime-owned capability broker 同时保留 closed
`source_root_deletion_anchor {object_capability_id,platform_namespace_id,volume_or_mount_id,
object_file_id,object_generation,trusted_parent_capability,parent_identity,root_basename,
admission_mutation_generation,rename_cursor}`；它是 broker-owned identity-bearing directory handle/
object capability，不是 pathname 或 identity digest。该 anchor 不依赖 source root 路径存活，并随
registration/receipt lag pin 到 ack 或 terminalization。`global_lag_offset` 由该 initial root transition 分配；全部 query-scope fields
进入 registration/ref digest。任一 live、source 或 global admin entry/byte bound full 时零 durable
write。project→registration 是唯一锁序，
global worker 不反向持 registry lease 取得 project lock。随后才 append/fsync canonical barrier，
提交引用 slot 的 `projection_queued`，barrier + registration durable 后才 `done`。worker 在 exact
source route 证明 matching barrier 前保持 entry inert；并发 project publication、reserve/commit
crash 按 slot/generation 幂等恢复，full 时在 barrier 前 visible backpressure，禁止覆盖/丢 entry。

若 crash/abort 留下无 barrier registration，dispatcher 先释放 registry lease，再按 shared delivery
lease → source project lock 调用**同一 coordinator recovery**：receipts complete 则补 barrier/
queued，matching abort 则确认 durable `aborted`；coordinator 返回 digest-bound ready/abort receipt
后释放 project/delivery locks，dispatcher 才重新取得 registry lease，以 compare-and-swap 提交
ready，或在 abort tombstone/reclaim 的同一 root transition 释放 frozen-lag token。未知/损坏 entry fail visible 且禁止覆盖。
source route 若在 ready/abort receipt 前由 closed identity/owner/ACL proof 证明永久删除、替换或不可达，
dispatcher 必须用 admission 时已按两份 closed-max body bytes/time 预留的 frozen-lag/global-admin
entitlement，先把 identical `unreachable_registration_entry {source,event,expected_barrier,
projection_prepared_digest,queue_key,record_digest,eligibility_epoch,bounded_derived_body,
registration_id,state_root_id,route_identity_digest,source_root_deletion_anchor_digest,
canonical_event_timestamp,retention_bucket,global_lag_offset,query_scope_digest}`
分别写/fsync 到 independently checksummed per-source admin root 与 runtime-owned alternate admin vault；
全部 reconstruction fields/body 进入同一 entry digest，两份 root identity/generation 进入
`replica_set_digest`。两份都 durable 后，同一 global root CAS 才以
`unreachable_registration_lag_stub {source,event,expected_barrier,primary_root_id,
alternate_root_id,entry_digest,replica_set_digest,canonical_event_timestamp,retention_bucket,
global_lag_offset,query_scope_digest}` 替换 live registration 并释放 live slot，stub 不复制 body。
CAS 前 crash 保持 live entry；CAS 后任一 copy 独立匹配 entry/replica digest 即可恢复完整 exact
registration/reservation，但 rebind/retirement 前必须重建并 fsync 缺失 replica，两个 copy mismatch/
corrupt 才 `needs_repair`。transient/证据不全、任一 replica write/fsync 或 reserved double-copy bytes
不足都保留 live slot + visible lag。新 exact route bounded rebind 必须从 replica 恢复 exact
registration/reservation；否则该 ref 只可由下述 source-bound terminal discard proof 退休，不能 age-delete。
requested off 在 exclusive delivery lease → project lock 下先提交 durable `off_preparing {old_epoch,
requested_off_identity, requested_config_digest, config_mutation_fence_id, cursor}`：identity 是 existing config 的 no-follow file
identity+digest，或 `absent_file_identity {trusted_project_root_identity,canonical_parent_identity,
config_basename,start_absence_proof_digest}`；后者从 retained trusted parent capability 对 exact basename 做
`fstatat(..., NOFOLLOW)` 等价 lookup，只接受 `ENOENT`，不能从 ambient pathname 推断；symlink、`EACCES`/
unreadable 与其他错误不是 absence。fence 绑定同一 trusted parent directory handle/identity、runtime
requested-state writer lease 与 monotonic mutation generation；所有 runtime config writer 必须先取得它。
它立即禁止新 L2/shared admission，但还不是 effective
off。释放 project lock 后仍持 delivery lease，再取 global registration lease，将旧
epoch 的 pre-barrier 或 barrier-ready-but-unclaimed registrations 以 digest/epoch/state CAS
提交为 checksummed `off_frozen` administrative tombstone，并在同一 registry subgeneration/root
把 admission 时预留的 per-source token + global administrative entry/byte entitlement 转为 globally enumerable
`frozen_lag_ref {source,event,barrier,claim_digest,old_epoch,request_digest,
canonical_event_timestamp,retention_bucket,global_lag_offset,query_scope_digest}` 后回收 live slot。
`global_lag_offset` 是 registry root 在 initial admission 原子分配的 monotonic query ordinal，
不是 projection append `expected_offset`，不得预猜或 reserve-before-claim；其余 scope 字段来自
canonical project event/barrier 并进入 ref digest，使 bounded reader 无需 source scan 即可判定窗口成员。
该 bounded/retained plane 不计 live-work capacity，但由 committed root 中独立的
`global_admin_max_entries/global_admin_max_bytes` 与 per-source quota 同时约束；每个 ref/stub 必须
消费 admission 时的 exact entitlement，直到 rebind+ack retirement 或 source-bound terminal discard
原子释放。没有 matching entitlement、entry full 或 bytes full 时不得从 live plane handoff。aggregate
只从该 global admin index bounded 枚举，不得遍历 per-source roots。它不写/
删 source semantic journal；
canonical `projection_prepared`/activation receipts 保持冻结，re-enable 只能 bounded rebind
并重新发布，或由 approved maintenance drain 处理。worker 自身从不写 project journal。
因为该路径不同时持 project/registry locks，且 registration 仍只用 project→registry，
不形成 lock inversion；off project 也不会用 inert/ready orphan 永久耗尽
live registry capacity。ready worker 只能在 shared delivery lease 下先用 registry state CAS
提交 offset-independent `claim_prepared {claim_id, exact body/digest, reservation_seed_digest}`，
释放 registry lease 后才由 sequencer 分配 offset，并原子创建携带 offset/tail 的 full
`reservation_digest`，且同一 allocator/root commit 留下 durable `claim_binding {claim_id,
seed_digest,reservation_id,full_digest,state}`；它在 reservation body/outbox reclaim 后仍可 bounded
discover，直到 registry CAS acknowledgement。随后重取 registry lease CAS 为 `reservation_bound {reservation_id,
reservation_digest}`，再在 claimed tombstone/reclaim 的同一 root transition acknowledgement 并释放 binding 与未使用的
registration frozen-lag/global-admin entitlement；reservation 自身已在 allocator commit 原子取得
独立 quarantine/global-admin entitlement，不能出现无 isolation capacity 的 handoff。从不预猜 offset/reserve-before-claim，也不同时
持 registry/sequencer leases。crash 留下 claim-prepared 时先以 claim ID/seed/body 查 stable root 的
binding/reservation/outbox：matching applied/outbox binding 只补 registry acknowledgement，in-flight
binding 继续原 reservation；只有三者均 absent，普通 active recovery 在 matching
effective enabled identity/epoch 下才从 claim body 幂等创建 exact
reservation，禁止转为 off-frozen；只有 matching old epoch/request digest 的 durable `off_preparing`
才可把 absent-reservation claim CAS 为带 frozen-lag ref 的 `off_frozen`，并保留可 bounded rebind 的
canonical `projection_prepared`/barrier reference。matching reservation 必须先把 full digest CAS
回 claim 再正常前进；seed/body/full digest mismatch 一律 `needs_repair`。off-preparing 才必须先完成
第 4 节 allocator/outbox/receipt drain 再回收 slot。
project-local canonical decision、project-local consumer/precision/Learn 与 per-run project status
只在 `all_activated` barrier 后可见；它们不依赖 global mirror。允许读取 bounded project state 的
enforcement/history reader 必须再 join matching durable `projection_done`；global status/aggregate/
observe 与任何 global enforcement/history reader 不得扫描 project，只能 join success-history plane 的 `project_acknowledged`。缺各自第二层
authority 统一为 `projection_lag` + empty/zero-use；marker 已 fsync 但 global ack 未 CAS 时 global
reader 仍为 lag。project coordinator 最后在同一 lock 下消费 durable receipt slot 并提交
`projection_done`。

## 3. Bounded recovery admission

schema/policy 必须给每个 legal record/body 一个 closed maximum。实现从这些 maxima 计算：

```text
max_atomic_recovery_bytes(schema_version) = max over every legal recovery transition T of (
  fixed open/stat/header/index accounting for T
  + sum(maximum encoded length of every record T must read)
  + sum(maximum encoded length of every WAL transition, journal/queue record,
        marker, metadata generation, consumer record and receipt T must write/fsync)
)
max_atomic_recovery_ms(schema_version, platform, storage_class) = max over T of max(
  approved worst-case normal completion duration for T,
  max over each legal blocking fault point F of (
    approved worst-case prefix before F + operation_deadline(F)
    + cancel/escalate/terminate/join-or-reap(F)
    + durable-boundary/no-background-write verification(F)
  )
)
```

这是“一次可恢复原子状态边”的 worst-case **总 I/O** admission，不是挑一个最大输出、平均值，
也不能只计算 payload。例如同一 edge 必须同时写 WAL transition 与 queue metadata 时，两者
连同该 edge 的其它 required reads/writes 都进入求和，再与其它 edge 的总和取最大值。
policy 只有在 `reconcile_io_max_bytes >= max_atomic_recovery_bytes`、`reconcile_batch_max > 0`，
且 `reconcile_deadline_ms >= max_atomic_recovery_ms + fixed_scheduling_guard_ms` 时有效；此
time floor 已包含 bounded cancellation teardown，guard 只覆盖 admission/scheduling。任一
`floor - 1` 在 provider/cache/journal 前拒绝。处理每个 oldest-first work item 前同时证明
remaining byte budget 与 remaining deadline 分别足以完成该 item 的 exact worst-case
atomic edge，其中 time 为 exact edge normal-or-fault-teardown maximum + scheduling guard；任一
不足则在开始前停止并报告 backlog，零新写入。实际 open/stat/read/write/fsync/
marker/receipt 与 cancel/escalate/join/reap/verify 全部计入 byte/time counters。supported I/O backend
必须对每个 blocking operation 强制 deadline/cancellation；timeout 后只能留在既定的
crash-safe WAL boundary，并且 hook 返回前必须证明 operation 已取消/终止、无后台续写。
无法证明 bounded I/O 的 backend 在开始 edge 前返回 `unavailable`，禁止侥幸启动。

queue metadata 只保留两个 checksummed fixed-size generations、committed cursors、pending count
与 oldest timestamp；两个 A/B generation 都是每个 project root 的 positive fixed metadata component，
在 WAL/journal live 与 scratch 满载的 root aggregate/Cartesian proof 中持续计费，不得从 payload maxima
之外隐式分配。project recovery WAL 自身必须是 checksummed segmented store，并由 closed
positive `project_recovery_wal_max_entries`、`project_recovery_wal_max_bytes`、
`project_recovery_wal_max_segments` 与 `project_recovery_wal_segment_max_bytes` 同时约束。每个新
semantic attempt 必须在 cache lookup/provider/validator/reducer 前原子创建
`semantic_attempt_bundle {attempt_id,input_envelope_digest,project_wal_entitlement_id,
max_transition_bytes,reservation_bundle_digest}`，预留最大 legal `prepared`、`journaled` 与 recovery
transitions；任一 bound full 时 cache/provider call count 均为零、零 WAL/journal append并 visible
backpressure。cache hit/miss、provider error/timeout/cancel、validator/reducer reject 与 provider 后 crash
都是 bundle edge：WAL object 尚未 materialize 时用 committed-root absence proof 进入
`reserved→retirement_pending→released`；已经 materialize 时只能 durable abort/forward recovery，且每条
terminal root 必须对 attempt bundle 全量 release/transfer/retain。terminal group 只有在 canonical row、全部 consumer/
activation receipts、barrier、projection queue/marker 与仍可能引用 recovery record 的 reconcile cursor
都已转移到独立 durable authority 后才 eligible；pending/staged/abort/rebind/repair、open cursor、reader
snapshot 与 expected-offset proof 都必须 pin 原 segment。

project WAL、derived log 与 canonical journal GC/rotation 共用一个 compaction protocol：

1. 先把 matching scratch token 从其 fixed partition 的 `free` 变为 `reserved`，其 closed-max 六维 counts 足以
   容纳完整新 generation + manifest/checkpoint；从同一 root snapshot 生成 ordered old-live retirement units；
   mixed retained/reclaimed token 必须此时 exact split 并 fsync split receipt，所有 old live units 仍全额计费；
2. 写 staged generation，file fsync 后写/fsync manifest，记录 `target_durable` receipt；publish CAS 只把
   reader authority 指向该 receipt，并进入 `retirement_pending`，不得释放 old live 或 scratch credit；
3. 对 ordered old objects 写 exact tombstone/unlink，并取得各 parent directory fsync proof；任一 crash
   保持 `old live + new scratch` 双方计费，按 root-selected nonce roll-forward，不回退或覆盖；
4. 只有全部 tombstone/dir-fsync proofs durable 后，final ledger CAS 才提交 composite
   `compaction_exchange`：ordered retained live units 保持 tuple 并 retarget exact new key；ordered reclaimed live
   units 进入 `released`；scratch token 保持 scratch tuple 并进入 `released`。receipt 必须绑定 split、before/after
   六维 counts/keys/states、target receipt、ordered proofs、nonce、root before/after 与 predecessor；retain
   all/partial/zero 和连续 compaction 均走此 edge，lost response/replay 只返回同一 receipt。只有显式
   `released` units 向各自原 partition 产生 credit，禁止 scratch credit 进入 live partition。

project compaction 在 project lock 下按此协议使用独立 fixed A/B `project_wal_scratch`，其 staged body 是
`project_wal_checkpoint {last_terminal_group_digest,journal_tail,queue_generation,
committed_reconcile_cursor,ordered_pinned_group_roots,oldest_retained_offset}` + compacted segments/manifest；
final CAS 才推进 `project_wal_reclaim_watermark`。publish 前旧 WAL 权威；publish 后新 generation 是 reader
authority但旧 physical capacity 继续计费至 final receipt。crash、scratch full、pin mismatch、watermark
regression 或 malformed segment 保持 `needs_repair/backpressure`，不得 truncate、age-delete、扫描 journal
rebuild 或重复 credit。startup/hook 只读 fixed header，再按 cursor oldest-first 处理；不得完整
反序列化 index、扫描 journal、其它 project 或 HOME。测试必须覆盖每种 state edge 的最大 record、
WAL entry/byte/segment full、checkpoint/compaction 每个 crash boundary、pinned-group retention/release、
byte/time `floor - 1` rejection、exact floors 完成一条最大 transition、剩余任一 budget 不足时零写入、
slow/hung injected I/O 在 exact fault+teardown floor 内取消/终止/回收并只留 recoverable durable
boundary，teardown `floor - 1` 零 edge 写入，以及 malformed length/offset/digest。

canonical journal append/rotation 也不是 free filesystem side effect。每个普通 L1 writer 在 shared append
lease 内、任何 append 前，必须从不可被 L2/GC 借用的 `canonical_journal_live` L1 floor/partition 取得 exact
entry/byte/segment entitlement；append+fsync+manifest receipt 后才 `live`，never-materialized cancel 走 absent-
object release edge。full 时只允许 deadline-bounded backpressure/compaction；仍无 entitlement 时保留已算出的
L1 decision但返回 typed persistence unavailable，零 append且绝不越界。`gc-logs.sh` 由 journal manifest root
取得 fixed A/B `canonical_journal_scratch`，保留所有 project-WAL expected-offset、barrier/projection watermark
与 reader pins，并执行 common protocol + `compaction_exchange`。只在 I/O 最终成功且 pins 最终 unpin 的
fair schedule 下承诺 finite progress；永久 pin、disk/scratch failure 必须 fail visible并保持 bounded old state，
不得声称 liveness、移动 pinned row或超额 append。crash/replay 不得出现双 authority/early credit/scan rebuild。
policy epoch 必须证明 L1 floor + journal live/scratch 与 allocator fixed A/B root bytes 可同时落盘。

## 4. Serialized global offset append

global projection 使用一个跨 project/key/shard 的 deadline-bound append sequencer。sequencer
lease 通过 nonblocking stale-safe lock/CAS 取得，并且 **从分配 offset 一直持有到该 offset 的
append/fsync 与 durable applied/tail commit 完成**：

1. 先从 allocator fixed A/B metadata root oldest-first 恢复最早 committed reservation；存在未 applied reservation
   时不准分配或 append 更晚 offset；
2. 先证明 bounded derived-record append log、per-source keyed receipt-slot ledger、live completed index、shared live outbox、per-source route-quarantine、global
   administrative index，以及 independently bounded、按 source quota 隔离的 success-history plane
   各有一条 closed-max entry + bytes 容量；每个
   quarantine token 还必须从初始 admission 起独占一个 closed-max inactive replacement generation
   （固定 A/B buffer，仍只计一个 logical entry），再在单一
   checksummed global metadata root generation 中原子提交 allocator reservation、derived-log、completed-index、
   outbox entitlement、quarantine、global-admin 与 success-history reserved tokens
   `{reservation_id, identity_key, expected_offset, global_offset, canonical_event_timestamp,
   retention_bucket, query_scope_digest, barrier_digest, bounded_derived_body,
   record_digest, source_project_identity, receipt_route, registration_id, state_root_id,
   route_identity_digest, source_root_deletion_anchor_digest, bounded_receipt_body, new_tail,
   receipt_slot_entitlement_id,receipt_slot_reserved_entries,receipt_slot_reserved_bytes,exact_receipt_key,
   derived_log_entitlement_id,derived_log_reserved_bytes,target_segment_id,
   reservation_seed_digest, reservation_digest, completed_index_token_id,
   exact_completed_ref_identity, outbox_entitlement_id, exact_outbox_identity,
   quarantine_token_id,global_admin_entitlement_id,global_admin_reserved_bytes,
   success_history_entitlement_id,success_history_reserved_bytes}`；`global_offset = expected_offset`，
   timestamp/bucket/query scope 与 locator/deletion-anchor digest 必须从 live registration 原样复制；full reservation digest 绑定实际
   allocated offset/new tail 以及全部 canonical query-scope fields。global aggregate/window reader 只能从
   root-selected reservation、outbox 或 lag/success ref 读取这些 digest-bound fields，任一缺失或与
   registration 不匹配都 `needs_repair`，不得用 append position、wall clock 或 pathname 猜测窗口；任一 capacity full 时在任何 durable write 前
   visible backpressure；
3. 在同一 lease 下为 exact key durable 写 `projection_prepared`，只在 expected offset 和 allocator
   root 选定的 `target_segment_id` append/fsync derived record，并把 exact entitlement 原子转换为
   segment live bytes；
4. `receipt_route` 必须是预先注册在 runtime-owned closed project-state directory 的 exact
   capability，绑定 state-root ID、directory/file identity 与 content-addressed `receipt_key =
   H(source project, event, barrier, global record digest)`；每个 key 是独立 create-if-absent slot，
   不能使用共享 project-receipt append offset，也不能要求扫描 project/HOME。runtime-owned、按 source
   隔离的 slot ledger 同时有 global/per-source entry+byte maxima；reservation 必须在 offset 前原子预留
   exact one-entry + closed-max body bytes，full 时零 offset/reservation/write；
5. 仍在同一 lease 下把 `projection_applied`、allocator committed tail 与 checksummed
   `receipt_prepared {route,bounded_receipt_body,source_barrier_digest,record_digest,registration_id,
   state_root_id,route_identity_digest,canonical_event_timestamp,retention_bucket,global_offset,
   query_scope_digest,receipt_slot_entitlement_id,exact_receipt_key}` outbox intent
   原子提交到同一 metadata generation，并把 reservation 的 exact `outbox_entitlement_id`
   原子转换为该 live intent；只有该 generation durable 后才释放 lease、回收 reservation body。
   conversion 前 entitlement 仍计 shared outbox capacity，rebind/admission 不得借用；crash recovery
   只能完成 matching conversion，只有 reservation 进入带 committed-root absence/tombstone proof 的 durable cancellation 时才原子释放；
   cancellation/abort 必须提交该 `reservation_bundle_digest` 的 terminal totality map：slot 不存在时，
   同一 root transition 一次释放未消费的 receipt-slot、completed-index、outbox、quarantine/frozen-lag、
   success-history、global-admin 与 derived-log reservation token，并为每项保存 release receipt；已经
   append/live 或 slot durable 的项不得假释放，必须转入 matching recovery/retirement owner，带 exact
   target receipt 后标为 `transferred`。任一 item 缺失、重复或仍为 ownerless reserved 都拒绝整个
   cancel/abort commit。slot 已 durable 时先进入下述 retirement protocol，禁止留下 reservation 已占
   offset 却没有可提交 outbox 的状态。非 terminal 路径上的 quarantine token 与 success-history
   entitlement 跨 receipt-delivered、quarantine、admin 与 rebind states 原样携带，直到
   `project_acknowledged` 分别释放/转换，或 source-bound terminal discard 按同一 totality map 释放；
6. `.vibeguard.json` 只是 requested state；runtime-owned eligibility registry 才是 effective
   state，并绑定 observed config identity/digest + epoch。projector/receipt/source worker 处理
   intent 前取 deadline-bounded shared delivery lease，以 no-follow 重开 config 并比较 digest。
   若 drift，必须零 source write 释放 shared lease，再取 writer-fair exclusive lease。
   requested off 进入第 2 节 durable `off_preparing`；其 cursor 以 policy-bound batch/byte/time
   oldest-first 多 pass：(a) freeze/reclaim pre-barrier/ready-unclaimed；(b) 对 claim-prepared
   执行 absent-reservation freeze 或 matching reservation recovery；(c) 将该 source 的每个 applied/
   receipt-outbox intent 在 exclusive lease 下写 exact keyed slot，完成 file fsync + atomic
   create-if-absent + route-directory fsync。该 drain 在 effective off 前完成，不写 project journal/
   `projection_done`，也绝不能创建/保留 shared completed-index ref。每次 keyed slot durable 后，先以
   reservation-backed quarantine token 在 independently checksummed per-source administrative/quarantine
   root 写/fsync `off_receipt_lag_ref {source,event,barrier,projection_receipt_digest,canonical_event_timestamp,
   retention_bucket,global_offset,query_scope_digest,registration_id,state_root_id,route_identity_digest,
   source_root_deletion_anchor_digest,receipt_slot_entitlement_id,exact_receipt_key,slot_digest,
   old_epoch,request_digest}`；完整 slot retirement identity、route locator 与它们的 digest 必须从
   `receipt_prepared`/durable slot 原样复制，并跨 admin adoption/rebind/terminalization 保留；随后单一 global root CAS 同时发布 bounded lag stub、提交
   `receipt_applied`、reclaim outbox并释放 completed-index token。admin root/stub 任一失败则保持 outbox
   pending/error 且不得 effective off。只有 registry、reservation、live outbox 与 live completed index 中该 source
   所有 unacknowledged refs 均为零（每个 ref 在 admin handoff 前必须保留 capacity token），才在仍持
   exclusive delivery lease、且已释放全部 global leases 后取得 project lock，并重验 saved
   requested-off identity：present variant no-follow 重开并匹配 file identity+digest；absent variant 必须仍持
   matching `config_mutation_fence_id`，从同一 trusted parent capability 再做 exact no-follow lookup，只接受
   `ENOENT`，并匹配 project root、parent identity、fence generation 与 start proof。该 final lookup 是
   absence-off 的 linearization point：它与 durable `off_commit_fenced {absence_proof_digest,
   config_mutation_fence_id,mutation_generation}` 属于同一 project-lock transaction；在释放 exclusive
   delivery/fence 前必须再次 no-follow lookup 并读取 mutation generation。若 file/symlink 出现、generation
   改变、parent replacement、permission/error 或 identity drift，必须在 state 对任何 worker 可用前原子
   rollback 为 `enable_rebind`/pending；final lookup 后才完成的外部 create 线性化为新的 requested-state
   change，且所有 worker 写入前仍重验同一 file/fence generation。project lock 单独不构成 filesystem
   fence，禁止把 first ENOENT→commit 间窗口当作已关闭。
   retention-owned `project_acknowledged` success 已原子转入独立 success-history plane、无 live capacity token
   且不参与 zero predicate。若已变回 enabled，
   原子转为 durable `enable_rebind {new_identity,digest,cursor}`，保留 keyed slots/admin refs 并
   bounded rebind 全部 off-frozen/off-receipt canonical refs，完成前禁止新 L2；若是另一 off digest/identity，
   必须在任何 per-ref mutation 前提交 `off_supersede_pending {old_admin_set_digest,new_epoch,
   new_request_digest,selected_mode,mode_policy_digest,transaction_id,stage_cursor,
   adoption_manifest_entitlement_id,adoption_manifest_capacity_receipt}`。policy epoch 必须为同一 immutable
   `global_admin` kind 预配不可被 live admin 借用的 `quota_partition_id=adoption_scratch` fixed A/B slots；
   每个 slot 的 closed bytes 足以容纳全局可 admission 的最大 exact ordered old set，因此 live capacity=1
   且已满时仍可 adoption。选择 `adopt_all` 前在同一 global-admin root snapshot 枚举完整 set，并从 inactive
   scratch slot 原子 reserve token；capacity `floor - 1`、set drift 或无法证明全量时不得持久化 mode。
   只有 preflight receipt durable 后
   `selected_mode` 才可写为 `adopt_all`；`terminal_discard_all` 也必须在首个 ref mutation 前写入。
   `selected_mode` 只能是这两者，进入 digest 后不可改变，每个 recovery pass/ref transition/completion
   record 都必须匹配，否则 `needs_repair`。`adopt_all` 使用 journaled atomic generation：bounded passes 只在
   每个 authoritative per-source primary/alternate admin root 写/fsync inert
   `adopt_prepared {transaction_id,old_entry_digest,new_request_digest,new_entry_digest}`，不改变旧 ref 权威性；
   全部 exact old-admin-set entries staged 后，写/fsync ordered adoption manifest，再由一个 global-root CAS
   发布 `admin_adoption_committed {transaction_id,old_admin_set_digest,adoption_manifest_digest,
   new_request_digest}`。该 generation 是全 set 唯一可见切换点：commit 前全部旧 request，commit 后 global
   overlay 对全部 entries 原子解释为 new request，禁止 partial/mixed adoption。commit 后 bounded cleanup
   按 journal cursor roll-forward 重写/repoint per-source entries/stubs并保留 token/query scope/recovery locator/
   source-root deletion anchor；
   crash 只能继续同一 transaction，禁止 rollback 或换 mode。全部 root matching 后才提交
   `admin_adoption_complete {transaction_id,old_admin_set_digest,adoption_manifest_digest}`；随后 manifest
   slot 才按 materialized retirement edge tombstone+dir-fsync并释放同 kind scratch-partition token；
   `terminal_discard_all` 则按已持久化 mode 为每项验证 source-bound terminal proof并最终证明旧
   ref/stub/token 为零。两模式不可串联，successful adoption 不再要求 terminal proof；任一项 missing/
   mismatch 或 config invalid/unreadable 都保持 pending/error；preflight 后出现 manifest overflow 属于
   committed-root corruption，禁止用永久 pending 掩盖，必须 fail visible 且保留旧 set/entitlement。
   stale request 不得提交 effective off。任一 cap/deadline/route 失败保持 `opt_out_pending/error` + counts/
   oldest age，禁止新 L2 但不伪称 off，后续 bounded pass 续传；因而 effective off
   永不占 shared live registry/outbox/completed-index capacity。effective-off cleanup 只按 admin root
   oldest-first cursor；retention watermark/query-scope expiry 仅使 ref eligible，绝不构成 deletion proof。
   每个未 ack ref 必须先由 re-enable/approved maintenance 重取 completed/outbox capacity并完成 matching
   rebind→`project_acknowledged`→`retirement_pending`，或由 approved maintenance 在 exclusive delivery
   lease → project lock 下写/fsync source-bound `projection_terminal_discarded {event,barrier,ref_digest,
   query_scope_digest,policy_digest}` 并返回 digest acknowledgement；随后 global CAS 验证该 ack，才可
   原子 tombstone ref + delete stub + release token。无 source terminal proof 时永久保留 ref/locator/token；
   re-enable 则先以同样 bounds 重取 completed/outbox capacity再 rebind。crash 保留 matching ref/stub 并
   向前恢复；任一 missing/mismatch/timeout 保持 visible admin lag，禁止 scan 或假 cleanup。每个 pass 只外层持 exclusive delivery；
   对 source root 本身已永久删除、因而不可能再取得该 root 的 project lock 的 exact 特例，approved
   maintenance 必须改走 runtime-owned deletion terminalization：在 exclusive delivery lease 下，使用
   registration pin 的 identity-bearing `source_root_deletion_anchor` 取得 broker deletion-proof lease。
   old basename 的 repeated no-follow `ENOENT` 只表示 route missing，绝不是 deletion proof；broker 必须同时
   查询 retained object handle/capability 与 platform rename/delete journal。若 object identity/generation 仍活着
   或出现 matching rename/move event，必须提交 `source_root_relocated_pending {object_capability_id,
   old_route_digest,rename_event_id,new_route_capability_digest}`，保留 ref/token 并只接受 exact new parent/name
   capability 的 bounded rebind，不得扫描 filesystem 或 terminalize。只有 closed platform proof 明确表明
   同一 filesystem object 已 unlink/delete-complete、object capability 不再可 reopen、且没有未消费 matching
   rename event，才可在 runtime vault 写/fsync `source_root_deleted_terminal_tombstone
   {registration_id,state_root_id,route_identity_digest,object_capability_id,platform_namespace_id,
   volume_or_mount_id,object_file_id,object_generation,event,barrier,ref_digest,
   query_scope_digest,deletion_proof_digest,policy_digest}`。随后单一 global root CAS 必须同时验证 tombstone、
   locator/ref/token digests 与 broker deletion attestation，删除 matching admin ref/stub，并一次释放 frozen/global-admin/quarantine/
   success-history/receipt-slot entitlement 中该 ref 实际持有的集合；object-deletion tombstone 同时是 exact
   keyed slot 已随 root 消失的 retired proof；CAS 前 crash 保留 ref+tombstone 并只向前重试，
   CAS 后 tombstone 才可 bounded GC，重复 recovery 不得二次释放。rename/move、root 仍可由 object handle
   访问、root 重建、replacement、ACL/lookup error 或 mutation generation 变化均保持 visible lag；普通仍存活 source 的 terminal discard 继续要求
   exclusive delivery lease → project lock，禁止把 deletion proof 泛化成绕过 source ownership。
   project lock 在任一 global lease 前释放，registry 在 sequencer/receipt I/O 前释放，
   每次 durable handoff 后才取下一 lease，不同时持 project/registry/sequencer。re-enable 只能由 source coordinator bounded
   rebind/consume durable slots，或由另行批准的 maintenance drain 处理；
7. receipt worker 从 outbox oldest-first 打开 exact route，以 no-follow temp write + file fsync +
   atomic create-if-absent 写 keyed slot，再 fsync route directory。此后它只提交 global
   `receipt_applied`/reclaim，并在同一 root generation 将 completed-index token 转为
   `receipt_delivered {source,event,barrier,projection_receipt_digest,registration_id,state_root_id,
   route_identity_digest,canonical_event_timestamp,retention_bucket,global_offset,query_scope_digest,
   receipt_slot_entitlement_id,exact_receipt_key,global_admin_entitlement_id}` lag ref；
   locator 与 canonical query metadata 都必须从 exact `receipt_prepared` 原样复制并进入 delivered-ref
   digest；该 ref 必须继续绑定并计入预留的 quarantine token，直到
   `project_acknowledged` 或 atomic quarantine/admin handoff，并继续保留 A/B buffer；不得在 receipt
   delivery 时释放。worker 不得写 project journal/
   `projection_done`。slot 已存在且 digest 相同
   也必须证明 directory durability；不同 digest 才 `needs_repair`。project coordinator/approved
   maintenance route 必须按 shared delivery lease → project lock 的固定顺序取得 matching epoch，
   并持有两者直到 slot 验证与 `projection_done` fsync；随后返回 digest-bound marker acknowledgement，
   释放 project/delivery locks，再由 global root CAS 把 same entry 转为
   `project_acknowledged {source,event,barrier,projection_receipt_digest,canonical_event_timestamp,
   retention_bucket,global_offset,query_scope_digest,marker_digest,ack_epoch,registration_id,state_root_id,
   route_identity_digest,source_root_deletion_anchor_digest,receipt_slot_entitlement_id,exact_receipt_key,
   slot_digest,global_admin_release_receipt_id,receipt_slot_retirement_nonce,
   receipt_slot_retirement_state_digest}`，完整保留并 digest-bind
   receipt-delivered 的 canonical query metadata，并在同一 root generation 把 reservation-backed
   `success_history_entitlement_id` 转成 independently checksummed success-history ref、删除 live
   completed entry/释放其 token，同时释放仍未消费的 quarantine token；若 allocator
   `global_admin_entitlement_id` 仍为 reserved/unconsumed，同一 CAS 必须转为 `released_on_ack` 并保存
   digest-bound release receipt，若已 `consumed_by_admin` 则保持到 matching stub retirement。只有 history plane 中该 state
   是 aggregate success；crash 在 marker/
   ack 间时 globally enumerable `receipt_delivered` 仍为 lag；即使 outbox 已 reclaim/source 未启动，
   dispatcher 仍用 ref 内的 `registration_id/state_root_id/route_identity_digest` 在 runtime-owned directory
   精确解析 matching state-root/route capability；directory entry 与 deletion anchor 必须 pin 到 ref ack、
   quarantine handoff 或 runtime-owned deletion terminalization 后才可回收，因此 dormant source 无需
   outbox 或 project/HOME/global-log scan 也能调用同一 coordinator 验证/补 marker后补 ack。
   registration missing/drift/inaccessible 若已满足 closed permanent proof，必须在同一 global root
   把 exact `receipt_delivered` ref 原子移入 retained token 的 `quarantine_ack_pending` entry/stub、
   释放 completed-index capacity并发布 lag stub，不依赖已回收 outbox；transient failure 保持 ref/token，
   禁止猜 pathname。ack request/response 丢失时 recovery 只读 root-selected ack/release receipt：matching
   receipt 幂等返回 success，reserved 状态补同一 CAS，released/consumed identity mismatch 则
   `needs_repair`，禁止重复 credit。同一 ack CAS 必须原子发布下述完整
   `receipt_slot_retirement_pending` 并把其 digest 写入 acknowledgement；pending durable 前不得丢弃
   acknowledgement 中任何 slot/locator field。只有 global ack CAS 成功才释放未使用 token。off 同样按 exclusive lease →
   project lock，因而会等待 worker 与 marker writer。多个 keys 可任意 delivery order，仍只有一个 group writer。

keyed receipt slot 的 entitlement 在 slot file + route-directory fsync 后从 reserved 转为 live，并跨 outbox
reclaim、`receipt_delivered`、off/admin/quarantine handoff 原样携带，不能在 delivery 时释放。只有 matching
`project_acknowledged`，或已把完整 receipt body/digest + recovery locator durable 转移到 terminal/admin
authority 后，global root 才可发布 `receipt_slot_retirement_pending {entitlement_id,registration_id,
state_root_id,route_identity_digest,source_root_deletion_anchor_digest,exact_receipt_key,slot_digest,
final_state_digest,retirement_nonce}`。随后 dispatcher
按 exact capability、shared delivery lease → project lock 做 no-follow identity/digest check，unlink exact slot、
fsync route directory，并写/fsync `receipt_slot_retired {entitlement_id,exact_receipt_key,slot_digest,
retirement_nonce,directory_generation}`；最终 global CAS 验证 proof 后删除 pending state并释放 one entry + exact
bytes。verified source-object deletion tombstone 可作为 slot-gone proof；rename/move/inaccessible 不能，必须继续
pin entitlement 并 bounded rebind。pending 前 crash 保留 live slot/token，pending→unlink crash 以 exact absent
proof 补 retired，retired→final CAS crash 只重放同一 nonce，lost final acknowledgement 从 root receipt 恢复；
任何 mismatch/permission/error 保持 visible per-source backpressure，禁止扫描、age-delete 或 double release。

derived-record append log 是 allocator subgeneration 内的独立 capacity ledger + checksummed segmented
store；closed configuration 同时限制 global live entries、live bytes、segment bytes/count 与单条最大
record bytes。reservation admission 必须在 offset/new tail 分配前为一条 closed-max record 原子预留
`derived_log_entitlement_id/derived_log_reserved_bytes/target_segment_id`；任一 bound 满时零 offset、零
reservation、零 append，并 visible backpressure。reservation-before-append crash 保留 entitlement；matching
append 消费 exact reservation bytes，append-before-applied/tail crash 仍由同一 entitlement 和 record digest
幂等前进；只有带 committed-root exact-record absence proof 的 durable reservation cancellation 可释放，禁止让 earliest reservation
因磁盘满永久卡住全部 later offsets。

每个 sealed segment 记录 `{segment_id,first_offset,last_offset,entry_count,live_bytes,segment_digest}`；allocator
root 的 segment manifest、active tail 与 `derived_log_reclaim_watermark` 都进入 allocator generation/digest。
记录至少 pin 到 matching reservation 已 applied、receipt intent 已 durable，且其唯一 recovery proof 已转入
live completed/admin/quarantine 或 success-history ref；任一 reservation/outbox/receipt-delivered/admin/rebind
locator 仍引用该 record 时禁止 reclaim。retention/compaction 只处理 `last_offset < min(query_retention_watermark,
derived_log_reclaim_watermark)` 且没有 reader snapshot pin、lag/recovery ref 的完整 sealed segment。allocator
必须维护独立于 live log entry/byte/segment bounds 的 fixed A/B `derived_log_scratch`；开始前原子取得
`derived_log_compaction_entitlement_id`，其 reserved bytes/segments 足以容纳最大 legal compacted segment、
retained-proof manifest 与 metadata generation。live log 已达到任一 maximum 时该 entitlement 仍必须可用；
scratch unavailable/full 时保持旧 manifest并只 backpressure 新 reservation，不得先释放 live capacity。
derived compaction 严格执行上述 common protocol：publish CAS 只 repoint manifest/reader authority，old live
capacity 与 new scratch 同时计费；old segment exact tombstone + directory fsync 全部 durable 后，final ledger
CAS 才以 composite `compaction_exchange` retarget retained derived-live units、release reclaimed live 与
scratch units、推进 watermark并提交 full before/after receipt。CAS 前 crash 忽略未 publish
stage；publish 后只 roll-forward tombstone/final CAS，禁止回退、partial segment delete、age-delete lag proof
或重用 bytes 两次。malformed/missing segment、proof pin、watermark regression、live-full + scratch-full、
scratch `floor - 1` 与 compaction 每个 crash boundary
均 `needs_repair/projection_lag` + empty global data，只 backpressure 新 reservation，不删除 canonical project
journal；recovery 只按 root-selected segment/offset/digest，永不扫描 global/project/HOME log。

allocator、outbox、live completed index 与 success-history plane 各有独立 subgeneration，但所有跨 index transition 只由上述
单一 global metadata root generation 原子发布；因此 receipt delivery 同时发布 lag ref、
`receipt_applied` 与 outbox reclaim，ref 未 durable 时 reclaim 不可见；project ack + history transfer
是后续单一 CAS。history plane 有独立 global entry/byte maxima 与 per-source quota；reservation admission
预留 entitlement，因此 ack 不会在 marker durable 后因 history full 卡住。retained success 只计 history
quota，永不计 live completed capacity，off project 的 history 不得消耗其它 source partition。
recovery 只接受
root 指向且 reservation/token ID + exact ref identity 全匹配的 pair：matching pair 幂等前进；
旧 root 外的 token-only/reservation-only torn copy 回退到前一 committed root；matching claim binding
保留到 registry acknowledgement 后才 GC。committed root 内
任一缺失/错配则 `needs_repair`，禁止 append、reclaim 或重用 token。matching completed ref 可幂等
补 receipt-applied/reclaim；completed token 转为 ref 后不再重复计 capacity，但 quarantine token 在
`receipt_delivered` 期间继续计其预留 capacity，直到 ack 释放或转为 quarantine entry。每个 commit 前后 crash、full 与 mismatch
都必须证明无 token leak、无 reservation stall、无 completed-proof gap。

route open 的 timeout、single permission error 等仍以有界 retry/age 留在 outbox。permanent 的 closed
platform table 只接受删除/替换 proof，或在 policy-bound attempts/horizon 前后 route identity、
owner/ACL digest 与 worker credential capability 均稳定且每次返回同一 non-transient access-denied，
并由 source coordinator 证明无 valid writer capability；缺任一 evidence 仍 transient。
permanent 时先写/fsync independently checksummed per-source quarantine root 的 staged exact
route/body/barrier/ref/rebind entry。若该 source root 在 publication 前 delete/replace/permission-denied，
必须使用 reservation 时预留、与 receipt route 分离的 runtime-owned alternate quarantine vault：
vault 内仍按 source 独立 checksum/partition，写/fsync同一 exact entry，且不读取/创建 broken source
directory。每个 token 的 primary/alternate slot 都包含 admission 时物理预留的 fixed A/B generations；
inactive generation 不增加 logical quota，但其 closed-max bytes/time 必须进入 recovery floor。primary/alternate staged copies 都 inert；global stub 的 `root_kind/root_id/entry_digest`
才选择唯一权威 copy。crash 在 primary fsync 后可写 identical alternate stage并选择 alternate；primary
恢复后其 nonchosen stage 永不枚举/计 logical capacity，按 stub authority bounded tombstone/reclaim。
只有任一 candidate entry durable 后，
global root 才 atomically reclaim live outbox、释放 global
completed-index token、消费 quarantine token并发布 bounded `quarantine_lag_stub {source,event,
barrier,root_kind,root_id,entry_digest,canonical_event_timestamp,retention_bucket,global_offset,
query_scope_digest}`。scope 字段必须从 exact intent/ref 复制并进入 stub digest；两者都失败是 runtime quarantine storage unavailable，保持
outbox pending/error，不伪称隔离；alternate 可用时 broken source 永不占 shared live slot。root 前 crash 忽略/回收 staged orphan且 outbox 仍 live；root
后 stub 保证 lag 全局可枚举。shared allocator/outbox validation 不读取 per-source root；其后损坏只把
该 source 标记 `needs_repair`，不能阻止其他 source 的 root advance。
同一协议也处理 outbox 已 reclaim 后的 `receipt_delivered`：ack 前 route 达 closed permanent proof，或
该 ref 到达 retention 边界时，用仍保留的 token 将 exact ref/registration/marker recovery identity 写入
`quarantine_ack_pending` candidate，随后一个 global root 原子发布 stub、删除 completed ref并释放
completed capacity；candidate/stub 失败则原 ref 保持 pinned/visible，绝不丢失恢复入口。
source coordinator 注册 new exact route/epoch 后只能 bounded rebind quarantined intent；必须先在
一个 global root transition 中同时取得 completed-index token 与 shared live-outbox slot，任一不足则
保持 quarantine/stub 不变并只标记该 source `rebind_backpressure`。双容量均成功时仍保留原
quarantine token/entry/stub，并将 stub CAS 为 `rebind_inflight {new_route_digest,outbox_id}` 后恢复
live outbox/keyed-slot/receipt-delivered/project-ack transaction；所有 rebind/retirement states 必须原样
携带 timestamp/bucket/global offset/query-scope metadata。若 new route 再次 proven permanent，
先在同一 token 已预留的 inactive A/B generation 写/fsync replacement，再由 global root 原子 repoint
stub 后释放刚取得的 completed/outbox capacity；旧 generation 随后 bounded tombstone，closed one-entry
root 也始终有 handoff 空间，禁止 stranded live slot或第二 token。
project ack 成功后，global root 必须先把 stub CAS 为
`retirement_pending {root_kind,root_id,old_entry_digest,retirement_nonce,final_ack_digest,
expected_retired_generation,quarantine_token_id,global_admin_entitlement_id,
expected_global_admin_release_receipt_id}`；随后才在
stub 指定的 authoritative primary/alternate root 写/fsync
`retired {old_entry_digest,retirement_nonce,final_ack_digest}` proof 并原子 reclaim entry/free-list capacity。
retired proof 在最终 global CAS 前不可 GC；recovery 以 retirement-pending nonce/digest 接受 entry 已
reclaim 的 matching retired root generation，而不把它误判为 corruption。最后 global root 验证 proof，
删除 stub并在同一 CAS 释放 quarantine token + consumed allocator global-admin entry/bytes，提交 matching
global-admin release receipt；若 final response 丢失，recovery 以 root receipt 幂等确认，禁止第二次 credit。
旧 entry 不可再枚举/replay。未经 rebind 不得伪称 completed。token 缺失/错配/corrupt
均 `needs_repair` 且只 backpressure 对应 source；测试覆盖 transient/permanent 分类、delete/replace、
quarantine permission/delete/replace、primary-fsync→alternate-publication crash、nonchosen orphan cleanup、
post-commit per-source corruption、cross-source isolation、completed+outbox atomic reacquire/floor-minus-one、
rebound-route A/B replacement（含 one-entry-full/floor-minus-one）、retirement-pending 三阶段 crash、
receipt-delivered-route-quarantine、source-off-completed-capacity-handoff、off-terminal-proof、
off-request-admin-adoption、pre-barrier-unreachable-isolation、quarantine-lag-query-scope、
project-marker/global-ack crash（含 outbox reclaimed + dormant source + exact route resolution）、normal reuse、
full/mismatch 与 rebind。frozen ref bounded rebind 时同一 root 将 ref 还原为 reserved token + live
registration；正常 claim 再释放，禁止泄漏或重复分配。

因此 reservation A 未 applied 时，reservation B 不能 append；不会出现 later offset 先落盘、
earlier offset 留洞。crash recovery 只查 earliest reservation、exact key/offset/digest：缺 record
则补 append，匹配 record 则补 marker/tail/outbox intent/receipt slot，不匹配则 `needs_repair`。crash 在
applied 与 tail/outbox generation 之间时 reservation 仍 committed，可幂等重建；generation
之后即使 source project 永不再运行，outbox 也独立携带 exact route/body。temporary route failure
保持 pending lag，proved-permanent failure 进入上述 quarantine；requested off 则保持 off-preparing，
不得提交 effective off 后留 live intent。outbox 无法为下一最大 receipt admission 时在新 reservation
前 backpressure。禁止扫描 global/project/HOME log、跳洞、重新分配 offset 或按 per-key 并发
append。allocator/index/outbox full/corrupt/timeout 保持 `projection_lag` + 空 global data，不能
反写 canonical project decision。

### Aggregate snapshot proof

summary/health 等 multi-event/project reader 只能从 bounded registry/allocator/outbox、global
administrative index、live completed index 与 success-history plane 构造 v2 proof，禁止扫描 log。
success-history 以独立 generation-covered global entry/byte maximum + per-source quota 保留 H-014
批准的 query/retention window 内全部 acknowledged refs；只有其中 `project_acknowledged` 是 successful
ref，live completed index 的 `receipt_delivered` 必须进入 lag refs。GC 只能处理已越过 retained
window/watermark 且全部为 `project_acknowledged` 的完整 bucket，并必须在一个 success-history root CAS 中
原子删除 ordered refs/bucket、把每个 `success_history` token 的 entries/bytes/per-source quota 置为
`released`、提交 bundle totality map 与 digest-bound `success_history_gc_release_receipt`。CAS 前 refs 与全部
quota 仍 live；CAS 后 lost response/replay 只返回同一 receipt；缺 token、quota、ref 或 owner mismatch 时
整个 bucket 保留并 fail visible，禁止先删 ref、后补 credit。未 ack ref 到期时
必须先用 retained quarantine token 按上述原子 `quarantine_ack_pending` handoff 转移 exact route/
registration/state-root identity 与 query-scope metadata；handoff 未 durable 则 pin 原 bucket/ref/token
并计 capacity/backpressure，绝不能 age-delete 唯一 recovery locator。过旧 query、retention gap、capacity/
freshness overflow 必须 unavailable + empty，禁止回退扫描。reader 先读取 committed global
metadata root generation + 其引用的六个 checksummed subgenerations +
allocator tail/watermark，再按 query identity/window 有界枚举全部 in-scope state，生成稳定
ordered `barrier_refs` 与 ordered `lag_refs`（包括 live/frozen/unreachable registry、off-receipt admin、reservation、outbox 与
route-quarantine lag）；每个 frozen/admin ref 的 timestamp/bucket/global lag 或 projection offset/query-scope
metadata 必须 digest-bound 并用于 window inclusion，缺失或冲突即 proof unavailable；live
registration 必须使用 initial admission 保存的 timestamp/bucket/global lag offset/query scope，
successful `project_acknowledged` 必须使用 receipt-delivered 继承的 timestamp/bucket/global projection
offset/query scope。successful refs 只来自 success-history plane，最后重读
root + registry/allocator/outbox/completed/admin/history subgenerations/tail。前后任一变化必须在同一 deadline 内 bounded
retry；重试仍 drift 则 `projection_lag/unavailable` + 空 semantic aggregate。

`barrier_set_digest = H(schema, query_identity, ordered barrier_refs, ordered lag_refs,
root_generation, registry_generation, allocator_generation/tail, outbox_generation,
completed_index_generation, admin_index_generation, success_history_generation)`；`projection_watermark` 携带
同一组 generations/tail，两者不得分别取样。任一 lag ref、ready/outbox state 遗漏/
重排，digest 或 generation mismatch，proof 超 closed maximum，或无法证明全量集合时，
必须 fail visible 并保持空数据；禁止 partial/synced aggregate。测试覆盖 omitted/
reordered lag ref、ready-registry lag、outbox lag、completed retention/overflow 与 scan-generation drift。

## 5. Ownership and proof closure

实际 app-server session container/lifecycle router `vibeguard-runtime/src/codex_app_server.rs`、
capability semantics owner `vibeguard-runtime/src/codex_app_server_core.rs` 与 PostToolUse/PostEdit
delivery owner `vibeguard-runtime/src/hook_orchestrator_post_edit.rs` 必须进入 affected-file manifest、
focused test ownership 与 U-22 critical inventory。wrapper 的 `SharedState` 持有并在 client/server
message routes 间串行交还 `SessionState`；core 生成不可由 client thread ID/env 重现的 server-owned
capability，并在 app-server Rust process 内调用 semantic Core，覆盖 restart/rotation/spoof/
captured-value replay；delivery owner 的
payload→trusted session/root handoff、cache/provider ordering、error path 和 short-circuit
condition 达到 100% line + branch/condition coverage。
planned U-22 manifest 必须让每个 critical file 恰出现一次并携带非空 exact `owner_suites`；
gate 双向核对 manifest ↔ Product-to-Test mapping/Cargo exact name 或 shell selector，missing/empty/
unknown/duplicate、zero-match、rename drift 与未被 critical file 引用的 suite 均须 nonzero。

production Learn owner `vibeguard-runtime/src/hook_orchestrator_learn.rs` 也必须进入 complete manifest、
U-22 inventory 与 exact focused ownership。其 `recent_log_text`/`session_metrics::run_text` error 不得
`unwrap_or_default` 成 no-data：必须输出 typed source/error identity 或 `projection_lag/unavailable`，
保持 `finalized=false`、零 suggestion/candidate/provider write；只有真实空 history 才是 blank。

Codex `applyPatchApproval` 是 pre-application approval event，不能触发 semantic post-edit。
`codex_app_server_strategies.rs` 与 `codex_app_server_file_changes.rs` 必须把 legacy child-Bash L1
post-hook request 与 in-process semantic completion gate 分离：approval、decline、failed/
in-progress apply 全部在 semantic cache/provider/WAL 前零活动；只有 app-server-owned
completion event 绑定已应用的 exact before/after identity 后在 owning process 内执行一次。
协议没有 trusted completion callback 时，该 trigger 的 L2 必须 `unavailable`，禁止轮询猜测。
`SessionState` 达到 thread cap 时不得淘汰任何仍有 pending patch/completion 的 thread；若全部
slot pending，必须在接受新 patch 前返回 typed bounded backpressure。completion 查不到 retained
pending identity 时必须 fail visible，不能静默 `None`；fixture 覆盖 cap+1、乱序 completion、
retry/duplicate，并证明每个已接受 patch 恰好一次完成或具名 unavailable。

最小证明矩阵还必须包含：

- hostile PATH fake Git、Git/payload-directory replacement、revoke 与 ancestry/config no-follow cases；
- inherited session spoof、captured child value replay、app-server trusted-session conflict/rotation
  与 cross-session cache isolation；
- sidecar byte/version/target/protocol/manifest/attestation/revoke 的 eligibility + cache + evidence
  invalidation；
- approval/decline/failed apply 零 semantic activity，thread-cap backpressure 与 completion exactly once；
- every group edge、concurrent registration/orphan recover+tombstone、off-epoch defer、receipt crash；
- every maximum record 的 recovery floor、dormant-project receipt recovery，以及 concurrent
  projects/shards 严格 offset append order。
