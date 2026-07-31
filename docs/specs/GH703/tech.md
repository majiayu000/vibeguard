# Tech Spec — 默认周度价值摘要、scheduler 生命周期与本地分享合同

## Linked Issue

GH-703

## Product Spec

[`product.md`](product.md)

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

H-003 还必须附闭集 taxonomy snapshot；H-004 必须附 window/timezone/catch-up
状态机；H-005 必须附 share allowlist；H-007 必须附 scheduler failure policy。
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
- category precedence 不作为消解机制：一个 event 匹配零项时进入明确
  unclassified/operational 路径，匹配多项直接 nonzero；
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

`data_status` closed 为 `ok`、`no_data`、`partial_coverage`。`counts` 在
`no_data` 或 `partial_coverage` 时必须为 null/absent（最终形状由获批 H-004 固定），
不能输出伪造的五个零；`ok` 又要求 complete coverage 且 `event_count > 0`。内部
artifact 可带 closed evidence digests；shareable projection 使用
同一 schema 的专用 `$defs.shareable` 或第二个 closed variant，只允许 H-005 的
窗口、coverage、taxonomy version、headline/other counts、generated time 与
`summary_digest`，不含 source digests 或本地身份。

### 3. Rust `observe weekly-value` producer

在 observe 模块新增 `weekly-value` 命令和独立未来模块路径
vibeguard-runtime/src/observe/weekly_value.rs：

1. CLI 必须取得显式 `--window-start`、`--window-end`、`--timezone`、`--scope
   global`、`--taxonomy` 和 output kind；scheduler 计算窗口，runtime 重新校验
   start < end、offset/timezone 一致和输入有界。
2. Reader 对 canonical global log 使用 writer/GC 已有的 `<log>.lock.d` 协议。
   在同一 bounded lock 内枚举所有可能包含 window 的 retained gzip archives 与
   live log，拒绝 symlink/非 regular file，打开只读 handle，并记录不可变的
   file identity、长度和 digest 后释放锁；GC/retention 也必须在同一协议内操作。
   后续只从这些已打开 handle 读取 snapshot 时记录的精确长度，任何缺失、损坏、
   超限、短读、枚举变化或无法证明封闭性
   都是 `partial_coverage`/error，不能退回只读 live log 后声称 complete。
3. `schemas/event-log.schema.json` 增加 closed schema v2。Rust 与 shell canonical
   writer 在首次 append 前必须持久化 `event_id`、`classification_status`、nullable
   `rule_id`、nullable `reason_code` 和 `classification_source`；block/value-eligible
   event 要求显式的 rule/reason identity。值必须来自作出 decision 的 typed 分支，
   不得由 `reason`/`detail` regex、substring 或 renderer 反推。这个最小合同由
   GH-703 自己实现；GH-704 可在将来消费/扩展，但不是批准或实现前置条件。
   `classification_status` closed 为 `classified|not_applicable|unclassified`，
   `classification_source` closed 为 `rust_decision|shell_decision`；`classified` 要求
   taxonomy 允许的非空 rule/reason identity，`not_applicable` 只允许明确不进入 value
   taxonomy 的 event，`unclassified` 使包含它的 window 无法成为 complete。typed field
   或 CSPRNG 生成失败时 writer 必须 fail visible，不能写一个看似合规的降级 row。
4. `event_id` 在 writer 边界由 OS CSPRNG 生成，形状为 `VG-EVT-` 加 32 位大写
   hex；同一已持久化 row 在 GC、gzip archive 与 compaction 中 byte-stable 保留。
   重读/复制按 `event_id` 去重，真实新 attempt 即使内容相同也生成新 ID。legacy v1、
   缺 ID 或冲突 ID 都不得用 path/archive/offset/content 补造；窗口 coverage 降级。
5. 先复用 GH-706 protocol classifier；其余 block 再按 taxonomy 的 exact
   decision/rule_id/reason_code 集分类。`non_protocol_blocks` 只做 arithmetic
   cross-check，绝不是 value category。
6. producer 验证每个 block 至多匹配一个 mapping，并校验
   `total_blocks = protocol_errors + operational_blocks + dangerous_ops +
   invented_apis + other_rule_blocks`。无法证明等式时 fail loud。
7. `event_set_sha256` 对按 `event_id` 排序的安全 canonical tuple 做
   schema-defined canonical UTF-8 JSON（固定 key 顺序、无 insignificant
   whitespace，数值字段仅允许整数）+ SHA-256，不包含 raw
   reason/payload/content。`summary_digest` 只对 window、scope、taxonomy/producer
   schema、event-set digest 与 counts 的稳定内容投影使用同一 canonical encoding +
   SHA-256，明确排除 `generated_at`、attempt/retry time、freshness 与 renderer metadata。
8. internal JSON、shareable JSON 与 Markdown 都从同一个已验证 object 渲染；
   Markdown 不扫描 logs 或 taxonomy。`--shareable` 只做 allowlist projection。

现有 `summary` / `health` / `session` 与
`schemas/observe-output.schema.json` 保持兼容；weekly-value 用独立 schema，不把
share 字段挤入现有 `additionalProperties: false` contract。

### 4. Wrapper、文件布局与 atomic publish

复用 `scripts/health-report-scheduled.sh`，新增 closed
`--surface health|value`：

- 缺省仍为 `health`，保持 GH-556 手工/既有 job 兼容；
- default value job 总是显式传 `--surface value`、exact window 和 installed
  runtime/taxonomy paths；
- value artifacts 固定在
  `~/.vibeguard/reports/value/history/<window-id>.{json,md}`，
  `current.json` / `current.md` 是 atomic owned files 或安全 relative symlink；
- 自动 scheduler 不预先创建 shareable artifact；用户显式调用 export 后，才从
  已验证 current object 生成 allowlisted projection，并以 user-only 权限写入
  用户指定的新本地文件；
- temp file 在同目录创建，mode 0600，写完后 flush/fsync、schema validate 和
  digest verify，再 atomic rename；任何失败保留上一个 current 并记录 stale；
- scheduler attempt/success 只写 closed state/time/digest，不写 raw stderr、
  path、event 或 reason。

每次 atomic publish 还要在独立、append-only、versioned 的
`~/.vibeguard/weekly-value/ownership.jsonl` 中提交 owned-artifact receipt；未来路径
weekly-value ownership schema 约束 `artifact_id`、受限相对路径、创建时 schema/version、
artifact digest、owner nonce 与 ledger chain digest。mutable lifecycle
state 只记录已提交 ledger head，不作为唯一 ownership 证据。
历史 retention 只按 receipt 与路径绑定证明 ownership，再应用获批上限；不能要求
artifact 通过当前 summary schema。旧 schema 或内容损坏但 receipt 完整的 owned
artifact 仍可有界清理；receipt 损坏/矛盾时停止删除、state=`broken`，未知文件和显式
exports 保留。receipt/state/publish 必须通过同一 pending→atomic commit 恢复协议。

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
- `data_status`: `ok|no_data|partial_coverage|null`，其中 null 只允许尚无 attempt 的
  closed lifecycle 组合；三个维度分别验证，禁止彼此覆盖；
- approved consent/platform/window/taxonomy version；
- owned job identity、expected target digest、install mode；
- last attempt/success/window/summary digest；
- migration source（none / legacy missing field / explicit prior value state）；
- versioned ownership ledger head 与 pending transaction identity；
- `recovery_reason` closed 为
  `none|rollback_disabled|target_drift|apply_failed|probe_failed|evidence_invalid`，
  `repair_action` closed 为 `none|manual_enable|repair_target|retry_install`；两者只
  解释 `broken` 的恢复路径，不形成新的 lifecycle state。

install/upgrade/enable/disable/clean、scheduled/manual generation、publish 与 retention
全部使用
`~/.vibeguard/weekly-value/.lifecycle.lock` 的 bounded exclusive lock。状态转换按
`plan → snapshot owned job/state → apply → scheduler probe → commit/rollback`
执行。probe 必须验证 manager 返回 active、target/arguments 正确、wrapper/runtime/
taxonomy 都存在且 digest 匹配；文件存在不算 active。失败只回滚本次 owned
changes，不覆盖第三方 actor 的新内容。

generator 在取得 lifecycle lock 后才能固定 source handles，并持锁完成 validate、
history/current publish、ownership receipt 与 success state commit。disable/clean 先取得
同一 lock，阻止新 generator，再停止/验证 scheduler inactive，最后删除 owned control
state；超时、取消不确定或 late-publish 无法排除时 nonzero 且不得报告 lifecycle 成功。

### 6. Setup、upgrade、doctor 与 clean

在 `scripts/setup/install.sh` 的安装计划和最终确认中加入 weekly value 项：

- public `setup.sh` 继续作为唯一用户入口，必须把 weekly-value opt-out 与
  provenance/setup 参数原样委托到同一 `scripts/setup/install.sh` 路径，不新增
  平行 installer；
- H-001 recommendation 下，受支持平台默认 plan 为 enabled，显式
  `--no-weekly-value` 记录 `disabled_by_user`；
- `--yes` 只在输出完整 plan 后确认同一 plan，不允许环境变量静默强开；
- setup snapshot 同时安装 value wrapper、taxonomy/schema 和稳定 runtime target，
  scheduler 不指向可消失的临时 payload/checkout path；
- scheduler 失败时不输出 setup complete，并返回 nonzero；已成功的 core install
  可保留，但 weekly-value state 必须 rollback/broken 且可重试。

`scripts/setup/check.sh` 为 value surface 增加独立 doctor/verify section，验证
`scheduler_state`、`artifact_state`、`data_status` 三个正交维度，以及 job manager、
target digest、taxonomy、last attempt/success 和 current artifact schema/digest/
freshness。`verify-install` 在 H-001 recommendation 和支持
平台上把 `active|disabled_by_user` 按用户选择判定；broken/stale/未记录 consent
不得伪装 active。

`scripts/setup/clean.sh` 先取得 generation/retention 共用的 lifecycle lock，停止并
probe scheduler inactive，再只卸载 owned value job、删除 value state/current pointer，
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

2026-08-01（Asia/Shanghai）复核时 PR #732 仍为 open，head 为
`91ef1571921c9296473e8f8f52ccfa449d8da241`，merge state 为 `CLEAN`，Ubuntu、macOS、
Windows、Self-Application 与 Benchmark checks 均成功。该 bootstrap orphan-lease
结果仅是未来 implementation 的 distribution coordination 输入；开始实现前仍必须
重新固定其最终 merge/result 与 payload contract。GH-703 Draft、structured event v2
和本次 corrective 均不以 #732 合并为前提。

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
    "hooks/_lib/log_json.sh",
    "hooks/_lib/log_write.sh",
    "hooks/_lib/post_edit_history.sh",
    "hooks/analysis-paralysis-guard.sh",
    "hooks/circuit-breaker.sh",
    "hooks/count_active_constraints.sh",
    "hooks/log.sh",
    "hooks/post-build-check.sh",
    "hooks/pre-commit-guard.sh",
    "schemas/event-log.schema.json",
    "schemas/weekly-value-ownership.schema.json",
    "schemas/weekly-value-state.schema.json",
    "schemas/weekly-value-summary.schema.json",
    "schemas/weekly-value-taxonomy.schema.json",
    "scripts/CLAUDE.md",
    "scripts/gc/gc-logs.sh",
    "scripts/health-report-scheduled.sh",
    "scripts/install-health-report-scheduler.sh",
    "scripts/release/payload-manifest.txt",
    "scripts/setup/check.sh",
    "scripts/setup/clean.sh",
    "scripts/setup/com.vibeguard.weekly-value.plist",
    "scripts/setup/install.sh",
    "scripts/systemd/vibeguard-weekly-value.service",
    "scripts/systemd/vibeguard-weekly-value.timer",
    "setup.sh",
    "tests/fixtures/observability-schemas",
    "tests/fixtures/weekly-value",
    "tests/hooks/test_analysis_paralysis_guard.sh",
    "tests/hooks/test_count_active_constraints.sh",
    "tests/hooks/test_log_injection.sh",
    "tests/hooks/test_log_locking.sh",
    "tests/hooks/test_post_build_check.sh",
    "tests/hooks/test_post_edit_churn.sh",
    "tests/hooks/test_precommit_nested_roots.sh",
    "tests/setup/install_flow_tests.sh",
    "tests/setup/syntax_manifest_tests.sh",
    "tests/test_gc_logs_concurrent.sh",
    "tests/test_gc_logs_rotation.sh",
    "tests/test_health_report_scheduler.sh",
    "tests/test_observability_schemas.sh",
    "tests/test_observe.sh",
    "tests/test_payload.sh",
    "vibeguard-runtime/Cargo.lock",
    "vibeguard-runtime/Cargo.toml",
    "vibeguard-runtime/src/event_schema.rs",
    "vibeguard-runtime/src/hook_checks_common.rs",
    "vibeguard-runtime/src/hook_orchestrator.rs",
    "vibeguard-runtime/src/hook_orchestrator_learn.rs",
    "vibeguard-runtime/src/hook_orchestrator_post_edit.rs",
    "vibeguard-runtime/src/hook_orchestrator_post_edit_history.rs",
    "vibeguard-runtime/src/hook_orchestrator_post_write.rs",
    "vibeguard-runtime/src/hook_orchestrator_pre_bash.rs",
    "vibeguard-runtime/src/hook_orchestrator_pre_edit.rs",
    "vibeguard-runtime/src/hook_orchestrator_stop.rs",
    "vibeguard-runtime/src/observe/aggregate.rs",
    "vibeguard-runtime/src/observe/mod.rs",
    "vibeguard-runtime/src/observe/model.rs",
    "vibeguard-runtime/src/observe/read.rs",
    "vibeguard-runtime/src/observe/weekly_value.rs"
  ],
  "spec_refs": [
    "docs/specs/GH703/product.md",
    "docs/specs/GH703/tech.md",
    "docs/specs/GH703/tasks.md"
  ]
}
```

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 decisions are explicit and complete | Spec approval gate and H decision snapshot | focused workflow check rejects missing/double H selection before tasks; manual review compares selected values with updated manifest |
| B-002 default install produces scheduled summary after one install confirmation | setup plan + value scheduler integration | `bash tests/test_setup.sh` fresh macOS/Linux fixtures assert plan disclosure, one confirmation, active job and next-window artifact |
| B-003 narrow GH-556 supersession | surface dispatch in wrapper/installer | `bash tests/test_health_report_scheduler.sh` asserts standalone health remains opt-in/default-health while setup invokes explicit value surface |
| B-004 opt-out creates no job | setup option + weekly state | `bash tests/test_setup.sh` asserts `--no-weekly-value`, no manager entry and `disabled_by_user` |
| B-005 unsupported platform fail-visible | platform resolver | `bash tests/test_setup.sh` Windows/unknown fixture asserts no fallback job and `unsupported_platform` |
| B-006 one owned identity and third-party preservation | installer upsert/remove | `bash tests/test_health_report_scheduler.sh` repeated install plus third-party launchd/systemd fixtures |
| B-007 registration failure rollback | lifecycle snapshot/probe/rollback | `bash tests/test_setup.sh` launchd/systemd write/load/probe failure matrix; setup completion absent and owned before-state restored |
| B-008 exact half-open window metadata | weekly-value CLI parser and wrapper window calculator | `cargo test --manifest-path vibeguard-runtime/Cargo.toml weekly_value_window`; shell fixtures cover timezone/DST boundary |
| B-009 bounded catch-up and stable window idempotence | wrapper history/current commit + stable content projection | `bash tests/test_health_report_scheduler.sh` missed-run + repeated same-window fixture changes retry/generated times but reuses one digest-bound artifact |
| B-010 no-data/partial coverage has no counts | weekly-value producer + summary schema | `cargo test --manifest-path vibeguard-runtime/Cargo.toml weekly_value_no_data`; both states reject numeric headline counts in Markdown/JSON |
| B-011 corrupt evidence publishes nothing new | schema/taxonomy/state readers + atomic publisher | `bash tests/test_health_report_scheduler.sh` malformed log/taxonomy/state/current fixtures preserve old current and exit nonzero |
| B-012 taxonomy version/category closure | taxonomy schema and loader | schema tests plus `cargo test --manifest-path vibeguard-runtime/Cargo.toml weekly_value_taxonomy` unknown/missing/version mismatch cases |
| B-013 one category per event | Rust exact classifier | overlapping schema-valid taxonomy fixture exits nonzero; mapping-order permutations produce same result |
| B-014 dangerous_ops exact mapping | approved taxonomy dangerous entries | mixed fixture in `bash tests/test_observe.sh` excludes pass/warn/protocol/baseline/circuit-breaker |
| B-015 invented_apis exact mapping without text heuristic | approved taxonomy invented entries | `bash tests/test_observe.sh` uses identical free text with mapped/unmapped rule evidence and asserts only mapped event counts |
| B-016 full block accounting and GH-706 separation | aggregate cross-check + weekly classifier | `cargo test --manifest-path vibeguard-runtime/Cargo.toml weekly_value_accounting`; `bash tests/test_observe.sh` parity |
| B-017 stable canonical event identity dedupe | event v2 writer + live/archive reader | copied/rotated same `event_id` counts once; two writer-created retries count twice; path/offset changes do not affect identity |
| B-018 cross-render parity | one validated summary object + renderers | `bash tests/test_observe.sh` compares JSON/Markdown/current/share counts and digest for exact inputs |
| B-019 share field allowlist | shareable schema projection | schema-valid key-set positive and each-extra-field negative fixture |
| B-020 sensitive fields absent | share privacy firewall | adversarial sentinel scan in `bash tests/test_observe.sh` and `bash tests/test_health_report_scheduler.sh` |
| B-021 no automatic egress or clipboard | wrapper/runtime static and dynamic fixtures | `bash tests/test_payload.sh` PATH stubs fail on network/open/clipboard commands; explicit local writes still pass |
| B-022 secure atomic local writes | wrapper temp/permission/symlink checks | interrupted write, mode 0600, same-dir rename, symlink/non-owned-output negative fixtures |
| B-023 health/value surfaces independent | wrapper/installer closed surface dispatch | `bash tests/test_health_report_scheduler.sh` installs/disables each identity independently and compares outputs |
| B-024 bounded owned retention | durable ownership receipts + value history cleanup | stale/fresh/boundary/manual-export fixtures prove only receipt-bound expired history is removed |
| B-025 existing health job migration safety | migration detector | legacy launchd/cron fixtures remain byte-identical while new value state does not claim legacy consent |
| B-026 disabled state survives upgrade | weekly-value state schema + setup migration | two-version install fixture keeps `disabled_by_user`; missing-field fixture follows approved visible migration |
| B-027 legal transitions require probe | lifecycle transition gate | direct file injection/history-only/executable-only fixtures remain non-active; explicit enable + probe becomes active |
| B-028 concurrent lifecycle/generation serialization | shared bounded lifecycle lock | install/disable/clean racing generator/retention yields no late publish; one actor commits and the other visibly times out/rolls back |
| B-029 clean removes only owned control state | setup clean + installer remove | `bash tests/test_setup.sh` preserves third-party jobs/history/exports by default and deletes owned reports only with approved purge |
| B-030 doctor/verify orthogonal state truth | setup check three-dimension evaluator | matrix covers lifecycle × freshness × data status, including active+no_data and active+stale, plus target/digest drift |
| B-031 checkout/payload parity | payload manifest and no-clone smoke | `bash tests/test_payload.sh` exact schema/taxonomy/count/digest parity, no Python/network/checkout |
| B-032 host coverage from canonical contract | event normalization coverage filter | `bash tests/test_observe.sh` current clients accepted; unknown/incompatible/missing-identity evidence excluded with coverage gap |
| B-033 artifact evidence binding | stable content digest verifier + doctor/export | generated/attempt metadata changes preserve digest; tampered evidence/window/taxonomy changes alter/reject digest |
| B-034 interruption recovery | pending state + atomic publish/lifecycle recovery | kill-at-each-phase fixtures followed by retry leave one owned job/current artifact and no temp/pending success claim |
| B-035 closed live+archive snapshot | GC-compatible snapshot reader | `bash tests/test_gc_logs_rotation.sh` and concurrent fixtures cover cross-month/overflow archives, GC race, missing/corrupt archive and bounded scan |
| B-036 structured classification at creation | event schema v2 + Rust/shell writers | `bash tests/test_observability_schemas.sh`, hook fixtures and Rust unit tests require closed typed fields and reject free-text derivation |
| B-037 byte-stable event identity | writer-generated event ID + GC byte preservation | append→rotate→gzip→read fixture preserves ID; copy dedupes, real retry differs, legacy/duplicate ID downgrades coverage |
| B-038 headline publication gate | summary schema + all renderers | empty, partial and invalid evidence fixtures assert null/absent counts in internal/share/Markdown; complete nonempty evidence may contain true zero |
| B-039 stable summary digest | canonical stable-content projection | same evidence with different generated/attempt/renderer metadata yields identical digest; event/taxonomy/window changes differ |
| B-040 orthogonal state dimensions | state schema + doctor/verify | exhaustive valid/invalid combination table proves no dimension overwrites another and unknown combinations fail visible |
| B-041 generation/lifecycle exclusion | one lifecycle lock and pending transaction | deterministic barriers race publish/retention against disable/clean/upgrade; success is impossible before generator quiescence |
| B-042 version-independent ownership | versioned owned-artifact receipts | old-schema and corrupt-owned fixtures remain bounded; corrupt receipt stops deletion and all unknown/manual files remain byte-identical |

## 数据流

1. setup 展示包含 weekly value 的完整 plan；获批 consent/platform policy 决定
   enabled/disabled/unsupported，不能由 environment 默选。
2. setup 把 runtime、wrapper、taxonomy/schema 安装到 stable snapshot，在 lifecycle
   lock 内 plan/snapshot/apply/probe/commit 独立 value job 与 state。
3. scheduler 计算获批的 exact half-open window，并显式调用 installed wrapper 的
   `--surface value`。
4. wrapper 在 lifecycle lock 内打开一个封闭的 live+retained-archive source snapshot；
   reader 只接受 event schema v2 的 stable ID/typed classification evidence，legacy/
   corrupt/missing archive 使 coverage 降级且不发布 headline。
5. Rust `observe weekly-value` 按 `event_id` 去重，GH-706 classifier 先分 protocol，
   versioned taxonomy 再分 rule/operational categories；不解析 reason/detail。
6. producer 构造一个 schema-valid internal object，并从稳定内容投影计算 evidence/
   summary digests；generated/attempt/renderer metadata 不参与 identity。JSON、Markdown
   和后续显式 export 都从该 object 渲染。
7. wrapper 在同目录安全写 temp、验证、atomic publish history/current，原子提交
   ownership receipt 与 attempt/success state，再按 receipt 做 bounded retention。
8. doctor/verify 分别读取 scheduler lifecycle、artifact freshness 与 data status，并
   重新验证 manager、target、state、taxonomy 和 current artifact；
   explicit export 只从验证后的 current object 生成 allowlisted projection，
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
- **Performance**：周度扫描可能遇到大量 gzip archives。获批 H-004/H-007 必须固定
  file/byte/time budgets；snapshot 打开 handle 后可释放 GC lock，但 generator 仍持有
  lifecycle lock。任何超限只能 partial/failed，不能截断后声称 complete。
- **Concurrency / data loss**：GC rotation、generator publish 与 disable/clean 可能
  交错。source 使用既有 log lock，report lifecycle 使用单一 bounded lock，并用
  deterministic race fixtures 证明没有 missing archive 或 lifecycle 成功后的 late publish。
- **Maintenance**：taxonomy 与 GH-700 failure classes 可能漂移。版本、digest、
  release notes 和 shared closed names 可对齐，但两者 evidence source 保持分离。
- **Rollback**：回滚 default-on 不能删除用户 reports 或恢复旧 job 覆盖第三方状态；
  必须通过 owned lifecycle 将 value job disabled 并保留 health/manual surfaces。

## 测试计划

- [ ] Schema/unit：event v2、taxonomy、summary、state/ownership schema；Rust
  window/category/dedupe/accounting/canonical encoding/stable digest/render tests；critical
  privacy/classification paths 100%。
- [ ] Observe integration：Rust/shell typed writer parity、live+gzip archives、GC race、
  legacy identity、mixed categories、GH-706 protocol split、unknown host、no-data/
  partial、old/invalid taxonomy、cross-render parity 和 sentinel。
- [ ] Scheduler lifecycle：launchd/systemd plan/apply/probe/rollback、legacy health
  preservation、repeat/concurrent install、missed run、generation-vs-disable/clean race、
  receipt-based cross-version/corrupt retention、interrupt recovery。
- [ ] Setup lifecycle：默认 plan disclosure、`--no-weekly-value`、unsupported、
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
