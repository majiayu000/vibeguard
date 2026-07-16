# Tech Spec: reminder-aware pre-write escalation recovery

## Linked Issue

GH-615

## Product Spec

[`product.md`](product.md)

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Source-new orchestration | `vibeguard-runtime/src/hook_orchestrator.rs:284-366` | 在 breaker check 前记录 attempt；以全部 prior attempts 触发 escalation；仅 breaker Run 时记录 reminder | 当前把不可见 attempt 错算为未响应证据 |
| Escalation history | `vibeguard-runtime/src/hook_orchestrator.rs:509-528` | 逆序扫描最近 500 行，只按 session/hook/`New source file attempt` 计数，不识别 Grep/Glob 边界 | 需要改为 visible-reminder-since-search 语义 |
| Search evidence producer | `hooks/analysis-paralysis-guard.sh:97-108` | 每次 Read/Glob/Grep 都以原始 tool name 记录同 session pass event，且不受其 breaker 静默影响 | 已有 schema 足够表示 Grep/Glob heed boundary |
| Shell regression | `tests/hooks/test_pre_write_guard.sh:188-214` | 明确断言 breaker-silenced attempts 会累计并断言无效 export 文案 | 必须 red-first 改写为新合同 |
| Rust integration | `vibeguard-runtime/tests/cli_hook_orchestrator.rs:321-375` | 覆盖首次 attempt/reminder telemetry；文件已 799 行 | 保留 telemetry 回归，不在该文件继续追加超过 U-16 上限 |

## 设计方案

1. 将 `count_recent_source_new_attempts` 改名为
   `count_unheeded_source_new_reminders`，保持返回 `Result<u64>` 和最近 500 行的有界读取。
2. 从 event log 最新向最旧遍历并只处理可解析 JSON：
   - 先过滤 `session_id == ctx.session_id`；
   - 遇到 `hook == analysis-paralysis-guard` 且 `tool` 为 `Grep` 或 `Glob` 时停止遍历，该事件是最近
     heed boundary；
   - 在边界之前，仅累计 `hook == pre-write-guard` 且
     `reason == New source file reminder` 的 event；
   - Read、其他 session、attempt、escalation、breaker 与 malformed lines 均忽略。
3. `run_source_new` 在 threshold check 前调用新 counter。保留 attempt event 在 breaker check 前的现有
   位置作为 observability，但 attempt 不再参与 escalation。这样 breaker OPEN 的静默 calls 仍留痕，
   却不构成用户忽略提醒的证据。
4. escalation event reason 与 block 文案使用 `unheeded source-new reminders`/`visible ... reminders`
   语义。ACTION 明确“在本 repo 运行 Grep/Glob，确认无重复，然后重试 Write”，删除 child process 中
   session-local `export` 和必须新 session 的恢复建议。threshold 的持久配置方式不在本修复中改写。
5. 保持 `threshold == 0` 短路、`write_mode == block` 早期阻断、breaker record/check、attempt/reminder
   event schema 与 log read behavior 不变。本 Issue 不扩大为 log I/O 错误策略重构。
6. Red-first 改写 `tests/hooks/test_pre_write_guard.sh` 的旧错误合同，使用隔离 log/state：
   - breaker threshold=1：一条 visible reminder 后多个 silent writes 不 escalation；
   - breaker threshold 高于 escalation threshold：可见 reminders 达阈值后下一次阻断；
   - append/emit 同 session Grep 或 Glob 后下一次 write 不再被旧 history 阻断；
   - Read 与 other-session Grep 不恢复；
   - 恢复后的新 reminders 可重新累计；
   - block copy 不含无效 export。
7. 若 shell end-to-end test 无法确定性覆盖 event ordering，搜索后新增独立的
   `cli_hook_pre_write` focused Rust integration target；禁止向已 799 行的
   `cli_hook_orchestrator.rs` 追加。新文件只覆盖缺失的 runtime integration contract，不复制全部 hook
   harness。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 | reminder-based history counter | focused breaker-silence regression + event-count assertions |
| B-002 | reverse scan Grep/Glob boundary | same-session Grep and Glob recovery cases |
| B-003 | session/tool/reason filters | Read, other-session Grep and malformed/unrelated event cases |
| B-004 | unchanged breaker flow | threshold=1 silent-write regression and existing CB tests |
| B-005 | post-boundary reminder accumulation | visible reminders reach threshold and next write blocks |
| B-006 | escalation recovery | blocked → Grep/Glob → retry sequence, including OPEN breaker case |
| B-007 | escalation copy | exact positive Grep/Glob guidance and negative export assertion |
| B-008 | early modes, telemetry, bounded schema | existing threshold/write-mode/Rust telemetry tests + changed-file audit |

## 数据流

`pre-write-guard.sh` 将 Write input 交给 Rust orchestrator。source-new warn path 读取同一 append-only JSONL
event log 的最近 500 行，从尾部找到本 session 最新 Grep/Glob boundary，并累计其后的 visible reminder
events。未达到阈值时仍记录 attempt，再由 circuit breaker 决定是否记录/输出 reminder；达到阈值则记录
escalation 并输出 block。`analysis-paralysis-guard.sh` 已把 Grep/Glob tool name 和 session 写入同一日志，
无需新字段、跨进程状态或外部调用。

## 备选方案

- 继续累计 attempts、只提高默认阈值：拒绝；不可见事件仍会伪造“unheeded”证据。
- 仅在任何 analysis event 后清零：拒绝；Read 不满足 L1 search-first，其他 session 也不能证明当前
  用户已响应。
- 删除 escalation：拒绝；会失去重复忽略可见提醒时的 anti-duplication enforcement。
- 在 escalation 后自动清零计数：拒绝；用户未搜索即可反复绕过，且没有真实 heed evidence。
- 新增 greenfield heuristic：拒绝；这是独立产品决策，超出 GH-615 的 A+B+F 修复范围。
- 让 hook 执行 `export`：拒绝；child process 不能修改已运行 agent 的父进程环境。

## 风险

- Security：错误识别 boundary 会削弱 L1；严格限定 same-session、exact hook、exact Grep/Glob。
- Compatibility：保留 event schema、attempt telemetry、threshold=0 与 block mode；只改变错误计数语义。
- Performance：继续最多解析最近 500 行，复杂度与当前实现相同。
- Maintenance：reason/tool 字符串是现有事件合同；集中在一个 counter，tests 锁定正负边界。
- Silent degradation：malformed event 继续按现状忽略，log read 错误继续由现有调用层处理；本 Issue 不
  宣称修复该兼容边界，也不新增 fallback。
- File size：`cli_hook_orchestrator.rs` 已 799 行，禁止追加；优先使用已有 focused shell test，必要时
  新建职责单一的 Rust integration file。

## 测试计划

- [ ] Red evidence：先改旧 shell regression 期待“silent attempts 不累计、search 可恢复、无 export”，
  在 production 未改时确定性失败并保存输出。
- [ ] Focused：`bash tests/hooks/test_pre_write_guard.sh`。
- [ ] Rust build/test：`cargo check --manifest-path vibeguard-runtime/Cargo.toml`；
  `cargo test --manifest-path vibeguard-runtime/Cargo.toml`。
- [ ] Hook contracts：`bash tests/test_hooks.sh`；`bash scripts/ci/validate-hooks.sh`；
  `bash scripts/ci/validate-hooks-manifest.sh`。
- [ ] Broad：`bash scripts/local-contract-check.sh --quick`；`git diff --check`。
- [ ] Review/gate：独立 reviewer 对照 GH-615 与三份 Spec；current-head CI 全绿、零 unresolved review
  threads、SpecRail required PR gate allowed。

## 回滚方案

恢复 attempt-based counter、旧 escalation copy 与旧 shell expectation 即可回滚；没有 schema、用户数据、
配置或 breaker state 迁移。若恢复会重新引入 GH-615 的不可恢复锁死，应仅在新回归证据表明搜索边界
误判时执行，并重新进入 Spec 流程。
