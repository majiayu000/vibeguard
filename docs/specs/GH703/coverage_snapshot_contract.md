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
- manual `stop` 必须先 quiesce parents 并 append+fsync terminal seal；`generate` 只读一个 exact sealed
  manual epoch（active epoch 必须先 stop），接受任一通过第 3 节 CLI 语法、边界与 budget 校验的显式
  half-open window。只有被该 epoch 连续覆盖的 window 才能返回 `complete`；早于 `manual_enabled_at`、
  跨未覆盖区间或在 seal 后结束的合法 window 必须返回无 headline 的 `partial_coverage`；schema/corruption
  等 terminal evidence 仍 nonzero/no-publish。命令不得拒绝合法历史 window或用 on-demand scan补造 complete。

任一 mode 的 epoch 都绑定 exact installed snapshot digest、authority provider identity、
批准的 cadence/jitter/expiry 和 lifecycle generation。mode、epoch 或 snapshot digest 不同的
heartbeat/slot 不能拼接。manual stop 先封闭 admission、等待 quiescence、提交 terminal fence，
再停止 resident authority；不确定状态形成 gap，而不是成功 stop。

H-002 approval 必须固定正整数 seconds 的 `heartbeat_cadence_seconds`、
`heartbeat_max_jitter_seconds`、`heartbeat_expiry_seconds`，并满足
`heartbeat_expiry_seconds > heartbeat_cadence_seconds + heartbeat_max_jitter_seconds`。
不满足该不等式的 selection 无效，Draft Gate 继续 blocked。

## 2. Heartbeat、ingress 与 standalone writer

Authority 在每个 cadence deadline 加获批 jitter bound 之前 durable append+fsync
digest-linked `{authority_id, authority_mode, authority_epoch, heartbeat_sequence,
heartbeat_at, expires_at, prior_digest}`。`heartbeat_at` 只能来自 H-002 批准 provider 以同一 boot
monotonic ordering约束的 trusted wall-clock anchor；host wall clock、scheduler enqueue time与 caller timestamp
均不授权续租。令 `deadline(n)=authority_epoch_started_at+n*heartbeat_cadence_seconds`，sequence `n`
只在 `deadline(n-1)<heartbeat_at<=deadline(n)+heartbeat_max_jitter_seconds` 且前一 heartbeat 尚未过期时接受，
`expires_at=checked_add(heartbeat_at,heartbeat_expiry_seconds)`；overflow、倒退、跳号、晚到或不等式不成立均
封闭旧 epoch并形成 gap，不得回填连续性。journal 使用独立 path、lock 与 atomic-commit domain，不与
canonical log、coverage ledger 或 spool 共故障域。

每个 canonical caller 在执行 event-capable work 前必须拥有单次、严格递增且不复用的
`{authority_epoch, invocation_id, attempt_sequence, attempted_at}` reservation：

- installed `hooks/run-hook.sh` 与 `hooks/run-hook-codex.sh` 由 parent 生成 CSPRNG
  `invocation_id`，authority fsync `invocation_open`/reservation 并 ack 后才 spawn caller；
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

writer 把 reservation token 与 conservative half-open `coverage_interval` 写入 coverage ledger；
主 ledger 不可写时写独立 spool。row append+fsync 后才能以 matching event identity/tail commit。
ledger/spool 双失效时 reservation 保持 pending 并在 authority journal 写 `dual_channel_gap`；后续
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

authority journal 按 cadence bucket compact。完全 closed bucket 记录 first/last sequence、count 与
event-tail/root digest；含 pending/unacknowledged/gap 的 bucket 固化成覆盖整个 bucket 的 conservative
gap。新 generation fsync 后引用 prior root，再 atomic swap 并保留两代；current bucket 不 compact。
hard bound 为
`ceil((retention_horizon_seconds + maximum_catch_up_duration_seconds +
maximum_query_window_duration_seconds + heartbeat_expiry_seconds) /
heartbeat_cadence_seconds) + 3`。H-004 必须批准正整数 maximum query-window duration，且任何可选择 window
的实际 span 不得超过它；超限或无法证明最早 query start 仍在 journal 内必须 partial/error，禁止丢 proof。

complete window 要求：所有 available intervals 有连续、未过期 heartbeat；所有 host-unavailable
interval 有第 3 节 trusted fence；authority/attempt sequence 连续；每个与 query window相交的 reservation
都有 matching committed row，或有第 2 节 exact `aborted_before_spawn` terminal proof，且不存在任何相交的
open或 closed gap；source snapshot有效。closed gap只证明已知缺口的 terminal accounting，绝不证明
complete。连续 proof + 仅含 verified no-spawn reservation 的空 event set且零相交 gap才是 complete-empty；
任何 query-overlap gap一律 `partial_coverage`。

## 5. Immutable source generation 与 lock budget

writer/GC 的 `<log>.lock.d` 是短 critical lock，不是 archive hashing lock。reader 必须：

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

verifier 同时受 H-004 的 file/byte/elapsed budgets 约束；timeout/short read/identity change/
post-verify ledger drift 都 fail visible。retained archive unreadable、gzip/row parse 失败或 digest mismatch
是 terminal `archive_corrupt`：generator nonzero，不提交新 history/current/share generation，旧 current
标 stale。`archive_missing|archive_tombstoned|snapshot_changed|budget_exceeded` 可按 closed precedence
形成无 headline 的 `partial_coverage` artifact；`archive_corrupt` 不在可发布 summary reason enum 中。

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
current-pointers/<pointer-sequence>-<pointer-id>.json
```

producer 从同一 verified object 渲染 JSON/Markdown；`generation.json` 绑定 window、generation ID、
两个 renderer 的 restricted relative path、length/digest、`summary_digest` 与 ownership receipt identity。
发布顺序固定为 temp generation directory → 写两种 renderer/manifest → flush/fsync files → schema/digest
verify → fsync generation directory/parent → append+fsync ownership receipt → prepare pointer record → atomic
create-only publish → fsync pointer directory/parent → success state。pointer record exact绑定 strictly monotonic
sequence、CSPRNG ID、prior pointer digest、generation/receipt/object identities与 record digest。producer先在同一
filesystem、mode 0700 owned staging directory以 CSPRNG name和 no-follow `O_CREAT|O_EXCL`创建 mode 0600 inode，
完整 write+fsync+verify 后用 `linkat` 等经 capability test 的 atomic no-replace hard-link primitive创建 final
pointer pathname；既有、symlink、跨 filesystem或 non-owned target导致 nonzero/stale，禁止 rename/replace、
truncate或覆盖。crash recovery只接受两种结果：final absent时旧 pointer仍 current；final存在时必须是完整、
digest-valid且 exact匹配 pending receipt/prior head的 inode，recovery fsync directory并幂等 adopt同一 sequence，
否则按 tamper fail visible，绝不跳号。staging link只在 final durable后按 exact inode清理。consumer只 fold
gap-free、digest-linked、receipt-authorized pointer chain并选择最后一个 generation或 clean提交的 no-current
tombstone；unknown/fork/gap/tamper均 fail visible，不得分别追踪 `current.json`/`current.md`或读取 orphan/partial
generation。

任一 renderer、manifest、receipt或 pointer commit失败都保留旧 logical pointer、nonzero/stale。receipt-durable
但 pointer未提交的 orphan在 `capability_attested` backend上也只有 atomic expected-identity claim与同 identity
retire成功才可删除；默认 `no_auto_delete` backend只记录 orphan identity/bytes并计入 approved hard caps，不删除。
capability缺失/失败时保留 orphan；下一 write将触及 entries/bytes cap前停止新增，保证 bounded accounting且不
依赖原 pathname。share export同样只从 pointer chain选中的 verified object产生 H-005 allowlist projection。

## 8. Focused verification

- suspend/resume、clean shutdown、unclean reboot、clock uncertainty、open-slot boundary 与普通 nightly sleep；
- scheduled/manual authority namespace、unsupported manual start/status/stop/sealed-generate、历史 window partial；
- Claude/Codex launcher与 authorized-discard preflight 的 slot-before-work 顺序及 opt-out bypass；
- large archive async hashing 与 GC/writer contention 下的 exact installed wrapper P95 gate；
- archive corrupt terminal non-publish、missing/tombstone/snapshot-change partial 分支；
- zero taxonomy match、version-match/digest-mismatch 与 duplicate-ID tuple permutation；
- JSON-only、Markdown-only、manifest、receipt、pre-link/post-link/pre-directory-fsync crash、append-only pointer与
  orphan-cap barrier，consumer永不看到 truncated/mixed generation、retention永不 retire current pin或
  receipt-only replacement。
