# Product Spec

## Linked Issue

GH-581

## User Problem

VibeGuard 的 Rust runtime 已经用真实 `cargo llvm-cov` 阻止覆盖率回退，但当前 CI 只执行 66% 的 blocking baseline，距离 U-22 的 80% 目标仍有明显差距。更重要的是，若 hook 输入异常、deny/block、依赖缺失或错误传播路径没有测试，覆盖率数字即使上升，也不能证明 fail-closed 行为安全。

当前 `origin/main` 的干净测量为 67.39%（12,425 / 18,438 行）。63 个 Rust 源文件中有 34 个低于 80%，其中 `hook_orchestrator_post_edit.rs`、`hook_checks.rs`、`setup_codex_hooks_health.rs` 和 `hook_orchestrator_pre_bash.rs` 仍约为 27%–32%。

## Goals

- 将 Rust 总行覆盖率提升到至少 80%，并让 CI 在低于 80% 时失败。
- 优先覆盖 hook 的异常输入、deny/block、缺失依赖和错误传播路径。
- 用多个可独立审阅的 tranche 单调提高 blocking baseline，不用一次性大规模重写测试。
- 每个 tranche 都保留同一工具链下的 before/after 覆盖率证据，并由独立 reviewer 审阅。
- 对不能在 canonical CI 平台执行的关键行逐项记录原因和 reviewer 结论，不用文件级排除隐藏缺口。

## Non-Goals

- 不为提高数字而删除生产代码、删除测试、弱化断言或排除源文件。
- 不在本 issue 中重写 hook 架构或改变既有 allow/block/warn/correction 语义。
- 不把本机工具链差异当成仓库通过或失败的依据；blocking truth 仍来自固定 Linux CI 环境。
- 不要求非关键模块达到 100%；总目标为至少 80%，关键 fail-closed 路径单独治理。

## Behavior Invariants

1. `cargo llvm-cov` 执行失败、工具版本漂移、manifest 缺失或覆盖率低于门槛时，coverage gate 必须非零退出。
2. 每个实现 tranche 必须让 `floor(post_coverage) > floor(before_coverage)`，并把 `LINE_COVERAGE_BASELINE` 提高到 post clean measurement 可证明的整数下界；不得用 tranche 开始前已有的 gate headroom 充当新增测试进展。
3. malformed input、deny/block、缺失依赖和错误传播等关键路径必须有行为断言；只执行代码而不验证决策或可见错误不算覆盖。
4. 测试不得用 `--ignore-filename-regex`、`#[coverage(off)]`、删除代码或平台无关的 skip 制造覆盖率提升。
5. canonical Linux CI 无法执行的平台分支必须进入逐行 exception ledger，包含原因、替代行为证据和独立 reviewer 结论。
6. 每个 tranche 必须由非实现 lane 的 reviewer 检查测试完整性、覆盖率证据和 baseline ratchet 后才能合并。

## Acceptance Criteria

- [ ] `cargo llvm-cov` 总行覆盖率达到至少 80%，CI 的 blocking baseline 同步提升到 80%。
- [ ] hook 的 malformed input、deny/block、缺失依赖和错误传播路径有明确行为测试，关键 fail-closed 路径达到 100% 或有逐项 reviewer 接受的例外。
- [ ] 每个关键风险面都有绑定 PR head SHA 的 exhaustive disposition：所有 in-scope critical scenario/path 映射到精确 `file:line`，每行都有 llvm-cov covered 证据或逐行 exception，不允许未列出的关键行。
- [ ] 每个实现 tranche 都提交同一 pinned Linux 环境下的 before/after 行覆盖率证据，并提高 blocking baseline。
- [ ] deterministic contract tests 继续证明工具缺失、版本漂移、manifest 缺失、coverage/test 失败均 fail closed。
- [ ] 没有通过排除文件、关闭 coverage、删除生产代码、删除测试或弱化断言提高数字。
- [ ] 最终 PR 的独立 reviewer 明确确认 80% gate、关键路径 exception ledger 和测试完整性。

## Edge Cases

- 本机默认 PATH 指向没有 `llvm-profdata` 的 Rust 安装：本地测量应明确失败并切换到 pinned rustup 工具链，不能 fallback 成虚假通过。
- Ubuntu 无法执行 `#[cfg(not(unix))]` 分支：需要 Windows 行为证据或逐行 reviewer exception。
- 文件状态竞争等不可稳定触发的分支：必须记录具体行、不可达理由和替代测试，不能排除整个文件。
- 新测试没有让 clean total coverage 跨过相对 before measurement 的下一个整数档：该 tranche 不能合并为已完成的 baseline ratchet，应继续补齐同一风险面；只把旧 gate 调到 before measurement 已支持的整数值不算进展。
- 测量分母因合入其他 Rust 变更发生变化：重新以最新 PR head 做干净 before/after 测量，不复用旧百分比。

## Rollout Notes

先落 `pre-bash` fail-closed orchestration tranche，再按 hook checks / post-edit、runtime policy / setup health、observability、其余低覆盖模块推进。部分 tranche 使用 `Refs #581`；只有总覆盖率和 blocking baseline 都达到 80%、关键路径例外审计完成的最终 tranche 才关闭 GH-581。
