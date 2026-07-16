# Task Plan: GH618 compliance 语言矩阵

## Linked Issue

GH-618

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## 实现任务

- [ ] `SP618-T1` Owner: implementation agent — 扩展现有 compliance focused harness，以隔离 fixtures 先复现 Rust/Go/JS/TS/mixed/undeclared/invalid manifest/config 的错误分类，并保留 Python/default/override 回归。Depends on: Spec PR merged and implementation route allowed。Covers: B-001, B-002, B-003, B-004, B-006, B-007, B-008, B-009。Done when: 具名断言覆盖语言 pack、Python 专属文案排除、共享 module 去重、WARN/FAIL/status 与无 fallback，且 production fix 前按预期失败。Verify: `bash tests/unit/test_compliance_check.sh`。
- [ ] `SP618-T2` Owner: implementation agent — 在现有 project config validator 增加 schema 验证后的机器可读 languages 输出，默认 CLI 保持兼容。Depends on: SP618-T1。Covers: B-005, B-006, B-007, B-009。Done when: 有效声明按合同输出，缺失/空声明输出为空，非法 JSON/类型/语言维持可见错误和非零状态。Verify: `python3 -m py_compile scripts/lib/project_config_validate.py`; focused harness。
- [ ] `SP618-T3` Owner: implementation agent — 在现有 manifest helper 增加去重的 language guard-module 查询，不复制语言/module 表且文件不超过 800 行。Depends on: SP618-T1。Covers: B-003, B-004, B-005, B-008。Done when: Rust/Go/Python/JS/TS 映射来自 manifest，JS+TS 共享 module 只输出一次，损坏 manifest 非零失败，helper 总行数小于等于 800。Verify: `python3 scripts/lib/vibeguard_manifest.py validate`; focused harness; `wc -l scripts/lib/vibeguard_manifest.py`。
- [ ] `SP618-T4` Owner: implementation agent — 修改 checker 读取目标根显式语言、报告 guard pack、只对 Python 声明运行 Python 专属检查，并把 helper/manifest 错误桥接为 FAIL。Depends on: SP618-T2, SP618-T3。Covers: B-001, B-002, B-003, B-004, B-006, B-007, B-008, B-009。Done when: 无语言猜测或静默 fallback，通用检查/summary/显式 guard root/命令入口保持兼容。Verify: `bash -n scripts/verify/compliance_check.sh tests/unit/test_compliance_check.sh`; `bash tests/unit/test_compliance_check.sh`。
- [ ] `SP618-T5` Owner: implementation agent — 执行 unit、manifest/schema、workflow、文档与 quick gates，并复核 diff/行数/范围。Depends on: SP618-T4。Covers: B-001, B-002, B-003, B-004, B-005, B-006, B-007, B-008, B-009。Done when: 所有 fresh 命令通过，reviewer 无 blocker，review threads 为零，PR gate 对当前 head 返回 allowed。Verify: `bash tests/unit/run_all.sh`; `bash tests/test_manifest_contract.sh`; `bash tests/test_workflow_contracts.sh`; `bash scripts/ci/validate-doc-paths.sh`; `bash scripts/ci/validate-doc-command-paths.sh`; `bash scripts/local-contract-check.sh --quick`; `git diff --check`。

## 并行拆分

本变更的 checker、两个 helper 与同一个 focused harness 强耦合，采用单一 implementation writer。
独立 reviewer 仅只读检查 spec 覆盖、失败语义、测试 mutation 与当前 PR head，不写共享文件。

## 验证

- Evidence: focused 与 unit runner 覆盖全部语言/失败矩阵。
- Evidence: manifest、project schema、workflow 与 auto-optimize 入口合同通过。
- Evidence: Python helper 可编译，shell syntax 通过，manifest helper 不超过 800 行。
- Evidence: 文档路径、quick gate、diff check、CI、review threads 与 SpecRail PR gate 通过。

## Handoff Notes

- `mode`: `specrail-implement`
- `artifacts`: `docs/specs/GH618/product.md`, `docs/specs/GH618/tech.md`, `docs/specs/GH618/tasks.md`
- `runtime_pinning_snapshot`: None；本变更不修改或要求 production runtime。
- `verification_owner`: `/root`
- `stop_conditions`: schema/manifest 需要新增重复语言表；helper 超过 800 行且无法最小拆分；非法配置只能通过 fallback 继续；focused/unit/contract/quick gate 失败；独立 review 有 blocker；当前-head CI、review threads 或 PR gate 未通过。
- `lane_map`: implementation `/root` 独占 `scripts/verify/compliance_check.sh`, `scripts/lib/project_config_validate.py`, `scripts/lib/vibeguard_manifest.py`, `tests/unit/test_compliance_check.sh`；independent reviewer `/root/review_pr612` 只读，无可写文件。
- Spec PR 只 `Refs #618`；只有独立 Impl PR 合并后才关闭 Issue。
