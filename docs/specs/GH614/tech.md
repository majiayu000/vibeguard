# Tech Spec

## Linked Issue

GH-614: https://github.com/majiayu000/vibeguard/issues/614

## Product Spec

[`product.md`](product.md)

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| 主 CI matrix | `.github/workflows/ci.yml:21` | `validate-and-test` 生成稳定的 Ubuntu/macOS required check | 必须保持 job id、名称表达式和 OS matrix |
| 总作业上限 | `.github/workflows/ci.yml:24` | Ubuntu/macOS 共用 `timeout-minutes: 45` | macOS 已在 45 分 16 秒被取消 |
| setup 覆盖 | `.github/workflows/ci.yml:282` | `bash tests/test_setup.sh` 是普通阻塞步骤 | 不能删除、跳过、弱化或改成 advisory |
| 后续回归 | `.github/workflows/ci.yml:294` | setup 后仍有 GC、hook、stats、precision、performance 与 benchmark 检查 | 总作业取消会使后续证据全部缺失 |
| benchmark 依赖 | `.github/workflows/ci.yml:485` | `Benchmark Report` 依赖完整 `validate-and-test` | 必须保持依赖和现有 check 拓扑 |
| workflow contract | `tests/test_workflow_contracts.sh:621` | 精确固定 45 分钟、稳定名称、matrix 与 setup 阻塞语义 | 本次必须先改为 60 并在旧 workflow 上记录 RED |
| spec 索引 | `docs/specs/README.md:5` | 维护 active/draft spec 入口 | 重开纠正期间恢复为 Draft |

远端事实快照（2026-08-01）：PR #727 head
`3947abd7583ac90a93516ee8476d807c3856dfca` 的 run `30651857110`、
macOS job `91226778977` 从 `2026-07-31T19:44:43Z` 到 `20:30:02Z`，结论为
`cancelled`。步骤 1–63 均成功（不适用的 Windows 步骤除外），约 34 分钟的
`Setup regression tests` 已通过；第 64 步 `Guard unit tests` 被取消，后续
precision、performance 与 benchmark 被跳过。实现不得通过改名 required context、
跳过步骤或弱化阻塞语义规避该事实。

## 设计方案

1. 在 `.github/workflows/ci.yml` 中仅把 `validate-and-test.timeout-minutes`
   从 `45` 调整为 `60`。
2. 保持 `validate-and-test` job id、`CI (${{ matrix.os }})` 名称、
   `os: [ubuntu-latest, macos-latest]`、全部步骤顺序及
   `benchmark-report.needs: validate-and-test` 不变。
3. 60 分钟相对已观测的 45 分 16 秒取消点提供 14 分 44 秒余量。它仍是
   fail-closed 的有限上限；正常运行的计费时长不变，只有异常挂起时每个 matrix
   leg 的最坏上限增加 15 runner-minutes。
4. 更新 `tests/test_workflow_contracts.sh` 的 `ci setup timeout headroom` contract：
   - 定位 `validate-and-test` job block；
   - 要求稳定名称、Ubuntu/macOS matrix 与 `timeout-minutes: 60`；
   - 定位 `Setup regression tests` step，要求精确命令
     `bash tests/test_setup.sh` 且不存在 `continue-on-error`；
   - 不把 GitHub 历史运行时长写成脆弱的动态测试输入。
5. contract 必须先在旧值 `45` 上红，再进行 workflow 一行实现，确保测试真正
   证明缺失行为而不是事后装饰。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 | `.github/workflows/ci.yml` 总上限 | `bash tests/test_workflow_contracts.sh`；实现 PR 完整 macOS CI |
| B-002 | setup step block | contract 检查精确命令与无 `continue-on-error`；`bash tests/test_setup.sh` |
| B-003 | job name 与 OS matrix | contract 检查 `CI (${{ matrix.os }})` 和两个 OS；读取 main branch protection evidence |
| B-004 | 既有步骤与 benchmark 依赖不变 | `git diff -- .github/workflows/ci.yml` 只出现 timeout 一行；完整 CI rollup |
| B-005 | 有限 60 分钟上限 | contract 精确要求 `timeout-minutes: 60`，不得删除或设为无界 |
| B-006 | 非目标 job/latency contract | `git diff --check`；`bash tests/test_hook_perf_contract.sh`；workflow diff review |
| B-007 | workflow contract | 红态 fixture/旧值运行失败证据；绿态 `bash tests/test_workflow_contracts.sh` |

## 数据流

GitHub 事件触发 `validate-and-test` → matrix 生成 Ubuntu/macOS 两个稳定 check →
每个 leg 继承 60 分钟有限总上限 → 按原顺序执行全部阻塞步骤（含 setup）→ 两个
leg 成功后才触发 `Benchmark Report`。没有新增持久化、外部写入、secret 或网络接口。

## 备选方案

- 只重跑超时 job：45 分 16 秒的真实取消已证明当前边界不足；重跑不能消除错误
  状态与人工等待，因此拒绝。
- 拆分独立 macOS setup job：能隔离长步骤，但会引入新的 check 名、branch
  protection 迁移、依赖聚合和额外 runner 启动；对当前 P0 修复风险过高，后续可在
  有独立成本/拓扑 spec 时评估。
- 修改或删减 setup fixture：违反覆盖与测试完整性，拒绝。
- 按 OS 动态 timeout：需要把简单 OS list 改成 include matrix；正常运行成本并不
  由上限决定，因此本次不为仅减少异常最坏成本增加 YAML 复杂度。
- 直接设为无界或极大值：会掩盖真实挂起并增加成本，拒绝。

## 风险

- Security: 不新增权限、secret 或外部调用；required checks 仍由现有分支保护约束。
- Compatibility: required check 名、job id、matrix 和 benchmark 依赖保持不变。
- Performance: 正常运行耗时不变；异常挂起的最坏上限从 45 增至 60 分钟。
- Maintenance: contract 固定 60 分钟策略值；未来调整必须同步 spec 与测试，避免
  静默回退到无余量配置。

## 测试计划

- [ ] Unit tests: N/A；纯 GitHub Actions 配置与 shell contract 改动。
- [ ] Integration tests: `bash tests/test_workflow_contracts.sh`，先红后绿。
- [ ] Integration tests: `bash tests/test_setup.sh`，证明 setup 覆盖未弱化。
- [ ] Integration tests: `bash scripts/local-contract-check.sh --quick`。
- [ ] Static validation: `bash scripts/ci/validate-workflow-contracts.sh`、
      `bash scripts/ci/validate-doc-paths.sh`、
      `bash scripts/ci/validate-doc-command-paths.sh`、`git diff --check`。
- [ ] Manual verification: 读取实现 PR 当前 head 的 GitHub CI rollup，要求全部 check
      completed/success、无 unresolved review thread，并运行 SpecRail required PR gate。

## 回滚方案

若 60 分钟上限造成不可接受的异常成本，整体回滚本次 workflow、contract 与 spec
提交以恢复 45 分钟，并保持 GH614 打开或建立明确的替代 Issue，因为 45 分钟已被
真实运行越过。禁止只删除 contract、保留未证明的配置；任何替代方案仍须保留全部
阻塞步骤、required check 名称和 benchmark 依赖。
