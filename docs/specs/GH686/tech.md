# Tech Spec — prompt 注入规则的 with/without 配对评测（副作用门）

## Linked Issue

GH-686

## Product Spec

`docs/specs/GH686/product.md`

## Codebase Context

行号在 `origin/main` 上核对过。

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| 单次 model-backed 评测 | `eval/run_eval.py:215` | `run_eval(args, baseline)` 加载规则、构造 system prompt、逐样本调用模型 | 配对运行需要它的评测循环，但**不能**整体复用（见下） |
| 规则注入的**两个**来源 | `eval/run_eval.py:38`、`:225` | `load_rules(rules_dir, core_rules_file)` 先 `rglob` 规则目录，**再无条件拼上** `core_rules_file` | 决定性事实：只换 `--rules-dir` 不能移除候选规则 |
| core 规则文件默认值 | `eval/run_eval.py:35` | `DEFAULT_CORE_RULES_FILE = claude-md/vibeguard-rules.md` | 该文件以**表格行**重复规则正文（`claude-md/vibeguard-rules.md:69` 是 U-16 那一行） |
| 输入身份 | `eval/run_eval.py:227`、`:228`、`:230` | `rule_digest`、`dataset_digest`、`filtered_sample_digest` | B-002 的审计基础已存在 |
| 模型解析 | `eval/run_eval.py:231` | `baseline.resolve(args.model)` | 两次运行必须解析到同一 ID |
| 样本筛选 | `eval/run_eval.py:189` `filter_samples` | **前缀**匹配（`startswith`）**并强制附带** `rule == "NONE"` 的样本 | 不能用它做目标样本划分，会前缀误命中并混入 NONE |
| 跳过样本 | `eval/run_eval.py:315-321` | `skipped_count > EVAL_MAX_API_FAILURES`（默认 0）→ `sys.exit(2)` | 作为库调用会直接打死配对运行器 |
| 指标口径 | `eval/run_eval.py:332` `model_summary_metrics` | `valid_results` **剔除**跳过样本后再算比率 | 与"分母是请求样本数"相反，不能复用 |
| 返回值 | `eval/run_eval.py:215-247` | 无返回值；结果经 stdout 与 `write_run_artifacts`（`eval/artifacts.py:64`）落盘 | 调用方拿不到 pass rate |
| 数据集现状 | `eval/datasets/v1.jsonl` | 共 **40** 条，`rule == "NONE"` 仅 **4** 条，单个规则最多 4 条 | 决定 D1 与样本量下限 |
| 数据集 schema | `eval/dataset.py:105-118` | 强制 `type ∈ {tp,fp}`；`fp` 必须 `rule="NONE"` 且 `expected_action="allow"` | 决定非目标轴实际能测什么 |
| 确定性行为门 | `eval/run_behavior_eval.py`、`.github/workflows/ci.yml:240` | hook 强制规则的确定性门，已在 CI | 配对门是补充，不替换、不进默认 CI |
| 规则 PR 模板 | `templates/pull_request.md` | 无任何 prompt 规则副作用证据要求 | B-009 的落点 |

## 设计方案

### 0. 一个必须先纠正的前提

初版设计假定"把候选规则文件从 `--rules-dir` 移除即可得到 without 对照"。**这是错的**：
`load_rules` 还会拼上 `core_rules_file`，而 `claude-md/vibeguard-rules.md` 以表格行
重复规则正文。只换目录的 without 运行里，候选规则仍然在 system prompt 中——得到的
是一个**假对照**，而且初版的 B-003 断言（"without 文本不含 `## <ID>:` 标题"）对表格行
永远为真，正好放行这个假对照。

因此候选规则的剔除必须同时作用于两个来源，且断言必须是差集断言而非在场/缺席断言。

### 1. 候选规则的剔除与对照有效性

1. **with 文本** = `load_rules(rules/claude-rules/, claude-md/vibeguard-rules.md)`。
2. **without 文本** = 同样两个来源，但：
   - 规则目录：复制到临时目录，从候选规则所在文件中**只删除该规则的 `## <ID>:` 小节**。
     不允许整文件删除——`rules/claude-rules/common/coding-style.md` 一个文件里有 24 条
     `## U-` 规则，整文件删除会连带移除 23 条无关规则，直接违反 B-001。
   - core 文件：复制到临时文件，删除该 ID 的表格行。
3. **比较口径是逐文件差分，不是在拼装文本上重放剔除。** 这是第三轮审查纠正的架构点：
   `load_rules`（`eval/run_eval.py:38-68`）给每个文件加 `# {stem}` 头、用 `\n\n---\n\n`
   拼接。在拼装文本上以 `(?=^## )` 为界重放剔除，对"候选是所在文件最后一节"的规则会越过
   文件边界吃到下一个文件——全仓当前 127 条定义中有 18 条处于这个位置（含 10 个单规则文件，
   如 `rules/claude-rules/common/evidence-provenance.md` 的 W-21）。

   文件内候选 span 以 canonical `RULE_ID_HEADING_RE` 的下一条规则定义为边界，不以任意
   `^## ` 为边界；否则 W-11 fenced 示例中的 `## Facts` 会被误当成下一条规则。

   因此断言直接比较**临时树与真实树**：
   - 只允许一个规则文件不同，且该文件的差异**恰为**候选小节；
   - core 文件的差异**恰为**该 ID 的表格行；
   - 其余文件逐字节相同。

4. **在场断言**：候选定义必须真的存在于真实树中。找不到就以"候选规则不存在"终止。
   没有这条，剔除是 no-op 时两个完全相同的运行会冒充合法对照，把"ID 写错/规则不在树里"
   误报成"规则无效果"。core 文件的 marker 区只有约 16 条 Key Detailed Rules，所以 core
   侧剔除对多数候选本来就是 no-op —— no-op 是常态，不是异常。

5. **定义计数断言**：复用现有独立 canonical parser
   `scripts/lib/vibeguard_manifest.py:35` 的 `RULE_ID_HEADING_RE` 识别定义；`with_text`
   的定义数减去 `without_text` 的定义数**必须恰好等于 1**，且被删 span 内除首个候选
   标题外不得再出现第二条 canonical 规则定义；普通 Markdown `##` 标题属于规则正文。
   不得把 `strip_candidate` / `extract_section` 的结果本身拿来计数。
   canonical parser 当前覆盖 127 条定义，包括三个非数字后缀 ID：`TASTE-ANSI`、
   `TASTE-ASYNC-UNWRAP`、`TASTE-PANIC-MSG`。这条**不依赖剔除逻辑**，是专门用来抓
   "删多了"的非同源断言。

   删多了是唯一会制造**假 pass** 的失效模式：若剔除正则贪婪（`.*\Z` with DOTALL，或
   lookahead 写错），候选之后的若干小节会被一起吃掉。此时在场、非平凡、差集（两侧用同一个
   剔除逻辑，同样删多了）、定义位点四条断言**全部通过**，而 without 少了候选之外的规则，
   目标轴 delta 被系统性放大，一条无效规则更容易越过"严格大于"。

6. **定义位点 token 断言**：`without_text` 中不得出现候选的定义位点
   （`## <ID>:` 小节标题、core 表格行）。这条抓的是"删漏了"。

**断言范围为什么不是全文（B-012）**：规则之间存在跨文件交叉引用。按当前 `main`
实测全仓 127 条规则定义中，**30 条**被其它规则文件的正文引用。`U-32` 的候选小节外
引用现为 13 处（规格起草时记录的 4 处已因后续规则内容增长而过时）。小节级剔除后这些
引用仍在 `without_text` 里，一条 `\b<ID>\b` 全文断言会让门对这 30 条规则**无条件
终止**——其中就包括 `U-32`，也就是本 issue 用来论证自身动机的那条规则。

这些交叉引用**无法消除**：删掉它们会改动其它规则的正文，直接违反 B-001 的"其余规则
完全一致"。它们的偏置方向是保守的（without 仍向模型提示该 ID 存在，压缩而非放大 delta），
但**残留多到一定程度对照就不成立**。因此：逐条列出真实规则树中的 `文件:行号`，并在
数量超过 `max_cross_refs` 时判 `inconclusive` —— 只写进 caveat 不影响判定，等于
"记录即免责"，会把"对照被严重污染"与"对照干净"输出成同一个 `pass`。默认阈值仍为
4，不因 U-32 当前已有 13 处引用而放宽；U-32 应据此得到 `inconclusive`。

同理，单规则文件剔除后 `load_rules` 仍会产出一个 `# {stem}` 空标题块，without 文本里
留着"此处曾有一条规则"的痕迹。该残留一并在报告中标注。

### 2. 与 `run_eval` 的集成方式

`run_eval` 无返回值、跳过样本会 `sys.exit(2)`、指标口径把跳过样本剔出分母——三点
都与本门冲突，所以**不复用 `run_eval` 顶层函数**。配对运行器复用的是它的下层组件：

- `load_rules` / `build_system_prompt` / `sha256_text` / `file_digest` / `sample_set_digest`
- `evaluate_sample`（仅用于目标轴的逐样本调用与 structured-JSON 打分）
- `load_dataset`

自建评测循环，自算通过率。`run_eval.py` 不做任何修改，"不改 `run_eval.py`"的承诺
因此成立，但代价要写明：本门与单次评测路径共享组件、不共享指标实现。非目标轴不得
复用 `build_system_prompt` / `evaluate_sample` 的 code-review JSON 输出契约；否则 pairwise
judge 比较的仍是 detection / false-positive 回答，不是普通任务质量。它使用同一 producer
模型与规则文本构造普通任务响应，再交给独立 judge 比较。

### 3. 运行次数

两条轴用两个数据集，因此是 **4 次运行**，不是 2 次：

| | 目标数据集 | 非目标数据集 |
| --- | --- | --- |
| with 候选规则 | run A1 | run A2 |
| without 候选规则 | run B1 | run B2 |

B-002 的摘要相等断言**按轴配对比较**：A1/B1 共用一个 `sample_set_digest`，A2/B2 共用
另一个；四次运行共用同一个解析后的模型 ID；A 与 B 的 `rule_digest` 必须不等。

### 4. 目标样本与非目标样本

- 目标样本：`rule == <candidate>` 的**精确**匹配。**不得复用 `filter_samples`**，它是
  前缀匹配且强制混入 `NONE` 样本，两者都会污染目标轴。
- 非目标样本：来自独立的 `non-target` 数据集（见 D1 结论）。每条包含普通任务输入、
  明确的质量 rubric 与 `excluded_rules`；若候选 ID 在该列表中，本次运行排除该样本，
  防止候选相关任务被误算为非目标副作用。`excluded_rules` 除格式校验外还必须属于当前
  `--rules-dir` 的 canonical inventory；未知 ID fail closed。它不复用只支持 tp/fp 的
  现有 dataset schema。

### 5. 两条证据轴与判定

| 轴 | 判定 |
| --- | --- |
| 目标场景改善 | `pass_rate(A1) - pass_rate(B1) > min_target_delta`（**严格大于**） |
| 非目标不回归 | 盲化 pairwise judge 对 A2/B2 逐样本换序复核；`quality_delta = (with_wins - without_wins) / requested_samples >= -max_non_target_drop` |

目标轴用严格大于：`>= 0.0` 会让一条毫无可测效果的规则通过，那正是弱门冒充强门。

整体判定 = 两轴合取。任一轴 `inconclusive` → 整体 `inconclusive`。

非目标 judge 只看到任务、rubric 与标为 A/B 的两份输出，不得看到候选规则 ID 或
with/without 标签。每个样本调用两次 judge，第二次交换 A/B 位置；映射回 with/without
后，两次结果必须一致为 `with_win`、`without_win` 或 `tie`。不一致记为 `conflict`，
非目标轴直接 `inconclusive`，不得择一、投票或静默丢弃。报告记录 producer model ID、
judge model ID、judge prompt digest、两次原始响应与映射结果。

真实运行必须显式提供 `--judge-model`，并通过现有 model baseline 解析为审计用 ID；不得
静默复用 producer model。judge 输出使用独立的严格 JSON 契约
`{"winner":"A"|"B"|"tie","reason":"..."}`，缺字段、越界 winner、解析失败或 API 失败都
按 B-007 计为 skipped/judge failure，而不是猜测 winner。dry-run 只解析并打印 producer /
judge 模型身份与 judge prompt digest，不调用模型。

### 6. 跳过样本与可比性

- 分母**始终**是请求的样本数，不是成功返回的样本数。不复用 `model_summary_metrics`。
- 任一次运行的跳过率超过 `max_skip_rate` → `inconclusive`。
- with 与 without 的跳过率之差超过 `max_skip_delta` → `inconclusive`：跳过率偏差会
  直接主导 delta，输入身份相等不等于产出可比。
- 每条模型调用边界单独捕获 `KeyboardInterrupt`。一旦中断，不再发起新的 producer /
  judge / placebo 请求；当前及后续槽位填入带 stage 的 skipped 记录，已完成响应原样保留，
  最终报告写入 `interrupted: true` 与 `interruption_stage`，整体强制
  `inconclusive` 并非零退出。
- producer 返回空字符串或纯空白时按 skipped 记录，不得发送给 pairwise judge。

### 7. 阈值与标定

`eval/paired/` 下新增 `thresholds.json`：

```json
{
  "min_target_samples": 5,
  "min_non_target_samples": 30,
  "min_target_delta": 0.0,
  "max_non_target_drop": 0.0,
  "max_skip_rate": 0.1,
  "max_skip_delta": 0.05,
  "max_cross_refs": 4,
  "max_placebo_length_ratio": 0.25,
  "calibrated": false
}
```

`calibrated: false` 时整体判定**强制降级为 `inconclusive`，永不输出 `pass`**。
只打一行 warning 是不够的——那样未标定的门仍会被下游当作已标定的门引用。

当前 `calibrated` 是单个布尔，覆盖文件中**全部**阈值键（新增键必须一并纳入）。
`max_skip_rate`、`max_skip_delta` 与 `max_placebo_length_ratio` 同样是新拍的数字。所有
比例阈值必须是 0–1 的有限数，样本量与引用上限必须是非负整数；JSON `NaN` 不得静默
绕过比较。标定其中一项就把整个文件翻成 `true`，会顺带把仍未标定的其余阈值洗白 ——
若将来分项标定，改为逐键标注。

placebo 长度资格比较使用 `len(with_rules) - len(without_rules)` 的完整 prompt 差值；
候选和 placebo 都必须在各自原生小节及 core ID 行处理完成后再比较。只比较
`removed_section_characters` 会漏掉 core 行，使真实上下文差超过 25% 的组合被错误接受。

未标定阶段本门恒定输出 `inconclusive`，因此规则 PR 在这一阶段可接受的证据形态是
**inconclusive 报告加两轴 delta 数值与样本量**，不是 `pass`（B-009）。

### 8. 离线 dry-run

不调用模型，输出：四次运行的规则摘要与逐文件差分/在场/计数/定义位点全部断言的结果、交叉引用残留
清单、数据集与样本集摘要、目标/非目标样本划分与数量、解析后的模型 ID、阈值是否已标定。

**dry-run 不产出判定**，因此不受"未标定强制 inconclusive"与"inconclusive 非零退出"
约束，正常完成时退出 0。否则在 `calibrated: false` 阶段 dry-run 会恒定非零退出，而
确定性测试只测这条路径，那些测试将永远无法通过。

## 前置决策的结论

初版把三个问题都推给维护者。核对代码后，其中两个 spec 自己就能定：

- **D1（非目标任务集来源）→ 已定：必须新建 `non-target` 数据集。**
  `eval/datasets/v1.jsonl` 只有 4 条 `NONE` 样本，而非目标轴下限是 30。从 v1 划分
  在算术上不成立，不是一个可选项。
- **D3（标定实验）→ 已定：先落地方向性门。**
  `calibrated: false` 强制 `inconclusive` 之后，未标定的门不会产生误导性的 `pass`，
  标定实验可以独立进行。
- **D2（打分方式）→ 已定：混合打分。** 目标轴复用 structured-JSON grader；非目标轴
  使用盲化、换序复核的 pairwise judge。

## D2 裁定与理由

`eval/dataset.py:105-118` 强制 `type ∈ {tp,fp}`，且 `fp` 样本必须
`rule="NONE"` + `expected_action="allow"`；现有 grader 只产出 detection rate 与
false-positive rate。也就是说复用既有 grader 时，非目标轴实际度量的是**误报漂移**，
不是 product.md 说的"普通编码任务的质量没有下降"。

因此不把一个 scorer 强行套到两条轴：目标轴继续用现有 structured-JSON grader，
保持对候选规则 detection 的既有语义；非目标轴使用 pairwise judge 比较普通任务质量，
保持 issue 的原始产品目标。pairwise judge 必须盲化条件标签、交换 A/B 位置复核并保存
完整审计证据；换序冲突 fail closed 为 `inconclusive`。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 | 同轴内非候选文本一致 | `bash tests/test_paired_eval.sh`（非候选规则文本逐字节一致；整文件删除必须被拒） |
| B-002 | 按轴配对的摘要相等断言 | `bash tests/test_paired_eval.sh` |
| B-003 | 逐文件差分 + 在场 + 计数 + 定义位点 token；匿名 compact 等价语义候选拒绝表 | `bash tests/test_paired_eval.sh`（候选不存在时终止；core 仍含候选时终止；no-op 剔除被拒；**贪婪剔除多删一节必须被拒**；候选位于文件末节时必须能跑通；U-04 等已知 compact 重复在调用前拒绝） |
| B-004 | 精确匹配的目标/非目标划分；排除 ID 属于 canonical inventory | `bash tests/test_paired_eval.sh`（未知 `excluded_rules` ID 在调用模型前失败） |
| B-005 | 合取判定 | `python3 eval/test_paired_eval.py`（单轴通过不得整体通过） |
| B-006 | 任一轴样本量下限 → inconclusive | `python3 eval/test_paired_eval.py` |
| B-007 | 分母口径 + 跳过率与跳过率差 + 空响应 + 中断 partial report | `python3 eval/test_paired_eval.py`（空白 producer 响应 skipped；Ctrl-C 后不再调用模型，已完成响应保留，未完成项 skipped） |
| B-008 | dry-run 无需密钥 | `bash tests/test_paired_eval.sh` |
| B-009 | `templates/pull_request.md` | `bash tests/test_eval_contract.sh` 内新增模板断言段 |
| B-010 | `calibrated: false` 强制 inconclusive | `python3 eval/test_paired_eval.py` |
| B-011 | 真实运行的 inconclusive 非零退出 | `python3 eval/test_paired_eval.py` |
| B-012 | 交叉引用残留逐条列出并计入判定 | `bash tests/test_paired_eval.sh`（U-32 这类被引用规则必须能跑完并列出残留；残留超 `max_cross_refs` 判 inconclusive） |
| B-013 | 字符数与长度差报告 | `bash tests/test_paired_eval.sh` |
| B-014 | 标定流程的不同规则、按完整 prompt 差值校验长度的 placebo | `bash tests/test_paired_eval.sh`（U-21/U-16 原生小节相近但完整差值超限时拒绝） |
| B-015 | 目标 structured-JSON + 非目标盲化换序 pairwise judge | `python3 eval/test_paired_eval.py`（A/B 换序一致、冲突 inconclusive、judge 审计字段完整） |

## 数据流

```
候选规则 ID
        |
        +-- with:    rules/claude-rules/  +  claude-md/vibeguard-rules.md   --> text_A
        +-- without: <tmp 规则树, 剔除该 ## <ID>: 小节>
                   + <tmp core 文件, 剔除该 ID 表格行>                       --> text_B
        |
        |   断言 1: 逐文件差分 — 仅一个规则文件不同, 差异恰为候选小节
        |             + core 文件差异恰为该 ID 表格行, 其余逐字节相同
        |   断言 2: 候选定义确实存在于真实树 (否则"候选不存在"终止)
        |   断言 3: 定义计数差 == 1, 删除 span 内无第二条 canonical 规则定义
        |   断言 4: text_B 不含候选的定义位点                  (抓"删漏了")
        |   报告:   交叉引用清单 + 空壳文件; 超 max_cross_refs -> inconclusive
        v
   同一模型 ID
        |
        +-- 目标数据集   (rule == candidate, 精确匹配)  --> A1, B1
        +-- 非目标数据集 (独立 non-target 集)           --> A2, B2
        |
        |   分母 = 请求样本数; 跳过率与跳过率差超阈值 -> inconclusive
        v
   目标轴:   pass(A1) - pass(B1) >  min_target_delta
   非目标轴: (with_wins - without_wins) / requested_samples >= -max_non_target_drop
              A/B 换序结论冲突 -> inconclusive
        |
        v
   整体 = 合取; 任一 inconclusive -> inconclusive; calibrated=false -> inconclusive
   inconclusive 与 fail 均以非零退出码结束
```

## 风险与权衡

- **成本**：4 次 producer 模型运行，外加每个非目标样本两次换序 judge 调用，且有采样
  噪声。因此是按需的规则 PR 门，不进默认 CI。
- **与单次评测路径共享组件而非共享指标**：`run_eval.py` 零修改，但两条路径的指标口径
  会不同（本门把跳过样本留在分母）。这是有意的，必须在实现中注释说明，否则后来者会
  以为其中一处是 bug。
- **差集断言的代价**：要求剔除逻辑对两个来源都精确。这正是它存在的理由——一次没有
  真正移除候选规则的"对照"比没有对照更危险，因为它会产出看起来合法的数字。
