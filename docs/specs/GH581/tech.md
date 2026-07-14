# Tech Spec

## Linked Issue

GH-581

## Product Spec

`docs/specs/GH581/product.md`

## Codebase Context

| Area | Files | Current behavior | Relevance |
| --- | --- | --- | --- |
| Blocking coverage gate | `scripts/ci/self-application/check-u22-coverage.sh`, `tests/test_u22_coverage.sh` | 固定 `cargo-llvm-cov 0.8.7`，当前执行 66% baseline，并把 80% 显示为未执行目标 | 每个 tranche 需要按干净测量提高 baseline，最终改为 80% |
| Canonical CI | `.github/workflows/ci.yml`, `rust-toolchain.toml` | Ubuntu `Self-Application CI` 安装 Rust 1.95.0、`llvm-tools-preview` 和固定 llvm-cov | blocking measurement 的唯一跨 tranche 比较环境 |
| Pre-Bash orchestration | `vibeguard-runtime/src/hook_orchestrator_pre_bash.rs`, `vibeguard-runtime/tests/cli_hook_orchestrator.rs` | classifier 已有较高覆盖，但 orchestrator 的 spawn/error/log/skip 分支覆盖不足 | 第一 tranche 的最小高风险面 |
| Hook checks and Post-Edit | `vibeguard-runtime/src/hook_checks.rs`, `hook_orchestrator_post_edit.rs`, `hook_orchestrator_post_edit_history.rs`, `vibeguard-runtime/tests/cli_hook_checks.rs` | 核心行为存在，但多个异常和 fallback 分支未被执行 | 后续 fail-closed tranche |
| Runtime/setup policy | `runtime_policy.rs`, `setup_codex_hooks_health.rs`, `setup_manifest.rs`, `setup_install_state.rs` 及现有 CLI/unit tests | 配置与安装健康检查包含多种 parse/error/platform 路径 | 第二风险组 |
| Rendering/observability | `observe/`, `setup_markdown.rs`, `hook_status.rs` 及现有测试 | 渲染、空数据、I/O 错误和平台分支覆盖不均 | 低于 80% 的后续风险组 |

## Measured Baseline

在 `origin/main` `59d1005`、Rust 1.95.0、`cargo-llvm-cov 0.8.7` 的干净运行中：

- Total lines: 18,438
- Covered lines: 12,425
- Total line coverage: 67.39%
- Current blocking baseline: 66%
- Files below 80%: 34
- Files below 50%: 19

关键热点：

| File | Lines | Missed | Coverage |
| --- | ---: | ---: | ---: |
| `hook_orchestrator_post_edit.rs` | 421 | 306 | 27.32% |
| `hook_checks.rs` | 657 | 460 | 29.98% |
| `setup_codex_hooks_health.rs` | 326 | 225 | 30.98% |
| `hook_orchestrator_pre_bash.rs` | 179 | 121 | 32.40% |

这些百分比是规划基线，不是可复用的 merge evidence；每个 PR 必须在最新 head 上重新测量。

## Proposed Design

### 1. Keep one canonical measurement

继续使用现有 coverage job、toolchain 和 `check-u22-coverage.sh`。每个 tranche 在同一 pinned Linux 环境生成 before/after summary，记录总行数、覆盖行数、总百分比和本 tranche 目标文件百分比。完整日志作为 CI artifact 或本地 `artifacts/logs/` 证据，不提交生成物。

### 2. Ratchet the blocking baseline

每个实现 tranche 完成测试后：

1. 在最新 head 上执行干净 coverage。
2. 记录 `floor(before_coverage)`，并要求新增测试后的 `floor(post_coverage)` 至少高 1；没有跨过新整数档时继续补齐同一风险面。
3. 将 `LINE_COVERAGE_BASELINE` 提高到 post clean result 可证明的整数下界；不得只消费 before measurement 已经支持、但 gate 尚未执行的 headroom。
4. 同步更新 `tests/test_u22_coverage.sh` 的输出和命令断言。
5. 不得用预测值或不同平台的结果提高门槛。

最终 tranche 把 baseline 和目标统一为 80%，移除 “target not yet enforced” 表述。

### 3. Risk-ordered tranches

1. **Pre-Bash fail-closed orchestration**：覆盖 malformed/missing command、deny/block、pre-commit nonzero、launcher/spawn failure、runtime/log error、warn/correction/pass 和明确的 skip 语义。优先扩展 `cli_hook_orchestrator.rs`；只有 subprocess 无法到达的纯 helper 才放私有 unit test。
2. **Hook checks and Post-Edit**：覆盖 `hook_checks.rs`、post-edit/history 的异常输入、缺失文件、日志失败、history 读取失败与 fallback 可见性。超过 800 行的生产文件不内联新增测试；复用 integration test 或现有拆分 test-module 模式。
3. **Runtime policy and setup health**：覆盖 invalid config、缺失 manifest/hook、权限/I/O 错误、strict verdict 和平台分支。
4. **Rendering and observability**：覆盖 no-data、malformed data、输出失败与 deterministic rendering 分支。
5. **Long tail and final 80% gate**：按最新 coverage inventory 补齐其余低覆盖模块，完成 exception ledger，执行最终 80% ratchet。

### 4. Critical-path exception ledger

每个无法在 canonical Linux CI 到达的关键行必须在 PR 描述或关联 artifact 中记录：

- file and line/range
- path category (`platform_only`, `race_unreachable`, `defensive_unreachable`)
- why canonical execution cannot reach it
- alternate behavioral evidence
- reviewer identity and verdict

不接受文件级 exclusion 或没有具体行号的笼统例外。

### 5. Exhaustive critical-path disposition

每个风险 tranche 在写测试前建立绑定 before head SHA 的 critical-path inventory，并在 post head 上更新 disposition。每行必须包含：

- stable scenario/path ID
- exact `file:line` or line range at the recorded head SHA
- expected decision, error or log behavior
- disposition: `covered` or `exception`
- 对 `covered`：完整 llvm-cov JSON 中对应行的非零执行证据和行为测试名称
- 对 `exception`：exception ledger row 和独立 reviewer verdict

完整覆盖报告使用：

```bash
cargo llvm-cov --locked \
  --manifest-path vibeguard-runtime/Cargo.toml \
  --json \
  --output-path artifacts/logs/<tranche>/coverage.json
```

inventory 必须覆盖该 tranche 源码审计识别出的所有 malformed、deny/block、missing dependency、child/process failure、I/O/log failure 和 fallback/skip critical branches。独立 reviewer 对照 PR head 源码与完整 JSON 检查是否存在未列出的 critical line；summary-only 百分比不能替代这项审计。

## First Tranche Test Matrix

| Scenario | Expected evidence |
| --- | --- |
| Malformed JSON or missing `tool_input.command` | visible block decision and block log |
| Destructive command | deny/block reason remains visible and logged |
| Pre-commit script exits nonzero | blocking result includes child stdout/stderr and log evidence |
| Bash/launcher cannot spawn | visible spawn error; no pass fallback |
| Runtime context or event-log write fails | nonzero or explicit blocking output; no silent success |
| Rewrite target or uv virtualenv is missing | current explicit skip event is asserted and independently reviewed as intentional |
| Warn, correction, empty and ordinary pass | output and event decision agree |

Tests that alter PATH, cwd or environment must scope those changes to child `Command` processes. Process-global environment mutation is not allowed in parallel Rust tests.

## Verification Plan

Focused first-tranche checks:

```bash
cargo test --manifest-path vibeguard-runtime/Cargo.toml --test cli_hook_orchestrator pre_bash
bash tests/test_u22_coverage.sh
```

Full Rust and coverage checks for every implementation tranche:

```bash
cargo fmt --manifest-path vibeguard-runtime/Cargo.toml -- --check
cargo clippy --manifest-path vibeguard-runtime/Cargo.toml --all-targets -- -D warnings
cargo check --manifest-path vibeguard-runtime/Cargo.toml
cargo test --manifest-path vibeguard-runtime/Cargo.toml
bash scripts/ci/self-application/check-u22-coverage.sh
bash scripts/ci/self-application/run-all.sh
bash tests/test_self_application_ci.sh
bash tests/test_release_workflow.sh
bash scripts/local-contract-check.sh --quick
git diff --check
```

When a local shell resolves Homebrew Rust without `llvm-profdata`, prefix PATH with the pinned rustup bin directory and rerun; do not reinterpret the failed measurement as a repository failure.

## Risks

- Coverage-only assertions can execute lines without proving behavior. Mitigation: require decision/error/log assertions for critical paths.
- Global environment changes can make tests flaky. Mitigation: configure subprocesses, temporary directories and child PATH explicitly.
- Denominator drift can invalidate old baseline evidence. Mitigation: measure on latest PR head immediately before ratcheting.
- Linux cannot cover every platform branch. Mitigation: Windows behavioral evidence or line-specific exception ledger with independent review.
- Adding tests to already oversized source files violates U-16. Mitigation: use integration tests or existing split test modules.

## Rollback Plan

Revert only the failing tranche's tests and its baseline increment together. Do not lower a previously green baseline to accommodate unrelated regressions; diagnose the regression or revert the responsible Rust change. The final 80% gate is rolled back only with explicit maintainer approval and preserved before/after evidence.
