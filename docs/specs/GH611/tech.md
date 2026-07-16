# Tech Spec

## Linked Issue

GH-611

## Product Spec

`docs/specs/GH611/product.md`

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Benchmark runner | `tests/bench_hook_latency.sh` | direct/wrapper 各自采样并重复计算 percentile/status；任一 P95 breach 立即累加 failure | confirmation 必须覆盖两种 fixture 且避免继续复制 decision logic |
| CI invocation | `.github/workflows/ci.yml` | `--runs=3 --fail-on-regression` | 三样本 P95 实际选择 max，单 outlier 直接阻断 PR |
| Contract harness | `tests/test_hook_perf_contract.sh` | persistent synthetic slow 证明 hard gate 会失败，但没有 transient outlier 恢复与证据断言 | 新正反路径的 deterministic 入口 |
| Public contract | `docs/reference/hook-latency-contract.md` | 声明 P95 breach 立即失败，未描述确认语义 | 必须同步用户可见 gate contract |

## 根因

当前 index 为 `count * 95 / 100`。CI count=3 时 index=2，选中排序后的第三项，即 max；
默认 count=5 时同样选中 max。spawn baseline 只在所有 fixture 前采样，无法识别中途单次
runner stall。PR #610 初次远端 breach 542ms/500ms、同 head rerun pass；本地又在不同
fixture 产生 1014ms/900ms outlier，证明错误不是特定 hook 的持续回归。

## 设计方案

1. 将采样、percentile 计算和最终 decision 拆成可复用 helper；direct hook 与 Codex wrapper
   只保留各自的执行 adapter，共享状态机与 evidence serialization。
2. 保留当前 `RUNS` 作为 initial batch size。初始 P95 未 breach 时直接输出普通 PASS；不
   增加健康路径耗时。
3. 初始 P95 breach 且 environment healthy 时，用完全相同的 fixture、budget、环境与
   `RUNS` 执行 confirmation batch。confirmation breach 才累加 `FAILURES`；confirmation
   pass 使用明确的 `PASS-CONFIRMED`（最终命名由实现保持一致）状态。
4. Internal JSON 的旧顶层 `p50/p95/p99/max/status/runs` 始终镜像 initial batch，保持旧
   consumer 语义；新增 `decision` 闭集 `normal_pass | cleared_transient |
   confirmed_regression | environment_distorted | confirmation_error`、`initial` metrics object、
   `confirmation`（未触发/失败时为 null，否则为同 shape metrics object）和
   `confirmation_runs`（未触发为 0）。
5. Benchmark-action 的旧 `e2e <display> P50/P95/P99` rows 保持 initial 数值且继续使用
   `unit: ms`。触发确认时追加固定 rows：`e2e <display> confirmation P95`、
   `e2e <display> budget`，以及三选一的 `e2e <display> decision cleared`、
   `... decision confirmed-regression`、`... decision confirmation-error`；decision row 的
   numeric value 为 confirmation P95，error 时为 initial P95。所有新增 row 仍为 ms，旧
   JSON parser contract 不变。
6. 新增 deterministic direct transient 与 wrapper transient fixtures：第一次批次超 budget，
   后续确认批次正常；与现有 persistent synthetic slow fixture 分别固定两种 adapter 的
   cleared 分支和 confirmed-regression 分支。wrapper fixture 必须断言恰好一次确认并复用
   相同 serializer/decision enum。
7. confirmation 命令失败、样本数不足或 percentile 为空时输出 ERROR 并非零退出，同时先
   flush initial evidence：internal decision 为 `confirmation_error`、confirmation 为 null；
   action output 只有 initial/budget/error rows，严禁 cleared row。继续保留 distorted 分支。
8. 新增正整数参数 `--confirmation-runs=<n>`，默认等于 `RUNS`；CI 显式传
   `--confirmation-runs=3`，使 hard-gate 语义不依赖隐式默认。非法值按 B-009 失败。

## Product-to-Test Mapping

| Invariant | Implementation | Verification |
| --- | --- | --- |
| B-001/B-005 | breach-triggered fixture-local confirmation | contract test 断言 normal fixture 无 confirmation，transient fixture 恰有一次 confirmation |
| B-002 | confirmed regression decision | persistent slow fixture 非零且两批均 breach |
| B-003/B-004 | evidence model 与 serializers | console/JSON/action output 断言 initial、confirmation、budget、cleared decision |
| B-006 | existing distortion branch | 既有 distorted spawn test 保持通过且无伪 confirmation |
| B-007 | shared evaluator | direct transient 与 deterministic wrapper transient 都断言一次确认、相同 decision/evidence serializer |
| B-008 | deterministic synthetic fixtures | `bash tests/test_hook_perf_contract.sh` |
| B-009 | validation/error path | confirmation failure 开启两类 machine output，断言非零、initial 保留、confirmation null、error row 存在且 cleared/PASS rows 不存在 |

## 备选方案

- 提高 budget：拒绝，会隐藏真实回归且违反 #611 非目标。
- 只增加到 5 个样本：拒绝，当前 percentile 公式下 P95 仍等于 max。
- CI 失败后人工 rerun workflow：拒绝，证据割裂且浪费完整 job 时间。
- 忽略 max 或裁剪最高样本：拒绝，会永久丢失 tail evidence。
- 初次 breach 后直接通过：拒绝，持续回归将被放行。

## 风险

- False negative: confirmation 可能偶然变快；要求 persistent fixture 两批均慢，并保留 initial
  breach 供趋势审计，不提高预算。
- Runtime: 只有 breached fixture 增加采样，健康路径不变。
- Schema drift: internal/action output consumers 可能依赖字段/name；新增字段与 entries 保持旧
  核心字段存在，并由 contract test 固定。
- Duplication: direct/wrapper 当前逻辑重复；实现必须共享 evaluator，不能分别补丁。

## 测试计划

- [ ] Syntax/ShellCheck: benchmark 与 contract harness。
- [ ] Focused: transient cleared、persistent confirmed、normal no-confirmation、distorted 分支。
- [ ] Output: console、internal JSON、benchmark-action JSON 全部具名断言。
- [ ] Real: build runtime 后运行 CI 等价 latency command。
- [ ] Broad: performance validator、local contract quick、diff check。

## 回滚方案

原子回滚 shared confirmation evaluator、synthetic fixtures、output fields 与文档。不得只删除
persistent negative assertion或仅保留 cleared 分支，否则 hard gate 会被弱化。
