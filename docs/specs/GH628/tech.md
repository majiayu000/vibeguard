# Tech Spec

## Linked Issue

GH-628

## Product Spec

See `product.md`.

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Personal-path scanner | `scripts/ci/validate-no-personal-paths.sh:36` | 对全部 `*.md` 直接 continue | tracked Markdown 盲区根因 |
| Historical plan | `plan/2026-05-01_18-56-41-vibeguard-audit-remediation.md:3` | 保存 literal `/Users/apple/...` cwd | 当前主线可复现漏报 |
| Older plan | `plan/2026-04-19_00-15-39-main-architecture-convergence.md:3` | 保存另一机器 literal user path | 证明不是单一用户名特例 |
| Doc allowlist | `.vibeguard-doc-paths-allowlist:20` | 保留已迁移命令的旧位置条目 | stale entry 示例 |
| Current path entry | `.vibeguard-doc-paths-allowlist:35` | 同时允许迁移后路径 | 双豁免会掩盖迁移漂移 |
| Doc validators | `scripts/ci/validate-doc-paths.sh:1`, `scripts/ci/validate-doc-command-paths.sh:1` | 使用 allowlist 但不做 unused-entry gate | 需要共享 freshness 结果 |

## 设计方案

把 personal-path 输入边界改为 Git tracked files，而不是递归扫描整个 worktree 后按扩展名
跳过。实现可保留 shell entrypoint，但分类逻辑应集中到可测试 helper：literal username、
明确 placeholder、pattern documentation 和 test fixture 使用不同 decision。默认只允许
稳定占位符；真实历史路径应机械替换为 repo-relative command/`<repo>` 表达。

为 doc allowlist 增加消费记录：validator 解析每个非注释 entry，处理文档引用时记录
命中；结束时拒绝 zero-hit、duplicate 或迁移对（同一 suffix 的旧/新路径同时存在）。
若确需允许不存在的示例路径，entry 必须使用显式类别/理由，而不是普通路径字符串；
该格式是否扩展由实现前 review 决定，不能 silent accept legacy ambiguity。

两个 doc validators 应复用同一 allowlist parser/freshness helper，避免分别实现不同语义。
扫描命令失败、无法读取 tracked file 或 allowlist parse error 均返回非零。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 | tracked-file enumeration | Markdown literal-path fixture 被扫描；untracked artifact 不扫描 |
| B-002 | path classifier | literal user negatives 与 placeholder/pattern positives |
| B-003 | plan cleanup + narrow policy | `rg '/Users/|/home/' plan` 只剩经允许 pattern/placeholder |
| B-004 | allowlist usage accounting | unused、duplicate、deleted-target fixtures 返回非零 |
| B-005 | migration-pair detection + normal path validation | old+new allowlist fixture 失败，broken doc reference 仍失败 |
| B-006 | error reporter | 文件/行/类别 assertions；模拟 read/parse failure 非零 |
| B-007 | Git-boundary tests | 相同 commit 重跑输出稳定，untracked files 不改变结果 |

## 数据流

输入为 `git ls-files` 的 tracked snapshot、文档文本和 allowlist；classifier 输出 violations
与 allowlist hit set；entrypoint 汇总并以 exit code 表达 pass/fail。无网络或持久化写入。

## 风险

- Security: 避免把本机用户名/路径继续发布；validator 必须正确处理特殊字符而非 shell 注入。
- Compatibility: 历史文档可能含合法示例，需以明确 placeholder 转写而非删除证据。
- Performance: tracked files 单次扫描；不得对整个 build tree 递归。
- Maintenance: 两个 doc validators 必须共享 allowlist 语义。

## 测试计划

- [ ] Unit: personal path classifier 与 allowlist parser/freshness fixtures。
- [ ] Integration: `bash scripts/ci/validate-no-personal-paths.sh`。
- [ ] Required: `bash scripts/ci/validate-doc-paths.sh`、`bash scripts/ci/validate-doc-command-paths.sh`。
- [ ] Broad: `bash scripts/local-contract-check.sh --quick`。

## 回滚方案

可回滚 helper、fixture 和一次性文档转写。不得通过恢复 Markdown blanket skip 或重新加入
僵尸 allowlist 来回滚；若出现合法历史样例误报，应增加可审计的窄分类规则。
