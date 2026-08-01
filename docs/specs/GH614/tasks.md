# Task Plan

## Linked Issue

GH-614: https://github.com/majiayu000/vibeguard/issues/614

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## 实现任务

- [x] `SP614-T1` Owner: `/root/audit_pr727_remote` — 把现有 timeout contract 从 45 更新为 60，并在 workflow 仍为 45 时记录确定性 RED。Depends on: live duplicate evidence and SpecRail implementation route allowed。Covers: B-001, B-005, B-007。Done when: 失败原因精确指向缺失的 `timeout-minutes: 60`。Verify: `bash -n tests/test_workflow_contracts.sh && bash tests/test_workflow_contracts.sh`。
- [x] `SP614-T2` Owner: `/root/audit_pr727_remote` — 将 `.github/workflows/ci.yml` 的 `validate-and-test.timeout-minutes` 从 45 调到 60，不改 job id、名称、matrix、步骤、命令或依赖。Depends on: SP614-T1。Covers: B-001, B-003, B-004, B-005, B-006。Done when: workflow diff 只有目标 timeout 一行，新增 contract 转绿。Verify: `git diff -- .github/workflows/ci.yml && bash tests/test_workflow_contracts.sh`。
- [x] `SP614-T3` Owner: `/root/audit_pr727_remote` — 运行 setup、workflow、文档、索引、U-16 与 broad contract 验证并记录 fresh 输出。Depends on: SP614-T2。Covers: B-002, B-004, B-006, B-007。Done when: focused/setup/quick/static 命令全部通过且 worktree 无意外产物。Verify: `bash tests/test_setup.sh && bash scripts/local-contract-check.sh --quick`。
- [ ] `SP614-T4` Owner: human maintainer — 审查纠正 PR，并获取当前 SHA 完整 GitHub CI、review thread 与 required PR gate 证据后决定是否合并。Depends on: SP614-T3 and explicit human confirmation。Covers: B-001, B-002, B-003, B-004, B-005, B-006, B-007。Done when: gate 为 `allowed`、人类明确批准且 PR 已合并；当前任务不得代替该确认。Verify: `python3 checks/pr_gate.py --repo . --evidence <current-evidence> --mode required --json`。

## 并行拆分

实现改动只有两个相互关联文件，采用单一可写 lane：

- implementation：`/root/audit_pr727_remote`，独占 `.github/workflows/ci.yml` 与
  `tests/test_workflow_contracts.sh`。
- human_review：待维护者在 PR 上完成，不拥有本地文件、不提交实现修改。

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
  verification_owner: /root/audit_pr727_remote
  stop_conditions:
    - 新 contract 未在旧 45 分钟配置上先红
    - 实现需要修改 setup 产品行为、fixture 或断言
    - required check 名、OS matrix、步骤命令或 benchmark 依赖发生变化
    - 任一真实 CI、独立审查、review thread 或 required PR gate 未通过
  lane_map:
    implementation: /root/audit_pr727_remote
    human_review: pending
```

关键决策：使用 60 分钟有限总上限，为 45 分 16 秒取消点提供 14 分 44 秒余量；
不拆 job、不改 required context、不弱化测试。纠正分支从 `origin/main` 的
`ce5bada07bda1ae72b5488fcf08be8982185a115` 创建；合并与最终批准保留给人类。
