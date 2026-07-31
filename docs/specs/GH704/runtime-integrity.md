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
global registration lease，在 checksummed fixed-capacity generations 中 reserve unique slot，写入并
fsync inert `projection_prepared {source_route, queue_key, bounded_derived_body, barrier_digest,
record_digest, eligibility_epoch}`，再原子提交 generation；project→registration 是唯一锁序，
global worker 不反向持 registry lease 取得 project lock。随后才 append/fsync canonical barrier，
提交引用 slot 的 `projection_queued`，barrier + registration durable 后才 `done`。worker 在 exact
source route 证明 matching barrier 前保持 entry inert；并发 project publication、reserve/commit
crash 按 slot/generation 幂等恢复，full 时在 barrier 前 visible backpressure，禁止覆盖/丢 entry。

若 crash/abort 留下无 barrier registration，dispatcher 先释放 registry lease，再按 shared delivery
lease → source project lock 调用**同一 coordinator recovery**：receipts complete 则补 barrier/
queued，matching abort 则确认 durable `aborted`；coordinator 返回 digest-bound ready/abort receipt
后释放 project/delivery locks，dispatcher 才重新取得 registry lease，以 compare-and-swap 提交
ready 或 checksummed tombstone/reclaim。未知/损坏 entry fail visible 且禁止覆盖；requested
off 在 exclusive delivery lease → project lock 下先提交 durable `off_preparing {old_epoch,
requested_config_digest, cursor}`：它立即禁止新 L2/shared admission，但还不是 effective
off。释放 project lock 后仍持 delivery lease，再取 global registration lease，将旧
epoch 的 pre-barrier 或 barrier-ready-but-unclaimed registrations 以 digest/epoch/state CAS
提交为 checksummed `off_frozen` administrative tombstone 并回收 live slot。它不写/
删 source semantic journal；
canonical `projection_prepared`/activation receipts 保持冻结，re-enable 只能 bounded rebind
并重新发布，或由 approved maintenance drain 处理。worker 自身从不写 project journal。
因为该路径不同时持 project/registry locks，且 registration 仍只用 project→registry，
不形成 lock inversion；off project 也不会用 inert/ready orphan 永久耗尽
live registry capacity。ready worker 只能在 shared delivery lease 下先用 registry state CAS
提交 `claim_prepared {claim_id, exact body/digest, reservation_digest}`，释放 registry lease 后
才幂等 durable 创建 exact sequencer reservation，然后重新取 registry lease CAS 为
claimed tombstone/reclaim；从不 reserve-before-claim，也不同时持 registry/sequencer leases。
crash 留下 claim-prepared 时，recovery/off-preparing 先查 exact claim/reservation digest；
无 reservation 可 CAS off-frozen，matching reservation 则必须先完成第 4 节的 allocator/
outbox/receipt drain 再回收 slot，mismatch 则 `needs_repair`。
global view 仍只在 barrier 后可见。decision、
consumer/status/aggregate/precision/Learn 仍只 join barrier；project coordinator 最后在同一 lock
下消费 durable receipt slot 并提交 `projection_done`。

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
2. 在 checksummed allocator WAL/metadata 原子提交
   `{reservation_id, identity_key, expected_offset, barrier_digest, bounded_derived_body,
   record_digest, source_project_identity, receipt_route, bounded_receipt_body, new_tail}`；
3. 在同一 lease 下为 exact key durable 写 `projection_prepared`，只在 expected offset
   append/fsync derived record；
4. `receipt_route` 必须是预先注册在 runtime-owned closed project-state directory 的 exact
   capability，绑定 state-root ID、directory/file identity 与 content-addressed `receipt_key =
   H(source project, event, barrier, global record digest)`；每个 key 是独立 create-if-absent slot，
   不能使用共享 project-receipt append offset，也不能要求扫描 project/HOME；
5. 仍在同一 lease 下把 `projection_applied`、allocator committed tail 与 checksummed
   `receipt_prepared {route, bounded_receipt_body, source barrier/record digest}` outbox intent
   原子提交到同一 metadata generation；只有该 generation durable 后才释放 lease、回收
   reservation body；
6. `.vibeguard.json` 只是 requested state；runtime-owned eligibility registry 才是 effective
   state，并绑定 observed config identity/digest + epoch。projector/receipt/source worker 处理
   intent 前取 deadline-bounded shared delivery lease，以 no-follow 重开 config 并比较 digest。
   若 drift，必须零 source write 释放 shared lease，再取 writer-fair exclusive lease。
   requested off 进入第 2 节 durable `off_preparing`；其 cursor 以 policy-bound batch/byte/time
   oldest-first 多 pass：(a) freeze/reclaim pre-barrier/ready-unclaimed；(b) 对 claim-prepared
   执行 absent-reservation abort 或 matching reservation recovery；(c) 将该 source 的每个 applied/
   receipt-outbox intent 在 exclusive lease 下写 exact keyed slot，完成 file fsync + atomic
   create-if-absent + route-directory fsync，再提交 global `receipt_applied`/reclaim。该 drain
   在 effective off 前完成，不写 project journal/`projection_done`。只有 registry、
   reservation 与 live outbox 中该 source 均为零，才重取 project lock 原子提交
   effective off epoch。任一 cap/deadline/route 失败保持 `opt_out_pending/error` + counts/
   oldest age，禁止新 L2 但不伪称 off，后续 bounded pass 续传；因而 effective off
   永不占 shared live registry/outbox capacity。每个 pass 只外层持 exclusive delivery；
   project lock 在任一 global lease 前释放，registry 在 sequencer/receipt I/O 前释放，
   每次 durable handoff 后才取下一 lease，不同时持 project/registry/sequencer。re-enable 只能由 source coordinator bounded
   rebind/consume durable slots，或由另行批准的 maintenance drain 处理；
7. receipt worker 从 outbox oldest-first 打开 exact route，以 no-follow temp write + file fsync +
   atomic create-if-absent 写 keyed slot，再 fsync route directory。此后它只提交 global
   `receipt_applied`/reclaim；不得写 project journal/`projection_done`。slot 已存在且 digest 相同
   也必须证明 directory durability；不同 digest 才 `needs_repair`。project coordinator/approved
   maintenance route 必须按 shared delivery lease → project lock 的固定顺序取得 matching epoch，
   并持有两者直到 slot 验证与 `projection_done` fsync；off 同样按 exclusive lease → project lock，
   因而会等待 worker 与 marker writer。多个 keys 可任意 delivery order，仍只有一个 group writer。

因此 reservation A 未 applied 时，reservation B 不能 append；不会出现 later offset 先落盘、
earlier offset 留洞。crash recovery 只查 earliest reservation、exact key/offset/digest：缺 record
则补 append，匹配 record 则补 marker/tail/outbox intent/receipt slot，不匹配则 `needs_repair`。crash 在
applied 与 tail/outbox generation 之间时 reservation 仍 committed，可幂等重建；generation
之后即使 source project 永不再运行，outbox 也独立携带 exact route/body。route inaccessible/
identity mismatch 保持 pending lag；requested off 则保持 off-preparing，不得提交 effective
off 后留 live intent。outbox 无法为下一最大 receipt admission 时在新 reservation
前 backpressure。禁止扫描 global/project/HOME log、跳洞、重新分配 offset 或按 per-key 并发
append。allocator/index/outbox full/corrupt/timeout 保持 `projection_lag` + 空 global data，不能
反写 canonical project decision。

### Aggregate snapshot proof

summary/health 等 multi-event/project reader 只能从 bounded registry/allocator/outbox indexes
构造 v2 proof，禁止扫描 log。reader 先读取三个 checksummed committed generation +
allocator tail/watermark，再按 query identity/window 有界枚举全部 in-scope state，生成稳定
ordered `barrier_refs` 与 ordered `lag_refs`（包括 ready-registry、reservation 与 outbox lag），
最后重读三个 generations/tail。前后任一变化必须在同一 deadline 内 bounded
retry；重试仍 drift 则 `projection_lag/unavailable` + 空 semantic aggregate。

`barrier_set_digest = H(schema, query_identity, ordered barrier_refs, ordered lag_refs,
registry_generation, allocator_generation/tail, outbox_generation)`；`projection_watermark` 携带
同一组 generations/tail，两者不得分别取样。任一 lag ref、ready/outbox state 遗漏/
重排，digest 或 generation mismatch，proof 超 closed maximum，或无法证明全量集合时，
必须 fail visible 并保持空数据；禁止 partial/synced aggregate。测试覆盖 omitted/
reordered lag ref、ready-registry lag、outbox lag 与 scan-generation drift。

## 5. Ownership and proof closure

实际 app-server session owner `vibeguard-runtime/src/codex_app_server_core.rs` 与
PostToolUse/PostEdit delivery owner `vibeguard-runtime/src/hook_orchestrator_post_edit.rs` 必须进入
affected-file manifest、focused test ownership 与 U-22 critical inventory。前者生成不可由
client thread ID/env 重现的 server-owned capability，并在 app-server Rust process 内调用
semantic Core，覆盖 restart/rotation/spoof/captured-value replay；后者的
payload→trusted session/root handoff、cache/provider ordering、error path 和 short-circuit
condition 达到 100% line + branch/condition coverage。

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
