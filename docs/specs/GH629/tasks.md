# Task Plan

## Linked Issue

GH-629

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`
- Status: draft；执行前必须有 spec approval 与 `ready_to_implement`

## 实现任务

- [ ] `SP629-T1` 定义 runtime-config schema、精确 per-path range、兼容规则与完整 getter/template inventory，并把 3 个已支持但未出现在 template 的 path 补入 template。Covers: B-001, B-002, B-007. Owner: implementation agent. Dependencies: spec approval + W-20 check. Done when: template/legacy v1/explicit v1 contract 可机读，每个 numeric path 的 0/max/max+1 和 warn-limit clamp 有具名 fixture，schema 与 production getter path 无缺漏。Verify: `bash tests/test_runtime_config_schema.sh`; `bash tests/test_manifest_contract.sh`。
- [ ] `SP629-T2` 在 Rust 中实现 typed fail-visible validator、path-state classifier 与 redacted errors。Covers: B-003, B-004, B-008. Owner: implementation agent. Dependencies: SP629-T1. Done when: missing、directory、FIFO、dangling/readable symlink、unreadable、invalid UTF-8 及内容负例按矩阵判定，INVALID 非零且不打印 value。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml runtime_config`; `cargo test --manifest-path vibeguard-runtime/Cargo.toml --test runtime_config_cli`。
- [ ] `SP629-T3` 统一 runtime policy、validator/getter 与 setup mode adapter，并加入 parity gate。Covers: B-005, B-006. Owner: implementation agent. Dependencies: SP629-T1..T2. Done when: 三入口 decision 一致、setup compatibility/strict/install exit matrix 保持、字段集合漂移被阻断。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml --test runtime_policy_cli`; `bash tests/hooks/test_runtime_config.sh`; `bash tests/test_setup_check.sh`; `bash tests/test_manifest_contract.sh`。
- [ ] `SP629-T4` 运行 Rust/config 提交门禁。Covers: B-001, B-002, B-003, B-004, B-005, B-006, B-007, B-008. Owner: verification owner. Dependencies: SP629-T1..T3. Done when: focused、完整 Rust、完整 setup 与 quick contract checks 在同一提交通过。Verify: `cargo check --manifest-path vibeguard-runtime/Cargo.toml`; `cargo test --manifest-path vibeguard-runtime/Cargo.toml`; `bash tests/test_setup.sh`; `bash scripts/local-contract-check.sh --quick`; `git diff --check`。

## 并行拆分

不并行：schema、Rust validator 与 getter fixtures 共享字段 contract，单 owner 降低漂移风险。

## 验证

- Product invariant 集合：B-001..B-008；task coverage union 完整。
- `python3 checks/check_workflow.py --repo . --spec-dir docs/specs/GH629`

## Handoff Notes

- `mode`: `plan_first`
- `artifacts`: `docs/specs/GH629/{product,tech,tasks}.md`、`docs/specs/GH629/{runtime-pinning.snapshot,tool-inventory.txt}`、spec index；implementation 计划修改 runtime-config schema、template、Rust validator/getters、setup check 与 focused contracts
- `runtime_pinning_snapshot`: `docs/specs/GH629/runtime-pinning.snapshot`；每次 implementation 开始/续跑先执行 `bash guards/universal/check_runtime_drift.sh check --snapshot docs/specs/GH629/runtime-pinning.snapshot --tool-inventory docs/specs/GH629/tool-inventory.txt --rules-dir rules/claude-rules`
- `verification_owner`: coordinator `/root`; independent reviewer 由 threads lane 指派且只读
- `stop_conditions`: 无 spec approval/`ready_to_implement`、W-20 drift、无法保持 env-over-JSON-default 优先级、schema/template/getter inventory 无法一致、错误可能泄露 value、setup mode exit contract 改变、或任一入口仍 silent fallback 时停止
- `lane_map`: spec 与 implementation 由 coordinator `/root` 单 writer；independent reviewer `/root/review_pr612` 只读且无 writable files；setup/full contract 等共享状态验证由 coordinator 串行运行
无 spec approval/`ready_to_implement` 时停止。禁止新增 Python runtime validator，禁止通过
放宽 `additionalProperties` 或恢复 silent fallback 解决失败。
