# Task Plan

## Linked Issue

GH-629

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`
- Status: draft；执行前必须有 spec approval 与 `ready_to_implement`

## 实现任务

- [ ] `SP629-T1` 定义 runtime-config schema、兼容规则与完整 getter/template 字段 inventory，并把 3 个已支持但未出现在 template 的 path 补入 template。Covers: B-001, B-002, B-007. Owner: implementation agent. Dependencies: spec approval. Done when: template/legacy v1/explicit v1 contract 可机读，schema 与 production getter path 无缺漏。Verify: schema positive/negative fixtures与 inventory drift mutation。
- [ ] `SP629-T2` 在 Rust 中实现 typed fail-visible validator 与 redacted errors。Covers: B-003, B-004, B-008. Owner: implementation agent. Dependencies: SP629-T1. Done when: 非法值均非零且不打印 value。Verify: Rust unit tests。
- [ ] `SP629-T3` 统一 runtime policy、getter 与 setup check，并加入 parity gate。Covers: B-005, B-006. Owner: implementation agent. Dependencies: SP629-T1..T2. Done when: 三入口 decision 一致且字段集合漂移被阻断。Verify: shell integration、manifest contract tests。
- [ ] `SP629-T4` 运行 Rust/config 提交门禁。Covers: B-001, B-002, B-003, B-004, B-005, B-006, B-007, B-008. Owner: verification owner. Dependencies: SP629-T1..T3. Done when: focused 和完整 Rust tests 在同一提交通过。Verify: `cargo check --manifest-path vibeguard-runtime/Cargo.toml`; `cargo test --manifest-path vibeguard-runtime/Cargo.toml`; focused shell tests。

## 并行拆分

不并行：schema、Rust validator 与 getter fixtures 共享字段 contract，单 owner 降低漂移风险。

## 验证

- Product invariant 集合：B-001..B-008；task coverage union 完整。
- `python3 checks/check_workflow.py --repo . --spec-dir docs/specs/GH629`

## Handoff Notes

- `mode`: `plan_first`
- `artifacts`: `docs/specs/GH629/{product,tech,tasks}.md`、spec index；implementation 计划修改 runtime-config schema、template、Rust validator/getters、setup check 与 focused contracts
- `runtime_pinning_snapshot`: None；实现沿用仓库 pinned Rust toolchain 与现有无第三方 runtime dependency 边界
- `verification_owner`: coordinator `/root`; independent reviewer 由 threads lane 指派且只读
- `stop_conditions`: 无 spec approval/`ready_to_implement`、无法保持 env-over-JSON-default 优先级、schema/template/getter inventory 无法一致、错误可能泄露 value、或任一入口仍 silent fallback 时停止
- `lane_map`: spec 与 implementation 均由 coordinator 单 writer；independent reviewer 只读，无 writable files；setup/full contract 等共享状态验证串行运行
无 spec approval/`ready_to_implement` 时停止。禁止新增 Python runtime validator，禁止通过
放宽 `additionalProperties` 或恢复 silent fallback 解决失败。
