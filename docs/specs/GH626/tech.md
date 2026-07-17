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
| Rule generator | `scripts/generate_rule_docs.py:23`, `scripts/generate_rule_docs.py:555` | `Rule.summary` 是首句/140 字启发式，且 `--check` 不渲染 compact table | 复用 parser/check 框架，但不能把通用 summary 当 compact 执行文案 |
| Generated-doc CI | `scripts/ci/validate-generated-rule-docs.sh:9` | 只调用现有 generator check | 扩展后自然覆盖 compact drift |
| Marker-only check | `scripts/ci/validate-rules.sh:69` | 仅检查 compact 文件 marker | 保留结构检查，不作为语义 freshness 证明 |
| Constraint-budget regression | `tests/hooks/test_count_active_constraints.sh:175` | 以 compact 文件验证默认 U-32 预算 | 防止生成结果扩大 live constraints |

## 设计方案

推荐 Route A：扩展 `scripts/generate_rule_docs.py`，在现有 canonical parser 上增加
compact table renderer。每个被选中的 canonical rule record 增加唯一的单行
`**Compact guidance:** <text>` 字段；首次迁移把当前 compact 表的 16 条展示文案逐条
放入对应 record，不改 rule heading、severity 或既有规范正文。`Rule` 增加可选的
`compact_guidance` 字段，renderer 只保存一个有序 rule-id selection，并从同一 record
读取 severity 与 compact guidance。通用 `Rule.summary` 继续服务其他生成文档，但禁止
作为 compact guidance fallback。

`claude-md/vibeguard-rules.md` 在 `Key Detailed Rules` 下增加唯一的
`<!-- vibeguard-generated-compact-rules:start -->` 与
`<!-- vibeguard-generated-compact-rules:end -->` inner markers。生成器要求各 marker 恰好
出现一次且 start 在 end 前；write/check 在缺失、重复或错序时返回非零并指出文件。
成功 write 只替换 markers 内部，包含 markers 在内的前后字节原样保留；fixture test 对
区块外前缀/后缀做精确字节断言，防止 SEC-13 高上下文内容被扩大改写。

不采用 Route B（另建 compact-summary JSON/YAML），因为它仍会维护第二份规则语义，
只是把漂移从 Markdown 转移到结构化文件。不采用“删表只留指针”，因为 minimal/core
profile 当前依赖该小表提供关键执行约束，删除会改变产品行为。

生成器在 write 与 `--check` 模式共享同一 parser、selection validator、region replacer
和 renderer。selection id 缺失/重复、selected canonical id 重复、selected guidance
缺失/重复/空、canonical 解析失败或 inner marker 非法时抛出明确错误并返回非零；不得
读取旧表或通用 summary 作为 fallback。输出使用固定 selection 顺序、固定列和 newline
规则。首次迁移 fixture 固化现有 16 行的 id/severity/guidance，特别覆盖 U-17、SEC-01、
SEC-02、SEC-13，确保生成前后逐行一致而非仅集合一致。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 | canonical parser + compact renderer | `python3 tests/test_generate_rule_docs.py`：selected guidance 来自同一 record；禁止 summary/旧表 fallback |
| B-002 | 有序 rule-id selection | fixture 新增未选中 rule 后 compact 集合不变 |
| B-003 | parser + selection validation | 缺失/重复 selection、重复 selected canonical record、缺失/重复/空 guidance negative cases 非零并包含 id/文件 |
| B-004 | `--check` integration | `python3 tests/test_generate_rule_docs.py` 覆盖 stale fixture；`bash scripts/ci/validate-generated-rule-docs.sh` 校验当前仓库 snapshot |
| B-005 | inner markers + region replacer | marker 缺失/重复/错序 negative cases；成功 write 前后 prefix/suffix 精确字节不变 |
| B-006 | compact template + setup/constraint tests | `bash tests/test_setup.sh`；`bash tests/hooks/test_count_active_constraints.sh` |
| B-007 | selected-rule migration fixture | 迁移前后 16 行逐行一致，并具名断言 U-17/SEC-01/SEC-02/SEC-13 未变成 heuristic summary |
| B-008 | deterministic renderer | 连续两次生成后 `git diff --exit-code` 无差异 |

## 数据流

输入为 `rules/claude-rules/**/*.md` 的 canonical records、record 内显式 compact guidance
与 generator 内的有序 selection；解析和完整性校验后渲染 inner-marker 区域并写入同一
repository snapshot。区块外字节不参与生成。setup 继续读取同一
`claude-md/vibeguard-rules.md`，运行时不新增持久化或网络调用。

## 风险

- Security: 高上下文分发文件受 SEC-13 约束；实现必须只生成声明区块，不能覆盖用户文件。
- Compatibility: canonical compact guidance 长度可能增加 live constraint 计数，必须由
  16-row migration fixture、setup 与 U-32 tests 共同阻断；不得接受首句启发式造成的语义弱化。
- Performance: 仅 CI/setup 前生成，无运行时热路径影响。
- Maintenance: selection 仍需人工决定，但只表达集合，不重复规则语义。

## 测试计划

- [ ] Unit tests: `python3 tests/test_generate_rule_docs.py` 覆盖 selection、canonical/guidance
      重复或缺失、inner marker 完整性、区块外字节保护、16-row migration 与确定性渲染。
- [ ] Integration tests: `bash scripts/ci/validate-generated-rule-docs.sh`。
- [ ] Setup/constraint tests: `bash tests/test_setup.sh`；
      `bash tests/hooks/test_count_active_constraints.sh`。
- [ ] Manual verification: 比较迁移前后 16 行，确认 id、severity、顺序和 guidance 逐行一致，
      并检查 inner markers 外 `git diff --word-diff=porcelain` 无改动。
- [ ] Required gates: `bash scripts/ci/validate-rules.sh`、`bash scripts/verify/doc-freshness-check.sh --strict`。

## 回滚方案

回滚 generator、canonical compact guidance 字段、inner markers 与生成产物到前一提交
即可；外层 setup marker/profile 不变。若 guidance 迁移无法保持 16 行或导致 U-32 超预算，
停止实现并回到规格评审，不得以 summary fallback、删除区块外内容或跳过 budget test
作为回退。
