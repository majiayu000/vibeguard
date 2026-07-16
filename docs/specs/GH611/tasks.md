# Task Plan

## Linked Issue

GH-611

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## 实现任务

- [ ] `SP611-T1` Owner: implementation agent — 为 transient outlier、persistent regression、normal 和 distorted 路径补 deterministic red tests。Depends on: Spec PR merged and live implementation route allowed。Covers: B-001, B-002, B-003, B-005, B-006, B-008, B-009。Done when: 当前实现不能区分 transient/persistent，新增断言以预期方式失败且未弱化既有 slow fixture。Verify: focused contract harness。
- [ ] `SP611-T2` Owner: implementation agent — 抽取 direct/wrapper 共用的 sampling/percentile/confirmation decision，并只在 initial breach 时运行同 fixture confirmation。Depends on: SP611-T1。Covers: B-001, B-002, B-003, B-005, B-006, B-007, B-009。Done when: 相同 budget/workload 下 transient cleared、persistent fail closed、normal 无额外批次，错误路径显式失败。Verify: syntax、ShellCheck、focused contract harness。
- [ ] `SP611-T3` Owner: implementation agent — 扩展 console/internal/action evidence 并更新 latency contract，不改变预算表。Depends on: SP611-T2。Covers: B-003, B-004, B-007, B-008。Done when: 三种输出保留 initial/confirmation/final decision，旧核心 metrics 仍存在。Verify: JSON parsing 与具名 output assertions。
- [ ] `SP611-T4` Owner: verification owner + independent reviewer — 运行真实 CI 等价 benchmark、performance/broad gates并逐项审查。Depends on: SP611-T3。Covers: B-001..B-009。Done when: deterministic gates 全绿、persistent slow 仍红、无 budget/hook/timeout scope drift，当前 PR head 的 CI/threads/PR gate 有 fresh 证据。Verify: performance contract、latency benchmark、local contract quick、SpecRail review/gate。

## 并行拆分

T1-T3 共享 benchmark/harness/output contract，必须由单 implementation lane 串行完成；
T4 reviewer 只读。

| Lane | Owner | Writable files |
| --- | --- | --- |
| implementation | `/root` | `tests/bench_hook_latency.sh`, `tests/test_hook_perf_contract.sh`, `docs/reference/hook-latency-contract.md` 及必要的 CI invocation |
| verification | `/root` | none |
| independent_review | native reviewer agent | none |

## Plan-First Handoff

```yaml
handoff:
  mode: specrail-implement
  artifacts:
    - docs/specs/GH611/product.md
    - docs/specs/GH611/tech.md
    - docs/specs/GH611/tasks.md
  runtime_pinning_snapshot: None
  verification_owner: /root
  stop_conditions:
    - Any latency budget is raised or production hook code changes.
    - A persistent slow fixture passes or an incomplete confirmation looks cleared.
    - Initial breach evidence is overwritten or omitted from machine output.
    - Direct and wrapper fixtures gain divergent decision implementations.
    - Scope expands to the macOS job timeout.
  lane_map:
    implementation: /root
    verification: /root
    independent_review: native reviewer agent (read-only)
```

## 验证

```bash
python3 checks/check_workflow.py --repo . --spec-dir=docs/specs/GH611
python3 checks/check_workflow.py --repo . --all-specs
bash scripts/ci/validate-doc-paths.sh
bash scripts/ci/validate-doc-command-paths.sh
git diff --check
```

## Handoff Notes

- 写作基线：`origin/main@43d3678b569548446397da85b38cb7dc0c9abd65`。
- #610 的 initial failure、failed-only rerun success 与本地不同 fixture outlier 是诊断证据，
  不得把具体毫秒数写成长期测试阈值。
- Issue #611 readiness、duplicate evidence 与实现基线必须在 Spec merge 后重新获取。
