# Product Spec

## Linked Issue

GH-595

关联实现 PR：#594。

## 用户问题

VibeGuard 目前不能在仓库内对 PR #587 或后续 PR 执行完整、可复现的
SpecRail 离线 gate。缺失的不是开关，而是 evidence adapter、workflow
validator、PR gate、runtime checkpoint gate 及其 schema、fixture 和测试本身。
如果在这些能力缺失时把自动化授权视为 merge 依据，agent 可能在没有当前
head、CI、review threads、独立 reviewer、merge state 或人工授权证据时给出
错误的 merge-ready 结论。

VibeGuard 还需要保持自己的采用边界：spec packet 位于
`docs/specs/GH<number>/`，人类可读内容默认使用 `zh-CN`，持久化
`auth_mode` 保持 `review`，repository adoption 不得隐式安装用户目录下的
Codex skills，也不得把源仓库示例伪装成目标仓库的本地证据。

## 目标

- 在仓库内提供可离线复现、默认 fail-closed 的 SpecRail workflow、PR 和
  runtime checkpoint gates。
- 从 GitHub 只读收集绑定当前 PR head 的 CI、review、review threads、
  merge state、linked issue 和 reviewer-lane 证据。
- 保持 VibeGuard 的 spec root、locale、持久化授权模式和现有文档所有权。
- 用固定上游 SHA、target-local adoption smoke 和负例 fixture 证明采用结果，
  并让 CI 持续执行这些检查。
- 保留 readiness、spec approval、human final review、merge、security 和
  release 等人工 gate。

## 非目标

- 不在本 issue 中安装或更新 `$CODEX_HOME/skills`、`~/.codex/skills` 或全局
  `AGENTS.md`。
- 不自动评论、approve、mark-ready、merge 或关闭 #587、#594 或其他 PR/issue。
- 不把 `implx auto` 解释为绕过 CI、PR gate、runtime ledger、review threads、
  reviewer-lane 或 merge-state evidence 的永久授权。
- 不替换 VibeGuard 的 README、LICENSE、CHANGELOG、运行时实现或构建规则。
- 不把外部仓库路径当成必须存在于 VibeGuard checkout 的本地 artifact。

## Behavior Invariants

1. B-001 仓库采用结果必须包含可运行的 workflow validator、GitHub PR evidence
   adapter、offline PR gate、runtime checkpoint gate，以及它们声明的配置、
   schema、fixture、skill 和测试依赖；任一必需资产缺失或格式非法时确定性检查
   必须非零退出。
2. B-002 VibeGuard 的 consumer overrides 必须保持
   `docs/specs/GH{issue_number}/`、`zh-CN` 和持久化 `auth_mode: review`；调用者提供
   的其他文件即使存在，也不得冒充配置路径中的 spec artifact。
3. B-003 `check_workflow.py` 必须从 `workflow.yaml` 解析 configured spec root，
   校验状态图、labels、action policy、templates、schemas、skills lock 和选中的
   spec packets；`--all-specs` 必须覆盖 configured root 下的全部 GH packet。
4. B-004 GitHub PR evidence 收集必须只读，完整读取 review threads 的全部分页，
   并在读取前后两次确认 PR head 与 issue relation 未漂移；分页不完整、漂移、
   缺字段或无效值必须失败并要求重跑，不得输出貌似 current 的部分 evidence。
5. B-005 Offline PR gate 只有在 PR 非 draft、head/linked issue/current gate query、
   CI、review、review threads、review source 和 merge state 等全部 pre-merge
   确定性证据满足时才可越过 `blocked`；pre-merge `allowed` 不要求
   `merge_record`。一旦 evidence 声明 merge dispatch，gate 必须校验 dispatch
   字段成对出现、merge head SHA 与 gate-query head 一致且 dispatch 晚于 gate
   query；一旦声明 `merge_record`，必须校验 `merge_path`、
   `remote_confirmed: true` 和非空 merge commit SHA。缺少的唯一条件是有效人工
   merge 授权时，判定必须是 `needs_human` 而不是 `allowed`。
6. B-006 持久化 `auth_mode: review` 下，merge 必须有当前对话中针对该 PR 的人工
   授权；`implx auto` 仅能作为当前显式 invocation 的临时授权，且两种模式都不能
   绕过 current-head、CI、review-thread、reviewer-lane 或 merge-state evidence。
7. B-007 独立 review 来源、reviewer lane failure 和 thread resolver role 必须
   可审计：lane failure 不能静默替换为 coordinator self-review；self-review 只能
   在已记录 lane failure 且另有专用授权时作为恢复路径；implementer 解决 reviewer
   thread 不能被当作独立 reviewer resolution。
8. B-008 Runtime checkpoint 是本地 handoff 辅助层而不是 durable workflow truth；
   merge-ready/merged 记录缺少 current-head PR gate、CI、独立 review、零 unresolved
   threads、clean merge state 或显式授权时，runtime ledger 必须阻断。
9. B-009 Full-queue checkpoint 不得把 `needs_spec`、`needs_tasks`、waiting/review
   状态伪装为 drained；必须校验 spec status、bounded tranche budget、lane failure、
   spec-only streak 和可恢复的 resume handoff，超过未授权边界时 fail closed。
10. B-010 Adoption evidence 必须固定精确上游 SHA，区分 target-local
    `specrail_artifact` 与 external evidence；所有 target-local 路径必须存在，外部
    pointer 不得被离线检查当成本地路径解引用。
11. B-011 Repository adoption 与本地 agent 安装必须分离；未显式授权时不得写入
    用户目录，VibeGuard 现有 README、LICENSE、CHANGELOG 和非采用范围文件必须保留。
12. B-012 PR #594 在上游兼容依赖和 human final review 完成前必须保持 draft；本
    issue 的实现和验证证据不授权自动合并 #587、#594 或任何其他 PR。

## 验收标准

- [ ] 四个核心检查脚本及必要的配置、schemas、fixtures、skills、tests 和 CI
      workflow 进入仓库，缺失或非法资产会使 deterministic check 失败。
- [ ] `python3 checks/check_workflow.py --repo .`、单 packet 检查和
      `python3 checks/check_workflow.py --repo . --all-specs` 均通过。
- [ ] `github_pr_evidence.py` 产出绑定 current head 的只读 GitHub evidence，
      head 或 issue relation 在采集中漂移时失败。
- [ ] `pr_gate.py` 对 current-head evidence 给出确定性 `allowed`、`needs_human`
      或 `blocked`，并阻止缺失 CI、review threads、review source、clean merge
      state 或授权的 merge claim。
- [ ] `runtime_ledger_gate.py` 阻止缺少 current-head PR gate evidence、reviewer
      lane、零 unresolved threads、clean merge state、预算或授权的 terminal claim。
- [ ] adoption smoke 固定精确上游 SHA，验证 configured spec root、`zh-CN`、
      `auth_mode: review`、target-local matrix evidence 和错误 artifact path 负例。
- [ ] repository adoption 没有安装本地 Codex skills，没有覆盖现有 README、
      LICENSE、CHANGELOG，也没有授权自动合并其他 PR。
- [ ] Python、shell contract、Rust、CI 和文档路径验证全部通过，并由 human final
      reviewer 决定是否解除 draft/merge gate。

## 边界情况清单

| 类别 | 判定（covered: B-xxx / N/A + 原因） |
| --- | --- |
| 空/缺失输入 | covered: B-001, B-003, B-004, B-005, B-008 |
| 错误与失败路径 | covered: B-001, B-004, B-005, B-007, B-008, B-009 |
| 授权/权限 | covered: B-005, B-006, B-007, B-012 |
| 并发/竞态 | covered: B-004（采集前后 head/relation 一致性） |
| 重试/幂等 | covered: B-004, B-009（漂移后重跑与 checkpoint resume） |
| 非法状态转换 | covered: B-005, B-008, B-009, B-012 |
| 兼容/迁移 | covered: B-002, B-010, B-011 |
| 降级/回退 | covered: B-004, B-005, B-007, B-008, B-009 |
| 证据与审计完整性 | covered: B-003, B-004, B-005, B-007, B-008, B-010 |
| 取消/中断 | covered: B-004, B-009（丢弃漂移 evidence；从显式 handoff 恢复） |

## 发布说明

该采用只增加仓库内 workflow 能力，不安装用户目录资产。PR #594 继续保持
draft，直到上游兼容依赖和 human final review 完成。合入后首次用例是重新收集
#587 的 current evidence 并执行 offline PR gate；这个动作仍需独立 review 和
人工 merge authorization。
