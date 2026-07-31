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

全部 activation receipts 匹配后，coordinator 在仍持有 project lock 时取得 deadline-bounded
global registration lease，先证明 live slot 与 per-source frozen-lag quota 均有容量，再由一个
global metadata root 原子发布 registry subgeneration 中的 unique live slot + reserved
`frozen_lag_token_id/exact_frozen_lag_identity`，并 fsync inert `projection_prepared {source_route,
queue_key, bounded_derived_body, barrier_digest, record_digest, eligibility_epoch}`；任一 full 时零
durable write。project→registration 是唯一锁序，
global worker 不反向持 registry lease 取得 project lock。随后才 append/fsync canonical barrier，
提交引用 slot 的 `projection_queued`，barrier + registration durable 后才 `done`。worker 在 exact
source route 证明 matching barrier 前保持 entry inert；并发 project publication、reserve/commit
crash 按 slot/generation 幂等恢复，full 时在 barrier 前 visible backpressure，禁止覆盖/丢 entry。

若 crash/abort 留下无 barrier registration，dispatcher 先释放 registry lease，再按 shared delivery
lease → source project lock 调用**同一 coordinator recovery**：receipts complete 则补 barrier/
queued，matching abort 则确认 durable `aborted`；coordinator 返回 digest-bound ready/abort receipt
后释放 project/delivery locks，dispatcher 才重新取得 registry lease，以 compare-and-swap 提交
ready，或在 abort tombstone/reclaim 的同一 root transition 释放 frozen-lag token。未知/损坏 entry fail visible 且禁止覆盖；requested
off 在 exclusive delivery lease → project lock 下先提交 durable `off_preparing {old_epoch,
requested_config_identity, requested_config_digest, cursor}`：它立即禁止新 L2/shared admission，但还不是 effective
off。释放 project lock 后仍持 delivery lease，再取 global registration lease，将旧
epoch 的 pre-barrier 或 barrier-ready-but-unclaimed registrations 以 digest/epoch/state CAS
提交为 checksummed `off_frozen` administrative tombstone，并在同一 registry subgeneration/root
把 admission 时预留的 per-source administrative token 转为 globally enumerable
`frozen_lag_ref {source,event,barrier,claim_digest,old_epoch,request_digest}` 后回收 live slot。
该 bounded/retained plane 不计 live-work capacity，按 source quota 隔离且供 aggregate 枚举。它不写/
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
frozen-lag token。从不预猜 offset/reserve-before-claim，也不同时
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
只在 `all_activated` barrier 后可见；project-local enforcement/history 可再 join matching durable
`projection_done`。所有 global aggregate/status/enforcement/history reader 只能从 bounded global
indexes join `project_acknowledged`；该 state 是唯一 global success。缺 ack 统一为
`projection_lag` + empty/zero-use，不得把 barrier 或 project-local marker 当成 global success。

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
与 oldest timestamp。startup/hook 只读 fixed header，再按 cursor oldest-first 处理；不得完整
反序列化 index、扫描 journal、其它 project 或 HOME。测试必须覆盖每种 state edge 的最大
record、byte/time `floor - 1` rejection、exact floors 完成一条最大 transition、剩余任一
budget 不足时零写入、slow/hung injected I/O 在 exact fault+teardown floor 内取消/
终止/回收并只留 recoverable durable boundary，teardown `floor - 1` 零 edge 写入，
以及 malformed length/offset/digest。

## 4. Serialized global offset append

global projection 使用一个跨 project/key/shard 的 deadline-bound append sequencer。sequencer
lease 通过 nonblocking stale-safe lock/CAS 取得，并且 **从分配 offset 一直持有到该 offset 的
append/fsync 与 durable applied/tail commit 完成**：

1. 先从 allocator WAL oldest-first 恢复最早 committed reservation；存在未 applied reservation
   时不准分配或 append 更晚 offset；
2. 先证明 completed index 与 per-source route-quarantine 各有一条 closed-max entry，再在单一
   checksummed global metadata root generation 中原子提交 allocator reservation、completed-index
   与 quarantine reserved tokens
   `{reservation_id, identity_key, expected_offset, barrier_digest, bounded_derived_body,
   record_digest, source_project_identity, receipt_route, bounded_receipt_body, new_tail,
   reservation_seed_digest, reservation_digest, completed_index_token_id,
   exact_completed_ref_identity, quarantine_token_id}`；full reservation digest 绑定实际 allocated
   offset/new tail；任一 capacity full 时在任何 durable write 前
   visible backpressure；
3. 在同一 lease 下为 exact key durable 写 `projection_prepared`，只在 expected offset
   append/fsync derived record；
4. `receipt_route` 必须是预先注册在 runtime-owned closed project-state directory 的 exact
   capability，绑定 state-root ID、directory/file identity 与 content-addressed `receipt_key =
   H(source project, event, barrier, global record digest)`；每个 key 是独立 create-if-absent slot，
   不能使用共享 project-receipt append offset，也不能要求扫描 project/HOME；
5. 仍在同一 lease 下把 `projection_applied`、allocator committed tail 与 checksummed
   `receipt_prepared {route, bounded_receipt_body, source barrier/record digest}` outbox intent
   原子提交到同一 metadata generation；只有该 generation durable 后才释放 lease、回收
   reservation body；reserved token 独立保留 exact identity 直到 receipt completion；
6. `.vibeguard.json` 只是 requested state；runtime-owned eligibility registry 才是 effective
   state，并绑定 observed config identity/digest + epoch。projector/receipt/source worker 处理
   intent 前取 deadline-bounded shared delivery lease，以 no-follow 重开 config 并比较 digest。
   若 drift，必须零 source write 释放 shared lease，再取 writer-fair exclusive lease。
   requested off 进入第 2 节 durable `off_preparing`；其 cursor 以 policy-bound batch/byte/time
   oldest-first 多 pass：(a) freeze/reclaim pre-barrier/ready-unclaimed；(b) 对 claim-prepared
   执行 absent-reservation freeze 或 matching reservation recovery；(c) 将该 source 的每个 applied/
   receipt-outbox intent 在 exclusive lease 下写 exact keyed slot，完成 file fsync + atomic
   create-if-absent + route-directory fsync，再提交 global `receipt_applied`/reclaim。该 drain
   在 effective off 前完成，不写 project journal/`projection_done`；每次 keyed slot durable 后，
   必须在同一 metadata generation 将 token 转为 `completed_projection_index {state=receipt_delivered,
   source_project_digest,event_id,barrier_digest,projection_receipt_digest,global_offset,retention_bucket,
   receipt_route_registration_id,state_root_id,route_identity_digest}` 并提交；三项 route identity 来自
   runtime-owned closed project-state directory registration，进入 exact ref/root digest，不能只保留 pathname
   `receipt_applied`/reclaim。只有 registry、reservation 与 live outbox 中该 source 均为零，
   才在仍持 exclusive delivery lease 时 no-follow 重开 config，复核 current file identity+digest
   与 saved request 完全相等，再取 project lock 提交 effective off epoch。若已变回 enabled，
   原子转为 durable `enable_rebind {new_identity,digest,cursor}`，保留 keyed slots/completed refs 并
   bounded rebind 全部 off-frozen canonical refs，完成前禁止新 L2；若是另一 off digest/identity，
   以新 epoch/request 从 cursor zero 重启 off-preparing；invalid/unreadable 则保持 pending/error。
   stale request 不得提交 effective off。任一 cap/deadline/route 失败保持 `opt_out_pending/error` + counts/
   oldest age，禁止新 L2 但不伪称 off，后续 bounded pass 续传；因而 effective off
   永不占 shared live registry/outbox capacity。每个 pass 只外层持 exclusive delivery；
   project lock 在任一 global lease 前释放，registry 在 sequencer/receipt I/O 前释放，
   每次 durable handoff 后才取下一 lease，不同时持 project/registry/sequencer。re-enable 只能由 source coordinator bounded
   rebind/consume durable slots，或由另行批准的 maintenance drain 处理；
7. receipt worker 从 outbox oldest-first 打开 exact route，以 no-follow temp write + file fsync +
   atomic create-if-absent 写 keyed slot，再 fsync route directory。此后它只提交 global
   `receipt_applied`/reclaim，并在同一 root generation 将 completed-index token 转为上述
   `receipt_delivered` lag ref；该 ref 必须继续绑定并计入预留的 quarantine token，直到
   `project_acknowledged`，不得在 receipt delivery 时释放。worker 不得写 project journal/
   `projection_done`。slot 已存在且 digest 相同
   也必须证明 directory durability；不同 digest 才 `needs_repair`。project coordinator/approved
   maintenance route 必须按 shared delivery lease → project lock 的固定顺序取得 matching epoch，
   并持有两者直到 slot 验证与 `projection_done` fsync；随后返回 digest-bound marker acknowledgement，
   释放 project/delivery locks，再由 global root CAS 把 same entry 转为
   `project_acknowledged {marker_digest,ack_epoch}`。只有该 state 是 aggregate success；crash 在 marker/
   ack 间时 globally enumerable `receipt_delivered` 仍为 lag；即使 outbox 已 reclaim/source 未启动，
   dispatcher 仍用 retained registration ID 在 runtime-owned directory 精确解析 matching state-root/
   route capability，再调用同一 coordinator 验证/补 marker后补 ack，无需扫描 project/HOME/global log。
   route 若 proven permanent inaccessible，则同一 global root CAS 必须把 `receipt_delivered` exact ref
   原子移入已预留 token 的 quarantine、释放 completed-index capacity并发布 lag stub，不依赖已回收 outbox；
   transient failure 保持该 ref 与 token。只有 global ack CAS 成功才释放未使用 token。off 同样按 exclusive lease →
   project lock，因而会等待 worker 与 marker writer。多个 keys 可任意 delivery order，仍只有一个 group writer。

allocator、outbox 与 completed index 各有独立 subgeneration，但所有跨 index transition 只由上述
单一 global metadata root generation 原子发布；因此 receipt delivery 同时发布 lag ref、
`receipt_applied` 与 outbox reclaim，ref 未 durable 时 reclaim 不可见；project ack 是后续 CAS。
recovery 只接受
root 指向且 reservation/token ID + exact ref identity 全匹配的 pair：matching pair 幂等前进；
旧 root 外的 token-only/reservation-only torn copy 回退到前一 committed root；matching claim binding
保留到 registry acknowledgement 后才 GC。committed root 内
任一缺失/错配则 `needs_repair`，禁止 append、reclaim 或重用 token。matching completed ref 可幂等
补 receipt-applied/reclaim；其 quarantine token 继续计 capacity 到 global ack 或原子隔离 handoff。每个 commit 前后 crash、full 与 mismatch
都必须证明无 token leak、无 reservation stall、无 completed-proof gap。

route open 的 timeout、single permission error 等仍以有界 retry/age 留在 outbox。permanent 的 closed
platform table 只接受删除/替换 proof，或在 policy-bound attempts/horizon 前后 route identity、
owner/ACL digest 与 worker credential capability 均稳定且每次返回同一 non-transient access-denied，
并由 source coordinator 证明无 valid writer capability；缺任一 evidence 仍 transient。
permanent 时先写/fsync independently checksummed per-source quarantine root 的 staged exact
route/body/barrier/ref/rebind entry。若该 source root 在 publication 前 delete/replace/permission-denied，
必须使用 reservation 时预留、与 receipt route 分离的 runtime-owned alternate quarantine vault：
vault 内仍按 source 独立 checksum/partition，写/fsync同一 exact entry，且不读取/创建 broken source
directory。primary/alternate staged copies 都 inert；global stub 的 `root_kind/root_id/entry_digest`
才选择唯一权威 copy。crash 在 primary fsync 后可写 identical alternate stage并选择 alternate；primary
恢复后其 nonchosen stage 永不枚举/计 logical capacity，按 stub authority bounded tombstone/reclaim。
只有任一 candidate entry durable 后，
global root 才 atomically reclaim live outbox、释放 global
completed-index token、消费 quarantine token并发布 bounded `quarantine_lag_stub {source,event,
barrier,root_kind,root_id,entry_digest}`。两者都失败是 runtime quarantine storage unavailable，保持
outbox pending/error，不伪称隔离；alternate 可用时 broken source 永不占 shared live slot。root 前 crash 忽略/回收 staged orphan且 outbox 仍 live；root
后 stub 保证 lag 全局可枚举。shared allocator/outbox validation 不读取 per-source root；其后损坏只把
该 source 标记 `needs_repair`，不能阻止其他 source 的 root advance。
source coordinator 注册 new exact route/epoch 后只能 bounded rebind quarantined intent；必须先在
一个 global root transition 中同时取得 completed-index token 与 shared live-outbox slot，任一不足则
保持 quarantine/stub 不变并只标记该 source `rebind_backpressure`。双容量均成功时仍保留原
quarantine token/entry/stub，并将 stub CAS 为 `rebind_inflight {new_route_digest,outbox_id}` 后恢复
live outbox/keyed-slot/receipt-delivered/project-ack transaction。若 new route 再次 proven permanent，
同一 token/逻辑 slot 必须以 reservation 时预留的 scratch generation/bytes 做 copy-on-write in-place
replacement：先 fsync replacement，再由单一 global root CAS 同时 repoint stub、释放刚取得的
completed/outbox capacity并使旧 generation inert；source root 即使只有一条且已满也不需第二 entry/token。
project ack 成功后，global root 必须先 CAS stub 为 digest-bound
`retirement_pending {root_kind,root_id,old_entry_digest,final_ack_digest,quarantine_token_id}`；随后 authoritative
root 才写/fsync `retired` generation并 reclaim entry/free-list capacity。最后 global root 验证 pending 与
retired digests 后删除 stub并释放 token；任一 phase crash 均按 pending/retired 状态向前恢复，禁止产生
valid-transition mismatch。未经 rebind 不得伪称 completed。token 缺失/错配/corrupt
均 `needs_repair` 且只 backpressure 对应 source；测试覆盖 transient/permanent 分类、delete/replace、
quarantine permission/delete/replace、primary-fsync→alternate-publication crash、nonchosen orphan cleanup、
post-commit per-source corruption、cross-source isolation、completed+outbox atomic reacquire/floor-minus-one、
rebound-route replacement（含 one-entry-full/floor-minus-one）、retirement-before-token-reuse 每阶段、
receipt-delivered-route-quarantine、project-marker/global-ack crash（含 outbox reclaimed + dormant source + exact route resolution）、normal reuse、
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

summary/health 等 multi-event/project reader 只能从 bounded registry/allocator/outbox 与
completed-projection indexes 构造 v2 proof，禁止扫描 log。completed index 以 generation-covered
fixed entry/byte maximum 保留 H-014 批准的 query/retention window 内全部 refs；仅
`project_acknowledged` 是 successful ref，`receipt_delivered` 必须进入 lag refs。GC 只能删除
已 ack 且越过 retained window/watermark 的完整 bucket；未 ack ref、registration/state-root/route identity
locator 与其 token 必须 pin 并计 capacity/backpressure，或先原子转入可枚举 quarantine/admin lag index，
绝不能 age-delete 唯一 recovery locator。过旧 query、retention gap、capacity/
freshness overflow 必须 unavailable + empty，禁止回退扫描。reader 先读取 committed global
metadata root generation + 其引用的四个 checksummed subgenerations +
allocator tail/watermark，再按 query identity/window 有界枚举全部 in-scope state，生成稳定
ordered `barrier_refs` 与 ordered `lag_refs`（包括 live/frozen registry、reservation、outbox 与
route-quarantine lag），
其中 successful refs 只来自 completed index 的 project-acknowledged state，最后重读 root + 四个 subgenerations/tail。前后任一变化必须在同一 deadline 内 bounded
retry；重试仍 drift 则 `projection_lag/unavailable` + 空 semantic aggregate。

`barrier_set_digest = H(schema, query_identity, ordered barrier_refs, ordered lag_refs,
root_generation, registry_generation, allocator_generation/tail, outbox_generation, completed_index_generation)`；`projection_watermark` 携带
同一组 generations/tail，两者不得分别取样。任一 lag ref、ready/outbox state 遗漏/
重排，digest 或 generation mismatch，proof 超 closed maximum，或无法证明全量集合时，
必须 fail visible 并保持空数据；禁止 partial/synced aggregate。测试覆盖 omitted/
reordered lag ref、ready-registry lag、outbox lag、completed retention/overflow 与 scan-generation drift。

## 5. Ownership and proof closure

实际 app-server session owner `vibeguard-runtime/src/codex_app_server_core.rs` 与
PostToolUse/PostEdit delivery owner `vibeguard-runtime/src/hook_orchestrator_post_edit.rs` 必须进入
affected-file manifest、focused test ownership 与 U-22 critical inventory。前者生成不可由
client thread ID/env 重现的 server-owned capability，并在 app-server Rust process 内调用
semantic Core，覆盖 restart/rotation/spoof/captured-value replay；后者的
payload→trusted session/root handoff、cache/provider ordering、error path 和 short-circuit
condition 达到 100% line + branch/condition coverage。
planned U-22 manifest 必须让每个 critical file 恰出现一次并携带非空 exact `owner_suites`；
gate 双向核对 manifest ↔ Product-to-Test mapping/Cargo exact name 或 shell selector，missing/empty/
unknown/duplicate、zero-match、rename drift 与未被 critical file 引用的 suite 均须 nonzero。

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
