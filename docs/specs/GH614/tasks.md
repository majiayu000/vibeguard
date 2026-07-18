# Task Plan

## Linked Issue

GH-614: https://github.com/majiayu000/vibeguard/issues/614

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## 实现任务

- [ ] `SP614-T1` Owner: `/root` — 在 `tests/test_workflow_contracts.sh` 添加 timeout、稳定 check 名称、Ubuntu/macOS matrix、setup 精确命令和阻塞语义 contract。Depends on: Spec PR merged and live implementation route allowed。Covers: B-001, B-002, B-003, B-005, B-007。Done when: 旧 `timeout-minutes: 30` 上的新 contract 确定性失败，且失败原因指向缺失的 45 分钟余量。Verify: `bash tests/test_workflow_contracts.sh`。
- [ ] `SP614-T2` Owner: `/root` — 将 `.github/workflows/ci.yml` 的 `validate-and-test.timeout-minutes` 从 30 调到 45，不改 job id、名称、matrix、步骤、命令或依赖。Depends on: SP614-T1。Covers: B-001, B-003, B-004, B-005, B-006。Done when: workflow diff 只有目标 timeout 一行，新增 contract 转绿。Verify: `git diff -- .github/workflows/ci.yml && bash tests/test_workflow_contracts.sh`。
- [ ] `SP614-T3` Owner: `/root` — 运行 setup、workflow、文档与 broad contract 验证并记录 fresh 输出。Depends on: SP614-T2。Covers: B-002, B-004, B-006, B-007。Done when: focused/setup/quick/static 命令全部通过且 worktree 无意外产物。Verify: `bash tests/test_setup.sh && bash scripts/local-contract-check.sh --quick`。
- [ ] `SP614-T4` Owner: `/root` + independent reviewer — 创建独立 Impl PR，获取独立 reviewer、当前 SHA 全量 CI、reviewThreads 与 SpecRail required PR gate 证据后合并。Depends on: SP614-T3。Covers: B-001, B-002, B-003, B-004, B-005, B-006, B-007。Done when: gate 为 `allowed`、PR 已合并且 GH614 已关闭。Verify: `python3 checks/pr_gate.py --repo . --evidence <current-evidence> --mode required --json`。

## 并行拆分

实现改动只有两个相互关联文件，采用单一可写 lane：

- implementation：`/root`，独占 `.github/workflows/ci.yml` 与
  `tests/test_workflow_contracts.sh`。
- independent_review：只读 reviewer，不拥有文件、不提交修改。

禁止两个 agent 同时写 workflow contract 或 CI YAML。

## 验证

实现时先记录红态，再执行：

```bash
bash -n tests/test_workflow_contracts.sh
bash tests/test_workflow_contracts.sh
bash tests/test_setup.sh
bash scripts/ci/validate-workflow-contracts.sh
bash scripts/ci/validate-doc-paths.sh
bash scripts/ci/validate-doc-command-paths.sh
bash scripts/local-contract-check.sh --quick
git diff --check
```

最后读取实现 PR 当前 head 的 GitHub CI、独立 review 与 SpecRail PR gate。

## Handoff Notes

```yaml
handoff:
  mode: specrail-implement
  artifacts:
    - docs/specs/GH614/product.md
    - docs/specs/GH614/tech.md
    - docs/specs/GH614/tasks.md
  runtime_pinning_snapshot: None
  verification_owner: /root
  stop_conditions:
    - 新 contract 未在旧 30 分钟配置上先红
    - 实现需要修改 setup 产品行为、fixture 或断言
    - required check 名、OS matrix、步骤命令或 benchmark 依赖发生变化
    - 任一真实 CI、独立审查、review thread 或 required PR gate 未通过
  lane_map:
    implementation: /root
    independent_review: read_only_reviewer
```

关键决策：使用 45 分钟有限总上限，不拆 job、不改 required context、不弱化测试；
实现必须从 Spec PR 合并后的最新 `origin/main` 创建独立 worktree 与 Impl PR。
