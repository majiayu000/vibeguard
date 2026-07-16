# Task Plan: GH644 deterministic expected-error tests

## Linked Issue

GH-644: https://github.com/majiayu000/vibeguard/issues/644

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## 实现任务

- [ ] `SP644-T1` Owner: `/root` — 在 `runtime_policy_diag_io_cli.rs` 建立 file-backed deterministic stdin runner，将 parent-create、open-directory 与 Linux `/dev/full` 三个 failure cases 统一接入；把 open-error case 从通用 policy test 迁入；将剩余 invalid-payload test 准确重命名并改为 null stdin direct command，保留 exact error 断言。Depends on: Spec PR merged and implementation route allowed。Covers: B-001-B-008。Done when: diff 仅含两个 integration test 文件；四个 affected cases 均无 live pipe writer/BrokenPipe fallback；全部 child/fixture assertions 保留；通用文件缩小且 `<800`。Verify: focused + related Rust targets、`git diff` boundary audit、`wc -l`。
- [ ] `SP644-T2` Owner: `/root` — 对 diagnostic I/O target 与 invalid-payload exact case 各运行 200 次 stress，再运行 Rust fmt/check/full tests 与 quick contract 并保存 fresh 输出；以两次远端失败作为旧 harness red baseline，不虚构本地必现。Depends on: SP644-T1。Covers: B-001-B-008。Done when: 两类各 200 次无失败、完整命令全绿、worktree clean 且无意外产物。Verify: tech spec 测试计划中的全部本地命令。
- [ ] `SP644-T3` Owner: `/root` + independent reviewer — 创建独立 Impl PR，核对 Issue/Spec/diff/test integrity，收集当前 SHA 全量 CI、reviewThreads 与 SpecRail required PR gate 后合并。Depends on: SP644-T2。Covers: B-001-B-008。Done when: 独立 reviewer NO BLOCKER，gate `allowed`，PR 合并且 GH-644 关闭。Verify: `python3 checks/pr_gate.py --repo . --evidence <current-evidence> --json`。

## 并行拆分

实现为两个强关联 test 文件，由单一 writer `/root` 顺序修改：

- implementation：`/root` 独占 `vibeguard-runtime/tests/runtime_policy_cli.rs` 与
  `vibeguard-runtime/tests/runtime_policy_diag_io_cli.rs`。
- independent_review：只读 reviewer，不拥有文件、不提交修改。

禁止两个 agent 同时写 test harness，禁止 reviewer 修改工作树。

## 验证

```bash
cargo fmt --manifest-path vibeguard-runtime/Cargo.toml -- --check
cargo check --manifest-path vibeguard-runtime/Cargo.toml
cargo test --manifest-path vibeguard-runtime/Cargo.toml --test runtime_policy_diag_io_cli
cargo test --manifest-path vibeguard-runtime/Cargo.toml --test runtime_policy_cli
cargo test --manifest-path vibeguard-runtime/Cargo.toml
for i in {1..200}; do cargo test --quiet --manifest-path vibeguard-runtime/Cargo.toml --test runtime_policy_diag_io_cli || exit 1; done
for i in {1..200}; do cargo test --quiet --manifest-path vibeguard-runtime/Cargo.toml --test runtime_policy_cli runtime_policy_downgrade_output_invalid_payload_is_visible -- --exact || exit 1; done
wc -l vibeguard-runtime/tests/runtime_policy_cli.rs vibeguard-runtime/tests/runtime_policy_diag_io_cli.rs
bash scripts/local-contract-check.sh --quick
git diff --check
```

最后读取实现 PR 当前 head 的 CI、独立 review、review threads 与 SpecRail PR gate。

## Handoff Notes

```yaml
handoff:
  mode: specrail-implement
  artifacts:
    - docs/specs/GH644/product.md
    - docs/specs/GH644/tech.md
    - docs/specs/GH644/tasks.md
  runtime_pinning_snapshot: None
  verification_owner: /root
  stop_conditions:
    - 实现需要修改 vibeguard-runtime/src、schema、hook、setup 或公开命令
    - 实现需要忽略 BrokenPipe、弱化 status/stdout/stderr 或 fixture 完整性断言
    - 实现需要修改 vibeguard-runtime/tests/common/mod.rs 或无关 stdin-driven tests
    - 两个目标 test 文件任一达到或超过 800 行
    - 两类 focused repetition 任一未达到 200 次，或 Rust full test、quick contract 任一失败
    - 独立 reviewer 有 blocker，或 current-head CI/review threads/SpecRail gate 未通过
  lane_map:
    implementation: /root
    independent_review: read_only_reviewer
```

关键决策：Spec PR 只 `Refs #644`；只有独立 Impl PR 使用 `Fixes #644`。实现必须从
Spec merge 后最新 `origin/main` 创建新 worktree，不复用 Spec 分支或旧 implementation base。
