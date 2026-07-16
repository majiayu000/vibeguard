# Tech Spec

## Linked Issue

GH-626

## Product Spec

See `product.md`.

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Compact injection source | `claude-md/vibeguard-rules.md:62` | 手工维护 `Key Detailed Rules` 表 | 需要成为 canonical 派生产物 |
| Maintainer guidance | `claude-md/CLAUDE.md:13` | 指示直接编辑 compact 文件 | 需要改为编辑 canonical source 并运行生成器 |
| Rule generator | `scripts/generate_rule_docs.py:555` | 支持 `--check`，但不渲染 compact table | 复用现有解析与 check 机制 |
| Generated-doc CI | `scripts/ci/validate-generated-rule-docs.sh:9` | 只调用现有 generator check | 扩展后自然覆盖 compact drift |
| Marker-only check | `scripts/ci/validate-rules.sh:69` | 仅检查 compact 文件 marker | 保留结构检查，不作为语义 freshness 证明 |
| Constraint-budget regression | `tests/hooks/test_count_active_constraints.sh:175` | 以 compact 文件验证默认 U-32 预算 | 防止生成结果扩大 live constraints |

## 设计方案

推荐 Route A：扩展 `scripts/generate_rule_docs.py`，在现有 canonical parser 上增加
compact table renderer。renderer 只保存一个有序 rule-id selection；severity 与展示摘要
从已解析 canonical rule 记录取得。`claude-md/vibeguard-rules.md` 仍保留人工维护的
L1-L7、Chat Contract 等非 canonical 编排，但 `Key Detailed Rules` 区块由 generator
确定性替换并带生成说明。

不采用 Route B（另建 compact-summary JSON/YAML），因为它仍会维护第二份规则语义，
只是把漂移从 Markdown 转移到结构化文件。不采用“删表只留指针”，因为 minimal/core
profile 当前依赖该小表提供关键执行约束，删除会改变产品行为。

生成器在 write 与 `--check` 模式共享同一渲染函数。selection id 缺失、重复或解析失败
时抛出明确错误并返回非零；不得读取旧表作为 fallback。输出使用固定 selection 顺序、
固定列和 newline 规则。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 | canonical parser + compact renderer | fixture 修改被选中 rule 字段后生成表随之变化；无独立摘要映射 |
| B-002 | 有序 rule-id selection | fixture 新增未选中 rule 后 compact 集合不变 |
| B-003 | generator validation | 缺失/重复 id negative tests 返回非零并包含 id |
| B-004 | `--check` integration | `bash scripts/ci/validate-generated-rule-docs.sh` 在 stale fixture 上失败 |
| B-005 | compact template + setup/constraint tests | `bash tests/hooks/test_count_active_constraints.sh` 与 focused setup tests |
| B-006 | deterministic renderer | 连续生成两次后 `git diff --exit-code` 无差异 |

## 数据流

输入为 `rules/claude-rules/**/*.md` 与 generator 内的有序 selection；解析得到 canonical
rule records，渲染 compact Markdown 区块并写入 repository snapshot。setup 继续读取同一
`claude-md/vibeguard-rules.md`，运行时不新增持久化或网络调用。

## 风险

- Security: 高上下文分发文件受 SEC-13 约束；实现必须只生成声明区块，不能覆盖用户文件。
- Compatibility: canonical 摘要长度可能增加 live constraint 计数，必须由 U-32 test 阻断。
- Performance: 仅 CI/setup 前生成，无运行时热路径影响。
- Maintenance: selection 仍需人工决定，但只表达集合，不重复规则语义。

## 测试计划

- [ ] Unit tests: generator selection、缺失/重复 id、确定性渲染。
- [ ] Integration tests: `bash scripts/ci/validate-generated-rule-docs.sh`。
- [ ] Manual verification: 检查生成表与 canonical anchors 一致且默认集合未扩大。
- [ ] Required gates: `bash scripts/ci/validate-rules.sh`、`bash scripts/verify/doc-freshness-check.sh --strict`。

## 回滚方案

回滚 generator 与生成产物到前一提交即可；setup marker/profile 不变。若 canonical 摘要
导致 U-32 超预算，停止实现并回到规格评审，不得以跳过 budget test 作为回退。
