# Tech Spec

## Linked Issue

GH-652

## Product Spec

See `product.md`.

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Structured report suite | `tests/test_setup_check.sh:284-331` | first setup invocations, including help and end-to-end checks, happen before any current-runtime build in this suite | stale binary can own early assertions |
| Late runtime build | `tests/setup/runtime_config_check_tests.sh:7-10` | current runtime is built only when the late mode matrix is sourced | explains first-run/second-run ordering drift |
| Runtime candidate order | `scripts/setup/lib.sh:23-49` | explicit env precedes installed/release/debug/PATH candidates | test can deterministically pin without changing production |
| Capability probe | `scripts/setup/lib.sh:67-100` | version and command-presence checks do not encode source commit freshness | same-version stale binary can pass |

## 设计方案

在 `tests/test_setup_check.sh` 的 shared assertion helpers 已声明、但首个 `setup.sh` invocation 尚未
发生的位置建立唯一 runtime owner 和自包含回归场景：

1. 在 suite 临时目录生成 executable stale runtime fixture：`version` 报告当前
   `vibeguard-runtime/VERSION`，其余 legacy probe commands 返回受支持结果，并在任何调用时写
   marker。调用现有 `setup_runtime_supports` 时必须使用 command-scoped clean context：显式
   `VIBEGUARD_REPO_DIR="${REPO_DIR}"`、显式 current `VIBEGUARD_SETUP_RUNTIME_VERSION`、marker
   disabled；不得读取真实 caller 的错误 version。该 clean probe 证明 fixture 确实能通过旧
   version/command contract；验证后清空 marker。
2. 把 fixture 注入 `VIBEGUARD_SETUP_RUNTIME`，同时注入
   `VIBEGUARD_SETUP_SKIP_REPO_RUNTIME=1`、错误 `VIBEGUARD_SETUP_RUNTIME_VERSION`、外部
   `CARGO_TARGET_DIR` 与无效 `CARGO_BUILD_TARGET`，形成单一 hostile caller 场景。
3. 在 build 前 unset `CARGO_BUILD_TARGET` 与 `VIBEGUARD_SETUP_RUNTIME_VERSION`，固定
   `VIBEGUARD_SETUP_SKIP_REPO_RUNTIME=0`。以 array-safe
   `cargo build --manifest-path ... --target-dir
   "${REPO_DIR}/vibeguard-runtime/target"` build 当前 worktree runtime；显式 target dir 覆盖 caller
   `CARGO_TARGET_DIR`，保证 build output 与 pin 指向同一目录。
4. build 失败时立即打印具名错误并非零退出，禁止继续测试或 fallback。该 build 继续占用原有
   260 项中的 build assertion 计数，不删除任何既有 assertion。
5. 校验确定路径 `vibeguard-runtime/target/debug/vibeguard-runtime` 可执行，然后无条件 export
   `VIBEGUARD_SETUP_RUNTIME` 为该绝对路径，覆盖调用者值。
6. `tests/setup/runtime_config_check_tests.sh` 删除迟到的重复 build，直接复用 suite pin；它仍可用
   现有 per-command env 传递同一值。
7. 全部 setup assertions 后检查 stale fixture marker 不存在；出现任何调用立即使 suite 非零失败。

不改 `scripts/setup/lib.sh`。现有 behavior assertions 文本、期望结果和 fixture 不变；实现 diff
只移动 build ownership、增加 fail-fast pin，并让后段 matrix 引用唯一 pin。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 | `tests/test_setup_check.sh` preflight | source-order audit；`bash tests/test_setup_check.sh` |
| B-002 | probe-compatible same-version stale fixture + hostile env normalization + zero-call marker | self-contained hostile scenario；`bash tests/test_setup_check.sh` |
| B-003 | fail-fast cargo/executable checks | focused static review；shell syntax；negative command-path review |
| B-004 | `tests/setup/runtime_config_check_tests.sh` reuse | only one `cargo build` owner；full suite |
| B-005 | existing assertions | assertion diff/count audit + full 260/260 suite |
| B-006 | production resolver exclusion | `git diff --name-only` and Rust/setup focused verification |

## 数据流

当前 Rust source 经 Cargo 写入 worktree debug binary；suite 将其绝对路径 export 给所有子进程。
无网络、用户配置持久化或生产安装写入。测试临时 HOME/fixture 生命周期保持现状。

## 备选方案

- 修改生产 resolver 优先选择 repo binary：拒绝，会改变安装/执行契约且不能保证 binary 来自当前 source。
- 只比较 runtime version：拒绝，已复现 same-version stale binary。
- 保留后段 build 并给早期失败加重试：拒绝，会掩盖顺序依赖并重复执行旧行为。
- 删除新 health assertions：拒绝，违反测试完整性。

## 风险

- Security: Cargo 使用固定 manifest path；不拼接命令，不读取外部凭据。
- Compatibility: 仅测试 harness；生产 resolver 和 runtime 未改。
- Performance: suite 将在开头执行一次增量 Cargo build；删除后段重复 build owner。
- Maintenance: 单一 `VIBEGUARD_SETUP_RUNTIME` pin 避免两个 fixture 各自决定 runtime。

## 测试计划

- [ ] `bash -n tests/test_setup_check.sh tests/setup/runtime_config_check_tests.sh`。
- [ ] `bash tests/test_setup_check.sh`。
- [ ] `bash tests/test_setup_check.sh`（内部 fixture 必须先在 scoped current-version/repo context
  通过 legacy capability probe，再注入 hostile env 运行完整 suite，最终 marker 零调用且
  260/260）。
- [ ] `cargo check --manifest-path vibeguard-runtime/Cargo.toml`。
- [ ] `cargo test --manifest-path vibeguard-runtime/Cargo.toml`。
- [ ] SpecRail、doc paths、doc command paths 与 diff check。

## 回滚方案

整体回滚两个测试 harness 文件；回滚后不得声称 cold/stale-artifact 运行具有确定性。若 build 成本
需要重新设计，应另立 issue 引入共享 build fixture，不得恢复 release/installed fallback。
