# GH-703 Coverage、Source Snapshot 与 Atomic Publish 合同

## 状态与范围

本文件是 [`tech.md`](tech.md) 的规范性拆分，仍受 [`product.md`](product.md) 中
未批准的 H-001 至 H-008 约束。它不批准任何 recommendation，也不授权 tasks 或
implementation。若本文与 product invariant 冲突，以 product invariant 为准并阻止实现。

本文只拥有三项机器可执行边界：

1. canonical writer attempt 的 coverage authority、gap 与 host availability proof；
2. live log/retained archive 的 immutable source generation 与 bounded verification；
3. JSON/Markdown history/current 的单一 generation commit。

## 1. Authority mode 与 epoch

Authority mode closed 为 `scheduled|manual`：

- `scheduled` 只在 value scheduler `active` 时存在，由 H-002 获批的 owned job 承载；
- `manual` 只由用户显式运行
  `vibeguard-runtime observe weekly-value manual-authority start` 创建，不注册或伪造
  scheduler，不要求 `scheduler_state=enabled`，并使用与 scheduled mode 不可混用的
  `authority_id`、epoch namespace、owner nonce 与 journal root；
- `disabled_by_user` 和默认 `unsupported_platform` 不创建 authority、heartbeat、slot 或
  逐事件 coverage diagnostic；unsupported 平台必须展示 exact
  `vibeguard-runtime observe weekly-value manual-authority start|status|stop|generate`
  命令序列；`generate` 还必须携带第 3 节 CLI 的 exact window/timezone/scope/taxonomy 参数；
- manual `stop` 必须先 quiesce parents 并按本节 authority-record 原子提交合同提交 terminal seal；`generate` 只读一个 exact sealed
  manual epoch（active epoch 必须先 stop），接受任一通过第 3 节 CLI 语法、边界与 budget 校验的显式
  half-open window。只有被该 epoch 连续覆盖的 window 才能返回 `complete`；早于 `manual_enabled_at` 或
  在 seal 后结束的合法 window 分别固定为无 headline `manual_pre_start|manual_post_seal` partial；跨两边界时
  precedence 选择 `manual_pre_start`。schema/corruption
  等 terminal evidence 仍 nonzero/no-publish。命令不得拒绝合法历史 window或用 on-demand scan补造 complete。

任一 mode 的 epoch 都绑定 exact installed snapshot digest、authority provider identity、
批准的 cadence/jitter/expiry 和 lifecycle generation。mode、epoch 或 snapshot digest 不同的
heartbeat/slot 不能拼接。manual stop 先封闭 admission、等待 quiescence、提交 terminal fence，
再停止 resident authority；不确定状态形成 gap，而不是成功 stop。

clean 也是 authority terminator，而不只是 scheduler probe：在删除 control state 或提交
`no_current` 前，必须对每个 active authority mode（包括 manual）执行相同的封闭 admission、等待所有
registered parents quiescence、原子提交 terminal seal、停止 resident authority 与存活证明；scheduler
inactive 不能替代 manual authority 的 quiesce/seal/stop。任一 proof 缺失、不确定或 resident process 仍在，
clean 必须 nonzero、保留 control state、不得提交 `no_current` 或报告成功。

H-002 approval 必须固定正整数 seconds 的 `heartbeat_cadence_seconds`、
`heartbeat_max_jitter_seconds`、`heartbeat_expiry_seconds`，并满足
`heartbeat_expiry_seconds > heartbeat_cadence_seconds + heartbeat_max_jitter_seconds`；还必须固定正整数
`maximum_active_journal_entries`、`maximum_active_journal_bytes` 与 `maximum_active_journal_segments`。
不满足该不等式的 selection 无效，Draft Gate 继续 blocked。

## 2. Heartbeat、ingress 与 standalone writer

fresh source bootstrap 是一个单目录 transaction，不得先后暴露独立 log/ledger pathname。authority 先在
writer lock 内证明无任何 source ledger/history，再于同 filesystem、mode 0700 staging directory 中创建
空 log、`empty_source_generation` ledger 与绑定 transaction/source ID、restricted relative paths、length、digest 和
no-follow object identities 的 manifest；全部 file+directory fsync 且重验后，以 Linux
`renameat2(RENAME_NOREPLACE)` / macOS `renameatx_np(RENAME_EXCL)` atomic no-replace directory rename
一次发布 `source-generations/<source-generation-id>/`，再 fsync parent。lifecycle pending state 在任何 bytes
物化前预留该 transaction identity/entry/byte budget；crash retry 只可 exact-adopt 已完整发布且 manifest/
identity/digest 全匹配的 generation，或在受限 staging identity 匹配时完成/清理未发布 transaction。
不完整、外来或冲突 target 一律 fail activation；任一曾登记 source 缺失/不符都不得重建空源。

所有 authority journal logical record（genesis、heartbeat、reservation、admission outcome、gap、terminal seal 与
checkpoint）必须使用同一 crash-atomic primitive：先在 segment-private staging 中以 `O_CREAT|O_EXCL`
写完整 length-bounded JCS record并 fsync，再以 atomic no-replace link 发布到
`authority-journal/segments/<segment-id>/records/<sequence>-<record-id>.json` 并 fsync records directory。
ack/续租/封闭只在 directory fsync 后生效；reader/recovery 忽略 staging，只 fold 从 exact genesis 开始的
contiguous sequence+prior-digest chain。final pathname 必须 absent 或完整；truncated/多出/fork/gap record 使旧
epoch 无法 active/renew，禁止 truncate-tail 后继续或将 partial bytes 当 gap proof。下文的 authority
record “提交”均指这个 primitive。完整 source generation 发布后才提交 genesis record：
`heartbeat_sequence=0`、`heartbeat_at=authority_epoch_started_at`、必需 `prior_digest=null`（禁止非 null
predecessor），并绑定 source root、launcher generation、零 open slot与
`expires_at=checked_add(authority_epoch_started_at,heartbeat_expiry_seconds)`；两者完成才可 active或 spawn。
Authority 对每个 `n>=1` 在 cadence deadline 加获批 jitter bound 之前 durable commit
digest-linked `{authority_id, authority_mode, authority_epoch, heartbeat_sequence,
heartbeat_at, expires_at, prior_digest}`。`heartbeat_at` 只能来自 H-002 批准 provider 以同一 boot
monotonic ordering约束的 trusted wall-clock anchor；host wall clock、scheduler enqueue time与 caller timestamp
均不授权续租。令 `deadline(n)=authority_epoch_started_at+n*heartbeat_cadence_seconds`，sequence `n`
只在 `deadline(n-1)<heartbeat_at<=deadline(n)+heartbeat_max_jitter_seconds` 且前一 heartbeat 尚未过期时接受，
所以首 heartbeat `n=1` 的前项是 genesis而非例外。`expires_at=checked_add(heartbeat_at,heartbeat_expiry_seconds)`；
overflow、倒退、跳号、晚到或不等式不成立均
封闭旧 epoch并形成 gap，不得回填连续性。journal 使用独立 path、lock 与 atomic-commit domain，不与
canonical log、coverage ledger 或 spool 共故障域。

每个 canonical caller 在执行 event-capable work 前必须拥有单次、严格递增且不复用的
`{authority_epoch, invocation_id, attempt_sequence, attempted_at}` reservation：

- installed `hooks/run-hook.sh` 为每个 caller生成 CSPRNG ID，authority fsync reservation并 ack后才 spawn；
- installed Git pre-commit parent（`scripts/setup/install.sh` 生成的
  `~/.vibeguard/pre-commit` wrapper，再执行 `hooks/pre-commit-guard.sh`）也是 registered
  canonical parent，必须以固定的 `canonical_hook_id=git_pre_commit` 在 guard 进程启动前取得并
  fsync single-use reservation，再把不可伪造 token 交给 guard；guard 不得自行创建首个 slot。
  专用且唯一的 B-035 launcher fixture 是 Planned Changes Manifest 中的 `test_precommit_authority.sh` entry，必须逐项断言
  reservation ack 先于 guard、pre-slot `reservation_rejected` 返回 nonzero 且
  `guard_started=false`/目标 read-write 次数为零；已 ack 的 invocation 必须以同一 epoch、invocation_id、token
  产生恰好一个 `committed|gap|aborted_before_spawn` terminal outcome，禁止重复 terminal record 或 sibling
  复用，且该 fixture path 由 tech manifest 独占。
- `hooks/run-hook-codex.sh` outer normalization只生成一次 CSPRNG `outer_request_id`，不得预留或复用 slot；
  `hooks/_lib/codex_runner.sh` fan-out loop才是每个 normalized inner caller的 parent。每个 iteration以 exact
  canonical resolved hook name作为 `canonical_hook_id`、从 0 严格递增 `fanout_index`，并以 epoch-keyed、
  domain-separated HMAC-SHA-256 对 JCS `{outer_request_id,canonical_hook_id,fanout_index}` 派生独立
  `invocation_id`，取得 single-use durable ack后再 spawn。authority拒绝重复 tuple/index/ID/token；某 child
  crash/deny只能终结自身 slot，不得关闭、提交或复用 sibling reservation；
- `scripts/authorized-discard.py` 的 top-level preflight 是独立的 authority slot owner：它必须在
  解析完成确认参数后、读取或执行 discard plan 之前取得并 fsync reservation，再把不可伪造 token
  传给同一进程内的 action/writer boundary；action boundary 不得自行创建首个 slot；
- pre-slot failure 不得启动 hook caller，也不得让 authorized-discard 读取/修改目标；host launcher
  按既有 PreToolUse/PostToolUse/Stop failure contract fail visible，standalone command nonzero；
- opt-out 或未启动 manual authority 的 unsupported 路径明确 bypass value reservation，保持既有
  guard/command 语义且不产生逐事件 coverage failure。

slot state closed 为 `opened|spawned|committed|gap|aborted_before_spawn`。只有绑定 reservation、launcher
generation、spawn syscall outcome 与 fsynced quiescence proof 的 durable no-spawn record 才能写
`aborted_before_spawn`；它证明 caller 从未存在，所以是无需 event row、也不产生 partial reason 的 terminal
accounting。crash、timeout、可能已 spawn 或任何不确定一律 gap。heartbeat renewal 必须先封闭 launcher
generation，取得所有 registered parents 的 quiescence ack、最高 sequence 与全部 slot terminal proof；缺任一
证据禁止续租。

reservation request 在 slot open 之前被拒绝时不创建 slot，也不能伪装成
`aborted_before_spawn`；authority 必须以 request identity 原子提交独立的 closed admission outcome
`reservation_rejected`，launcher 返回 nonzero 且不得启动 guard。`aborted_before_spawn` 只适用于已收到
reservation ack、随后由 durable spawn outcome 证明 caller 从未启动的 slot。拒绝 outcome 本身无法 durable
记录时，authority 必须 fail closed、保留不可证明状态并禁止 caller spawn；该 window 不得报告 complete。

writer 把 reservation token 与 conservative half-open `coverage_interval` 写入 coverage ledger；
主 ledger 不可写时写独立 spool。row append+fsync 后才能以 matching event identity/tail commit。
ledger/spool 双失效时 reservation 保持 pending 并在 authority journal 原子提交 `dual_channel_gap`；后续
heartbeat 或重试不能抹去。caller 已启动后的 accounting failure 必须发 closed
`coverage_recording_failed`，但不得改变原 guard decision、blocking 语义或 exit code。

## 3. Trusted suspend/resume/boot fence

H-002 还必须固定 platform availability provider identity/version 与 attestation contract。provider
必须从 OS-trusted boot session identity、suspend/resume notification、monotonic clock 和 bounded
wall-clock anchor 产生 digest-linked fence；应用自行观察到“heartbeat 没出现”不构成 fence。

在预计 heartbeat expiry 时：

1. authority 先封闭当前 ingress generation并收集第 2 节的 quiescence proof；
2. provider 记录 `suspend_begin` 或 terminal `boot_end`，绑定最后 heartbeat/slot root 与时间界限；
3. resume/new boot 记录新 boot identity、`resume_at`/`boot_at`、prior fence digest 和 clock uncertainty；
4. recovery 创建新 fenced epoch，不续接旧 heartbeat sequence。

只有 fence 同时证明整个 interval 内 host 不可能运行任何 registered canonical parent、边界没有
open/spawned slot、boot identity/monotonic ordering 连续且 clock uncertainty 不越过查询 window
边界时，该 interval 才标为 `host_unavailable` 并从 heartbeat coverage obligation 中排除。reader
把 fence 两侧已覆盖的 available intervals 拼接，而不是要求 unavailable interval 有 heartbeat。

缺 suspend-begin/boot proof、provider 不受信、clock rollback/uncertainty、未确认 launcher、open slot
或边界与 window 相交时，gap 起点 exact 为 present operands 的 minimum：
`min(last_trusted_heartbeat_at, earliest_unacknowledged_claim_at)`，其中 absent
`earliest_unacknowledged_claim_at` 等价 `+∞`，所以无 pending claim 时从 last trusted heartbeat开始；
last heartbeat也 absent是非法 authority state，整个 epoch从 `authority_epoch_started_at` 到 recovery
checkpoint均为 gap。正常 sleep/reboot不必自动降级，而 coverage evidence真正缺失时仍不可伪造 complete。

## 4. Ledger、compaction 与 coverage truth

versioned two-generation ledger 记录 writer/authority identity 与 epoch、heartbeat/attempt sequence、
event tail、pending/gap、每个 archive 的 stable ID/source generation/coverage interval/file identity/
length/digest、retention tombstone、availability fence 以及
`earliest_provable_window_start`/`coverage_unprovable_before` watermark。

GC 必须先写/fsync archive 与 parent directory，再 commit archive ledger entry，最后才 rewrite/reclaim
live rows。retention 在 lifecycle lock 内先 fold并验证第 7 节 pointer chain，取得 current target的
generation/receipt/object identities并对该 target加 durable pin；candidate selection必须排除 pinned target，
直到另一个 pointer commit或 clean的 no-current tombstone成功后才可解除。pointer chain缺失、fork、损坏或
current target无法重验时停止全部 retirement，不得先写 tombstone。其余 candidate删除前先 commit
tombstone/watermark。成功 reservation只有在 matching row已进入 tail后才能折叠。closed gap仅在完全早于
retention + maximum catch-up最早查询 window后 compact，且 watermark、gap digest、interval与 sequence
range永久保留；open gap不 compact。

authority journal 按 cadence bucket compact。完全 closed bucket记录 first/last sequence、count与 root；含
pending/unacknowledged/gap 的 bucket固化成 conservative gap。每个 active physical segment受获批 entry/byte
limits约束，并保留 exact segment counter；触及任一 limit前先把最长 fully-terminal prefix增量折叠成 fixed-size
digest-linked checkpoint。若折叠后下一 append仍将超限，必须 early seal+fsync该 segment并在同一 cadence开启新
segment；达到 `maximum_active_journal_segments` 后，在创建新 reservation前 fail visible且禁止 spawn。每个 open
slot仍预留 terminal record与 heartbeat容量，既有 slot始终可闭合；无 safe prefix/reserved capacity同样先拒绝新
reservation。新 generation引用 prior root后fsync并 atomic swap，保留两代。time-bucket bound为
`ceil((retention_horizon_seconds + maximum_catch_up_duration_seconds +
maximum_query_window_duration_seconds + heartbeat_expiry_seconds) /
heartbeat_cadence_seconds) + 3`。H-004 必须批准正整数 maximum query-window duration，且任何可选择 window
的实际 span不得超过它；retained segments硬界为 time-bucket bound × `maximum_active_journal_segments`，
retained entries/bytes再分别乘以对应 per-segment cap，并加 fixed-size checkpoints。
超限或无法证明最早 query start仍在 journal内必须 partial/error，禁止丢 proof。

complete window 要求：所有 available intervals 有连续、未过期 heartbeat；所有 host-unavailable
interval 有第 3 节 trusted fence；authority/attempt sequence 连续；每个与 query window相交的 reservation
或 pre-slot admission request 都有 matching committed row、exact `aborted_before_spawn` terminal proof 或
durable `reservation_rejected` outcome，且不存在任何相交的
open或 closed gap；source snapshot有效。closed gap只证明已知缺口的 terminal accounting，绝不证明
complete。连续 proof + 仅含 verified no-spawn reservation 的空 event set且零相交 gap才是 complete-empty；
任何 query-overlap gap一律 `partial_coverage`。

## 5. Immutable source generation 与 lock budget

writer/GC 的 `<log>.lock.d` 是短 critical lock，不是 archive hashing lock。任何 query content budget 生效前，
reader必须完成 mandatory **integrity preflight**：遍历 ledger 中 **all retained archives**（数量同时受 H-004
`max_retained_archives` 与 retention hard cap约束），逐个验证 membership root、no-follow identity/length、
archive header 与完整 compressed-byte digest。preflight不消费 `max_source_files`、`max_uncompressed_bytes`、
`max_snapshot_elapsed_ms`；只受独立 `max_integrity_preflight_elapsed_ms`约束。corruption固定 terminal
`archive_corrupt`；count超限、timeout或任一 root/header/digest/identity 无法完成固定 terminal
`integrity_preflight_incomplete`。两者均 nonzero/no-publish并把旧 current标 stale。只有 preflight全绿后，
以下 content scan才可应用 query budgets：

1. 在 lock 内固定 ledger 的 `captured_prefix_root`/generation、window所需 live/archive entries、snapshot
   lengths、query evidence frontier与 no-follow readonly handles；拒绝 symlink/非 regular file，并验证
   identity/length 与 entry；
2. 生成 immutable `source_snapshot_id`，绑定 captured prefix、完整 ordered entry identities、handles、
   lengths、query frontier与 approved budgets；GC 对已发布 archive 禁止 in-place mutation，只能发布新 generation；
3. 在释放 `<log>.lock.d` 后由 bounded async verifier 读取 handles 的 snapshot length、计算 digest 并
   parse；writer、hook 与 GC 此时可继续取得 critical lock；
4. verification完成后重新取得短 lock，证明 `captured_prefix_root`仍是 current ledger的 byte-identical
   immutable ancestor、captured entries/handles仍匹配且未 tombstone，并 fold prefix之后的 suffix，确认没有
   新 reservation/gap/archive/tombstone或 availability fact改变 query window的 evidence validity，然后释放。
   unrelated current-period append、root/generation或 live tail单纯前进不使 snapshot失效；prefix不再可证明、
   所需对象改变/retire或 suffix与 query相交才产生 `snapshot_changed`，不得把混合 generation当 complete。

content verifier受 H-004 的 file/byte/elapsed query budgets约束；timeout/short read/identity change/
post-verify ledger drift 都 fail visible。retained archive unreadable、gzip/row parse 失败或 digest mismatch
是 terminal `archive_corrupt`：generator nonzero，不提交新 history/current/share generation，旧 current
标 stale。因为 integrity已独立证明，后续 content budget耗尽固定为无 headline `budget_exceeded` partial；
`archive_missing|archive_tombstoned|snapshot_changed` 同样可按 closed precedence形成 partial。

官方 hook latency gate 必须在 verifier 持续处理 `max_uncompressed_bytes` 边界 archive、同时触发 GC
rotation/revalidation 的 contention fixture 下运行 exact installed Claude/Codex wrappers 与真实
authority IPC/fsync。绕过 verifier、IPC、fsync 或只测 idle path 都不算通过。

## 6. Deterministic classification 与 event-set hashing

producer registry entry 以
`{classification_contract_version, classification_contract_digest}` 为不可拆分 identity。reader 只有
两者都 exact-match 且 typed decision/rule/reason tuple 合法时才进入 taxonomy matching；同版本但未知/
篡改 digest 固定 `unclassified_event`。typed tuple 对获批 taxonomy 恰好零匹配也固定
`unclassified_event`，不得落入 operational 或 other；多匹配 nonzero。

canonical tuple 的 exact key order 由 event schema 固定，至少绑定 event schema/version、host、decision、
rule/reason、classification source/version/digest 与 event identity。event set 先按 `event_id`，再按完整
canonical tuple UTF-8 bytes 排序。同一 ID 的相同 tuple 折叠；同一 ID 的不同 tuples 以该 secondary key
稳定排序并产生 `event_identity_conflict`。archive enumeration 或 rotation 顺序不得改变 digest。

## 7. One-generation JSON/Markdown publish

一个 summary generation 使用 CSPRNG `artifact_generation_id`，布局为：

```text
history/<window-id>/<artifact_generation_id>/summary.json
history/<window-id>/<artifact_generation_id>/summary.md
history/<window-id>/<artifact_generation_id>/generation.json
generation-claims/records/<claim-sequence>-<claim-id>.json
generation-claims/commits/<claim-sequence>-<claim-id>.commit
ownership-receipts/records/<receipt-sequence>-<receipt-id>.json
ownership-receipts/commits/<receipt-sequence>-<receipt-id>.commit
lifecycle-terminals/records/<terminal-sequence>-<terminal-id>.json
lifecycle-terminals/commits/<terminal-sequence>-<terminal-id>.commit
current-pointers/<pointer-sequence>-<pointer-id>.json
audit-checkpoints/<chain-kind>/<checkpoint-sequence>-<checkpoint-id>.{json,commit}
```

producer 从同一 verified object 渲染 JSON/Markdown；`generation.json` 绑定 window、generation ID、
两个 renderer 的 restricted relative path、length/digest、`summary_digest` 与 ownership receipt identity。
发布前 producer 已在内存中得到 exact renderer bytes/digests，必须先以与 receipt 相同的 prepared
record+commit-marker primitive 提交 generation claim；claim 绑定 transaction/generation ID、restricted paths、
exact planned entry/byte counts、renderer/manifest lengths+digests 与 owner nonce，并在任何 generation bytes 物化前从
hard caps 预留该份额。发布顺序固定为 committed claim → temp generation → renderer/manifest
flush+fsync+verify → fsync generation parent → ownership receipt commit → pointer commit → success。receipt先在同
filesystem staging以 no-follow `O_CREAT|O_EXCL`准备完整
JCS bytes并 fsync，再以 `linkat` atomic no-replace发布 record、fsync records dir；随后同样准备完整 marker并 fsync，
atomic no-replace发布绑定 record identity/digest/sequence的 commit marker，再 fsync commits dir。reader只 fold
contiguous、digest-linked且 record+marker exact匹配的 committed receipts；忽略 unpaired、uncommitted或 torn
record/marker/staging。lost-response retry以同一 transaction/sequence/ID重验并幂等 adopt exact pair；collision或
内容不匹配 terminal fail，禁止 duplicate或跳号。

receipt record 必需 `receipt_sequence,receipt_id,prior_receipt_digest,record_digest`；sequence 0 必需
`prior_receipt_digest=null`，`n>0` 必须 exact 引用 `n-1` committed record digest。第一个 generation 不得
从空字符串、零 digest 或隐式 predecessor 推导 genesis；gap/fork/unknown/extra 字段 terminal fail。
generation-claim 与 lifecycle-terminal chains 分别使用同构的 `<kind>_sequence,<kind>_id,
prior_<kind>_digest,record_digest` genesis/predecessor 规则，同样禁止隐式 genesis。lifecycle-terminal record
还必须绑定 exact lifecycle generation、closed terminal reason、authority mode/epoch、parent quiescence root、
terminal seal digest、resident stop proof root 和 installed snapshot digest；缺任一项都不能授权 pointer。

pointer是以必需 `record_type` 为 discriminator 的 closed tagged union。两 variant共用
`schema_version,pointer_sequence,pointer_id,lifecycle_generation,lifecycle_terminal,prior_pointer_digest,record_digest`：
`current_generation` 要求 `lifecycle_terminal=false,authorization_type=ownership_receipt` 与
`artifact_generation_id,ownership_receipt_id,ownership_receipt_digest,summary_digest,object_identities`，禁止
`terminal_reason,terminal_authorization_id,terminal_authorization_digest`；`no_current` 要求
`lifecycle_terminal=true,authorization_type=lifecycle_terminal`、closed `terminal_reason=disabled|cleaned` 与 exact
`terminal_authorization_id,terminal_authorization_digest`，后两者必须指向 lifecycle chain 中已 crash-atomic 提交、
绑定同一 generation/terminal reason 且具备全 parent quiescence/seal/stop proof root 的 terminal record；该
variant 禁止全部 generation/ownership-receipt/summary/object fields。sequence 0要求
`prior_pointer_digest=null`；`n>0` exact引用 `n-1` digest；
`record_digest=SHA-256(JCS(record without record_digest))`。unknown/extra、required/forbidden、lifecycle/terminal、
predecessor/fork/gap任一违例 terminal fail。pointer record使用同 filesystem prepared complete inode+fsync+
atomic no-replace link+dir fsync；lost response只可 exact adopt。consumer先 fold committed receipt chain，再 fold
receipt/lifecycle-terminal-authorized pointer chain并选择最后 `current_generation`或 `no_current`；不得读取
orphan/partial generation。clean/disable 不得复用旧 generation receipt 授权 `no_current`。

任一 renderer、manifest、receipt或 pointer commit失败都保留旧 logical pointer、nonzero/stale。committed claim
未产生 matching receipt、或 receipt-committed 但 pointer未提交，都是 orphan；其 claim 预留额与实际可验证
bytes/identities 必须计入 hard caps。`capability_attested` backend 也只有 atomic expected-identity claim与同
identity retire 成功才可释放；默认 `no_auto_delete` 只保留并计数。未被 committed claim 预留的
generation bytes 不得创建，因此 repeated pre-receipt crash 不能越过 cap。

generation claims、receipts、lifecycle terminals 和 pointers 的 record/marker/checkpoint 全部计入 H-007 的
`hard_history_cap_entries|bytes`，禁止把 audit metadata 排除于上限。每条 chain 在下一个 record 触及 cap 前，
必须以同样 prepared-record+commit-marker primitive 提交 checkpoint，且每次 append 前必须从 cap 预留一个
maximum-sized checkpoint record+marker；连预留都无法满足时在写当前 record 之前停止。checkpoint 绑定 exact folded sequence range、
genesis/prior checkpoint digest、prefix Merkle root、last record digest、current pin、所有 live claims/receipts 与累计
entry/byte accounting。reader 先验证 checkpoint chain 再继续 contiguous suffix；checkpoint/fork/gap失效停止 publish/
retention。只有 `capability_attested` backend 可在 checkpoint commit+dirfsync 后对已 folded、非 pinned prefix 做
atomic expected-identity retire，并将 checkpoint chain 保持为 latest+previous 两代，所以可持续发布；
`no_auto_delete` 不删除 audit prefix，在下一 record 将触及 cap
前 fail visible 并停止新 generation。两种 policy 都 bounded：不允许无上限增长，也不允许无 capability
却为保持 availability 忽略 cap。share export同样只从 pointer chain选中的 verified object产生 H-005 allowlist projection。

## 8. Focused verification

- suspend/resume、clean shutdown、unclean reboot、clock uncertainty、open-slot boundary 与普通 nightly sleep；
- scheduled/manual namespace、exact seq0/later deadline、manual pre-start/post-seal precedence；
- Planned Changes Manifest 中的 `test_precommit_authority.sh` entry 独占验证 installed Git pre-commit `git_pre_commit` parent reservation、
  pre-slot rejection/nonzero/zero-write、`guard_started=false` 与同 token 恰一个 `committed|gap|aborted_before_spawn`
  outcome；Codex outer/hook/index fan-out identity、duplicate rejection、sibling crash isolation与 slot-before-work；
- large archive async hashing 与 GC/writer contention 下的 exact installed wrapper P95 gate；
- segment cap/early seal/reserved capacity；all-retained preflight mutation/incomplete terminal与后续 budget partial；
- zero taxonomy match、version-match/digest-mismatch 与 duplicate-ID tuple permutation；
- source bootstrap directory、authority record、generation claim/renderer/manifest、receipt record/marker、pointer与
  audit checkpoint 的每个 crash barrier/lost-response replay；receipt/pointer exact genesis；`no_current` lifecycle
  authorization；pre-receipt orphan/cap-minus-one/cap/exceed；consumer不读 torn/uncommitted/mixed generation。
