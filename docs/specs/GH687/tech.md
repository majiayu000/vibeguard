# Tech Spec — 证据必须可证明被执行（W-21）+ W-01 通道可信性 step 0

## Linked Issue

GH-687

## Product Spec

`docs/specs/GH687/product.md`

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| 规范规则源 | `rules/claude-rules/common/workflow.md:5` | W-01 的四阶段调试协议从"根因调查"开始 | 需要在前面插入 step 0 通道可信性检查 |
| 规范规则源 | `rules/claude-rules/common/workflow.md:203` | W-16 要求验证命令来自本会话 | W-21 补的是"来自本会话"之外的"确实执行过" |
| ID 空间 | `rules/universal.md:62` | `W-20` 已分配给"长任务必须钉住运行时、工具与规则" | GH-687 原文提议的 `W-20` 冲突，必须换 ID |
| 派生文档生成 | `scripts/generate_rule_docs.py:16-46` | 扫描 `rules/claude-rules/` 下 `## <ID>: <name> (<severity>)` 标题与 `**Compact guidance:**` 行，生成 `rules/*.md` 与 `docs/rule-reference.md` | 新规则必须写成规范源，派生文档由生成器产出 |
| 规则校验 | `scripts/ci/validate-rules.sh:43-67` | 校验必需规则文件、路径作用域与 W-18 归属 | 新规则文件需保持同样的结构约定 |
| 生成一致性校验 | `scripts/ci/validate-generated-rule-docs.sh:8` | `generate_rule_docs.py --check` 比对生成结果 | 忘记重新生成会在 CI 失败 |
| 主题规则文件先例 | `rules/claude-rules/common/execution-pinning.md:3`、`fact-inference-separation.md` | 单一主题规则独立成文件 | W-21 按同样模式独立成文件，避免 workflow.md 越过 U-16 warn 线 |

## ID 决策

GH-687 建议的 `W-20` 已被占用（`rules/universal.md:62`，"Long tasks must pin
runtime, tools, and rules"）。本实现使用**未占用的 `W-21`**。已占用与未占用
的 W 段位来自 `grep -n '^| W-' rules/universal.md`：W-01..W-05、W-10..W-20、
W-30、W-37、W-38、W-41、W-42 已占用，W-21 空闲。

## 设计方案

1. 新增规范源文件 `rules/claude-rules/common/evidence-provenance.md`，内容为
   `## W-21: Evidence must be provably executed, not merely cited (strict)`，
   含 `**Compact guidance:**` 行，覆盖四个要素：
   - **会话外通道验证**（B-002）：transcript JSONL / 文件系统 / git / 持久化退出码
     与哈希，至少一个能证明被声明的命令或文件操作真的发生过。
   - **单值信号优先**（B-003）：优先持久化到磁盘的退出码与哈希，而不是多行文本
     回忆；编造风险随输出长度增长。
   - **指控 harness 是红旗**（B-004）：先验概率强烈偏向模型退化而非工具链损坏；
     禁用任何 hook 之前必须先拿到会话外证据。
   - **会话止损判据**（B-005）：同一排查中根因理论被证伪 2 次 → 停止原地迭代，
     杀会话重开，从磁盘产物恢复状态而不是从退化上下文恢复。
   同时写明与 W-01 / W-02 / W-03 / W-16 的关系边界，避免重复定义既有规则文本。
2. 在 `rules/claude-rules/common/workflow.md` 的 W-01 段落中，把四阶段协议改为
   五阶段：新增 **step 0 — 通道可信性检查**（B-006），并在 W-01 内交叉引用 W-21。
   只增不删既有四阶段文本，避免改动 W-01 的既有语义。
3. 运行 `python3 scripts/generate_rule_docs.py` 重新生成
   `rules/universal.md`、`rules/python.md`、`rules/typescript.md`、`rules/go.md`、
   `rules/rust.md`、`rules/security.md`、`docs/rule-reference.md`、
   `claude-md/vibeguard-rules.md`（B-008）。W-21 不进 `COMPACT_RULE_IDS`，
   保持 compact 表体积不变，符合 U-32 约束预算。
4. 新增确定性测试 `tests/test_evidence_provenance_rule.sh`，断言 B-001 ~ B-007
   的文本要素与 ID 唯一性，并接入 CI（紧邻既有 "Validate rule files" 步骤）。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 | `rules/claude-rules/common/evidence-provenance.md` | `bash tests/test_evidence_provenance_rule.sh` |
| B-002 | 同上，"会话外通道"小节 | `bash tests/test_evidence_provenance_rule.sh` |
| B-003 | 同上，"单值信号优先"小节 | `bash tests/test_evidence_provenance_rule.sh` |
| B-004 | 同上，"指控 harness 是红旗"小节 | `bash tests/test_evidence_provenance_rule.sh` |
| B-005 | 同上，"会话止损判据"小节 | `bash tests/test_evidence_provenance_rule.sh` |
| B-006 | `rules/claude-rules/common/workflow.md` W-01 step 0 | `bash tests/test_evidence_provenance_rule.sh` |
| B-007 | ID 唯一性断言 | `bash tests/test_evidence_provenance_rule.sh` |
| B-008 | `scripts/generate_rule_docs.py` 输出 | `python3 scripts/generate_rule_docs.py --check`; `bash scripts/ci/validate-generated-rule-docs.sh` |

## 数据流

```
rules/claude-rules/common/*.md   (规范源, 人手编辑)
        |
        v
scripts/generate_rule_docs.py    (解析 ## <ID>: <name> (<severity>) + Compact guidance)
        |
        +--> rules/universal.md, rules/{python,typescript,go,rust,security}.md
        +--> docs/rule-reference.md
        +--> claude-md/vibeguard-rules.md (compact 区间, W-21 不入选)
        |
        v
setup.sh --> ~/.claude/rules/vibeguard/   (用户侧安装)
```

## 风险与权衡

- **ID 与 issue 原文不一致**：issue 写的是 W-20。实现改用 W-21 并在 PR 与 issue
  评论中说明冲突来源，避免两条规则共用一个 ID 造成引用歧义。
- **规则条数增加**：U-32 要求活跃约束 ≤15。W-21 不进 compact 表，只在按需加载的
  规范文件中出现，因此不增加常驻上下文预算。
- **无机械拦截**：本规则靠 agent/reviewer 遵守，与 W-01 / W-02 / W-16 同级。
  测试只能证明规则文本存在与自洽，不能证明模型遵守；这与仓库既有 strict 规则的
  验证水平一致，不做超出既有水平的承诺。

## 未纳入本 PR 的范围

GH-687 第 3 节（U-32 / W-19 自合规：默认安装只发 compact 索引、全文严格按需）改变
所有用户的安装默认行为，属于架构级决策，留给维护者单独决定，不在本 PR 内实现。
