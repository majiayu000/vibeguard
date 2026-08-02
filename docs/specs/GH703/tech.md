# Tech Spec — 默认周度价值摘要、scheduler 生命周期与本地分享合同

## Linked Issue

GH-703

## Product Spec

[`product.md`](product.md)

## Normative Coverage Contract

[`coverage_snapshot_contract.md`](coverage_snapshot_contract.md)

## Draft Gate

本文件描述 H-001 至 H-008 的 Draft recommendation 对应设计，不代表维护者已经
选择这些值。八项 decision 任一未获批时，`tasks.md`、implementation 和默认调度
变更都不得开始。维护者选择任一互斥备选后，必须先更新 product/tech、下面的
planned-changes manifest 和受影响 verification，再重新 review。

本次 corrective 只补强 merged PR #715 的 Draft 合同；写作基线为
`ce5bada07bda1ae72b5488fcf08be8982185a115`。它不批准任何 H decision、不创建
`tasks.md`、不实现默认调度，也不关闭 GH-703。当前 PR #732 的结果只在未来实施
开始前作为 GH-699 distribution 协调输入重新固定，不是本 Draft 的批准或硬依赖。

推荐实现特意不让默认 value summary 依赖 Python：现有
`scripts/health-report.py` 继续作为 checkout/维护者 health surface；默认安装的
简洁 value summary 由已安装的 Rust runtime 从 canonical event log 生成。这样
GH-699 verified payload 不需要为了默认 retention surface 引入未声明的 Python
运行时依赖。

## Codebase Context

以下锚点在写作基线 `ce5bada07bda1ae72b5488fcf08be8982185a115`
逐项核实。

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Roadmap contract | `plan/2026-07-26-growth-and-architecture-roadmap.md:82`; `plan/2026-07-26-growth-and-architecture-roadmap.md:88` | WS5 要把 PR #572 的 opt-in report 变成默认且可分享的周度价值摘要 | 定义 GH-703 的用户结果，不授权具体 consent/privacy 选择 |
| Existing product contract | `docs/specs/GH556/product.md:28`; `docs/specs/GH556/product.md:33`; `docs/specs/GH556/product.md:51` | no-data/parse error 已 fail visible，但 scheduler 必须 opt-in 且默认不安装 | GH-703 只能显式、窄范围 supersede scheduler 默认值 |
| Health aggregator | `scripts/health-report.py:140`; `scripts/health-report.py:205`; `scripts/health-report.py:391`; `scripts/health-report.py:466`; `scripts/health-report.py:581` | Python 聚合 summary/health、precision、idle assets，生成完整 Markdown/JSON health report | 继续作为 maintainer surface；不能直接当 privacy-safe share projection |
| Scheduled wrapper | `scripts/health-report-scheduled.sh:5`; `scripts/health-report-scheduled.sh:31`; `scripts/health-report-scheduled.sh:91`; `scripts/health-report-scheduled.sh:114` | 固定调用 Python health report，按 UTC 日期写一个文件 | 可复用调度/atomic-output 入口，但需显式区分 `health` 与 `value` surface |
| Opt-in installer | `scripts/install-health-report-scheduler.sh:23`; `scripts/install-health-report-scheduler.sh:35`; `scripts/install-health-report-scheduler.sh:116`; `scripts/install-health-report-scheduler.sh:145`; `scripts/install-health-report-scheduler.sh:203` | 默认 dry-run；macOS launchd、其他平台 cron；job 指向 repo-relative wrapper | 需保留手动 health opt-in，同时新增独立 value identity、Linux systemd 和 stable installed target |
| launchd template | `scripts/setup/com.vibeguard.health-report.plist:5`; `scripts/setup/com.vibeguard.health-report.plist:10`; `scripts/setup/com.vibeguard.health-report.plist:19` | 唯一 `com.vibeguard.health-report` job，每周一 09:00 调 repo wrapper | 旧 health job 必须识别并保留；value job 使用不同 identity |
| Setup install | `scripts/setup/install.sh:457`; `scripts/setup/install.sh:467`; `scripts/setup/install.sh:473`; `scripts/setup/install.sh:481` | 初始化 install state；只处理 opt-in scheduled GC，没有 value scheduler | 默认 consent、owned state、snapshot target 和 failure gate 的接入点 |
| Setup check | `scripts/setup/check.sh:603`; `scripts/setup/check.sh:619`; `scripts/setup/check.sh:694`; `scripts/setup/check.sh:704` | 只检查 scheduled GC，不验证 health/value job 或 summary freshness | doctor/verify 的正交状态需要新增独立检查 |
| Setup clean | `scripts/setup/clean.sh:100`; `scripts/setup/clean.sh:120`; `scripts/setup/clean.sh:403`; `scripts/setup/clean.sh:414` | clean 删除 installed snapshot/GC state；默认保留 projects/config；不卸载 health scheduler | value job/state/report ownership 和 purge 语义尚未定义 |
| Payload manifest | `scripts/release/payload-manifest.txt:1`; `scripts/release/payload-manifest.txt:19`; `scripts/release/payload-manifest.txt:44`; `scripts/release/payload-manifest.txt:60` | verified payload 包含 setup、hook-health 和 setup modules，但不含 health/value wrapper、installer、taxonomy 或 job templates | 当前 no-clone default install 无法产生周报 |
| Canonical event schema/writers | `schemas/event-log.schema.json:1`; `hooks/_lib/log_write.sh:243`; `vibeguard-runtime/src/event_schema.rs:1`; `vibeguard-runtime/src/hook_orchestrator.rs:609` | schema v1 的 `event_id`/`rule_id` 非必填且无 closed `reason_code`；shell/Rust writer 未持久化这些字段 | GH-703 必须自己建立最小 structured identity/classification producer 合同，不能从 free text 猜测 |
| GC/archive/locking | `scripts/gc/gc-logs.sh:70`; `scripts/gc/gc-logs.sh:196`; `vibeguard-runtime/src/hook_checks_common.rs:422`; `tests/test_gc_logs_rotation.sh:1`; `tests/test_gc_logs_concurrent.sh:1` | GC 会把 live rows 移入 gzip archives；writer/GC 已共享 `<log>.lock.d` 协议 | weekly snapshot 必须覆盖 live+archives，并与 GC/append 使用兼容锁和封闭 snapshot |
| Shared block aggregate | `vibeguard-runtime/src/observe/aggregate.rs:70`; `vibeguard-runtime/src/observe/aggregate.rs:258` | GH-706 的 rule/reason projection仍从 free-text reason 派生；non-protocol 是补集 | 只能做旧 summary compatibility，不能作为 GH-703 headline 的 canonical structured evidence |
| Observe CLI | `vibeguard-runtime/src/observe/model.rs:8`; `vibeguard-runtime/src/observe/model.rs:55`; `vibeguard-runtime/src/observe/model.rs:77`; `vibeguard-runtime/src/observe/mod.rs:20`; `vibeguard-runtime/src/observe/mod.rs:45` | 只有 summary/health/session/export；默认 rolling window，没有 value-summary 命令 | 需要一个 exact-window、taxonomy-bound 的 Rust surface |
| Observe reader | `vibeguard-runtime/src/observe/read.rs:21`; `vibeguard-runtime/src/observe/read.rs:48`; `vibeguard-runtime/src/observe/read.rs:62`; `vibeguard-runtime/src/observe/read.rs:90` | reader 只选一个 live log，跳过 malformed/non-object row，且不读取 gzip archives | weekly-value 需新增严格的 live+archive snapshot reader，不能把 storage offset 当 identity |
| Observe schema | `schemas/observe-output.schema.json:6`; `schemas/observe-output.schema.json:23`; `schemas/observe-output.schema.json:46`; `schemas/observe-output.schema.json:68` | summary/health/session 共用 schema，包含 block split 和 top rule/reason counts | value/share 的字段和隐私边界不同，应使用独立 schema |
| Regression surfaces | `tests/test_observe.sh:110`; `tests/test_health_report.sh:174`; `tests/test_health_report.sh:236`; `tests/test_health_report_scheduler.sh:107`; `tests/setup/install_flow_tests.sh:12`; `tests/test_payload.sh:1` | 已覆盖 GH-706 parity、health no-data/repeatability、opt-in job 和 payload install，但没有 archived evidence、structured producer、default value、privacy 或 migration matrix | 这些现有 harness 与 GC/schema fixtures 应扩展而非另起重复框架 |

## 推荐设计（待 H-001–H-008 批准）

### 1. Human-decision freeze

spec approval 必须把 H-001 至 H-008 的 selected value 写回 product/tech。若选择
与 recommendation 不同，先修改设计、planned paths 与 tests；不得让 task author
或 implementer 在 `tasks.md`、CLI 默认值、fixture 或环境变量中替维护者选项。

H-002 还必须附 local authority backend、availability provider、正整数 heartbeat cadence/max jitter/expiry、
`maximum_active_journal_entries`/`maximum_active_journal_bytes`/`maximum_active_journal_segments`、`expiry > cadence + max_jitter`与 owned job
identity；H-003 必须附闭集 taxonomy snapshot；H-004 必须附 window/timezone/catch-up
状态机、`empty_counts_representation=json_null|field_absent` 互斥选择、正整数
`maximum_query_window_duration_seconds`、`maximum_catch_up_duration_seconds` 与 `max_source_files`、`max_uncompressed_bytes`、
`max_snapshot_elapsed_ms`、`max_retained_archives`、`max_integrity_preflight_elapsed_ms`；H-005 必须附 share allowlist；H-007 必须附 scheduler/authority failure、recovery、
clean policy、正整数 `retention_horizon_seconds`/`hard_history_cap_entries`/`hard_history_cap_bytes` 及
retention backend policy，且 caps 必须包含 claim/receipt/lifecycle-terminal/pointer/checkpoint/orphan；选择 `capability_attested` 还须固定 backend identity/version/attestation contract。
缺任一 selection-specific 字段时 spec 仍是 Draft。

### 2. 两个独立 schema 与 versioned taxonomy

新增未来路径 schemas/weekly-value-taxonomy.schema.json，约束未来 taxonomy
数据路径 data/weekly-value-taxonomy.json：

- `schema_version` 与 `taxonomy_version`；
- closed categories：
  `dangerous_ops`、`invented_apis`、`other_rule_blocks`、
  `operational_blocks`、`protocol_errors`；
- 每条 mapping 固定 `category`、closed `decision` 集、closed `rule_ids` /
  `reason_codes`，并禁止 free-text pattern、regex 或 payload/content 条件；
- category precedence 不作为消解机制：typed event 匹配零项时固定为
  `unclassified_event` 并降级 coverage，不得回退 operational/other；匹配多项直接 nonzero；
- taxonomy file 本身的 raw-byte SHA-256 进入 summary evidence。

新增未来路径 schemas/weekly-value-summary.schema.json。内部 local artifact 的建议
envelope：

```json
{
  "schema_version": 1,
  "taxonomy_version": 1,
  "producer_version": "vX.Y.Z",
  "scope": "global",
  "window": {
    "start": "2026-07-20T00:00:00+08:00",
    "end": "2026-07-27T00:00:00+08:00",
    "timezone": "Asia/Shanghai",
    "coverage_status": "complete"
  },
  "data_status": "ok",
  "status_reason": "complete_nonempty",
  "counts": {
    "dangerous_ops": 1,
    "invented_apis": 0,
    "other_rule_blocks": 1,
    "operational_blocks": 0,
    "protocol_errors": 1
  },
  "evidence": {
    "event_count": 3,
    "event_set_sha256": "<sha256>",
    "taxonomy_sha256": "<sha256>"
  },
  "generated_at": "2026-07-27T09:00:00+08:00",
  "summary_digest": "<sha256>"
}
```

`data_status` closed 为 `ok`、`no_data`、`partial_coverage`；`status_reason` closed 为
`complete_nonempty|complete_empty|source_missing|ledger_gap|ledger_corrupt|
writer_coverage_unavailable|manual_pre_start|manual_post_seal|archive_missing|archive_tombstoned|
event_identity_conflict|incompatible_host|unknown_host|
unclassified_event|legacy_evidence|snapshot_changed|budget_exceeded`，禁止 free text 或扩展值。
`archive_corrupt|integrity_preflight_incomplete` 是 generator/state 的 closed terminal diagnostics，不是 summary schema
可发布 `status_reason`；命中时必须 nonzero、保留旧 current 并标 stale。`event_identity_missing` 同样只作为
schema-v2 required identity 缺失时的 closed terminal diagnostic，不在可发布 `status_reason` enum 中。
producer 必须先完成 candidate fact collection，再从所有适用的 partial reasons 按固定高到低顺序
`ledger_corrupt > writer_coverage_unavailable > manual_pre_start > manual_post_seal > ledger_gap > source_missing >
archive_missing > archive_tombstoned > event_identity_conflict > incompatible_host > unknown_host >
unclassified_event > legacy_evidence > snapshot_changed > budget_exceeded`
选择唯一 `status_reason`；扫描/枚举/错误发现顺序不得改变选择。`complete_empty` 或
`complete_nonempty` 只在 candidate set 没有任何 partial reason 且 coverage complete 时选择。
映射固定为 unknown host → `unknown_host`、known host/incompatible contract → `incompatible_host`、
schema-valid v2 `unclassified` → `unclassified_event`、同一 `event_id`对应不同 canonical tuple →
`event_identity_conflict`。声称 schema v2 却缺 required `event_id` 或任一 required typed identity 时产生 terminal
`event_identity_missing` 并按 B-011 nonzero/no-publish；只有真实 v1 row 缺 identity 才是 `legacy_evidence`。
manual window早于 start或晚于 seal分别 exact映射 `manual_pre_start|manual_post_seal`；同时命中以前者优先。
`no_data` 只允许 `coverage_status=complete`、`status_reason=complete_empty` 且 event set 为空；
任何 coverage 缺口优先产生 `partial_coverage`，即使 event set 同样为空。`counts` 在
`no_data` 或 `partial_coverage` 时必须严格使用 H-004 获批的
`empty_counts_representation`（`json_null` 或 `field_absent`，不可同时接受），
不能输出伪造的五个零；`ok` 又要求 complete coverage、`status_reason=complete_nonempty`
且 `event_count > 0`。内部
artifact 可带 closed evidence digests；shareable projection 使用
同一 schema 的专用 `$defs.shareable` 或第二个 closed variant，只允许 H-005 的
窗口、coverage、`data_status`、closed `status_reason`、taxonomy version、headline/other
counts、H-005 明确批准的 `generated_at` 与 `summary_digest`，不含 source digests 或本地身份。share renderer
不得删去状态字段；consumer 必须能区分 complete-empty 与每种 partial reason。

### 3. Rust `observe weekly-value` producer

在 observe 模块新增 `weekly-value` 命令和独立未来模块路径
vibeguard-runtime/src/observe/weekly_value.rs：

1. CLI 必须取得显式 `--window-start`、`--window-end`、`--timezone`、`--scope
   global`、`--taxonomy` 和 output kind；scheduler 计算窗口，runtime 重新校验
   start < end、offset/timezone 一致和输入有界。
2. Reader、coverage authority、trusted suspend/boot fence、standalone authorized-discard
   preflight、manual authority、ledger/compaction、immutable source generation 与 async bounded
   archive verification 必须完整实现
   [`coverage_snapshot_contract.md`](coverage_snapshot_contract.md)。`<log>.lock.d` 只保护短暂的
   generation/handle capture 与 post-verify generation recheck；archive hashing 不得在 writer/GC
   critical lock 内执行。所有 bounded retained archive先做 root/header/digest integrity preflight，成功后
   content scan才应用 query budgets；preflight incomplete/corrupt terminal no-publish，content budget partial；
   普通 sleep/reboot 只有在缺可信 fence 或 boundary proof 时才形成 coverage gap。
3. `schemas/event-log.schema.json` 增加 closed schema v2。Rust、shell 与 Python authorized-discard canonical
   writer 在首次 append 前必须持久化 `event_id`、`classification_status`、nullable
   `rule_id`、nullable `reason_code`、`classification_source`、
   `classification_contract_version` 与 `classification_contract_digest`；block/value-eligible
   event 要求显式的 rule/reason identity。值必须来自作出 decision 的 typed 分支，
   不得由 `reason`/`detail` regex、substring 或 renderer 反推。这个最小合同由
   GH-703 自己实现；GH-704 可在将来消费/扩展，但不是批准或实现前置条件。
   schema v2 required identity任何缺失都在 classification前 terminal拒绝，不能产生 publishable partial。
   `classification_status` closed 为 `typed|not_applicable|unclassified`，
   `classification_source` closed 为
   `rust_decision|shell_decision|python_authorized_discard_decision`；Python value 只允许
   `scripts/authorized-discard.py` 的 typed canonical boundary，不能作为任意 Python alias；其 top-level
   preflight 还必须按 coverage contract 在读取/执行 discard plan 前作为 slot owner 取得 durable authority
   ack，再把 token 交给 action/writer boundary。`typed` 只要求
   matching producer contract 允许的非空 rule/reason identity，不绑定
   event 创建后的任何 taxonomy snapshot；当前 taxonomy eligibility 始终由第 5 步 reader 计算。
   `not_applicable` 只允许明确不进入 value taxonomy 的 event，`unclassified` 使包含它的 window
   无法成为 complete。typed field/CSPRNG/append 失败必须进入第 2 步 durable gap protocol。
4. `event_id` 在 writer 边界由 OS CSPRNG 生成，形状为 `VG-EVT-` 加 32 位大写
   hex；同一已持久化 row 在 GC、gzip archive 与 compaction 中 byte-stable 保留。
   重读/复制按 `event_id` 去重，真实新 attempt 即使内容相同也生成新 ID。真实 v1 row 缺 ID 不得补造并以
   `legacy_evidence` partial；schema-v2 row 缺任一 required identity 是 terminal `event_identity_missing`；
   present ID 对应不同 canonical tuples 才是 `event_identity_conflict` partial。三者均不得用
   path/archive/offset/content 补造或互相回退。
5. schema v2 只按 closed typed mapping 分类：protocol branch 在 writer 当场持久化
   `reason_code=protocol_invalid_json|protocol_missing_field|protocol_invalid_shape|protocol_other`
   等由 event schema 固定的 code，weekly producer 只有在 producer registry 同时 exact-match
   `classification_contract_version` 与 `classification_contract_digest` 后，才按 exact
   decision/rule/reason 匹配 taxonomy；同版本但 digest 不匹配以及 taxonomy 零匹配都固定为
   `unclassified_event`。GH-706 `observe_is_protocol_error_block` free-text helper 仅作 legacy v1 display
   compatibility；legacy rows 已按第 2–4 步降级 coverage，绝不能进入 headline。其余 block 同样
   只按 typed fields 分类；`non_protocol_blocks` 只做 arithmetic cross-check，绝不是 value category。
6. producer 验证每个 block 至多匹配一个 mapping，并校验
   `total_blocks = protocol_errors + operational_blocks + dangerous_ops +
   invented_apis + other_rule_blocks`。无法证明等式时 fail loud。
7. `event_set_sha256` 对先按 `event_id`、再按完整 canonical tuple UTF-8 bytes 排序的安全 event set 做
   schema-defined canonical UTF-8 JSON（固定 key 顺序、无 insignificant
   whitespace，数值字段仅允许整数）+ SHA-256，不包含 raw
   reason/payload/content。同 ID/同 tuple 折叠；同 ID/不同 tuple 以完整 tuple 作确定性 tie-break 并产生
   `event_identity_conflict`，不能依赖 archive 顺序。`summary_digest` 只对 window、scope、taxonomy、exact
   `producer_version`、producer schema、`window.coverage_status`、`data_status`、closed
   `status_reason`、event-set digest 与 counts 的稳定内容投影使用同一 canonical encoding +
   SHA-256，明确排除 `generated_at`、attempt/retry time、freshness 与 renderer metadata。
8. internal JSON、shareable JSON 与 Markdown 都从同一个已验证 object 渲染；
   Markdown 不扫描 logs 或 taxonomy。`--shareable` 只做 allowlist projection。JSON/Markdown current
   必须遵循 coverage contract 的 immutable generation + 单一 create-only append-only pointer record，
   禁止两个 renderer各自推进 current或 pathname replace现有 pointer。

现有 `summary` / `health` / `session` 与
`schemas/observe-output.schema.json` 保持兼容；weekly-value 用独立 schema，不把
share 字段挤入现有 `additionalProperties: false` contract。
实现时必须逐一审计 planned manifest 中所有搜索出的 event v1 producer/consumer：shell/Rust
writers 与 append adapters、hook history/build/paralysis readers、observe/hook-status/session-metrics、
health/stats/metrics/quality/constraint/learn/false-positive consumers。legacy surface 继续读取 v1；
v2 新字段不得破坏它们，但只有 weekly-value headline 要求 v2 typed/coverage evidence。相关
focused shell 与 Rust CLI tests 必须同时覆盖 v1 compatibility、v2 preservation 和 unknown-version
fail-visible 行为，不能只验证新 weekly producer。

### 4. Wrapper、文件布局与 atomic publish

复用 `scripts/health-report-scheduled.sh`，新增 closed
`--surface health|value`：

- 缺省仍为 `health`，保持 GH-556 手工/既有 job 兼容；
- default value job 总是显式传 `--surface value`、exact window 和 installed
  runtime/taxonomy paths；
- value artifacts 与 current visibility 必须使用 coverage contract 的
  `history/<window-id>/<artifact_generation_id>/{summary.json,summary.md,generation.json}` 和
  `current-pointers/<pointer-sequence>-<pointer-id>.json` append-only chain；不得独立替换
  `current.json`/`current.md`或覆盖任何 existing pointer record。pointer schema是 JCS digest-linked
  `record_type=current_generation|no_current` closed union，exact固定 variant fields/predecessor/lifecycle/terminal；current
  由 committed receipt 授权，no-current 由同 generation 的 committed lifecycle-terminal proof 独立授权；
- 自动 scheduler 不预先创建 shareable artifact；用户显式调用 export 后，才从
  已验证 current object 生成 allowlisted projection，并以 user-only 权限写入
  用户指定的新本地文件；
- renderer bytes 物化前先提交绑定 exact identity/digests 与 entries/bytes 预留的 generation claim；再在
  同一受限 parent 建 mode-0700 temp generation，fsync+verify renderer/manifest，receipt/pointer 各以 `linkat` atomic
  no-replace hard link提交各自 prior-digest-linked final record并 fsync parent。recovery只接受 absent或完整 record并
  幂等 adopt exact pending sequence；collision/foreign/invalid target保留旧 logical pointer并 stale，禁止跳号/append/replace；
- scheduler attempt/success 只写 closed state/time/digest，不写 raw stderr、
  path、event 或 reason。

每次 generation publish 还要按 coverage contract 在独立、versioned 的 claim/receipt/pointer/checkpoint chains
以 prepared record+dirfsync、commit marker+dirfsync逐条提交；各 chain 的 seq0 prior digest 必须 null，后续 exact
连接前驱，reader 忽略 torn/uncommitted，lost-response 只 exact adopt。未来路径
weekly-value ownership schema 约束 CSPRNG `artifact_generation_id`（同时嵌入 generation manifest）、
两个 renderer 的受限相对路径、创建时 schema/version、各 artifact digest/length、publish 后由 no-follow opened handle 取得的
versioned file identity（platform file ID + device/inode/birth marker）、owner nonce 与 ledger
chain digest。mutable lifecycle state只记录已提交 receipt head，不作为唯一 ownership 证据。
标准 Linux/macOS 用户可写 pathname 没有 atomic compare-entry-identity + unlink capability；`openat2`/`openat`、
`renameat2(RENAME_NOREPLACE)`/`renameatx_np(RENAME_EXCL)` 与 post-rename reverify 仍有 source replacement 和
reverify→unlink race，默认 policy 必须是 `no_auto_delete`。只有 H-007 批准的 `capability_attested` backend 在
startup/runtime 证明 stable non-reusable object identity、atomic expected-identity claim、同 identity retire、
no-overwrite private quarantine、crash recovery 与 replacement-race evidence 全部可用时才 auto-retire；attestation
identity/version/digest写入 receipt，任一能力丢失立即降级且不得 pathname fallback。retention在 lifecycle lock内
先验证 pointer chain并 pin exact current generation/receipt/object identities；current target永不进入 candidate。
claim-only/pre-receipt/receipt-only orphan 和全部 audit metadata 均计入 hard caps；attested backend 只在
authenticated checkpoint 后 atomic retire folded prefix/orphan，默认 backend 保留且 cap 前停止新 history。
claim/receipt/pointer/checkpoint chain 损坏同样停止删除和新增 history，不改 `scheduler_state`。

### 5. 独立 scheduler identity 与状态机

扩展 `scripts/install-health-report-scheduler.sh` 支持
`--surface health|value`，但 standalone 缺省仍 dry-run，避免手工运行脚本时引入
新副作用。value surface 使用独立 identity：

- macOS：`com.vibeguard.weekly-value` 和新增
  `scripts/setup/com.vibeguard.weekly-value.plist`；
- Linux：新增 user units
  `scripts/systemd/vibeguard-weekly-value.service` 与
  `scripts/systemd/vibeguard-weekly-value.timer`；
- 不复用 `com.vibeguard.health-report`，也不改写第三方/未知同名文件。

状态固定在 `~/.vibeguard/weekly-value/state.json`，schema 由未来路径
schemas/weekly-value-state.schema.json 约束，至少包含：

- `scheduler_state`: `active|disabled_by_user|unsupported_platform|broken`；
- `artifact_state`: `current|stale|missing|invalid`；
- `data_status`: `ok|no_data|partial_coverage|null`，其中 null 只允许没有可信 completed
  data 的 `missing|invalid` artifact 组合；
- `retention_health`: `healthy|degraded|blocked|not_initialized`；`degraded` 表示 ledger chain
  有效但存在被保留的 legacy/identity-mismatch entry，`blocked` 表示 ledger/pending/head
  无法验证且全部自动删除暂停，`not_initialized` 只表示从未提交 ownership receipt；
  四个维度分别验证，禁止彼此覆盖；
- approved consent/platform/window/taxonomy version；
- owned job identity、expected target digest、install mode；
- last attempt/success/window/summary digest；
- migration source（none / legacy missing field / explicit prior value state）；
- versioned ownership ledger head 与 pending transaction identity；
- `recovery_reason` closed 为
  `none|rollback_disabled|target_drift|apply_failed|probe_failed|evidence_invalid`，
  `repair_action` closed 为 `none|manual_enable|repair_target|retry_install`；两者只
  解释 `broken` 的恢复路径，不形成新的 lifecycle state。

`scheduler_state` 不限制其它三个维度；每个 lifecycle 值只能与下表 26 个
artifact/data/retention combination 组合，因此形成 exact 4 × 26 closed legal matrix，
而不是由 renderer 猜测：

| `artifact_state` | legal `data_status` | legal `retention_health` | combination 数 | 语义 |
| --- | --- | --- | ---: | --- |
| `current` | `ok|no_data|partial_coverage` | `healthy|degraded|blocked` | 9 | current artifact 已验证；retention failure 不改变它的数据真值 |
| `stale` | `ok|no_data|partial_coverage` | `healthy|degraded|blocked` | 9 | 保留上一个已验证 artifact，但 freshness 不再成立 |
| `missing` | `null` | `healthy|degraded|blocked|not_initialized` | 4 | 没有可验证 current；history ledger 可独立存在或尚未初始化 |
| `invalid` | `null` | `healthy|degraded|blocked|not_initialized` | 4 | current evidence 不可验证，禁止沿用旧 data status；`not_initialized` 表示从未提交 receipt 但已有 malformed/foreign current |

其它 combination、unknown enum、缺任一维度均 schema-invalid，并在对应维度 fail visible；
例如 `active+current+no_data+blocked` 与 `disabled_by_user+stale+ok+degraded` 合法，
`active+missing+ok+healthy`、`current+ok+not_initialized` 非法。retention `blocked` 绝不把
健康 scheduler 改写为 scheduler `broken`。

install/upgrade/enable/disable/clean、scheduled/manual generation、publish 与 retention
全部使用
`~/.vibeguard/weekly-value/.lifecycle.lock` 的 bounded exclusive lock。状态转换按
`plan → snapshot owned job/state → apply → scheduler probe → commit/rollback`
执行。probe 必须验证 manager 返回 active、target/arguments 正确、wrapper/runtime/
taxonomy 都存在且 digest 匹配；文件存在不算 active。失败只回滚本次 owned
changes，不覆盖第三方 actor 的新内容。另保留不含 report/user data 的
`~/.vibeguard/weekly-value/lifecycle-generation.json`：每次 enable/disable/clean 以及
任何改变 wrapper/runtime/taxonomy/schema/generator inputs 的 upgrade 在 lock 内 monotonic
CAS generation，并写 lifecycle state + exact installed snapshot digest + owner nonce/digest；
clean 不删除该 fence。input-changing upgrade 在替换任何 input 前先提交 generation N+1
`upgrading` 以拒绝旧 token，成功后用 N+2 提交原 consent 对应的 enabled/disabled state 与
new snapshot digest；rollback 同样用 N+2（或更高）提交 restored snapshot，禁止复用旧 generation。

scheduled/manual generator 在等待 lifecycle lock 前捕获 admission 时的 exact generation +
installed snapshot digest token；取得 lock 后必须重开 fence：scheduled mode 验证 `state=enabled`；manual mode
只接受 coverage contract 中已由 `stop` durable封闭的 exact `manual_authority` epoch，并验证 terminal root、
stop boundary与全 parent quiescence proof，active或ambiguous epoch nonzero且不写。两者都须验证 matching
generation/snapshot，publish 前再次复核，然后才能固定 source handles，并持锁完成 validate、
history/current publish、ownership receipt 与 success state commit。disable/clean 先取得
同一 lock，先推进 generation fence 使所有既有/queued token 失效；clean 还必须对每个 active authority mode
执行 coverage contract 的 admission close、parent quiescence、terminal seal、resident stop 与存活证明，
再停止/验证 scheduler inactive，且只有全部 proof 通过后才可提交 terminal `disabled`/`cleaned` state、删除
owned control state 和写 no-current。generation fence 是防 late-publish 的非成功中间证据；quiesce/seal/stop
失败、取消不确定或 resident identity 无法重验时，保留该 fence 与可恢复 control state，禁止提交 terminal
cleaned/no-current 或报告 lifecycle 成功。操作开始前已启动但仍等待 lock 的 process 取得 lock 后必须因旧
token 退出且零 source/artifact write。超时或 late-publish 无法排除时 nonzero。tests 用 barrier 固定
“generator 已启动但尚未取得 lock”这一 race。

### 6. Setup、upgrade、doctor 与 clean

在 `scripts/setup/install.sh` 的安装计划和最终确认中加入 weekly value 项：

- public `setup.sh` 继续作为唯一用户入口，必须把 weekly-value opt-out 与
  provenance/setup 参数原样委托到同一 `scripts/setup/install.sh` 路径，不新增
  平行 installer；
- H-001 recommendation 下，受支持平台默认 plan 为 enabled，并显示 H-002 待批准的 heartbeat
  cadence/max jitter/expiry、availability provider 与 weekly output cadence；显式
  `--no-weekly-value` 记录 `disabled_by_user`；
- `--yes` 只在输出完整 plan 后确认同一 plan，不允许环境变量静默强开；
- setup snapshot 同时安装 value wrapper、taxonomy/schema 和稳定 runtime target，
  scheduler 不指向可消失的临时 payload/checkout path；
- scheduler 失败时不输出 setup complete，并返回 nonzero；已成功的 core install
  可保留，但 weekly-value state 必须 rollback/broken 且可重试。

`scripts/setup/check.sh` 为 value surface 增加独立 doctor/verify section，验证
`scheduler_state`、`artifact_state`、`data_status`、`retention_health` 四个正交维度，以及 job manager、
target digest、taxonomy、last attempt/success 和 current artifact schema/digest/
freshness。`verify-install` 在 H-001 recommendation 和支持
平台上把 `active|disabled_by_user` 按用户选择判定；broken/stale/未记录 consent
不得伪装 active。

unsupported 平台的 doctor 必须显示 coverage contract 的 exact manual command sequence：
`manual-authority start` 创建独立 epoch，`status` 验证 provider/heartbeat，`stop` quiesce并 durable封闭 epoch，
`generate` 只读选择 exact sealed epoch并接受任一通过 CLI 语法、边界与 budget 校验的显式 window；该 epoch
完整覆盖的 window 才能返回 `complete`，start前、跨未覆盖区间或 seal后结束的合法 window 返回无 headline 的
`partial_coverage`（terminal evidence仍 nonzero/no-publish）。它不安装 scheduler、不改 `scheduler_state`，
也不得拒绝合法历史 window、读取active epoch或把 start 前的 interval 报 complete。

`scripts/setup/clean.sh` 先取得 generation/retention 共用的 lifecycle lock，推进并 durable fsync generation
fence（不宣称 terminal clean 成功），再对每个 active authority mode（包括 manual）执行 coverage contract
规定的封闭 admission、parent quiescence、terminal seal、resident authority stop 与存活证明，然后停止并
probe scheduler inactive；resident-process proof 必须绑定 authority epoch、owner nonce、launch receipt 与
approved executable/snapshot digest，stop 后在释放 authority lock 前重新读取并校验该 identity；PID 或 pathname
单独不构成 proof，identity replacement、竞态或无法重验均失败。scheduler probe 不能替代 manual authority 的终止屏障。
只有全部 quiesce/seal/stop proof
通过后才 durable commit `cleaned` generation。任一 proof 缺失、resident identity 无法重验或状态不确定时必须
nonzero、保留该 generation fence 与 control state，禁止报告 clean 成功或提交 no-current tombstone。随后只卸载
owned value job、删除 value state并向 pointer chain append no-current tombstone（保留 chain与 generation fence），
然后走现有 install cleanup。默认保留 history/share；现有 `--purge-data` 只有在
H-007 获批包含 value report data 后，才按 durable ownership receipt 删除受限 owned
paths；不能以当前 artifact schema 是否 valid 代替 ownership。clean 必须保留旧
GH-556 health job，除非用户显式调用该 surface 的 remove。

### 7. GH-556 migration 与 GH-699 distribution

升级时先识别：

- 已存在 `com.vibeguard.health-report` / legacy cron marker：保留原参数和 opt-in
  语义，不迁移 consent，不改 identity；
- 已存在 valid weekly-value state：按 explicit enabled/disabled 更新同一 job；
- 旧 install state 没有 weekly-value 字段：按 H-001 最终批准的 migration
  显式显示一次，不把字段缺失当作 consent。

`scripts/release/payload-manifest.txt` 必须加入 public `setup.sh`、value wrapper、
installer、taxonomy/schema、launchd/systemd templates 和 setup runtime
dependencies。
`tests/test_payload.sh` 要从本地 payload fixture 完成 install → scheduler probe →
synthetic canonical log → scheduled value summary → doctor → clean，全程禁止
network/Python/repository checkout。GH-699 T3–T7 可以与本 spec 分 tranche，但两者
若同时修改 payload/setup surface 必须串行集成，不能各自维护不同 manifest。

PR #732 的 branch head、merge state与 check rollup是 mutable remote evidence，不进入 GH-703 normative
contract，也不得从本段快照推导 readiness。未来 implementation开始前必须重新查询 live PR、固定当时 exact
head/result与最终 payload contract，并把查询时间/证据留在 implementation handoff；PR变化即使旧 evidence
失效。GH-703 Draft、structured event v2和本次 corrective均不以 #732合并为前提。

### 8. Privacy/export firewall

自动路径不增加 network library/curl/gh/browser/open/pbcopy 调用。测试为 project
name/hash、absolute path、session/event ID、rule ID、free-text reason、command、
content、prompt 和 token 注入不同 sentinel，分别扫描 internal/share Markdown 与
JSON：

- internal artifact 只能保留 schema 明确允许的 closed fields/digests；
- share artifact 对所有 sentinel 必须零命中，且 object key set 精确等于
  allowlist；
- 命令 trace/diagnostic 也不得包含 raw event；
- explicit export 只从已验证 current object 生成并验证 allowlisted projection，
  再写入用户给定的新文件；不接受 URL，不执行 upload，不覆盖 symlink/既有文件。

## Planned Changes Manifest

下列 manifest 对应 **Draft recommendation**，且必须在任一 H decision 改变时先
更新。它只描述未来 implementation scope；本 spec PR 不实施这些路径。

<!-- specrail-planned-changes -->
```json
{
  "issue": 703,
  "complete": true,
  "paths": [
    "README.md",
    "data/weekly-value-taxonomy.json",
    "docs/README_CN.md",
    "docs/command-schemas.md",
    "docs/how/quickstart.md",
    "docs/how/team-rollout.md",
    "docs/reference/observability-harness.md",
    "hooks/CLAUDE.md",
    "hooks/_lib/codex_runner.sh",
    "hooks/_lib/log_json.sh",
    "hooks/_lib/log_write.sh",
    "hooks/_lib/post_edit_history.sh",
    "hooks/analysis-paralysis-guard.sh",
    "hooks/circuit-breaker.sh",
    "hooks/count_active_constraints.sh",
    "hooks/log.sh",
    "hooks/post-build-check.sh",
    "hooks/pre-commit-guard.sh",
    "hooks/run-hook-codex.sh",
    "hooks/run-hook.sh",
    "schemas/event-log-coverage.schema.json",
    "schemas/event-log.schema.json",
    "schemas/weekly-value-ownership.schema.json",
    "schemas/weekly-value-pointer.schema.json",
    "schemas/weekly-value-state.schema.json",
    "schemas/weekly-value-summary.schema.json",
    "schemas/weekly-value-taxonomy.schema.json",
    "scripts/CLAUDE.md",
    "scripts/authorized-discard.py",
    "scripts/ci/validate-hook-perf.sh",
    "scripts/constraints/count_active_constraints.py",
    "scripts/gc/gc-logs.sh",
    "scripts/gc/gc-rule-budget.sh",
    "scripts/health-report-scheduled.sh",
    "scripts/health-report.py",
    "scripts/hook-health.sh",
    "scripts/install-health-report-scheduler.sh",
    "scripts/learn/analyze.py",
    "scripts/metrics/metrics-exporter.sh",
    "scripts/quality-grader.sh",
    "scripts/release/payload-manifest.txt",
    "scripts/report-false-positive.py",
    "scripts/setup/check.sh",
    "scripts/setup/clean.sh",
    "scripts/setup/com.vibeguard.weekly-value.plist",
    "scripts/setup/install.sh",
    "scripts/stats.sh",
    "scripts/systemd/vibeguard-weekly-value.service",
    "scripts/systemd/vibeguard-weekly-value.timer",
    "setup.sh",
    "tests/fixtures/observability-schemas",
    "tests/fixtures/weekly-value",
    "tests/codex_runtime/authority_handoff_tests.sh",
    "tests/codex_runtime/native_permission_patch_tests.sh",
    "tests/hooks/test_analysis_paralysis_guard.sh",
    "tests/hooks/test_count_active_constraints.sh",
    "tests/hooks/test_log_injection.sh",
    "tests/hooks/test_log_locking.sh",
    "tests/hooks/test_log_timer.sh",
    "tests/hooks/test_post_build_check.sh",
    "tests/hooks/test_post_edit_churn.sh",
    "tests/hooks/test_pre_bash_guard.sh",
    "tests/hooks/test_pre_edit_guard.sh",
    "tests/hooks/test_precommit_nested_roots.sh",
    "tests/hooks/test_precommit_authority.sh",
    "tests/hooks/test_run_hook_authority.sh",
    "tests/setup/authority_clean_tests.sh",
    "tests/bench_hook_latency.sh",
    "tests/setup/install_flow_tests.sh",
    "tests/setup/syntax_manifest_tests.sh",
    "tests/test_authorized_discard.sh",
    "tests/test_gc_logs_concurrent.sh",
    "tests/test_gc_logs_rotation.sh",
    "tests/test_gc_scheduled.sh",
    "tests/test_health_report.sh",
    "tests/test_health_report_scheduler.sh",
    "tests/test_hook_health.sh",
    "tests/test_hook_perf_contract.sh",
    "tests/test_hook_status.sh",
    "tests/test_learn_adoption.sh",
    "tests/test_observability_schemas.sh",
    "tests/test_observe.sh",
    "tests/test_payload.sh",
    "tests/test_quality_grader.sh",
    "tests/test_report_false_positive.sh",
    "tests/test_setup.sh",
    "tests/test_stats.sh",
    "vibeguard-runtime/Cargo.lock",
    "vibeguard-runtime/Cargo.toml",
    "vibeguard-runtime/src/event_coverage.rs",
    "vibeguard-runtime/src/event_coverage_tests.rs",
    "vibeguard-runtime/src/event_schema.rs",
    "vibeguard-runtime/src/hook_checks.rs",
    "vibeguard-runtime/src/hook_checks_bash.rs",
    "vibeguard-runtime/src/hook_checks_common.rs",
    "vibeguard-runtime/src/hook_checks_history.rs",
    "vibeguard-runtime/src/hook_checks_tests.rs",
    "vibeguard-runtime/src/hook_checks_write.rs",
    "vibeguard-runtime/src/hook_checks_write_tests.rs",
    "vibeguard-runtime/src/hook_input_diag.rs",
    "vibeguard-runtime/src/hook_orchestrator.rs",
    "vibeguard-runtime/src/hook_orchestrator_context.rs",
    "vibeguard-runtime/src/hook_orchestrator_learn.rs",
    "vibeguard-runtime/src/hook_orchestrator_post_edit.rs",
    "vibeguard-runtime/src/hook_orchestrator_post_edit_history.rs",
    "vibeguard-runtime/src/hook_orchestrator_post_edit_history_tests.rs",
    "vibeguard-runtime/src/hook_orchestrator_post_edit_history_unit_tests.rs",
    "vibeguard-runtime/src/hook_orchestrator_post_write.rs",
    "vibeguard-runtime/src/hook_orchestrator_pre_bash.rs",
    "vibeguard-runtime/src/hook_orchestrator_pre_edit.rs",
    "vibeguard-runtime/src/hook_orchestrator_stop.rs",
    "vibeguard-runtime/src/hook_status.rs",
    "vibeguard-runtime/src/hook_status_render.rs",
    "vibeguard-runtime/src/hook_status_tests.rs",
    "vibeguard-runtime/src/lib.rs",
    "vibeguard-runtime/src/log_append.rs",
    "vibeguard-runtime/src/log_query.rs",
    "vibeguard-runtime/src/log_scope.rs",
    "vibeguard-runtime/src/main.rs",
    "vibeguard-runtime/src/observe/aggregate.rs",
    "vibeguard-runtime/src/observe/mod.rs",
    "vibeguard-runtime/src/observe/model.rs",
    "vibeguard-runtime/src/observe/prometheus.rs",
    "vibeguard-runtime/src/observe/read.rs",
    "vibeguard-runtime/src/observe/render.rs",
    "vibeguard-runtime/src/observe/stats_summary.rs",
    "vibeguard-runtime/src/observe/weekly_value.rs",
    "vibeguard-runtime/src/session_metrics/engine.rs",
    "vibeguard-runtime/src/session_metrics/mod.rs",
    "vibeguard-runtime/src/session_metrics/signals.rs",
    "vibeguard-runtime/src/session_metrics/tests/mod.rs",
    "vibeguard-runtime/src/session_metrics/tests/run.rs",
    "vibeguard-runtime/src/session_metrics/tests/time.rs",
    "vibeguard-runtime/src/session_metrics/time.rs",
    "vibeguard-runtime/tests/cli.rs",
    "vibeguard-runtime/tests/cli_hook_checks.rs",
    "vibeguard-runtime/tests/cli_hook_orchestrator.rs",
    "vibeguard-runtime/tests/cli_hook_post_edit.rs",
    "vibeguard-runtime/tests/cli_hook_pre_edit.rs",
    "vibeguard-runtime/tests/cli_log_commands.rs",
    "vibeguard-runtime/tests/hook_status_cli.rs",
    "vibeguard-runtime/tests/observe_cli.rs"
  ],
  "spec_refs": [
    "docs/specs/GH703/coverage_snapshot_contract.md",
    "docs/specs/GH703/product.md",
    "docs/specs/GH703/tech.md",
    "docs/specs/GH703/tasks.md"
  ]
}
```

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 decisions are explicit and complete | Spec approval gate and H decision snapshot | rejects missing H-002 entries/bytes/segments、H-004 retained/preflight/content budgets、H-007 retention/backend before tasks |
| B-002 default install produces scheduled summary after one install confirmation | setup plan + value scheduler integration | `bash tests/test_setup.sh` fresh macOS/Linux fixtures assert summary + cadence/jitter/expiry/provider disclosure, one confirmation, active job and next-window artifact |
| B-003 narrow GH-556 supersession | surface dispatch in wrapper/installer | `bash tests/test_health_report_scheduler.sh` asserts standalone health remains opt-in/default-health while setup invokes explicit value surface |
| B-004 opt-out creates no job | setup option + weekly state | `bash tests/test_setup.sh` asserts `--no-weekly-value`, no manager/authority/slot, no per-event coverage diagnostic and `disabled_by_user`; later enable starts a new partial epoch |
| B-005 unsupported platform fail-visible | platform resolver + manual authority | pre-start/post-seal map exactly to `manual_pre_start|manual_post_seal`，cross-boundary precedence fixed；active epoch zero-write |
| B-006 one owned identity and third-party preservation | installer upsert/remove | `bash tests/test_health_report_scheduler.sh` repeated install plus third-party launchd/systemd fixtures |
| B-007 registration failure rollback | lifecycle snapshot/probe/rollback | `bash tests/test_setup.sh` launchd/systemd write/load/probe failure matrix; setup completion absent and owned before-state restored |
| B-008 exact half-open window metadata | weekly-value CLI parser and wrapper window calculator | `cargo test --manifest-path vibeguard-runtime/Cargo.toml weekly_value_window`; shell fixtures cover timezone/DST boundary |
| B-009 bounded catch-up and stable window idempotence | wrapper history/current commit + stable content projection | `bash tests/test_health_report_scheduler.sh` missed-run + repeated same-window fixture changes retry/generated times but reuses one digest-bound artifact |
| B-010 no-data/partial coverage has no counts | weekly-value producer + summary schema | `cargo test --manifest-path vibeguard-runtime/Cargo.toml weekly_value_no_data`; genesis empty source can be no-data，post-activation missing source is partial，且只接受 H-004 null/absent choice |
| B-011 corrupt evidence publishes nothing new | integrity preflight + readers/publisher | out-of-window retained mutation或 preflight incomplete terminal no-publish；成功后 content budget exhausted emits partial |
| B-012 taxonomy version/category closure | taxonomy schema and loader | schema tests plus `cargo test --manifest-path vibeguard-runtime/Cargo.toml weekly_value_taxonomy` unknown/missing/version mismatch cases |
| B-013 one category per event | Rust exact classifier | overlapping schema-valid taxonomy fixture exits nonzero; mapping-order permutations produce same result |
| B-014 dangerous_ops exact mapping | approved taxonomy dangerous entries | mixed fixture in `bash tests/test_observe.sh` excludes pass/warn/protocol/baseline/circuit-breaker |
| B-015 invented_apis exact mapping without text heuristic | approved taxonomy invented entries | `bash tests/test_observe.sh` uses identical free text with mapped/unmapped rule evidence and asserts only mapped event counts |
| B-016 full block accounting and GH-706 separation | aggregate cross-check + weekly classifier | `cargo test --manifest-path vibeguard-runtime/Cargo.toml weekly_value_accounting`; `bash tests/test_observe.sh` parity |
| B-017 stable canonical event identity dedupe | event v2 writer + live/archive reader | copied/rotated same `event_id` counts once; two writer-created retries count twice; path/offset changes do not affect identity |
| B-018 cross-render parity | one object + pointer union | fixtures exhaust receipt/pointer genesis、both variants required/forbidden、JCS digest、current receipt auth/no-current terminal auth；crash never exposes mixed renderers |
| B-019 share field allowlist | shareable schema projection | schema-valid key-set requires H-005-approved `generated_at` plus explicit `data_status` + closed `status_reason`, rejects missing/null/extra fields；digest verification binds stable status fields but excludes generated time |
| B-020 sensitive fields absent | share privacy firewall | adversarial sentinel scan in `bash tests/test_observe.sh` and `bash tests/test_health_report_scheduler.sh` |
| B-021 no automatic egress or clipboard | wrapper/runtime static and dynamic fixtures | `bash tests/test_payload.sh` PATH stubs fail on network/open/clipboard commands; explicit local writes still pass |
| B-022 secure atomic local writes | atomic source/authority + claim/receipt/pointer chains | bootstrap/journal/claim/record/marker/pointer/checkpoint crash barriers、lost-response replay、collision/symlink fixtures ignore torn/uncommitted and never duplicate |
| B-023 health/value surfaces independent | wrapper/installer closed surface dispatch | `bash tests/test_health_report_scheduler.sh` installs/disables each identity independently and compares outputs |
| B-024 bounded owned retention | claims + committed receipt/pointer checkpoints + caps | claim/pre-receipt/receipt-only orphan and audit metadata counted；attested prefix retirement；no-auto-delete cap-minus-one/cap/exceed stop |
| B-025 existing health job migration safety | migration detector | legacy launchd/cron fixtures remain byte-identical while new value state does not claim legacy consent |
| B-026 disabled state survives upgrade | weekly-value state schema + setup migration | two-version install fixture keeps `disabled_by_user`; missing-field fixture follows approved visible migration |
| B-027 legal transitions require probe | lifecycle transition gate | direct file injection/history-only/executable-only fixtures remain non-active; explicit enable + probe becomes active |
| B-028 concurrent lifecycle/generation serialization | shared bounded lifecycle lock | install/upgrade/disable/clean racing generator/retention yields no late publish；upgrade success/rollback advances generation and stale actor visibly exits |
| B-029 clean removes only owned control state | setup clean + installer remove | scheduled/manual quiesce/seal/stop proof后才 commit exact `no_current` with same-generation terminal authorization，forbids receipt/current fields，preserves audit/history/exports/third-party jobs |
| B-030 doctor/verify orthogonal state truth | setup check four-dimension evaluator | matrix covers lifecycle × freshness/data × retention health，including active+no_data+blocked-retention，plus target/digest/ownership drift |
| B-031 checkout/payload parity | payload manifest and no-clone smoke | `bash tests/test_payload.sh` exact schema/taxonomy/count/digest parity, no Python/network/checkout |
| B-032 host coverage from canonical contract | event normalization coverage filter | `bash tests/test_observe.sh` maps unknown/incompatible evidence to closed partial reasons；real v1 missing identity is `legacy_evidence` partial，schema-v2 missing required identity is terminal `event_identity_missing`/no-publish，present-ID conflicting tuples are `event_identity_conflict` partial |
| B-033 artifact evidence binding | stable content digest verifier + doctor/export | generated/attempt metadata changes preserve digest；tampered coverage/data/status reason/evidence/window/taxonomy changes alter/reject digest |
| B-034 interruption recovery | pending claim + atomic publish/lifecycle recovery | kill at pre-claim/pre-receipt/pointer/checkpoint phases；retry exact-adopts once；all orphan reservations remain cap-accounted |
| B-035 closed live+archive snapshot | coverage contract + real launchers/authority/reader | single-directory source bootstrap and record-per-file authority crash barriers；exact seq0；`test_precommit_authority.sh` proves reservation-before-guard/pre-slot rejection/one terminal；fan-out sibling isolation；segment cap/preflight |
| B-036 structured classification at creation | event schema v2 + producer registry + Rust/shell/Python writers | version+digest exact match and typed zero-match map `unclassified_event`；fixtures enforce v1 missing → `legacy_evidence` partial，v2 required-identity missing → terminal/no-publish，present-ID conflict → `event_identity_conflict` partial |
| B-037 byte-stable event identity | writer-generated event ID + GC byte preservation | append→rotate→gzip→read preserves ID; copy dedupes, retry differs；duplicate-ID tuple permutations keep one deterministic conflict digest |
| B-038 headline publication gate | summary schema + all renderers | empty/partial fixtures只接受 H-004 选中的 null 或 absent 形状且跨 renderer 一致；invalid evidence不发布；complete nonempty 可含真实零 |
| B-039 stable summary digest | canonical stable-content projection + fixed status precedence | simultaneous-fact and duplicate-ID/full-tuple permutations keep reason/digest；generated/attempt/renderer metadata changes preserve digest；exact coverage/data/status reason/producer version/event/taxonomy/window changes differ |
| B-040 orthogonal state dimensions | state schema + doctor/verify | exact 4 × 26 scheduler × artifact/data/retention table includes `invalid+null+not_initialized` and proves no dimension overwrites another；every omitted/extra/unknown combination fails visible |
| B-041 generation/lifecycle exclusion | lifecycle fence + short source lock + async verifier | publish/retention races remain fenced；archive hashing never holds writer/GC lock；max-byte archive + GC contention keeps installed wrapper latency within gate；queued stale token exits zero-write |
| B-042 current-object ownership | committed claim/receipt chain + pointer pin + checkpoints | ignores uncommitted/torn；claim-only/pre-receipt/receipt-only orphan counted；attested checkpoint retires exact prefix；default stops at cap |

## 数据流

1. setup 展示包含 weekly value 的完整 plan；获批 consent/platform policy 决定
   enabled/disabled/unsupported，不能由 environment 默选。
2. setup 把 runtime、wrapper、taxonomy/schema 安装到 stable snapshot，在 lifecycle
   lock 内 plan/snapshot/apply/probe/commit 独立 value job 与 state。
3. scheduler 计算获批的 exact half-open window，并显式调用 installed wrapper 的
   `--surface value`。
4. wrapper验证 authority/ledger后先对所有 bounded retained archive做 root/header/digest preflight；成功后才
   捕获 immutable handles并用 query budgets扫描 content，再重验 generation。preflight失败 terminal；budget partial。
5. Rust `observe weekly-value` 按 event ID +完整 canonical tuple 排序/去重，并以 event v2 的 exact typed
   decision/rule/reason/contract version+digest 做 closed protocol mapping；versioned taxonomy
   再分其余 rule/operational categories。GH-706 free-text classifier 只供 legacy display，
   producer 不解析 reason/detail，legacy evidence 不进入 headline。
6. producer 构造一个 schema-valid internal object，并从包含 coverage/data/status reason 的
   稳定内容投影计算 evidence/summary digests；generated/attempt/renderer metadata 不参与 identity。JSON、Markdown
   和后续显式 export 都从该 object 渲染。
7. wrapper在 generation bytes 前先提交 cap-reserving claim，再提交 receipt 与 JCS tagged pointer；retention pin current，
   checkpoint 全链并只在 attested backend retire exact prefix/orphan；默认保留且 cap 前停止。
8. doctor/verify 分别读取 scheduler lifecycle、artifact freshness、data status 与
   retention health，并
   重新验证 manager、target、state、taxonomy 和 current artifact；
   explicit export 只从验证后的 current object 生成包含 `data_status`/`status_reason` 的 allowlisted projection，
   并写入用户指定本地新文件。

自动生成与默认安装没有网络输出；GH-699 release 下载发生在其既有、单独的 verified
bootstrap 边界，不属于 summary producer。

## 备选方案

- **把现有 Python health report 原样 default-on**：拒绝作为 recommendation。
  payload 当前不含 Python/report dependencies，完整 health report 还包含不适合分享的
  precision、idle asset 与维护者细节，会把 GH-556 surface 和 GH-703 surface 混在
  一起。
- **把 `non_protocol_blocks` 直接显示为 dangerous ops**：拒绝。GH-706 明确该补集
  包含 baseline unreadable、circuit-breaker 和其他 operational blocks。
- **从 reason 文本匹配 “hallucinated/invented/dangerous”**：拒绝。free text 会
  漂移并可能含敏感数据；同一文案不能证明 canonical failure category。
- **等待 GH-704 提供 semantic evidence**：拒绝作为硬依赖。GH-703 的 headline
  正确性要求 producer 当场持久化最小 closed event/rule/reason identity；GH-704
  后续只能在兼容该合同的前提下扩展或消费。
- **用 path/archive/byte offset 作为 event identity**：拒绝。GC、gzip、compaction
  和复制会改变 storage coordinate；identity 必须在首次 append 时生成并随 row 保留。
- **复用 `com.vibeguard.health-report` job identity**：拒绝。会静默迁移现有 opt-in
  consent，并让 health/value enable/disable 无法独立审计。
- **Linux 继续默认写 cron**：非推荐。GH699 package install 和现有 setup 已有
  user-systemd 模式；直接改写 crontab 难以做稳定 target probe 与 state ownership。
  若维护者批准 cron，需更新 H-002、生命周期和 fixtures。
- **自动上传 shareable summary**：拒绝。roadmap 是 local-first，且本 issue 没有
  endpoint、identity、retention、deletion 或安全 disclosure 授权。
- **等待 GH-700/GH-701 全部完成**：拒绝作为硬依赖。taxonomy 可独立版本化，
  canonical logs 已覆盖当前 hosts；未来 benchmark/adapter 只能在保持本合同的前提下
  对齐或扩展。

## 风险

- **Security / privacy**：event reason、command、path、prompt 或 project identity
  进入 share 会造成数据泄露。缓解为 Rust closed classifier、allowlist projection、
  adversarial sentinel 和零自动 egress。
- **Consent / permissions**：默认 background job 是用户系统状态变化。H-001 必须由
  维护者批准；install plan、opt-out、owned identity、probe 和 clean 都必须明确，
  不能从 issue slogan 推断授权。
- **Truthfulness**：protocol/operational noise 会夸大产品价值。互斥 taxonomy、
  structured producer evidence、live+archive closed snapshot、accounting 等式与
  no-data/partial publication gate 防止虚假 headline。
- **Compatibility**：旧 health job、缺 weekly 字段的 install state、checkout 和
  payload 可能漂移。独立 identity、显式 migration、stable snapshot 与 payload
  parity smoke 限制风险。
- **Platform**：launchd/systemd 的时区、DST、missed-run 与权限语义不同。窗口由
  wrapper 显式计算，runtime 复核；未获批平台 fail visible。
- **Performance**：周度扫描可能遇到大量 gzip archives。获批 H-004 必须固定
  file/byte/time budgets；source lock 内只捕获 immutable generation/handles，archive hashing 在释放
  writer/GC lock 后 async bounded 执行并重验 generation。常驻 authority 的 durable reservation 与
  max-byte archive + concurrent GC fixture 必须共同通过仓库既有 exact installed wrapper P95/contract gates；
  任何超限只能 partial/failed，不能截断证据或以异步未落盘 ack 声称 complete。
- **Concurrency / data loss**：GC rotation、generator publish、coverage authority heartbeat 与
  disable/clean/upgrade 可能
  交错。source 使用既有短 log lock + immutable generation，report lifecycle 使用单一 bounded lock，并用
  deterministic race fixtures 证明没有 missing archive 或 lifecycle 成功后的 late publish。
- **Maintenance**：taxonomy 与 GH-700 failure classes 可能漂移。版本、digest、
  release notes 和 shared closed names 可对齐，但两者 evidence source 保持分离。
- **Rollback**：回滚 default-on 不能删除用户 reports 或恢复旧 job 覆盖第三方状态；
  必须通过 owned lifecycle 将 value job disabled 并保留 health/manual surfaces。

## 测试计划

- [ ] Schema/unit：event v2、coverage ledger/spool/authority heartbeat+attempt chain、taxonomy、summary、state/ownership schema；Rust
  window/category/dedupe/accounting/canonical encoding/stable digest/render tests；critical
  privacy/classification paths 100%。
- [ ] Observe integration：Rust/shell/Python authorized-discard typed writer parity、all searched v1 consumer compatibility、
  empty-source+genesis complete-empty、trusted suspend/resume/boot fence、parent-ID/durable-slot handoff、
  disabled/unsupported no scheduled authority、manual epoch/start-before-window boundary、later-enable partial epoch、
  dual ledger/spool loss unresolved sequence、closed host/classification/identity downgrade reasons、
  authority expiry/recovery gap、verified no-spawn、source/bootstrap+authority-record crash barriers、prefix capacity+segment early seal、manual two-reason precedence、hook-decision preservation、
  live+gzip immutable snapshot、async hash/GC race、duplicate-ID tuple permutation、contract version+digest mismatch、
  zero taxonomy match、legacy identity、mixed categories、GH-706 protocol split、unknown host、no-data/partial、
  old/invalid taxonomy、claim/receipt/pointer/checkpoint genesis+crash+cap parity、no-current terminal auth、pre-receipt orphan、all-retained preflight和 sentinel。
- [ ] Launcher authority：Planned Changes Manifest 的 `test_precommit_authority.sh` entry 独占 installed Git pre-commit parent 的
  `git_pre_commit` wrapper→canonical parent→durable slot、reservation-before-guard、pre-slot nonzero/zero-write/
  `guard_started=false` 与同 token exactly-one terminal outcome；Claude、Codex outer normalizer+inner fan-out与 standalone
  authorized-discard exact fixtures 覆盖 outer request+canonical hook+index→
  每 inner durable slot、duplicate拒绝、sibling crash隔离、pre-slot failure、quiescence seal 与 opt-out bypass；
  禁止 mock IPC/fsync。
- [ ] Scheduler lifecycle：launchd/systemd heartbeat+weekly-output plan/apply/probe/rollback、legacy health
  preservation、authority state ownership、repeat/concurrent install、missed run、generation-vs-disable/clean/upgrade race、
  current-target pin、claim/pre-receipt/receipt-only orphan+audit-prefix bounded accounting、same-path replacement、pre-clean/pre-upgrade queued generator fence、
  scheduled/manual clean quiesce/seal/stop and resident-process proof fixture、interrupt recovery。
- [ ] Setup lifecycle：默认 plan disclosure、H-002 cadence/jitter/expiry inequality/provider、
  `--no-weekly-value`、unsupported manual start/status/stop/sealed-generate、exact 4 × 26
  orthogonal-state doctor/verify matrix、clean/purge ownership。
- [ ] Payload：无 Python/checkout/network 的 unpacked payload install → scheduled
  summary → doctor → clean；checkout/payload exact semantic parity。
- [ ] Documentation：
  `bash scripts/ci/validate-doc-paths.sh` 与
  `bash scripts/ci/validate-doc-command-paths.sh`。
- [ ] Broad verification：
  `cargo fmt --manifest-path vibeguard-runtime/Cargo.toml -- --check`、
  `cargo check --manifest-path vibeguard-runtime/Cargo.toml`、
  `cargo test --manifest-path vibeguard-runtime/Cargo.toml`、
  `bash tests/test_observe.sh`、
  `bash tests/test_health_report.sh`、
  `bash tests/test_health_report_scheduler.sh`、
  `bash scripts/ci/validate-hook-perf.sh`、
  `bash tests/test_hook_perf_contract.sh`、
  `bash tests/bench_hook_latency.sh --runs=3 --confirmation-runs=3 --fail-on-regression`、
  `bash tests/test_payload.sh`、
  `bash tests/test_setup.sh`、
  `bash scripts/local-contract-check.sh --quick` 和 `git diff --check`。
- [ ] Real acceptance：获批 macOS/Linux install entry 各完成一次 fresh install；
  不额外 setup，跨过一个 exact window 后生成 summary；人工确认 consent 文案、
  no-data/partial 和本地 share artifact，不执行上传。

## 回滚方案

在 taxonomy 或 summary truthfulness 出现问题时，先 fail closed 停止新的 current/
share publish，并让 doctor 标为 broken/stale；不得回退到
`non_protocol_blocks == dangerous_ops` 或 text heuristic。

回滚默认调度时，在 lifecycle lock 内只卸载
`com.vibeguard.weekly-value` / 对应 user-systemd units，将 valid state 设为
`broken`、`recovery_reason=rollback_disabled`、
`repair_action=manual_enable`，并保留 history/share。现有
`com.vibeguard.health-report`、第三方 jobs、event logs 和手工 health report 不变。
若 target 或 state 已被外部 actor 修改，停止自动回滚并保持 `broken`，
记录 `recovery_reason=target_drift`、`repair_action=repair_target`，不得覆盖。

从 payload 移除 value files 前，先发布不会注册该 job 的 setup，并验证 upgrade/
clean 能移除旧 owned job；否则旧 scheduler 会指向不存在 target。H-001 至 H-008
任一选择改变时，旧 taxonomy/summary evidence 立即 stale，必须更新 spec、schema、
manifest 和 release communication 后重新批准，不能用旧 summary 证明新合同。
