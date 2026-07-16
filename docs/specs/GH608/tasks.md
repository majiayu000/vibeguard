# Task Plan

## Linked Issue

GH-608

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## 实现任务

- [ ] `SP608-T1` Owner: implementation agent — 新增隔离的 compliance focused harness，先复现默认调用把 bundled duplicate/naming guards 报告为缺失。Depends on: Spec PR merged and live implementation route allowed。Covers: B-002, B-003, B-004, B-007。Done when: 测试从仓库外 cwd 调用 absolute entrypoint，使用临时 HOME/project，失败证据绑定两个具名 guard 和错误来源路径。Verify: `bash tests/unit/test_compliance_check.sh` 在 production fix 前以预期断言失败。
- [ ] `SP608-T2` Owner: implementation agent — 修正 compliance entrypoint 的默认 VibeGuard 根目录，同时保留显式环境变量优先级与完整 quoting。Depends on: SP608-T1。Covers: B-001, B-002, B-003, B-004, B-005, B-006。Done when: 默认 fixture 找到仓库 bundled guards；路径含空格的显式 fixture 被优先使用；shared discovery、其他 Layer 与 exit contract 未改。Verify: 对 entrypoint 与新增 focused harness 执行 shell syntax check，再运行该 focused harness。
- [ ] `SP608-T3` Owner: implementation agent — 把 focused harness 纳入现有 unit runner 并执行文档/跨表面回归，不修改 runner discovery。Depends on: SP608-T2。Covers: B-004, B-006, B-007。Done when: `test_compliance_check.sh` 被自动发现，具名断言与 expected status 全部通过，未固定 summary totals。Verify: `bash tests/unit/run_all.sh`; `bash scripts/ci/validate-doc-paths.sh`; `bash scripts/ci/validate-doc-command-paths.sh`; `bash scripts/local-contract-check.sh --quick`; `git diff --check`。
- [ ] `SP608-T4` Owner: verification owner + independent reviewer — 对 product/tech/tasks、implementation diff 与 fresh verification 做逐项覆盖审查。Depends on: SP608-T3。Covers: B-001, B-002, B-003, B-004, B-005, B-006, B-007。Done when: reviewer 确认根因被修复、无 shared search matrix 复制、无真实 HOME 依赖、无 exit semantics 或非目标脚本变化；当前 PR head 的 CI、review threads 与 SpecRail PR gate 均有有效证据。Verify: SpecRail implementation check、advisory review 与 PR gate 输出。

## 并行拆分

T1-T3 共享 entrypoint 与 focused harness，必须由单一 implementation lane 串行完成。
T4 的 independent reviewer 只读，不与实现 lane 共享 writable file。

| Lane | Owner | Writable files |
| --- | --- | --- |
| implementation | `/root` | `scripts/verify/compliance_check.sh` 与新增 compliance focused harness |
| verification | `/root` | none（只运行命令与记录证据） |
| independent_review | native reviewer agent | none（只读 review） |

## Plan-First Handoff

```yaml
handoff:
  mode: specrail-implement
  artifacts:
    - docs/specs/GH608/product.md
    - docs/specs/GH608/tech.md
    - docs/specs/GH608/tasks.md
  runtime_pinning_snapshot: None
  verification_owner: /root
  stop_conditions:
    - The default root still resolves to scripts instead of the repository root.
    - An explicit VIBEGUARD_DIR override or a path containing spaces stops working.
    - Tests depend on the real user HOME, swallow an unexpected status, or assert only summary totals.
    - The shared guard search matrix, exit semantics, metrics collector, or another non-goal changes.
    - A real CI, review-thread, or SpecRail PR gate is blocked.
  lane_map:
    implementation: /root
    verification: /root
    independent_review: native reviewer agent (read-only)
```

## 验证

```bash
python3 checks/check_workflow.py --repo . --spec-dir=docs/specs/GH608
python3 checks/check_workflow.py --repo . --all-specs
bash scripts/ci/validate-doc-paths.sh
bash scripts/ci/validate-doc-command-paths.sh
git diff --check
```

## Handoff Notes

- 写作基线：`origin/main@57f4128b091d6b84add94d0fa491b68b69564629`。
- Issue #608 的 live readiness label、实现前最新 `origin/main` 基线与当前 PR head 证据都必须
  重新获取；durable spec packet 不替代 live state。
- 本规格只覆盖已复现的 compliance entrypoint root bug。support matrix 与其他脚本的相似
  finding 必须独立 triage，不能借本 PR 顺带修改。
