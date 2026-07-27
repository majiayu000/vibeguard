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

推荐实现特意不让默认 value summary 依赖 Python：现有
`scripts/health-report.py` 继续作为 checkout/维护者 health surface；默认安装的
简洁 value summary 由已安装的 Rust runtime 从 canonical event log 生成。这样
GH-699 verified payload 不需要为了默认 retention surface 引入未声明的 Python
运行时依赖。

## Codebase Context

以下锚点在写作基线 `05ea122083e6bc4cc0b9fd3e2c168e576e8f431c`
逐项核实。

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Roadmap contract | `plan/2026-07-26-growth-and-architecture-roadmap.md:82`; `plan/2026-07-26-growth-and-architecture-roadmap.md:88` | WS5 要把 PR #572 的 opt-in report 变成默认且可分享的周度价值摘要 | 定义 GH-703 的用户结果，不授权具体 consent/privacy 选择 |
| Existing product contract | `docs/specs/GH556/product.md:28`; `docs/specs/GH556/product.md:33`; `docs/specs/GH556/product.md:51` | no-data/parse error 已 fail visible，但 scheduler 必须 opt-in 且默认不安装 | GH-703 只能显式、窄范围 supersede scheduler 默认值 |
| Health aggregator | `scripts/health-report.py:46`; `scripts/health-report.py:388`; `scripts/health-report.py:434`; `scripts/health-report.py:576`; `scripts/health-report.py:733` | Python 聚合 summary/health、precision、idle assets，生成完整 Markdown/JSON health report | 继续作为 maintainer surface；不能直接当 privacy-safe share projection |
| Scheduled wrapper | `scripts/health-report-scheduled.sh:14`; `scripts/health-report-scheduled.sh:105`; `scripts/health-report-scheduled.sh:113`; `scripts/health-report-scheduled.sh:114` | 固定调用 Python health report，按 UTC 日期写一个文件 | 可复用调度/atomic-output 入口，但需显式区分 `health` 与 `value` surface |
| Opt-in installer | `scripts/install-health-report-scheduler.sh:10`; `scripts/install-health-report-scheduler.sh:35`; `scripts/install-health-report-scheduler.sh:116`; `scripts/install-health-report-scheduler.sh:123`; `scripts/install-health-report-scheduler.sh:211` | 默认 dry-run；macOS launchd、其他平台 cron；job 指向 repo-relative wrapper | 需保留手动 health opt-in，同时新增独立 value identity、Linux systemd 和 stable installed target |
| launchd template | `scripts/setup/com.vibeguard.health-report.plist:5`; `scripts/setup/com.vibeguard.health-report.plist:10`; `scripts/setup/com.vibeguard.health-report.plist:19` | 唯一 `com.vibeguard.health-report` job，每周一 09:00 调 repo wrapper | 旧 health job 必须识别并保留；value job 使用不同 identity |
| Setup install | `scripts/setup/install.sh:388`; `scripts/setup/install.sh:415`; `scripts/setup/install.sh:418` | 初始化 install state；只处理 opt-in scheduled GC，没有 value scheduler | 默认 consent、owned state、snapshot target 和 failure gate 的接入点 |
| Setup check | `scripts/setup/check.sh:599`; `scripts/setup/check.sh:609` | 只检查 scheduled GC，不验证 health/value job 或 summary freshness | doctor/verify 六态需要新增独立检查 |
| Setup clean | `scripts/setup/clean.sh:100`; `scripts/setup/clean.sh:113`; `scripts/setup/clean.sh:133`; `scripts/setup/clean.sh:151` | clean 删除 installed snapshot/GC state；默认保留 projects/config；不卸载 health scheduler | value job/state/report ownership 和 purge 语义尚未定义 |
| Payload manifest | `scripts/release/payload-manifest.txt:19`; `scripts/release/payload-manifest.txt:29`; `scripts/release/payload-manifest.txt:44`; `scripts/release/payload-manifest.txt:58` | verified payload 包含 setup、hook-health 和 setup modules，但不含 health/value wrapper、installer、taxonomy 或 job templates | 当前 no-clone default install 无法产生周报 |
| Shared block aggregate | `vibeguard-runtime/src/observe/aggregate.rs:13`; `vibeguard-runtime/src/observe/aggregate.rs:53`; `vibeguard-runtime/src/observe/aggregate.rs:80`; `vibeguard-runtime/src/observe/aggregate.rs:279` | GH-706 已生成 block split、rule IDs 和 reason codes；non-protocol 是补集 | 可作为输入，但不能把 non-protocol 直接宣传成 dangerous/rule hit |
| Observe CLI | `vibeguard-runtime/src/observe/model.rs:8`; `vibeguard-runtime/src/observe/model.rs:55`; `vibeguard-runtime/src/observe/model.rs:77`; `vibeguard-runtime/src/observe/mod.rs:20`; `vibeguard-runtime/src/observe/mod.rs:45` | 只有 summary/health/session/export；默认 rolling window，没有 value-summary 命令 | 需要一个 exact-window、taxonomy-bound 的 Rust surface |
| Observe reader | `vibeguard-runtime/src/observe/read.rs:15`; `vibeguard-runtime/src/observe/read.rs:21`; `vibeguard-runtime/src/observe/read.rs:62`; `vibeguard-runtime/src/observe/read.rs:77` | reader 只返回 parsed object，丢弃 byte offset，且跳过 malformed/non-object row | weekly-value 需保留稳定 row identity，并以 strict mode 对无法分类的输入 fail loud |
| Observe schema | `schemas/observe-output.schema.json:6`; `schemas/observe-output.schema.json:23`; `schemas/observe-output.schema.json:46`; `schemas/observe-output.schema.json:68` | summary/health/session 共用 schema，包含 block split 和 top rule/reason counts | value/share 的字段和隐私边界不同，应使用独立 schema |
| Regression surfaces | `tests/test_observe.sh:110`; `tests/test_health_report.sh:142`; `tests/test_health_report_scheduler.sh:107`; `tests/setup/install_flow_tests.sh:12`; `tests/test_payload.sh:1` | 已覆盖 GH-706 parity、health no-data、opt-in job 和 payload install，但没有默认 value、privacy、taxonomy 或 migration matrix | 这些现有 harness 应扩展而非另起重复 setup 测试框架 |

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
    "dangerous_ops": 0,
    "invented_apis": 0,
    "other_rule_blocks": 0,
    "operational_blocks": 0,
    "protocol_errors": 0
  },
  "evidence": {
    "event_count": 0,
    "event_set_sha256": "<sha256>",
    "taxonomy_sha256": "<sha256>"
  },
  "generated_at": "2026-07-27T09:00:00+08:00",
  "summary_digest": "<sha256>"
}
```

`data_status` closed 为 `ok`、`no_data`、`partial_coverage`。`counts` 在
`no_data` 时必须为 null/absent（最终形状由获批 H-004 固定），不能输出伪造的
五个零。内部 artifact 可带 closed evidence digests；shareable projection 使用
同一 schema 的专用 `$defs.shareable` 或第二个 closed variant，只允许 H-005 的
窗口、coverage、taxonomy version、headline/other counts、generated time 与
`summary_digest`，不含 source digests 或本地身份。

### 3. Rust `observe weekly-value` producer

在 observe 模块新增 `weekly-value` 命令和独立未来模块路径
vibeguard-runtime/src/observe/weekly_value.rs：

1. CLI 必须取得显式 `--window-start`、`--window-end`、`--timezone`、`--scope
   global`、`--taxonomy` 和 output kind；scheduler 计算窗口，runtime 重新校验
   start < end、offset/timezone 一致和输入有界。
2. Reader 使用现有 canonical log selection；每个被纳入的 JSONL row 以
   `(selected log identity, byte offset, row digest)` 形成内部 event identity。
   重读同一 row 不重复，真实 retry 的新 row 可单独计数；identity 不进入 share。
3. 先复用 GH-706 protocol classifier；其余 block 再按 taxonomy 的 exact
   decision/rule_id/reason_code 集分类。`non_protocol_blocks` 只做 arithmetic
   cross-check，绝不是 value category。
4. producer 验证每个 block 至多匹配一个 mapping，并校验
   `total_blocks = protocol_errors + operational_blocks + dangerous_ops +
   invented_apis + other_rule_blocks`。无法证明等式时 fail loud。
5. `event_set_sha256` 对按 byte offset 排序的安全 canonical tuple 做
   schema-defined canonical UTF-8 JSON（固定 key 顺序、无 insignificant
   whitespace，数值字段仅允许整数）+ SHA-256，不包含 raw
   reason/payload/content；`summary_digest` 对去掉自身字段的 schema object
   使用同一 canonical encoding + SHA-256。
6. internal JSON、shareable JSON 与 Markdown 都从同一个已验证 object 渲染；
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

历史 retention 在持有 value lock 时只删除符合 owned filename/schema 且超过
获批上限的 history 文件。显式 exports 不参与自动 retention。

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

- `state`: `active|disabled_by_user|unsupported_platform|broken|stale|no_data`；
- approved consent/platform/window/taxonomy version；
- owned job identity、expected target digest、install mode；
- last attempt/success/window/summary digest；
- migration source（none / legacy missing field / explicit prior value state）。
- `recovery_reason` closed 为
  `none|rollback_disabled|target_drift|apply_failed|probe_failed|evidence_invalid`，
  `repair_action` closed 为 `none|manual_enable|repair_target|retry_install`；两者只
  解释 `broken` 的恢复路径，不形成新的 lifecycle state。

install/enable/disable/clean 使用
`~/.vibeguard/weekly-value/.lifecycle.lock` 的 bounded exclusive lock。状态转换按
`plan → snapshot owned job/state → apply → scheduler probe → commit/rollback`
执行。probe 必须验证 manager 返回 active、target/arguments 正确、wrapper/runtime/
taxonomy 都存在且 digest 匹配；文件存在不算 active。失败只回滚本次 owned
changes，不覆盖第三方 actor 的新内容。

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
六态、job manager、target digest、taxonomy、last attempt/success 和 current
artifact schema/digest/freshness。`verify-install` 在 H-001 recommendation 和支持
平台上把 `active|disabled_by_user` 按用户选择判定；broken/stale/未记录 consent
不得伪装 active。

`scripts/setup/clean.sh` 先在锁内卸载且只卸载 owned value job，删除 value state /
current pointer，再走现有 install cleanup。默认保留 history/share；现有
`--purge-data` 只有在 H-007 获批包含 value report data 后才删除 schema-valid
owned paths。clean 必须保留旧 GH-556 health job，除非用户显式调用该 surface 的
remove。

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
    "schemas/weekly-value-state.schema.json",
    "schemas/weekly-value-summary.schema.json",
    "schemas/weekly-value-taxonomy.schema.json",
    "scripts/CLAUDE.md",
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
    "tests/fixtures/weekly-value",
    "tests/setup/install_flow_tests.sh",
    "tests/setup/syntax_manifest_tests.sh",
    "tests/test_health_report_scheduler.sh",
    "tests/test_observe.sh",
    "tests/test_payload.sh",
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
| B-009 bounded catch-up and window idempotence | wrapper history/current commit | `bash tests/test_health_report_scheduler.sh` missed-run + repeated same-window fixture produces one byte-equivalent artifact |
| B-010 no-data/partial coverage | weekly-value producer | `cargo test --manifest-path vibeguard-runtime/Cargo.toml weekly_value_no_data`; schema-valid Markdown/JSON assertions |
| B-011 corrupt evidence publishes nothing new | schema/taxonomy/state readers + atomic publisher | `bash tests/test_health_report_scheduler.sh` malformed log/taxonomy/state/current fixtures preserve old current and exit nonzero |
| B-012 taxonomy version/category closure | taxonomy schema and loader | schema tests plus `cargo test --manifest-path vibeguard-runtime/Cargo.toml weekly_value_taxonomy` unknown/missing/version mismatch cases |
| B-013 one category per event | Rust exact classifier | overlapping schema-valid taxonomy fixture exits nonzero; mapping-order permutations produce same result |
| B-014 dangerous_ops exact mapping | approved taxonomy dangerous entries | mixed fixture in `bash tests/test_observe.sh` excludes pass/warn/protocol/baseline/circuit-breaker |
| B-015 invented_apis exact mapping without text heuristic | approved taxonomy invented entries | `bash tests/test_observe.sh` uses identical free text with mapped/unmapped rule evidence and asserts only mapped event counts |
| B-016 full block accounting and GH-706 separation | aggregate cross-check + weekly classifier | `cargo test --manifest-path vibeguard-runtime/Cargo.toml weekly_value_accounting`; `bash tests/test_observe.sh` parity |
| B-017 canonical row identity dedupe | log reader offset/digest identity | duplicate-read/same-row fixture counts once; two distinct retry rows count twice |
| B-018 cross-render parity | one validated summary object + renderers | `bash tests/test_observe.sh` compares JSON/Markdown/current/share counts and digest for exact inputs |
| B-019 share field allowlist | shareable schema projection | schema-valid key-set positive and each-extra-field negative fixture |
| B-020 sensitive fields absent | share privacy firewall | adversarial sentinel scan in `bash tests/test_observe.sh` and `bash tests/test_health_report_scheduler.sh` |
| B-021 no automatic egress or clipboard | wrapper/runtime static and dynamic fixtures | `bash tests/test_payload.sh` PATH stubs fail on network/open/clipboard commands; explicit local writes still pass |
| B-022 secure atomic local writes | wrapper temp/permission/symlink checks | interrupted write, mode 0600, same-dir rename, symlink/non-owned-output negative fixtures |
| B-023 health/value surfaces independent | wrapper/installer closed surface dispatch | `bash tests/test_health_report_scheduler.sh` installs/disables each identity independently and compares outputs |
| B-024 bounded owned retention | value history cleanup | stale/fresh/boundary/manual-export fixtures prove only owned expired history is removed |
| B-025 existing health job migration safety | migration detector | legacy launchd/cron fixtures remain byte-identical while new value state does not claim legacy consent |
| B-026 disabled state survives upgrade | weekly-value state schema + setup migration | two-version install fixture keeps `disabled_by_user`; missing-field fixture follows approved visible migration |
| B-027 legal transitions require probe | lifecycle transition gate | direct file injection/history-only/executable-only fixtures remain non-active; explicit enable + probe becomes active |
| B-028 concurrent lifecycle serialization | bounded lifecycle lock | two-writer contention/timeout fixture yields one committed job/state and one visible timeout |
| B-029 clean removes only owned control state | setup clean + installer remove | `bash tests/test_setup.sh` preserves third-party jobs/history/exports by default and deletes owned reports only with approved purge |
| B-030 doctor/verify six-state truth | setup check state evaluator | fixtures for active/disabled/unsupported/broken/stale/no_data plus target/digest/freshness drift |
| B-031 checkout/payload parity | payload manifest and no-clone smoke | `bash tests/test_payload.sh` exact schema/taxonomy/count/digest parity, no Python/network/checkout |
| B-032 host coverage from canonical contract | event normalization coverage filter | `bash tests/test_observe.sh` current clients accepted; unknown/incompatible/missing-identity evidence excluded with coverage gap |
| B-033 artifact evidence binding | internal/share digest verifier + doctor/export | tampered/stale/wrong-window/wrong-taxonomy fixtures rejected; unchanged current passes |
| B-034 interruption recovery | pending state + atomic publish/lifecycle recovery | kill-at-each-phase fixtures followed by retry leave one owned job/current artifact and no temp/pending success claim |

## 数据流

1. setup 展示包含 weekly value 的完整 plan；获批 consent/platform policy 决定
   enabled/disabled/unsupported，不能由 environment 默选。
2. setup 把 runtime、wrapper、taxonomy/schema 安装到 stable snapshot，在 lifecycle
   lock 内 plan/snapshot/apply/probe/commit 独立 value job 与 state。
3. scheduler 计算获批的 exact half-open window，并显式调用 installed wrapper 的
   `--surface value`。
4. wrapper 调用 Rust `observe weekly-value`；reader 选择 canonical global log，
   GH-706 classifier 先分 protocol，versioned taxonomy 再分 rule/operational
   categories。
5. producer 构造一个 schema-valid internal object并计算 evidence/summary digests；
   JSON、Markdown 和后续显式 export 都从该 object 渲染。
6. wrapper 在同目录安全写 temp、验证、atomic publish history/current，
   更新 attempt/success state，再按 owned retention 删除过期 history。
7. doctor/verify 重新读取 manager、target、state、taxonomy 和 current artifact；
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
  GH-706 first-pass split、accounting 等式与 no-data/partial 状态防止虚假 headline。
- **Compatibility**：旧 health job、缺 weekly 字段的 install state、checkout 和
  payload 可能漂移。独立 identity、显式 migration、stable snapshot 与 payload
  parity smoke 限制风险。
- **Platform**：launchd/systemd 的时区、DST、missed-run 与权限语义不同。窗口由
  wrapper 显式计算，runtime 复核；未获批平台 fail visible。
- **Performance**：周度扫描可能遇到大日志。producer 使用现有 bounded reader/
  limit 机制，但不得截断后仍声称 complete；超限应 partial/failed，并在后续 task
  固定预算。
- **Maintenance**：taxonomy 与 GH-700 failure classes 可能漂移。版本、digest、
  release notes 和 shared closed names 可对齐，但两者 evidence source 保持分离。
- **Rollback**：回滚 default-on 不能删除用户 reports 或恢复旧 job 覆盖第三方状态；
  必须通过 owned lifecycle 将 value job disabled 并保留 health/manual surfaces。

## 测试计划

- [ ] Schema/unit：taxonomy、summary、state schema；Rust window/category/dedupe/
  accounting/canonical encoding/digest/render tests；critical
  privacy/classification paths 100%。
- [ ] Observe integration：mixed categories、GH-706 protocol split、unknown host、
  no-data/partial、old/invalid taxonomy、cross-render parity 和 sentinel。
- [ ] Scheduler lifecycle：launchd/systemd plan/apply/probe/rollback、legacy health
  preservation、repeat/concurrent install、missed run、retention、interrupt recovery。
- [ ] Setup lifecycle：默认 plan disclosure、`--no-weekly-value`、unsupported、
  six-state doctor/verify、clean/purge ownership。
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
