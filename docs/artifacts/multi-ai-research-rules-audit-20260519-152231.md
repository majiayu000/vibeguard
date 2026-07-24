# VibeGuard 规则集合理性审计 (multi-ai-research)

> ## ⚠️ 报告状态：v2 — 已撤回所有 Fact-Level 声明
>
> **撤回日期**：2026-05-19
>
> 本报告 v1 版本声称 vibeguard 仓存在"4 个引用了不存在脚本的 fake-cmd bug"和"W-02 阈值漂移"，并在 Phase 6 P0 action items 中要求修复。
>
> **v1 的这些声明全部错误**。三轮验证后的真实情况：
> - 所有被声称"不存在"的 guard 脚本（`check_dependency_changes.sh` / `check_test_weakening.sh` / `check_runtime_drift.sh` / `count_active_constraints.sh|.py`）**在 vibeguard 仓 origin/main 上都真实存在**。
> - 当时主 agent 在 `codex/codex-usage-experience` 分支 working tree 上 `find`，这个分支主动删除了上述脚本与对应规则引用（一起删除，所以分支也是自洽的）。但主 agent 错把"working tree 没找到"读成"整个仓没有"。
> - "W-02 阈值漂移"也不成立：`post-build-check.sh` 的 `>= 5` 是 U-25 ESCALATE 阈值，跟 W-02 的"3 次失败撤退"不是同一个阈值。
>
> 本 v2 保留：研究问题、Phase 1 流程、基于规则**正文阅读**得出的 design observations。
>
> 本 v2 删除：所有 Fact-Level claims、Phase 6 的 A3/A4 action items、Phase 5 矩阵中受影响的行。
>
> Audit 方法学复盘见末尾。

---

## 研究问题

VibeGuard 仓 `rules/claude-rules/` 下 115 条规则是否都合理？

## Metadata

- 调研时间：2026-05-19
- 外部 AI：grok ✅ / gemini ✅ / chatgpt ❌（两次 NETWORK_ERROR timeout）
- 内部 sub-agent：2 个并行（重叠/冗余分析 + mechanical-check 审计）
- 数据源：vibeguard 仓 `rules/claude-rules/**/*.md` 共 13 个文件 1325 行
- **注意**：内部 Agent B 的"机械化检查可执行性"结论受限于其当时所看的分支 working tree（codex/codex-usage-experience），不代表 origin/main 的真实状态。

---

## Phase 1: 问题分解

| 任务 | 类型 | 关注点 |
|---|---|---|
| Agent A | 内部 | 规则间重叠/冗余矩阵 + 严格性等级与风险匹配 |
| Agent B | 内部 | 每条 strict 规则的 mechanical-check 可执行性 + hook/guard 实际存在性 |
| Grok | 外部 | 2026 业界共识对齐度 + 整改建议 |
| Gemini | 外部 | strict→guideline 降级 + 语言专用规则下沉路径 |
| ChatGPT | 外部 | 失败（2x NETWORK_ERROR timeout） |

外部 AI 的输入只有规则 ID + 一句话标题，**没有规则正文**。所以外部 AI 的合并/降级建议是基于标题的猜测，权重低于直接读规则正文的内部判断。

---

## Phase 5: 交叉验证矩阵（v2 修正）

### 🟢 站得住的强共识（基于规则正文阅读，与分支状态无关）

| 发现 | 内部证据 | grok | gemini | Tier |
|---|---|---|---|---|
| **U-17 / U-23 / U-29 + RS-10 概念重叠**：四条都讲"错误不能静默"，U-29 写得最具体（4 个 BAD/GOOD 代码 + 决策规则）；语言专用 RS-10/GO-01/PY-02/TS-02 是其具体化 | Agent A：70-80% 概念重叠 | ✅ 建议合并 | ✅ 建议合并 | 🟢 强共识 |
| **U-08 被 W-03 + W-16 完全覆盖**：U-08 一行 vs W-03 五步协议+60s nyquist vs W-16 fresh evidence 8 条拒绝清单 | Agent A 标 H 置信度 | （未直接说，但符合 W-17 描述的"渐进式精化"） | ✅ 类似建议 | 🟢 强共识 |
| **U-02/U-09/U-22 等部分 strict 偏 best-practice 而非可执行约束**：正文无 mechanical checks 或 mechanical checks 不强 | Agent A 详细列举 | ✅ 建议降级 | ✅ 建议降级 | 🟢 强共识 |
| **U-32 自身合规性问题**：U-32 设 ">30 条触发警告" 阈值，仓里规则总数接近此数（视语义) | 内部观察 | ✅ 元矛盾 | ✅ illusion of control | 🟢 强共识 |
| **W-13 / W-15 死循环阻断器是高价值**：实际有 hook 实现（`analysis-paralysis-guard.sh`, `post_edit_history.sh::vg_post_edit_detect_w15_loop`），阈值与文档一致 | Agent B 可执行性确认 | ✅ 对齐 SWE-agent 共识 | ✅ Token 费用护城河 | 🟢 强共识 |
| **W-10 hook 覆盖范围 < 规则承诺**：规则文列 7 类触发命令（cargo publish / docker push 等），当前 `pre-bash-guard.sh` 仅覆盖 `rm -rf` 子集 | Agent B 观察（在 codex 分支） | （未提） | ✅ 建议下沉为 Pre-commit Hook | 🟡 仍需在 main 验证 |
| **语言专用规则与 native linter 高度重叠**：GO-01/03/06/12、TS-03/06/08/09、PY-01/06/08/12 等都是 golangci-lint / eslint / ruff 标准覆盖 | 主 agent 对照标准 linter 规则集 | ✅ 部分下沉 | ✅ 动态局部 Skill 按需加载 | 🟢 强共识 |
| **U-11~U-14 / W-18 在 common/ 但场景窄**：U-11~U-14 仅针对多 binary monorepo；W-18 仅 eval 系统开发 | Agent A 识别 | ✅ 下沉到 skill | ✅ 同上 | 🟢 强共识 |

### ⚠️ v1 中已撤回的发现（错误事实判断）

| v1 声明 | v2 状态 | 真实情况 |
|---|---|---|
| "vibeguard 仓 SEC-11 引用不存在的 `check_dependency_changes.sh` / `check_test_weakening.sh`" | ❌ 撤回 | `git ls-tree origin/main guards/universal/` 显示两个脚本都存在 |
| "vibeguard 仓 W-20 引用不存在的 `check_runtime_drift.sh`" | ❌ 撤回 | 脚本存在；W-20 本身不在 vibeguard 仓 origin/main，仅在用户私人扩展副本 |
| "vibeguard 仓 U-32 引用不存在的 `count_active_constraints.sh/.py`" | ❌ 撤回 | `hooks/count_active_constraints.sh` + `scripts/constraints/count_active_constraints.py` 在 origin/main 都存在 |
| "W-02 阈值漂移：文档 3 次 vs hook 5 次" | ❌ 撤回 | 5 次是 U-25 ESCALATE 阈值，跟 W-02 "3 次失败撤退" 不是同一阈值；两者不存在冲突 |
| "SEC-12/13/14 全无 hook 实现" | 🟡 待复审 | Agent B 在 codex 分支观察的结论，main 分支需另查 |
| "41 条 strict 规则中只有 17% 真机械化执行" | 🟡 待复审 | 基于 codex 分支的不完整工作树，main 分支统计需另跑 |

### ⚪ Insufficient data

| 假设 | 缺什么数据 | 建议 |
|---|---|---|
| 60→25 条精简对 agent 实际行为的影响 | 需 A/B 对比规则集大小变化的 token 用量和任务失败率 | 用 `vibeguard:learn` 跟踪触发频率再决定 |
| W-19 200/800 行阈值是否合理 | 缺真实项目数据 | guard-precision-tracker 跟踪 |

---

## ⚠️ Audit 误判复盘（W-01 + W-16 反面教材）

本审计在 fact-level 判断上**连续犯了 3 次错**，值得作为"如何做错 audit"的教材。

### 错误链

**错误 1**：把用户私人 CLAUDE.md 加载的扩展正文当成 vibeguard 仓的实际正文。
- 主 agent 在 system context 里看到的 SEC-11 / W-12 / U-32 等规则正文带有 `bash guards/universal/check_*.sh ...` 引用。
- 直接把这些当成"vibeguard 仓的规则文本"。
- 没有 `git show origin/main:rules/...` 核对仓本身的版本。

**错误 2**：用 `find /Users/lifcc/Desktop/code/AI/tools/vibeguard -name xxx.sh` 扫工作目录得到 0 命中 → 判定"脚本不存在"。
- 没意识到当前 checked out 的 `codex/codex-usage-experience` 分支删除了这些脚本（`git diff --stat origin/main HEAD` 显示 -233/-302/-277/-189/-112）。
- 应当用 `git ls-tree origin/main path/` 查仓的真实状态。

**错误 3**："修正"为说 fake-cmd 在单数 `tool/vibeguard/` 私人扩展副本里 → 也错。
- 单数 `tool/vibeguard/` 是 vibeguard 仓 main 分支的较新 clone（remote 也是同一个 GitHub URL），脚本和引用都齐全。
- 第三次验证时通过 `ls /Users/lifcc/Desktop/code/AI/tool/vibeguard/guards/universal/` 才发现脚本全部真实存在。

### 违反的 VibeGuard 规则

- **W-01（无根因不修复）**：在 "fake-cmd" 假设上没真正复现，直接基于 `find` 0 命中就下结论。
- **W-16（验证证据要本会话产出且充分）**：把 `find` 0 命中当成充分证据，但 `find` 只看工作树不看 git 历史。
- **W-15（信息增益衰减）**：连续 3 轮"修正同一个事实判断"，每轮都缩小到错误的细节里，本应在第 2 轮就停下来质疑假设。
- **Fact / Inference / Suggestion 分离原则（W-11）**：把"working tree 没找到脚本"（fact）直接升级为"仓里没有脚本"（inference），且没标注置信度。

### 教训

1. **代码审计前先确认分支**。`git branch --show-current` + `git diff --stat origin/main HEAD` 应当是 audit 起点的一部分，不是 corrective action。
2. **`find` 工作树 ≠ 仓里没有**。应当用 `git ls-tree -r origin/main` 或 `git log --all --diff-filter=D -- path` 才能给出"X 不存在于仓里"的结论。
3. **多 clone 副本要警惕**。用户 `/Users/lifcc/Desktop/code/AI/tool/` (单数) vs `/Users/lifcc/Desktop/code/AI/tools/` (复数) 是两个独立 clone，加上 `~/.claude/rules/vibeguard/` 安装快照，共三处可能加载同一个仓的不同版本/分支状态。
4. **Skill 适用边界要尊重**。`multi-ai-research` 的 "❌ 不适合" 列表第一条就是"需要深度项目 context 的任务"——规则系统 audit 严重依赖 project context，跑 multi-ai-research 反而扩大了基于片面信息的判断。

---

## 还站得住的 design observations（推荐用作 issue 内容）

去掉 fact-level 后，基于规则正文阅读的设计观察依然有效，列在 `docs/artifacts/issue-draft-rule-system-design-discussion.md` 中。简要：

1. U-17 / U-23 / U-29 错误处理三件套语义重叠，U-29 写得最完整
2. U-08 被 W-03 + W-16 完全覆盖
3. 部分 strict 规则（U-02 / U-21 / U-22 / U-24）的正文偏向 best-practice 而非可执行约束；U-32 自己说 strict 规则需要 downgrade path
4. 部分语言专用规则与 golangci-lint / eslint / ruff 高度重叠
5. U-11~U-14 / W-18 在 common/ 但场景窄，可考虑路径范围化
6. `post_edit_history.sh:28`（在 codex 分支上）于 churn>=20 场景引用 W-02，但 churn 更接近 W-15 范畴 — 此条仅在 codex 分支验证过，main 需另查

---

## Phase 6 修正版 Action Items

### 🟢 推荐做（基于规则正文，与分支无关）

- 把 6 条 design observations 作为 issue 提到 vibeguard 仓，让 maintainer 决定是否处理。
- issue 草稿见 `docs/artifacts/issue-draft-rule-system-design-discussion.md`。
- **不要**提 PR：所有内容都是设计判断，应由 maintainer 决定。

### ⚪ 待 main 分支验证后再说

- SEC-12/13/14 hook 实现情况
- W-10 hook 与规则文 trigger 清单的覆盖率
- 41 条 strict 规则的真实机械化比例

### 🚫 已撤回的 v1 P0 action items

- ~~A3：修复 4 个 fake-cmd 引用~~ — 撤回，引用都不是 fake
- ~~A4：W-02 阈值漂移修复~~ — 撤回，不存在漂移

---

## Sources

**Internal agents**（read-only，no files modified）：
- Agent A：13 规则文件，识别 6 个 overlap group + 12 条降级候选 + 11 条缺 downgrade path — **基于规则正文阅读，结论有效**
- Agent B：13 规则文件 + hooks/guards 工作树 grep — **结论受限于 codex 分支工作树状态，跟 main 不一致**

**External AIs**：
- grok（46s thinking）：策略层建议 — 仅看规则 ID，权重低
- gemini：策略层建议 — 仅看规则 ID，权重低
- chatgpt：2x NETWORK_ERROR timeout，失败

**Main agent fact-level verification**：
- v1 用了不充分的 `find` 工作树 → 错误结论
- v2 用 `git ls-tree origin/main` + `git diff --stat origin/main HEAD` → 修正
