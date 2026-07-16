# Tech Spec: deterministic stdin for runtime-policy diagnostic I/O tests

## Linked Issue

GH-644: https://github.com/majiayu000/vibeguard/issues/644

## Product Spec

[`product.md`](product.md)

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| 通用 policy test helper | `vibeguard-runtime/tests/runtime_policy_cli.rs:26-43` | child 启动后由 parent 向 piped stdin `write_all`，写失败立即 panic，之后才 `wait_with_output` | 两次远端 BrokenPipe 都在该顺序的 `write_all` 处掩盖 child evidence |
| open-error case | `vibeguard-runtime/tests/runtime_policy_cli.rs:760-780` | 将既有目录作为 diag-file，预期 open 失败，但通过 live pipe helper 提供 reason | 应迁移到专用 I/O failure test，且通用文件当前 795 行 |
| 专用 diagnostic I/O cases | `vibeguard-runtime/tests/runtime_policy_diag_io_cli.rs:1-51` | parent-create 与 Linux `/dev/full` failure 也通过共享 live pipe helper | 同一根因的完整 failure-test family，应统一确定性输入 |
| 生产 diagnostic handler | `vibeguard-runtime/src/runtime_policy.rs:254-280` | create parent → 读取 stdin → open/append diag file，错误向 CLI 返回 | 行为正确且不在本 Issue 修改 |

远端 baseline：main run `29519621725` 与 Self-Application job `87708335153`
分别在 `runtime_policy_cli.rs:39` 报 `BrokenPipe`；相邻后续 run 通过，且本地完整
test binary 连续 200 次通过，证明问题为调度相关 flake 而非稳定产品失败。

## 设计方案

1. 在现有 `runtime_policy_diag_io_cli.rs` 内增加职责私有的 deterministic stdin
   runner：为每次调用创建 unique temp fixture，写入固定 reason，重新以只读文件打开，
   将该 file handle 作为 child 的 `Stdio`，再调用 `output()` 收集完整结果。
2. fixture 的目录创建、写入、打开、spawn/wait 任一步失败均使用具名 `expect` fail loudly；
   child 完成后清理输入 fixture。不得在 `BrokenPipe` 上 fallback 或返回伪造 Output。
3. parent-create、open-existing-directory、Linux `/dev/full` 三个用例统一使用该 runner。
   文件后端 stdin 没有 parent live writer，因此 child 何时失败都不会向 parent 产生 EPIPE。
4. 把 open-error case 从 `runtime_policy_cli.rs` 移入专用文件；保留其 child status、
   empty stdout、visible stderr 与 target-still-directory 断言。原函数中剩余 invalid-payload
   case 改为准确名称，不改变断言。
5. 不修改 `vibeguard-runtime/tests/common/mod.rs` 的共享 helper、不修改其他
   stdin-driven tests，也不修改
   `vibeguard-runtime/src/`。实现 diff 限定两个 integration test 文件。
6. 旧 harness 的远端两次失败是真实 red evidence。由于 200 次本地旧版本均通过，禁止
   声称本地稳定复现；绿态必须用 200 次新 focused repetition 与 current-head matrix 证明。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 | 专用 deterministic stdin runner | diff review 无 `Stdio::piped`/`write_all`；focused test 200 次 |
| B-002 | 三个 `runtime_policy_diag_io_cli` cases | `cargo test --manifest-path vibeguard-runtime/Cargo.toml --test runtime_policy_diag_io_cli`；Linux CI 覆盖 `/dev/full` |
| B-003 | 三个 case 的现有/迁移断言 | focused test；review 确认 status/stdout/stderr 与 fixture assertions 未删除 |
| B-004 | fixture setup 与 child `output()` error handling | negative code review：每个 setup/spawn/wait error fail loudly、无 BrokenPipe fallback |
| B-005 | changed-file boundary | `git diff --name-only origin/main...HEAD` 仅列两个 test 文件；`git diff -- vibeguard-runtime/tests/common/mod.rs` 为空 |
| B-006 | production boundary | `git diff -- vibeguard-runtime/src` 为空；完整 Rust test |
| B-007 | file-size/repetition/broad gates | `wc -l` 两文件、200 次 focused loop、full Rust test、quick contract 与 current-head CI |

## 数据流

test 创建隔离临时目录与 reason file → parent 在 spawn 前把完整 reason 写入并以只读
handle 交给 child stdin → child 执行 `runtime-policy-diag` 并在指定 parent/open/write 点
失败 → `Command::output()` 收集 status/stdout/stderr → test 断言真正 child evidence → 清理
fixture。没有网络、持久化迁移、共享状态或生产外部调用。

## 备选方案

- 在共享 helper 中忽略 `ErrorKind::BrokenPipe`：拒绝；会让无关 success-path test 失去
  stdin 完整写入保证，并可能把 child 早退误判为成功测试。
- 只在当前 open-error case 捕获 EPIPE：拒绝；专用 parent-create 与 `/dev/full` cases
  有同一 transport 风险，违反全量暴露。
- 修改生产 handler 先 open 再读 stdin：拒绝；改变真实命令数据流，且不能解决所有预期
  早退测试的 parent writer race。
- 增大重试次数或自动 rerun CI：拒绝；会隐藏 flake，而不是消除非确定性 transport。
- 向 795 行通用文件新增 helper：拒绝；逼近 U-16 800 行硬上限且职责错误。

## 风险

- Security: 仅测试临时文件；使用 unique temp path，不新增 secret、权限或 shell command。
- Compatibility: file-backed stdin 仍提供与 pipe 相同的字节；非 Linux case 跨平台，
  `/dev/full` 继续由现有 `cfg(target_os = "linux")` 限定。
- Performance: 单次增加小型 temp file I/O；仅测试环境，200 次 stress 只作为本地验证。
- Maintenance: helper 只服务 diagnostic I/O failure family；通用 policy test 缩小，职责更清晰。
- Test integrity: status/stdout/stderr 和 fixture assertions 不删不松；任何 setup error 直接失败。

## 测试计划

- [ ] Baseline：引用两次远端 BrokenPipe；明确旧 head 本地 200 次通过，不伪造 local red。
- [ ] Format/build：`cargo fmt --manifest-path vibeguard-runtime/Cargo.toml -- --check`；
      `cargo check --manifest-path vibeguard-runtime/Cargo.toml`。
- [ ] Focused：`cargo test --manifest-path vibeguard-runtime/Cargo.toml --test runtime_policy_diag_io_cli`。
- [ ] Stress：focused target 连续执行 200 次，任一次非零立即失败。
- [ ] Related：`cargo test --manifest-path vibeguard-runtime/Cargo.toml --test runtime_policy_cli`。
- [ ] Full：`cargo test --manifest-path vibeguard-runtime/Cargo.toml`。
- [ ] Size/boundary：`wc -l` 两个测试文件；changed-file 与 production/shared-helper diff audit。
- [ ] Broad：`bash scripts/local-contract-check.sh --quick`；`git diff --check`。
- [ ] Review/gate：独立 reviewer、current-head CI、零 unresolved threads、SpecRail PR gate allowed。

## 回滚方案

回滚两个 test-file 变更即可恢复旧 harness；没有生产代码、schema、配置或用户数据迁移。
若回滚会重新暴露已证实的 BrokenPipe flake，必须重新打开 GH-644 或以新 Issue 提供替代的
确定性输入设计，禁止只删除 stress/断言证据。
