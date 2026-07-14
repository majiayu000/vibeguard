# Task Plan

## Linked Issue

GH-588

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## 实现任务

- [ ] `SP588-T1` Owner: implementation agent — 在 `scripts/setup/check.sh` 增加只读 scheduled-GC freshness helper，并且只从 launchd active-valid target 与 systemd active timer 分支调用。Depends on: human spec approval。Covers: B-001, B-002, B-003, B-008。Done when: helper 与 scheduler 使用相同 interval key/default；只在 `0 <= age < interval` 时输出 OK；missing/empty/garbled/unreadable/future/exact-boundary/stale success 均 WARN；inactive/drift/absent 分支没有 freshness 行；没有新增 cron 或任何写操作。Verify: `bash -n scripts/setup/check.sh`；focused fixtures in `bash tests/test_setup.sh`。
- [ ] `SP588-T2` Owner: implementation agent — 为 unhealthy 路径增加平台 wrapper、公共 internal 日志的有界证据与 remediation，并把 `gc-last-attempt` 保持为可选关联信息。Depends on: SP588-T1。Covers: B-004, B-005, B-006。Done when: launchd wrapper 固定为 `gc-launchd.log`、systemd wrapper 固定为 `gc-systemd.log`、公共内部日志固定为 `gc-cron.log`；每个来源最多输出有界尾部最后一条匹配；无 attempt 的 pre-exec EPERM 仍可见；无日志时保留通用 WARN；提示不自动执行修复。Verify: focused log-source、missing-attempt、no-evidence、EPERM fixtures in `bash tests/test_setup.sh`。
- [ ] `SP588-T3` Owner: test agent（与 T1/T2 顺序执行，不并发写共享文件）— 扩展既有 `tests/test_setup.sh` harness 与 `tests/setup/install_flow_tests.sh` scheduler cases，覆盖两平台资格门槛、freshness 边界、日志来源、四种模式与只读幂等性。Depends on: SP588-T2。Covers: B-001, B-002, B-003, B-004, B-005, B-006, B-007, B-008。Done when: default-only WARN rc=0、strict rc=1/DEGRADED、JSON rc=1 且只有一个有效 JSON 文档并含 WARN event、install rc=0；检查前后 state/log/registration fixture 未改变；既有 absent INFO 与 target-drift assertions 仍通过。Verify: `bash tests/test_setup.sh`；`bash tests/test_gc_scheduled.sh`。
- [ ] `SP588-T4` Owner: verification owner — 执行 setup、GC、contract 与文档门禁，并记录绑定实现 head 的原始结果。Depends on: SP588-T3。Covers: B-001, B-002, B-003, B-004, B-005, B-006, B-007, B-008。Done when: 所有 focused/full checks 在同一最新 head 通过，diff 仅包含批准的实现/测试范围，任何平台未执行项均显式报告而不是推断通过。Verify: `bash tests/test_setup.sh`; `bash tests/test_gc_scheduled.sh`; `bash scripts/local-contract-check.sh --quick`; `git diff --check`。
- [ ] `SP588-T5` Owner: independent reviewer — 对照 GH-588 与 B-001..B-008 审查实现、测试完整性、日志来源、模式退出码和只读边界。Depends on: SP588-T4。Covers: B-001, B-002, B-003, B-004, B-005, B-006, B-007, B-008。Done when: reviewer 在当前 PR head 上确认不存在把 inactive/invalid registration 当 fresh、把 `gc-cron.log` 当 systemd wrapper、要求 attempt 才显示 pre-exec failure、或通过弱化断言获得通过的情况，并明确记录 verdict。Verify: read-only diff/spec review plus current-head CI evidence；不由 implementer 自批替代。

## 并行拆分

本实现不适合并行写入：T1 与 T2 都修改 `scripts/setup/check.sh`，T3 依赖最终输出契约并
修改共享 setup harness，因此按 T1 → T2 → T3 串行。T5 可在 T4 后作为独立只读 reviewer
lane；verification owner 不与 implementation lane 并发修改文件。

| Lane | Owner | Writable files |
| --- | --- | --- |
| Freshness implementation | one implementation agent | `scripts/setup/check.sh` |
| Regression fixtures | one test agent, after implementation | `tests/test_setup.sh`, `tests/setup/install_flow_tests.sh` |
| Verification/integration | root coordinator | no concurrent shared-file writes |
| Independent review | non-implementer reviewer | none (read-only) |

## Plan-First Handoff

```yaml
handoff:
  mode: specrail-implement
  artifacts:
    - docs/specs/GH588/product.md
    - docs/specs/GH588/tech.md
    - docs/specs/GH588/tasks.md
  runtime_pinning_snapshot: None
  verification_owner: root coordinator
  stop_conditions:
    - Human spec approval or ready_to_implement authorization is missing.
    - A proposed change writes outside scripts/setup/check.sh and the two approved setup test files without a new plan.
    - Freshness would run for inactive, absent, drifted, missing, or non-executable registration.
    - The implementation requires gc-last-attempt before surfacing wrapper failures.
    - A mode changes outside the B-007 WARN contract, a cron path is introduced, or check becomes mutating.
    - Tests require weakened assertions or overlapping writable ownership.
  lane_map:
    freshness_implementation: one implementation agent
    regression_fixtures: one sequential test agent
    verification_integration: root coordinator
    independent_review: non-implementer read-only reviewer
```

`runtime_pinning_snapshot` 为 `None`，因为当前 handoff 是单 issue、串行、边界明确的短实现；
若执行跨会话或超过 W-20 长任务阈值，implementation owner 必须在写入前另行捕获 snapshot，
不得复用本规格的代码行号作为运行时 pinning evidence。

## 验证

实现期间 focused checks：

```bash
bash -n scripts/setup/check.sh
bash tests/test_setup.sh
bash tests/test_gc_scheduled.sh
```

提交前 gates：

```bash
bash scripts/local-contract-check.sh --quick
bash scripts/ci/validate-doc-paths.sh
bash scripts/ci/validate-doc-command-paths.sh
git diff --check
```

## Handoff Notes

- 最新 live issue evidence 只包含 `bug`、`P2`、`dx`，没有受信任的 SpecRail readiness
  state/label；不提供 `--state` 时，write_spec 与 implement route 都返回
  `needs_human`，implement 还缺 duplicate evidence。readiness 与 spec approval 仍是人工
  gate，本 task plan 不构成 implementation authorization。
- 写作阶段曾显式传入 `--state ready_to_spec` 做本地规划状态检查；该假设性检查返回
  `allowed` 只证明“若状态已由可信流程确立，write_spec policy 可通过”，不能冒充 live
  GitHub readiness label、spec approval 或 implement authorization。
- 旧 plan/spec-588-gc-check-execution-freshness.md 在本规格 PR 中删除；后续唯一设计真相
  是 `docs/specs/GH588/`，不得同时维护两份不一致 spec。
- 实现前重新核对 line anchors 与 current head；本 tech spec 的 `path:line` 只表示写作时
  的树状态。
