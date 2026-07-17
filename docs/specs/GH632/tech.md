# Tech Spec

## Linked Issue

GH-632

## Product Spec

See `product.md`.

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Directory map | `docs/directory-map.md:13` | 只列 setup/lib 与 ci/verify script groups | operational groups 未解释 |
| Site badge | `site/index.html:28` | 静态显示 `v1.1` | 与 patch releases 的语义不明确 |
| Current site inventory | `site/index.html:43` | 已显示 126 native rules | 证明 rule inventory 另有当前事实 |
| Historical benchmark | `docs/internal/benchmarks/benchmark-design.md:14` | 使用 6/110 当前式措辞 | 需要快照语境，不重跑数据 |
| Duplicate heading | `workflows/plan-mode/SKILL.md:8`, `workflows/plan-mode/SKILL.md:24` | 两个同名章节 | 机械合并且保持触发语义 |

## 设计方案

这是 focused docs change：

1. 在 directory map 的 verification/operations 分组中补充当前遗漏的六个一级 script groups
   （`constraints`、`doctors`、`gc`、`learn`、`metrics`、`systemd`）及一句职责，不逐文件复制
   目录树。focused assertion 必须动态枚举全部 tracked 一级 `scripts/` 目录，并验证每个目录的
   精确路径都出现在 map 中；现有 `ci`、`lib`、`setup`、`verify` 也属于该完整性检查，避免
   新增目录再次静默漂移。
2. site 推荐去掉 patch-sensitive literal，改成稳定的“v1 series”或 canonical release link；
   不推荐把 `1.1.10` 继续手填，因为下一 tag 会再次漂移。若仓库已有构建时 version source，
   可从该 source 生成，但不得新增第二份 metadata。
3. benchmark 文档在表格与后文 110-rule 位置标注原始快照日期/版本，并说明当前 inventory
   需重新运行后才能替换数字。
4. 合并 plan-mode 的两个 `When to Activate` 列表，去重但不删除独特触发条件。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 | directory-map operations rows | 动态枚举全部一级 script-dir，并逐项验证 map 中的精确路径 |
| B-002 | site badge/release link | search 不再出现含糊 patch-like literal；link/path check |
| B-003 | benchmark snapshot wording | 两处 110 references 同时包含 snapshot context |
| B-004 | plan-mode heading merge | heading count = 1；skill format test |
| B-005 | existing validators | doc path/command path/skill format gates |

## 数据流

无运行时数据流；只修改 tracked Markdown/HTML/skill 文本。若 site 使用 canonical release link，
浏览器只做普通导航，不增加构建/网络依赖。

## 风险

- Security: 无。
- Compatibility: plan-mode 文本合并不能改变触发条件。
- Performance: 无。
- Maintenance: 避免再次手写 patch version/current rule count。

## 测试计划

- [ ] `bash scripts/ci/validate-doc-paths.sh`。
- [ ] `bash scripts/ci/validate-doc-command-paths.sh`。
- [ ] `bash scripts/ci/validate-skill-format.sh`。
- [ ] focused search assertions for dynamically enumerated first-level script groups、snapshot
  context、heading count。

## 回滚方案

单提交回滚文档即可；无数据或 runtime migration。
