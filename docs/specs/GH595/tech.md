# Tech Spec

## Linked Issue

GH-595

## Product Spec

`docs/specs/GH595/product.md`

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Adoption pin and agent boundary | `AGENT_USAGE.md:7-14`, `AGENT_USAGE.md:309-317` | 固定采用来源与 consumer overrides，并保留 human final gates | 防止把上游漂移、local install 或 agent 自批当成采用结果 |
| Workflow policy and configured artifacts | `workflow.yaml:15-68`, `workflow.yaml:82-105`, `workflow.yaml:140-145` | 持久化 `auth_mode: review`，spec packet 指向 `docs/specs/GH{issue_number}/`，默认 locale 为 `zh-CN` | 所有 route、artifact path 与授权判定的配置真相 |
| Deterministic pack/spec validator | `checks/check_workflow.py:245-305`, `checks/check_workflow.py:418-472` | 校验 configured packet identity、必需文件、状态图、labels、policy、assets、skills lock 和 task plan | 为 adoption 与 packet 完整性提供 fail-closed 检查 |
| GitHub PR evidence adapter | `checks/github_pr_evidence.py:24-60`, `checks/github_pr_evidence.py:475-591` | 只读收集 PR/issue/review-thread evidence，并在采集前后比较 head 与 issue relation | 阻止 stale 或混合快照冒充 current evidence |
| Offline PR gate | `checks/pr_gate.py:260-296`, `checks/pr_gate.py:391-454`, `checks/pr_gate.py:457-560` | 综合 PR 状态、head、CI、review、threads、review source、merge state、条件式 merge dispatch/record 和授权，返回稳定 decision | 允许无 `merge_record` 的 pre-merge 判定，并在声明 dispatch/record 后强制验证完整性 |
| Runtime checkpoint gate | `checks/runtime_ledger_gate.py:31-69`, `checks/runtime_ledger_gate.py:500-586` | 校验 queue/tranche 状态、review evidence、current-head PR gate、threads、merge state 和授权 | 防止 checkpoint 把未完成或无证据项声明为 terminal |
| Gate evidence schemas | `schemas/pr_review_gate.schema.json:1-20`, `schemas/runtime_checkpoint.schema.json:1-45`, `schemas/adoption_matrix.schema.json:1-27` | 约束 evidence/checkpoint/matrix 的结构与 required fields | schema 负责结构，offline gates 负责跨字段语义 |
| Target-local adoption smoke | `tests/test_specrail_adoption.sh:12-58`, `tests/test_specrail_adoption.sh:83-173` | 锁定上游 SHA 和 VibeGuard overrides，验证错误 configured artifact、正负 PR/runtime fixtures | 证明 copied pack 在目标仓库真实路径下可运行且 fail closed |
| CI integration | `.github/workflows/workflow-check.yml:13-34` | PR/push 上运行 all-spec check、adoption smoke 和 whitespace check | 防止 adoption assets 与 spec packets 后续漂移 |
| Adoption evidence model | `docs/ADOPTION_MATRIX.md:24-35`, `examples/adoptions/matrix.json:1-11` | 区分 target-local artifact 与 external evidence | 避免把源仓库路径伪装成本地证明 |

## 设计方案

### 1. 采用固定上游 pack，并显式覆盖 consumer contract

以 `AGENT_USAGE.md` 记录的精确上游 SHA 为来源，仓库内复制 workflow config、
states、labels、templates、skills、checks、schemas、fixtures、policies、review
guidance 和 CI integration。VibeGuard-specific override 只改变已声明的 consumer
边界：

- `artifacts.spec_packet`: `docs/specs/GH{issue_number}/`
- `presentation.default_locale`: `zh-CN`
- `automation_policy.auth_mode`: `review`
- imported skills 满足 VibeGuard 的格式检查
- adoption matrix 的本地证据改为 target-local path，源仓库路径标为 external

不创建第二个 `specs/` root，不运行 local skill installer 的 `--apply`，不替换
VibeGuard 的 README、LICENSE 或 CHANGELOG。

### 2. 配置驱动的 workflow 与 artifact validation

`checks/specrail_lib.py` 负责加载 YAML、渲染 configured artifact path、验证路径
仍位于仓库与 configured root 中，并为各 gate 提供一致的状态和 artifact 解析。
`checks/check_workflow.py` 在 pack 级校验 required files/globs、token、schema、
template、states、labels、action policy、branch template、auth mode、skills lock；
在 packet 级校验 `product.md`、`tech.md`、`tasks.md`、linked issue token 和稳定
task ID。显式提供的 artifact 只有与 configured path 一致时才满足 route gate。

### 3. Current-head PR evidence 与 offline gate

`github_pr_evidence.py` 先读取 PR snapshot，再分页读取 GraphQL review threads 到
`totalCount`，随后再次读取 PR snapshot。分页游标不前进、连接仍有下一页、节点数
与 `totalCount` 不一致，或两次 `headRefOid` / issue relation 不一致时直接失败；
一致时才输出 `gate_query_completed_at`、`gate_query_head_sha`、checks、reviews、
threads、resolver role、lane failures、review source、merge state 和授权字段。

`pr_gate.py` 只读取 JSON evidence，不调用 GitHub。确定性证据缺失或冲突返回
`blocked`；所有确定性证据满足、仅缺当前人工 merge authorization 时返回
`needs_human`；只有两类 gate 都满足时返回 `allowed`。self-review 不满足独立
review，除非它是已报告 reviewer-lane failure 的显式授权恢复路径。

Pre-merge evidence 不需要 `merge_record`。如果 evidence 声明
`merge_dispatched_at` / `merge_head_sha`，两者必须成对出现，dispatch 时间必须晚于
gate query，且 merge head 必须等于 gate-query head；如果声明 `merge_record`，则
必须验证允许的 `merge_path`、`remote_confirmed: true`、非空 merge commit SHA，
以及可选 branch-deletion outcome 的类型。缺失或不一致时必须 `blocked`。

### 4. Runtime checkpoint 语义 gate

`schemas/runtime_checkpoint.schema.json` 定义 checkpoint 结构，
`runtime_ledger_gate.py` 与 `runtime_gate_rules.py` 执行 schema 难以表达的语义：

- merge-ready/merged 项绑定 current item head 的 PR gate evidence
- CI、review、review threads、merge state、merge authorization 全部存在
- native reviewer lane 与 failure/retry/self-review evidence 保持可审计
- spec coverage、full-queue remainder、spec-only streak 和 tranche mix 不伪造进度
- bounded tranche budget、compaction handoff 和 resume prompt 完整

checkpoint 只保存本地运行 handoff；GitHub issue、PR、review、branch 和 configured
spec packet 继续是 durable truth。

### 5. Adoption smoke 与 CI

`tests/test_specrail_adoption.sh` 验证四个核心脚本可编译、上游 SHA 精确匹配、
VibeGuard overrides 未漂移、matrix 中所有 target-local artifact 存在、默认 CLI
拒绝 missing/non-directory configured root、错误 `product_spec=README.md` 不会冒充
configured GH packet、review threads 分页到后页未解决项，并对 PR gate/runtime
ledger 执行 allowed 与 fail-closed fixtures。独立 workflow 在 PR 和 main push 上
运行 `--all-specs`、adoption smoke 与绑定 event base/head 的
`git diff --check <base>...<head>`；checkout 必须保留所需历史。

### 6. Human gate 与 rollout

PR #594 保持 draft，直到上游兼容依赖与 human final review 完成。采用本身不
授权重新评估对象的 merge；后续对 #587 的 gate 运行必须重新收集 current head
evidence，并继续遵守独立 review、review-thread、CI、merge-state 和当前人工授权。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 required adoption assets 完整且非法资产 fail closed | pack files、`checks/check_workflow.py`、schemas、fixtures | `python3 checks/check_workflow.py --repo .`; `bash tests/test_specrail_adoption.sh` 证明 target helper 不能弱化 trusted validation，source helper 缺失时 fail closed |
| B-002 VibeGuard configured paths/locale/auth mode 保持 | `workflow.yaml`、`checks/specrail_lib.py`、configured-artifact smoke | `bash tests/test_specrail_adoption.sh`；确认 `README.md` 不能满足 configured product path，等价 `./` 路径在 config/evidence 两侧均规范化 |
| B-003 workflow/all-spec validation 覆盖 configured root | `checks/check_workflow.py`、`.github/workflows/workflow-check.yml` | `python3 checks/check_workflow.py --repo . --spec-dir docs/specs/GH595`; `python3 checks/check_workflow.py --repo . --all-specs`；smoke 证明默认 CLI 与 all-spec 均拒绝 missing/non-directory root |
| B-004 current-head 只读 evidence 与 drift detection | `checks/github_pr_evidence.py`、`checks/github_issue_reference.py` | `bash tests/test_specrail_adoption.sh` 覆盖 review-thread 全分页、不完整 connection fail closed 和 double-read evidence |
| B-005 offline PR decision 与条件式 merge evidence | `checks/pr_gate.py`、PR fixtures | `bash tests/test_specrail_adoption.sh` 证明 later-page unresolved thread 被阻断、`pr-clean-authorized` 为 `allowed`、仅缺授权的 `pr-missing-human-auth` 精确为 `needs_human`，pending-CI/unresolved-thread 为 non-allowed；另对 `pr-merge-confirmed`、`pr-merge-missing-path`、`pr-merge-unconfirmed-local-failure`、`pr-query-after-merge` 运行 `checks/pr_gate.py`，验证声明 dispatch/record 后的路径、remote confirmation、SHA 与时间顺序 |
| B-006 review/auto authorization 不绕过 evidence | `workflow.yaml`、`checks/pr_gate.py`、runtime fixtures | `python3 -m pytest -q`; `bash tests/test_specrail_adoption.sh`；人工核对持久化 `auth_mode: review` |
| B-007 reviewer lane failure/self-review/resolver role 可审计 | `checks/github_pr_evidence.py`、`checks/pr_gate.py`、review/runtime fixtures | `python3 -m pytest -q`; 对 lane-failure、self-review、implementer-resolved-thread fixtures 执行 gate |
| B-008 merge-ready checkpoint 必须有 current evidence | `checks/runtime_ledger_gate.py`、`schemas/runtime_checkpoint.schema.json` | `bash tests/test_specrail_adoption.sh`; `python3 checks/runtime_ledger_gate.py --checkpoint examples/fixtures/runtime-budget-exhausted-handoff.json --json` |
| B-009 queue/tranche/budget/spec streak 不能伪造完成 | `checks/runtime_gate_rules.py`、runtime queue fixtures | `python3 -m pytest -q`; 对 false-complete、streak、budget、lane-failure fixtures 执行 runtime ledger gate |
| B-010 pinned provenance 与 local/external evidence 分离 | `AGENT_USAGE.md`、`docs/ADOPTION_MATRIX.md`、`examples/adoptions/matrix.json` | `bash tests/test_specrail_adoption.sh`；确认 pin 为 `7de16e4780d903607b40220a9edb7a08fe222c78` |
| B-011 repository adoption 不写 local skills/既有文档 | `skills/specrail-install/SKILL.md`、`tools/install_codex_skills.py`、PR diff | `git diff --name-only origin/main...HEAD` 人工审查；确认未执行 `--apply` 且 README/LICENSE/CHANGELOG 无 diff |
| B-012 draft 与 human gates 保持 | `workflow.yaml`、`review/human_final_review.md`、PR #594 state | `gh pr view 594 --repo majiayu000/vibeguard --json isDraft,state,headRefOid`; human final review |

## 数据流

1. GitHub issue/PR/labels/reviews/branches 是 durable input；adapter 只读采集并绑定
   current head。
2. Adapter 输出 JSON evidence；schema 校验结构，offline gate 校验跨字段语义。
3. Gate 输出稳定 `allowed`、`warn`、`needs_human` 或 `blocked` decision；它不执行
   comment、approval 或 merge。
4. Runtime checkpoint 可引用 gate evidence path/URL 作为本地 handoff，但不能
   覆盖 GitHub 或 configured spec packet 的真相。
5. CI 在 PR/push 上重新运行 pack、all-spec、adoption smoke 和 whitespace checks。

该流程不引入数据库、服务端持久化或 secret；唯一外部调用是显式执行
GitHub evidence adapter 时的只读 `gh` 查询。

## 备选方案

- 只在本机安装上游 SpecRail skills：拒绝。它不能为仓库 CI、其他 agent 或
  maintainer 提供可复现 gate，且混淆 local setup 与 repository adoption。
- 只复制四个入口脚本：拒绝。缺少 schemas、fixtures、shared libraries、skills
  和 tests 会产生名义能力而非可验证能力。
- 使用上游默认 `specs/GH<number>` 和 `en-US`：拒绝。会创建第二个 spec root，
  并与 VibeGuard 现有维护约定冲突。
- 将 `auth_mode` 持久化为 `auto`：拒绝。仓库配置不能提供常驻 merge 授权。

## 风险

- Security: gate 错误放行会影响 merge 安全；通过 fail-closed fixtures、独立
  reviewer evidence、current-head binding 和人工 merge gate 缓解。
- Compatibility: 上游 pack 与 consumer path 可能漂移；通过精确 SHA pin、
  configured-root negative smoke 和 target-local evidence 缓解。
- Performance: all-spec 与 fixture corpus 增加 CI 时间；独立 workflow 设置
  10 分钟 timeout，核心 gate 保持离线和确定性。
- Maintenance: copied pack 可能与上游分叉；升级必须显式更新 pin、consumer
  overrides 和 adoption smoke，不允许无证据同步。

## 测试计划

- [ ] `python3 checks/check_workflow.py --repo . --spec-dir docs/specs/GH595`
- [ ] `python3 checks/check_workflow.py --repo . --all-specs`
- [ ] `bash tests/test_specrail_adoption.sh`
- [ ] `python3 -m pytest -q`
- [ ] `bash tests/test_manifest_contract.sh`
- [ ] `bash tests/test_workflow_contracts.sh`
- [ ] `bash scripts/ci/validate-doc-paths.sh`
- [ ] `bash scripts/ci/validate-doc-command-paths.sh`
- [ ] `bash scripts/local-contract-check.sh --quick`
- [ ] `python3 -m compileall -q checks`
- [ ] `cargo check --manifest-path vibeguard-runtime/Cargo.toml`
- [ ] `cargo test --manifest-path vibeguard-runtime/Cargo.toml`
- [ ] `git diff --check origin/main...HEAD`

## 回滚方案

回滚 PR #594 引入的 repository adoption assets、GH595 packet 与 CI workflow，
恢复到采用前的仓库状态。由于本方案不执行 local skill `--apply`、不修改用户
目录或远端权限，不需要清理用户级安装。若仅某个 gate 回归，先阻止 merge claim
并回滚整个 pinned adoption tranche，而不是删除负例 fixture、降低 schema 要求或
把 `blocked` 改成 warning。
