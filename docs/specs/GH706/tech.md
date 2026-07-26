# Tech Spec — malformed-input 诊断隐私与共享 block 聚合

## Linked Issue

GH-706

## Product Spec

[`product.md`](product.md)

## Codebase Context

以下锚点均在 spec 写作时的 HEAD `180c5d1725ee1632388a5fef7c99ac9a90202ef1`
核实。

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Malformed diagnostic | `vibeguard-runtime/src/hook_input_diag.rs:10` | helper 区分三种 shape，但 invalid JSON 在 `vibeguard-runtime/src/hook_input_diag.rs:15` 原样拼接 payload head，合法 JSON 也会原样回显 tool/event 名称 | raw detail 会进入持久化路径，必须改为闭集结构元数据 |
| Bash / Write classification | `vibeguard-runtime/src/hook_checks_bash.rs:148`; `vibeguard-runtime/src/hook_checks.rs:86` | Bash 与 Write malformed path 共用 diagnostic；Write 在 `vibeguard-runtime/src/hook_checks.rs:118` 把 U-16 baseline read failure 也返回 `Malformed` | 需要保留 fail-closed，并把 baseline failure 从 protocol input failure 分离 |
| Event persistence | `vibeguard-runtime/src/hook_orchestrator_pre_bash.rs:16`; `vibeguard-runtime/src/hook_orchestrator.rs:198`; `vibeguard-runtime/src/hook_orchestrator.rs:596` | diagnostic detail 经 `append_hook_event` 写 project log，并在 `vibeguard-runtime/src/hook_orchestrator.rs:677` 复制到 global log | privacy 断言必须同时覆盖两个持久化目的地 |
| Shared observe aggregate | `vibeguard-runtime/src/observe/aggregate.rs:6`; `vibeguard-runtime/src/observe/aggregate.rs:19` | aggregate 只有 `decision_counts` 等通用计数，没有 block split | block 分类 helper 与三个计数应在这里生成一次 |
| Human / structured render | `vibeguard-runtime/src/observe/stats_summary.rs:17`; `vibeguard-runtime/src/observe/stats_summary.rs:338`; `vibeguard-runtime/src/observe/render.rs:19`; `vibeguard-runtime/src/observe/render.rs:288` | human renderer 本地按 reason 拆分；JSON 只序列化 `decision_counts` | 两种 renderer 必须消费同一个 aggregate 结果 |
| Observe JSON contract | `schemas/observe-output.schema.json:21`; `schemas/observe-output.schema.json:45` | schema `additionalProperties: false`，且只声明 `decision_counts` | 新增 optional `block_counts` property，不改变 required 集合 |
| Health consumer | `scripts/health-report.py:137`; `scripts/health-report.py:388`; `scripts/health-report.py:418`; `scripts/health-report.py:525` | report 消费 observe JSON 的 `decision_counts`，markdown 从同一 report object 渲染 | 消费 `block_counts` 并显式区分 available / unavailable / no_data；不新增 health schema 文件 |
| Regression coverage | `tests/hooks/test_pre_bash_guard.sh:142`; `tests/hooks/test_pre_write_guard.sh:28`; `vibeguard-runtime/src/hook_checks_bash.rs:397`; `vibeguard-runtime/src/hook_checks_tests.rs:158`; `tests/test_observe.sh:68`; `tests/test_health_report.sh:91` | 已覆盖 fail-closed 与基础 summary/report，但测试仍期待 raw tool name/head，且没有跨格式 parity、旧 runtime 或 baseline unreadable 负例 | 这些测试面承载 executable acceptance evidence |

## 设计方案

### 1. Privacy-safe diagnostic

- 删除 `MALFORMED_DIAG_HEAD_CHARS`、payload head 拼接与 raw `tool_name` /
  `hook_event_name` 回显。
- 让 `malformed_input_diagnostic` 只构造固定字段：`category`、受支持的
  `required_field`、非负 `input_size`，以及归一化的 `tool_name_class` /
  `hook_event_name_class`。分类值使用 Rust enum/closed match；已知值可映射到
  固定枚举，未知、缺失、空或类型错误只能映射到 `other` /
  `absent_or_invalid`。
- invalid JSON 不保留 parser free-text；若需要定位信息，只允许固定
  `json_error_class` 与非负 line/column 数值。任何 serializer 都不得接收 raw
  stdin、command、content、file path、parser message 或未知字符串。
- Bash 与 Write 继续输出原有 block decision/reason；只替换持久化 detail 的
  安全结构。hook tests 用独特 secret/command/content sentinel，分别断言
  project 与 global `events.jsonl` 中不存在这些值。

### 2. U-16 baseline unreadable 独立分支

- 在 `PreWriteCheck` 增加独立的 `U16BaselineUnreadable` variant；读取失败仍从
  orchestrator 产生 block，但使用固定 reason/category，不复用
  `Malformed hook input`，detail 不携带 file path 或 OS error free text。
- aggregate protocol classifier 将该新 reason 明确视为 non-protocol。读取
  legacy logs 时，对 PR #707 的 `Malformed hook input` + 固定 legacy
  baseline-unreadable detail prefix 做兼容排除；其他既有 malformed reasons
  继续归入 protocol error。
- 用不可读的 source-path fixture 覆盖 fail-closed、独立 reason 与
  non-protocol 计数，不能通过弱化断言或改成 pass 来修复。

### 3. Shared aggregate 与 observe additive contract

- 把 `is_protocol_error_reason` 从 human renderer 移入
  `vibeguard-runtime/src/observe/aggregate.rs`，升级为 event-level helper，使 reason 与 legacy
  baseline exception 在单一位置判定。
- `ObserveAggregate` 新增共享 `block_counts`，固定键为
  `total_blocks`、`protocol_errors`、`rule_interceptions`。遍历事件时只对
  normalized decision `block` 计数，最后断言/构造
  `rule_interceptions = total_blocks - protocol_errors`。
- `stats_summary.rs` 保留现有 `Interception (block)` 行，并从 aggregate 显示
  两个子计数；不得保留 renderer-local 重算。
- `observe_summary_json` additive 输出同一个 `block_counts`，因此 summary 与
  health JSON 自动 parity。`decision_counts` 原样保留。
- `schemas/observe-output.schema.json` 新增 `block_counts` property，要求上述
  三个非负整数、`additionalProperties: false`；不把它加入顶层 `required`，
  以便 schema 仍表达 additive/旧输出兼容。

### 4. Health-report parity 与旧 runtime

- `build_report` 只消费 summary 的 `block_counts`，不得扫描 reason 或从
  `decision_counts` 猜 split。`overview` additive 增加 `block_counts` 与
  `block_counts_status`。
- 非空 summary 且字段合法时 status 为 `available`；非空 summary 缺字段（旧
  runtime）时 status 为 `unavailable`、counts 为 null，markdown 明示
  “unavailable from installed runtime”。结构错误或算术不一致必须 raise
  `HealthReportError`，不得 silent fallback。
- missing log 或 `event_count == 0` 时沿用 `no_data`；status 为 `no_data`，
  markdown 不显示 0 风险结论。新 runtime observe 自身仍返回三个 0。
- report 继续使用现有 `SCHEMA_VERSION = 1` 的 additive object，并从该 object
  同时渲染 JSON/markdown；本变更不创建 `schemas/health-*.json`。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 | Bash/Write classifiers 与 orchestrators | `cargo test --manifest-path vibeguard-runtime/Cargo.toml malformed_input`；`bash tests/hooks/test_pre_bash_guard.sh`；`bash tests/hooks/test_pre_write_guard.sh` |
| B-002 | `hook_input_diag.rs` closed category helper | `cargo test --manifest-path vibeguard-runtime/Cargo.toml malformed_input_categories` |
| B-003 | diagnostic serializer + project/global persistence tests | `bash tests/hooks/test_pre_bash_guard.sh` 与 `bash tests/hooks/test_pre_write_guard.sh` 的 adversarial sentinel cases |
| B-004 | `PreWriteCheck::U16BaselineUnreadable` + aggregate classifier | `cargo test --manifest-path vibeguard-runtime/Cargo.toml baseline_unreadable`；`bash tests/test_observe.sh` |
| B-005 | `ObserveAggregate.block_counts` | `cargo test --manifest-path vibeguard-runtime/Cargo.toml block_counts`；`bash tests/test_observe.sh` |
| B-006 | human renderer、summary/health JSON renderer、observe schema | `bash tests/test_observe.sh` |
| B-007 | unchanged `decision_counts` serialization | `bash tests/test_observe.sh` |
| B-008 | `health-report.py` overview + markdown renderer | `bash tests/test_health_report.sh` |
| B-009 | health consumer old-runtime fixture | `bash tests/test_health_report.sh` |
| B-010 | observe empty-window fixture + health missing/empty fixtures | `bash tests/test_observe.sh`；`bash tests/test_health_report.sh` |
| B-011 | aggregate legacy-event fixtures | `cargo test --manifest-path vibeguard-runtime/Cargo.toml legacy_block_classification`；`bash tests/test_observe.sh` |
| B-012 | read-only repeat-run assertions | `bash tests/test_observe.sh`；`bash tests/test_health_report.sh` |

## 数据流

1. pre-Bash / pre-Write stdin 进入 classifier；malformed path 只生成 closed
   diagnostic，baseline read failure 进入独立 variant。
2. orchestrator 保持 block 输出，并把固定 reason/安全 detail 写入 project/global
   event logs；不新增日志或持久层。
3. observe reader 读取选定窗口，shared aggregate 一次性生成
   `decision_counts` 与 `block_counts`。
4. human summary、summary JSON 与 health JSON 消费同一 aggregate；observe schema
   验证 structured output。
5. health report 消费 summary JSON，将 available/unavailable/no_data 状态写入
   report object，再由同一 object 渲染 JSON 与 markdown。

## 备选方案

- 仅把 payload head 替换为 hash：拒绝。hash 不是必要结构元数据，可能支持离线
  猜测，也不能满足“不派生持久化 raw payload”的边界。
- 只在 human renderer 继续按 reason 拆分：拒绝。会继续造成 JSON 与 health
  consumer 漂移。
- 旧 runtime 缺字段时用 `decision_counts.block` 推断全部为 rule interception：
  拒绝。该推断无法区分 protocol error，必须显式 unavailable。

## 风险

- Security：任何 raw/free-text 回流 diagnostic 都会重新引入源码或 secret
  泄露；以 adversarial 双日志 negative assertions 锁定。
- Compatibility：新 `block_counts` 必须保持 optional，`decision_counts` 不变；
  health consumer 对旧 runtime 显式 unavailable。
- Performance：每个 event 只增加常数次 enum/reason 比较，不新增 I/O 或二次扫描。
- Maintenance：分类规则若散落到 renderer 会再次漂移；只允许 shared aggregate
  helper 拥有 protocol 判定。

## 测试计划

- [ ] Unit tests：closed diagnostic categories、隐私 sentinel、baseline unreadable、
  legacy/new reason 分类与 block 算术。
- [ ] Integration tests：Bash/Write 两类 hook 的 project/global 持久化；
  observe human/summary JSON/health JSON parity 与 schema validation。
- [ ] Consumer tests：health markdown/JSON 的 available、old-runtime unavailable、
  missing/empty no_data 与 malformed `block_counts` fail-loud。
- [ ] Full focused verification：`cargo test --manifest-path vibeguard-runtime/Cargo.toml`、
  `bash tests/test_observe.sh`、`bash tests/test_health_report.sh`。

## 回滚方案

若 block split 或 health consumer 需要回滚，可移除 additive `block_counts` 展示并让
consumer 明示 unavailable，但不得恢复 renderer-local 伪计数。privacy-safe
diagnostic 与 baseline-unreadable 独立 reason 必须保留；最保守回滚只能停止持久化
diagnostic detail，绝不能恢复 raw stdin/payload head/command/content/free-text。
pre-Bash / pre-Write fail-closed posture 始终不变。
