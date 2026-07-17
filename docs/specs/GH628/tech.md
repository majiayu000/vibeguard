# Tech Spec

## Linked Issue

GH-628

## Product Spec

See `product.md`.

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Personal-path scanner | `scripts/ci/validate-no-personal-paths.sh:36` | 对全部 `*.md` 直接 continue | tracked Markdown 盲区根因 |
| Historical plan | `plan/2026-05-01_18-56-41-vibeguard-audit-remediation.md:3` | 保存 literal `/Users/<literal-user>/...` cwd | 当前主线可复现漏报 |
| Older plan | `plan/2026-04-19_00-15-39-main-architecture-convergence.md:3` | 保存另一机器 literal user path | 证明不是单一用户名特例 |
| Doc allowlist | `.vibeguard-doc-paths-allowlist:20` | 保留已迁移命令的旧位置条目 | stale entry 示例 |
| Current path entry | `.vibeguard-doc-paths-allowlist:35` | 同时允许迁移后路径 | 双豁免会掩盖迁移漂移 |
| Doc validators | `scripts/ci/validate-doc-paths.sh:1`, `scripts/ci/validate-doc-command-paths.sh:1` | 前者消费 allowlist 但不查 unused；后者是独立 command-path contract | 明确 freshness 的单一 owner，避免重复/漂移语义 |
| Existing regression | `tests/test_no_personal_paths.sh` | 只覆盖 gitfile/local state/普通源文件，没有 tracked Markdown 正反例 | T1 应扩展既有测试而非新增重复 runner |
| Command-path regression | `tests/test_workflow_contracts.sh` | 已覆盖 stale/missing command paths | 继续作为独立回归门禁 |

## 设计方案

把 personal-path 输入边界改为 `git ls-files -z` 的 Git tracked snapshot，而不是递归扫描
整个 worktree 后按扩展名跳过。实现保留 shell entrypoint；分类逻辑集中到可测试 helper：
literal username、明确 placeholder 与 pattern documentation 使用不同 decision。默认只允许
`<username>`、`<user>`、`$USER`/`${USER}` 等可判定占位符；测试动态拼接 negative fixture，
不得恢复 `tests/` 或 `*.md` blanket skip。历史 plan、docs、examples 与 workflow 文档中的
不可判定 literal user 路径机械替换为 repo-relative command 或 `<repo>`、`<username>` 表达；
validator 自身 pattern documentation 与测试 negative fixture 必须由窄分类或动态拼接覆盖，
不能依赖目录豁免。`git ls-files`、tracked-file read 或 classifier 错误均 fail visible。

`.vibeguard-doc-paths-allowlist` 改为严格的 pipe-delimited 五字段格式：

```text
reference | category | scope_glob | canonical_source | reason
```

- `runtime_alias`：`reference` 必须精确等于 `vibeguard/{canonical_source}`，且 canonical
  source 是当前 tracked file/dir；因此旧 "vibeguard/scripts/compliance_check.sh" 不能映射到
  新 `scripts/verify/compliance_check.sh` 后继续放行。
- `installed_alias`：仅适用于 native rule 安装目标。`canonical_source` 必须是当前
  `scripts/lib/vibeguard_manifest.py rule-links` 输出第一列，`reference` 必须精确等于同一行
  第二列 `dest_rel`；scope 必须限定到描述该安装后布局的具体文档。manifest command 失败、
  pair 缺失或 source/destination 任一不匹配均失败。
- `historical`：canonical source 为 `-`；scope 只允许 `CHANGELOG.md`、`docs/internal/**` 或
  `plan/**`，reason 必须说明历史时间/上下文。
- `planned`：canonical source 为 `-`；scope 只允许 `docs/internal/**` 或 `plan/**`，reason
  必须说明未落地边界。

`scripts/ci/validate-doc-paths.sh` 是该 allowlist 的唯一 freshness owner。hit occurrence 定义为
`(document_path, line, column, reference)`：每个 entry 可在自身 scope 内命中多个 occurrence，
但每个 occurrence 必须且只能匹配一个 entry；相同 reference 的 disjoint scopes 合法，重叠
scope 造成同一 occurrence 匹配多个 entry 时失败。结束时拒绝空字段、未知 category、zero-hit、
规范化五字段完全重复、overlap hit、scope 越界、live alias 缺失 canonical/mapping 证据，或
不满足 exact runtime/installed alias 关系。historical/planned 不要求目标存在，但仍要求 live
scoped occurrence、合法 scope/category 与非空结构化 reason。
普通存在路径不应进入 allowlist。`validate-doc-command-paths.sh` 当前不消费该 allowlist，保持
独立 command-path contract；实现不得为了“共享”而让它重复解析 allowlist。两个 validator
仍在同一回归 gate 中运行。allowlist parse、Git enumeration 或 tracked Markdown read error
均返回非零，不能用空结果降级。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 | tracked-file enumeration | Markdown literal-path fixture 被扫描；untracked artifact 不扫描 |
| B-002 | path classifier | literal user negatives 与 placeholder/pattern positives |
| B-003 | tracked Markdown cleanup + narrow policy | tracked Markdown audit 只剩可判定 pattern/placeholder 或带范围豁免 |
| B-004 | strict allowlist parser + usage accounting | unused、duplicate、overlap、invalid category/source/scope fixtures 返回非零；multi-occurrence single entry 通过 |
| B-005 | exact live-alias mapping + normal path validation | stale runtime alias、invalid manifest rule-link pair 与 broken doc reference 失败；current pairs 通过 |
| B-006 | error reporter | 文件/行/类别 assertions；模拟 read/parse failure 非零 |
| B-007 | Git-boundary tests | 相同 commit 重跑输出稳定，untracked files 不改变结果 |

## 数据流

输入为 `git ls-files -z` 的 tracked snapshot、tracked Markdown 文本和结构化 allowlist；
classifier 输出 violations 与 allowlist hit set；entrypoint 汇总并以 exit code 表达 pass/fail。
无网络或持久化写入。

## 风险

- Security: 避免把本机用户名/路径继续发布；validator 必须正确处理特殊字符而非 shell 注入。
- Compatibility: 历史文档可能含合法示例，需以明确 placeholder 转写而非删除证据。
- Performance: tracked files 单次扫描；不得对整个 build tree 递归。
- Maintenance: doc-path validator 独占 allowlist 语义；command-path validator 仅共享 fail-visible
  discipline 与同一 CI gate，不解析 allowlist。

## 测试计划

- [ ] Unit/fixture: 扩展 `tests/test_no_personal_paths.sh`，覆盖 tracked Markdown、placeholder、
  dynamic negative fixture、untracked artifact 与 Git/read failure。
- [ ] Integration: `bash scripts/ci/validate-no-personal-paths.sh`。
- [ ] Migration: 审计全部 tracked Markdown，并机械替换 plan/docs/examples/workflows 中不可判定的
  literal user；保留历史结论与示例意图。
- [ ] Allowlist: 为 `validate-doc-paths.sh` 增加 isolated Git fixture，覆盖 strict format、
  zero-hit、duplicate、overlap hit、single-entry multi-occurrence、scope/category/source、
  historical/planned scoped exception、stale/current runtime alias 与 manifest rule-link pair。
- [ ] Required: `bash scripts/ci/validate-doc-paths.sh`、`bash scripts/ci/validate-doc-command-paths.sh`。
- [ ] Broad: `bash scripts/local-contract-check.sh --quick`。

## 回滚方案

可回滚 helper、fixture 和一次性文档转写。不得通过恢复 Markdown blanket skip 或重新加入
僵尸 allowlist 来回滚；若出现合法历史样例误报，应增加可审计的窄分类规则。
