# Task Plan: GH615 pre-write escalation recovery

## Linked Issue

GH-615

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## 实现任务

- [ ] `SP615-T1` Owner: `/root` — 在 `tests/hooks/test_pre_write_guard.sh` 将“silent attempts 也累计”的旧合同改为 reminder-aware recovery 合同，覆盖 breaker-silenced writes、达到阈值、same-session Grep/Glob、Read、other-session Grep、重新累计与 copy。Depends on: Spec PR merged and implementation route allowed。Covers: B-001-B-008。Done when: 当前 production 对新期望确定性红，失败来自 GH-615 语义而非 fixture/环境错误，并单独提交 red test commit。Verify: `bash tests/hooks/test_pre_write_guard.sh`（production 修复前预期红）。
- [ ] `SP615-T2` Owner: `/root` — 在 `vibeguard-runtime/src/hook_orchestrator.rs` 实现 same-session Grep/Glob boundary 之后的 visible reminder counter，保留 attempt telemetry、breaker flow、500-event bound 与 mode/config semantics，并改正 escalation copy。Depends on: SP615-T1。Covers: B-001-B-008。Done when: focused red tests转绿；silent attempts 不计数；有效搜索恢复；无效事件不恢复；重新忽略 reminders 会再次阻断。Verify: focused shell test 与 Rust tests。
- [ ] `SP615-T3` Owner: `/root` — 仅在 shell test 无法确定性覆盖 counter event ordering 时，新建 `cli_hook_pre_write` focused Rust integration target；不得向 799 行的 `cli_hook_orchestrator.rs` 追加。Depends on: SP615-T2。Covers: B-001, B-002, B-003, B-005, B-006。Done when: 缺失的 runtime contract 被 focused integration test 覆盖，或以已有 shell evidence 记录本任务 N/A。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml --test cli_hook_pre_write`（若创建）。
- [ ] `SP615-T4` Owner: `/root` — 执行 hook/Rust/broad regression、独立审查和 current-head PR gates。Depends on: SP615-T2 and SP615-T3 disposition。Covers: B-001-B-008。Done when: tech spec 全部 fresh 命令通过，独立 reviewer 无 blocker，CI/threads/SpecRail required gate 全部通过。Verify: tech spec 测试计划中的全部命令。

## 并行拆分

实现由单一 writer `/root` 顺序完成 red test 与 production fix，避免 runtime/test expectation 由不同 writer
竞态修改。独立 reviewer `/root/review_pr612` 只读检查 linked Issue、Spec、red/green evidence 与 PR diff，
无可写文件。

## 验证

- Red-first shell evidence 与独立 red commit。
- Focused same-session/other-session、Grep/Glob/Read、breaker OPEN 与 re-escalation matrix。
- Fresh Rust check/test、hook validators、full hook suite、quick contract 与 diff check。
- Independent review、current-head CI、zero unresolved threads、SpecRail required PR gate。

## Handoff Notes

- `mode`: `specrail-implement`
- `artifacts`: `docs/specs/GH615/product.md`, `docs/specs/GH615/tech.md`,
  `docs/specs/GH615/tasks.md`
- `runtime_pinning_snapshot`: None；实现必须从 Spec merge 后的最新 `origin/main` 建立独立 worktree，并在
  PR evidence 中记录 exact base/head SHA；不跨 runtime/tool inventory 切换。
- `verification_owner`: `/root`
- `stop_conditions`: 需要新增 greenfield/commit/file-count heuristic；需要 event schema 或 breaker
  state migration；Grep/Glob event producer 与已核实合同不符；必须改变 threshold=0 或 block-mode 语义；
  必须向 799 行 integration file 追加；任一 focused/Rust/hook/quick test 失败；独立 reviewer 有 blocker；
  current-head CI、review threads 或 SpecRail required gate 未通过。
- `lane_map`: specification `/root` 独占 `docs/specs/GH615/`、triage artifact 与 spec index；
  implementation `/root` 独占 `vibeguard-runtime/src/hook_orchestrator.rs`、
  `tests/hooks/test_pre_write_guard.sh` 及必要时新增的 focused Rust test；independent reviewer
  `/root/review_pr612` 只读，无可写文件。
- Spec PR 只 `Refs #615`；只有独立 Impl PR 使用 `Fixes #615` 并在合并后关闭 Issue。
