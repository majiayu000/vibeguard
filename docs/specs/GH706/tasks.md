# Task Plan — GH706 malformed-input 诊断隐私与 block 计数

## Linked Issue

GH-706

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## 实现任务

- [ ] `SP706-T1` 收紧 malformed-input diagnostic 为闭集结构元数据，并先用 adversarial fixture 复现 raw payload head / command / content / secret 会进入 project/global logs 的问题，再保持 Bash/Write fail-closed 前提下删除全部 raw/free-text 回显。Owner: implementation agent. Covers: B-001, B-002, B-003. Depends on: human spec approval、fresh duplicate-work evidence 与 live implementation route allowed. Done when: empty stdin、invalid JSON、missing/empty/non-string required field 分别归入固定 category；unknown tool/event 只输出归一化 class；两个日志目的地均不含任一 sentinel；既有 block decision/reason 与空 command no-op 合同不变；测试先红后绿且未弱化。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml malformed_input`; `bash tests/hooks/test_pre_bash_guard.sh`; `bash tests/hooks/test_pre_write_guard.sh`.
- [ ] `SP706-T2` 将 U-16 baseline unreadable 从 `PreWriteCheck::Malformed` 拆为独立 fail-closed variant/reason/category，并移除 file path 与 OS error free text 的持久化。Owner: implementation agent. Covers: B-001, B-003, B-004. Depends on: SP706-T1. Done when: 合法 Write JSON 的 baseline read failure 仍 block，但不使用 malformed-input reason/category、不泄露路径/错误文本，且后续 aggregate 可明确判为 non-protocol；focused fixture 在修复前能复现误分类，修复后转绿。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml baseline_unreadable`; `bash tests/hooks/test_pre_write_guard.sh`.
- [ ] `SP706-T3` 把 protocol-error event classifier 与 `block_counts` 移入 shared observe aggregate，统一计算 `total_blocks`、`protocol_errors`、`rule_interceptions`，并兼容排除 PR #707 已写入的 legacy baseline-unreadable detail。Owner: implementation agent. Covers: B-005, B-007, B-011, B-012. Depends on: SP706-T2. Done when: 任意 fixture 满足 `total_blocks = protocol_errors + rule_interceptions = decision_counts.block`；既有 Bash/Write malformed reasons 仍归 protocol，legacy/new baseline unreadable 均为 non-protocol；重复 aggregate 结果确定且不写日志；human renderer 不再拥有第二套 classifier。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml block_counts`; `cargo test --manifest-path vibeguard-runtime/Cargo.toml legacy_block_classification`.
- [ ] `SP706-T4` 让 human summary、summary JSON 与 health JSON 消费 shared `block_counts`，并在现有 observe output schema 中声明 additive optional `block_counts`，保持 `decision_counts` 和顶层 required 集合兼容。Owner: implementation agent. Covers: B-005, B-006, B-007, B-010, B-012. Depends on: SP706-T3. Done when: 三种 observe 输出对混合与空窗口 fixture 给出同一计数；human 保留总 block 行并展示两个子计数；JSON schema 要求三个非负整数且拒绝额外键，但旧输出仍可因 optional 字段通过；`decision_counts` 未扣减或改名；重复运行不追加事件。Verify: `bash tests/test_observe.sh`; `cargo test --manifest-path vibeguard-runtime/Cargo.toml stats_summary_splits_protocol_error_blocks_from_rule_blocks`.
- [ ] `SP706-T5` 扩展现有 health-report consumer 直接消费 `block_counts`，在同一 report object 中提供 available / unavailable / no_data，再由该对象渲染 markdown 与 JSON；不得扫描 reason、自行推算 split 或新建 health schema。Owner: implementation agent. Covers: B-008, B-009, B-010, B-012. Depends on: SP706-T4. Done when: 新 runtime 的非空窗口两种格式与 observe parity 且 status=available；旧 runtime 非空窗口 counts=null 且显式 unavailable；缺日志/空窗口保持 no_data；结构或算术错误 fail loudly；相同输入重复运行结果除 generated timestamp 外语义一致且无持久化副作用。Verify: `python3 -m py_compile scripts/health-report.py`; `bash tests/test_health_report.sh`.
- [ ] `SP706-T6` 在同一 implementation head 上执行完整 focused/broad gates，并由 independent reviewer 对照 product/tech/tasks、PR #707 四条 finding、隐私负例、计数算术、兼容性与测试完整性做只读审查。Owner: verification owner + independent reviewer. Covers: B-001, B-002, B-003, B-004, B-005, B-006, B-007, B-008, B-009, B-010, B-011, B-012. Depends on: SP706-T5. Done when: 所有 fresh 命令通过；reviewer 确认无 raw/free-text leak、无 renderer-local classifier、无 health split 猜测、无 unreadable baseline 误分类、无弱化测试或越界 health schema；current-head CI/review-thread/PR-gate evidence 均满足后才可报告 merge-ready。Verify: 运行本文件“验证”中的全部命令，并记录 independent review 与 SpecRail PR gate 对当前 head SHA 的结果。

## 并行拆分

本实现禁止并行写 lane。`SP706-T1` → `SP706-T2` → `SP706-T3` →
`SP706-T4` → `SP706-T5` → `SP706-T6` 严格串行，避免 runtime classifier、
observe renderer、schema 与 consumer 在合同未稳定时漂移。仅 `SP706-T6` 的
independent review 是只读 lane，不与 implementation agent 共享 writable file。

## 验证

```bash
python3 checks/check_workflow.py --repo . --spec-dir=docs/specs/GH706
cargo fmt --manifest-path vibeguard-runtime/Cargo.toml --check
cargo check --manifest-path vibeguard-runtime/Cargo.toml
cargo test --manifest-path vibeguard-runtime/Cargo.toml
bash scripts/ci/validate-hooks.sh
bash scripts/ci/validate-hooks-manifest.sh
bash tests/hooks/test_pre_bash_guard.sh
bash tests/hooks/test_pre_write_guard.sh
bash tests/test_observe.sh
bash tests/test_health_report.sh
bash scripts/local-contract-check.sh --quick
git diff --check
```

## Handoff Notes

- Product invariants：`B-001`–`B-012`；任务 `Covers:` union 为同一完整集合，无
  orphan invariant 或额外 ID。
- 用户已在当前会话批准 product/tech spec；代码实施前仍须采集 fresh
  duplicate-work evidence，并让 implement route gate 对 live durable state
  通过。当前 preflight 的唯一缺口是 `duplicate_evidence`。
- 不改变非目标 `tool_name` payload 的放行策略，不新增 health schema/持久层，
  不迁移旧日志，不恢复 raw payload diagnostic。
- Stop conditions：任何 secret/raw/free-text 出现在 project/global logs；任一
  输出不满足 block 算术；旧 runtime 被伪装成 0；baseline unreadable 被归为
  protocol；focused 或 broad gate 失败；independent review 存在 current
  actionable finding。
- Human gates 继续保留：final PR review、security decision、merge 与 release。
