# Tech Spec — SpecRail packet 阶段化与基线防降级

## Linked Issue

GH-720

## Product Spec

见 `product.md`。

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| CLI 与 packet 校验 | `checks/check_workflow.py:248`、`checks/check_workflow.py:288` | 解析 git commit、检查基线文件并校验单 packet | 阶段语义与 fail-closed 基线查询的核心 |
| packet 发现 | `checks/check_workflow.py:395`、`checks/check_workflow.py:433` | 从配置根发现当前工作树 packet，并选择待校验集合 | 必须把基线 packet 纳入 `--all-specs` 并集，防止整目录删除绕过 |
| route 输出 | `checks/route_gate.py:369` | 返回 route 对应的确定性验证命令 | `write_spec` 与实现阶段需要不同 stage |
| GitHub workflow | `.github/workflows/workflow-check.yml:3`、`.github/workflows/workflow-check.yml:35` | PR/push 调用完整 packet 检查 | 依据 Draft 状态选择 stage，并在状态切换时重跑 |
| 回归覆盖 | `tests/test_specrail_adoption.sh:61`、`tests/test_specrail_adoption.sh:210` | 校验 adopted workflow 与临时 packet 行为 | 覆盖正例、缺文件、非法任务、单文件删除、整 packet 删除和 route 命令 |
| 使用合同 | `AGENT_USAGE.md:132` | 说明本地 workflow/route 验证 | 需要公开 Draft 与 Complete 的精确用法 |

## 设计方案

1. 在 `checks/check_workflow.py` 增加闭集参数
   `--spec-stage {complete,draft}`，默认 `complete`。
2. `validate_spec_packet()` 始终校验 product/tech；Complete 强制
   `tasks.md`，Draft 在文件存在时仍调用原任务计划校验器。
3. `--base-ref` 先由 `git rev-parse --verify <ref>^{commit}` 解析为确定 commit。
   所有 git 调用使用参数数组，不经过 shell。
4. Draft + base commit 时：
   - 单 packet 校验用 `git ls-tree` 判断基线是否已有 `tasks.md`；
   - `--all-specs` 额外枚举基线配置根下的直接 `GH<number>` 目录；
   - 当前与基线 packet 做去重并集后交给同一验证函数。
5. GitHub Actions 在 job 级共享事件类型、Draft 状态和 base SHA；主 packet
   check 与 adoption smoke 内的 checkout-wide check 都据此选择同一阶段。
   监听 `ready_for_review` 和 `converted_to_draft`。
6. `route_gate.py` 仅对 `write_spec` 输出 Draft 命令，其余 route 输出
   Complete 命令。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 | `check_workflow.py` 默认 stage 与 Complete 分支 | `python3 checks/check_workflow.py --repo . --all-specs`；临时缺 tasks 负例 |
| B-002 | `validate_spec_packet()` Draft 分支 | `bash tests/test_specrail_adoption.sh` 的 product+tech-only 正例 |
| B-003 | 非普通路径检查 + 复用 `validate_task_plan()` | 同一 smoke test 的 `tasks.md` 目录与非法内容负例 |
| B-004 | `discover_baseline_spec_packet_dirs()` 与选择并集 | 同一 smoke test 删除完整 `GH999` 的 `--all-specs` 负例 |
| B-005 | `git_path_exists()` | 同一 smoke test 删除基线 `tasks.md` 负例 |
| B-006 | `git_commit()`、NUL-delimited `git_path_exists()` 与基线目录发现 | smoke 中的非 ASCII git 基线路径正例；无效 base-ref 命令返回非零 |
| B-007 | workflow job env + adoption smoke 的 stage 分支 | product+tech-only 临时 packet 下用 Draft env 运行 `bash tests/test_specrail_adoption.sh` |
| B-008 | workflow `pull_request.types` | `bash tests/test_specrail_adoption.sh` 检查两个状态事件 token |
| B-009 | `checks/route_gate.py` | `bash tests/test_specrail_adoption.sh` 的 write_spec/implement route 断言 |
| B-010 | 原有 validator 调用链 | `bash scripts/local-contract-check.sh --quick` |

## 数据流

输入来自 CLI stage、可选 base ref、配置的 packet 根及当前文件树。base ref
先归一化为 commit，再由只读 git 查询产生基线 packet/文件存在性。当前 packet
与基线 packet 去重排序后逐一验证，所有错误聚合为非零退出。GitHub workflow
只负责从事件状态构造参数，不持久化新的状态。

## 备选方案

- 让所有 Draft PR 预先创建空 `tasks.md`：会伪造实现成熟度，并且空任务计划本身
  不具备可验证价值。
- 完全跳过 Draft 的 SpecRail check：会同时跳过 product/tech 和非法已有
  `tasks.md` 的校验。
- 只检查当前工作树中的 `tasks.md`：无法识别单文件或整个 packet 的删除降级。

## 风险

- Security: git ref 与路径只通过参数数组传递；配置根逃逸继续由 resolver 阻断。
- Compatibility: 默认保持 Complete，现有本地调用不改变。
- Performance: 仅 Draft CI 增加有界的本地 `git ls-tree` 查询，无网络调用。
- Maintenance: stage 枚举为闭集；新增阶段必须显式扩展 CLI、workflow 与测试。

## 测试计划

- [ ] Unit/focused: `bash tests/test_specrail_adoption.sh`
- [ ] Packet: `python3 checks/check_workflow.py --repo . --all-specs`
- [ ] Workflow contracts: `bash tests/test_workflow_contracts.sh`
- [ ] Broad local: `bash scripts/local-contract-check.sh --quick`
- [ ] PR evidence: GitHub CI、独立 reviewer 与 `checks/pr_gate.py`

## 回滚方案

同一回滚中恢复 workflow 的旧调用、移除 stage/base-ref CLI 与 route 文档，并
恢复对应测试。不得只回滚 workflow 而留下无人调用的宽松 Draft 路径，也不得
保留 Draft workflow 却移除基线防降级检查。
