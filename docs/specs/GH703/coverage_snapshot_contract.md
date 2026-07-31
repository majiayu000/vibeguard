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
  `vibeguard-runtime observe weekly-value manual-authority start|status|generate|stop`
  命令序列；`generate` 还必须携带第 3 节 CLI 的 exact window/timezone/scope/taxonomy 参数；
- manual `generate` 接受任一通过第 3 节 CLI 语法、边界与 budget 校验的显式 half-open
  window，但只有被该 manual epoch 连续覆盖的 window 才能返回 `complete`。早于
  `manual_enabled_at`、跨越未覆盖区间或在 stop 后结束的合法 window 必须生成无 headline 的
  `partial_coverage`；schema/corruption 等 terminal evidence 仍 nonzero/no-publish。命令不得拒绝合法的
  历史 window，也不能由一次 on-demand scan 补造 complete 历史。

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
heartbeat_at, expires_at, prior_digest}`。迟到 heartbeat 不得回填连续性。journal 使用独立
path、lock 与 atomic-commit domain，不与 canonical log、coverage ledger 或 spool 共故障域。

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

slot state closed 为 `opened|spawned|committed|gap|aborted_before_spawn`。只有 durable
no-spawn proof 才能写 `aborted_before_spawn`；crash、timeout 或不确定一律 gap。heartbeat renewal
必须先封闭 launcher generation，取得所有 registered parents 的 quiescence ack、最高 sequence 与
全部 slot terminal proof；缺任一证据禁止续租。

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
或边界与 window 相交时，必须从 recovery gap anchor 到 recovery checkpoint 记录 gap。anchor 定义为
`min(last_trusted_heartbeat_at, earliest_unacknowledged_claim_at)`，其中不存在的
`earliest_unacknowledged_claim_at` 按正无穷处理，而不是被省略或当作 epoch 起点；若没有 trusted
heartbeat，则使用该 authority epoch 的 admission lower bound；若两者都不存在，则从 epoch start
记录 conservative gap。这样在 host running 但没有 pending claim 时仍会以最后 heartbeat（或明确的
epoch lower bound）封住 idle interval，正常 sleep/reboot 不必自动降级，而 coverage evidence 真正
缺失时仍不可伪造 complete。

## 4. Ledger、compaction 与 coverage truth

versioned two-generation ledger 记录 writer/authority identity 与 epoch、heartbeat/attempt sequence、
event tail、pending/gap、每个 archive 的 stable ID/source generation/coverage interval/file identity/
length/digest、retention tombstone、availability fence 以及
`earliest_provable_window_start`/`coverage_unprovable_before` watermark。

GC 必须先写/fsync archive 与 parent directory，再 commit archive ledger entry，最后才 rewrite/reclaim
live rows；retention 删除前先 commit tombstone/watermark。成功 reservation 只有在 matching row 已进入
tail 后才能折叠。closed gap 仅在完全早于 retention + maximum catch-up 最早查询 window 后 compact，
且 watermark、gap digest 与 sequence range 永久保留；open gap 不 compact。

retention 在选择任何 candidate 前，必须在同一 lifecycle lock 内 no-follow 解析并 pin
`current-generation.json` 的 pointer identity/digest 及其 target generation/file identity。pin 住的 target
以及验证该 pointer 所需的 receipt 不能进入 tombstone/retire 集合，直到 pointer 已被同一合同的 atomic
expected-identity commit 前进或明确移除；pointer 缺失、foreign/malformed、identity 重验变化或 capability
不足时必须保留 current/candidate、停止 retention 并 fail visible。

authority journal 按 cadence bucket compact。完全 closed bucket 记录 first/last sequence、count 与
event-tail/root digest；含 pending/unacknowledged/gap 的 bucket 固化成覆盖整个 bucket 的 conservative
gap。新 generation fsync 后引用 prior root，再 atomic swap 并保留两代；current bucket 不 compact。
hard bound 为
`ceil((retention_horizon_seconds + maximum_catch_up_duration_seconds +
heartbeat_expiry_seconds) / heartbeat_cadence_seconds) + 3`。超限必须 partial/error，禁止丢 proof。

complete window 要求：所有 available intervals 有连续、未过期 heartbeat；所有 host-unavailable
interval 有第 3 节 trusted fence；authority/attempt sequence 连续；每个与 queried window 相交的
reservation 都有 matching committed row。任何相交的 open、pending 或 closed gap 都必须产生
`partial_coverage`；closed gap 只有在完全位于 queried window 之外、并已满足 compaction watermark 时
才能作为历史压缩 proof，不能代替 window 内的 committed row。source snapshot 有效。连续 proof +
空 reservation/event set 才是 complete-empty。

## 5. Immutable source generation 与 lock budget

writer/GC 的 `<log>.lock.d` 是短 critical lock，不是 archive hashing lock。reader 必须：

1. 在 lock 内固定 ledger generation/root、window 所需 live/archive entries、snapshot lengths 与
   no-follow readonly handles；拒绝 symlink/非 regular file，并验证 identity/length 与 entry；
2. 生成 immutable `source_snapshot_id`，绑定 generation/root、完整 ordered entry identities、handles、
   lengths 与 approved budgets；GC 对已发布 archive 禁止 in-place mutation，只能发布新 generation；
3. 在释放 `<log>.lock.d` 后由 bounded async verifier 读取 handles 的 snapshot length、计算 digest 并
   parse；writer、hook 与 GC 此时可继续取得 critical lock；
4. verification 完成后重新取得短 lock，重验 captured immutable generation、entry identity/length、
   tombstone 与 captured live-prefix witness，然后释放。重验必须证明 captured prefix 仍是当前
   append-only generation 的 ancestor；capture 之后追加到 live tail 的新记录不构成变化，但 prefix 被
   rewrite、truncate、rotate/retire、identity 改变或无法证明 ancestor 时产生 `snapshot_changed`，不得
   把混合 generation 当 complete。

verifier 同时受 H-004 的 file/byte/elapsed budgets 约束；timeout/short read/identity change，以及除已
证明 captured prefix ancestor 的 live-tail append 外的 post-verify ledger drift，都 fail visible。retained archive unreadable、gzip/row parse 失败或 digest mismatch
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
current-generation.json
```

producer 从同一 verified object 渲染 JSON/Markdown；`generation.json` 绑定 window、generation ID、
两个 renderer 的 restricted relative path、length/digest、`summary_digest` 与 ownership receipt identity。
发布顺序固定为 temp generation directory → 写两种 renderer/manifest → flush/fsync files → schema/digest
verify → fsync generation directory/parent → append+fsync ownership receipt → 在 lifecycle lock 内重新
no-follow capture 当前 pointer 的 expected identity（不存在时为 explicit absent state），再以 backend
提供的 atomic expected-identity/no-overwrite commit 提交 `current-generation.json` marker → fsync parent
→ success state。若当前 pointer 在 capture 后被替换、变成 symlink/foreign output，或 backend 不能证明
expected-identity commit，必须保留旧 pointer、nonzero/stale，不得退回 pathname-only replace。

consumer 只读取并验证 `current-generation.json` 指向的 immutable generation；不得分别追踪
`current.json`/`current.md`，也不得读取 orphan/partial generation。任一 renderer、manifest、receipt 或
pointer commit 失败都保留旧 pointer、nonzero/stale。receipt 只证明 ownership，不单独授予删除权：在
默认 `no_auto_delete` backend 上，失败 generation 必须保留为 orphan/candidate 并在达到 hard cap 前
停止新增 history；只有 B-042 `capability_attested` backend 能以同一 attested identity claim/retire
安全回收，不能从 receipt 或 pathname 单独推断可删除。
share export 同样只从 pointer 指向的 verified object 产生 H-005 allowlist projection。

## 8. Focused verification

- suspend/resume、clean shutdown、unclean reboot、clock uncertainty、open-slot boundary 与普通 nightly sleep；
- scheduled/manual authority namespace、unsupported manual start/status/generate/stop、历史 window partial；
- Claude/Codex launcher与 authorized-discard preflight 的 slot-before-work 顺序及 opt-out bypass；
- large archive async hashing 与 GC/writer contention 下的 exact installed wrapper P95 gate；
- archive corrupt terminal non-publish、missing/tombstone/snapshot-change partial 分支；
- zero taxonomy match、version-match/digest-mismatch 与 duplicate-ID tuple permutation；
- JSON-only、Markdown-only、manifest、receipt、pointer 各 crash barrier，consumer 永不看到 mixed generation；
  pointer replacement race、current-target retention pin、receipt-only orphan recovery 与 captured-prefix
  append/rotation fixture 必须分别证明 fail-closed 或保持旧 current。
