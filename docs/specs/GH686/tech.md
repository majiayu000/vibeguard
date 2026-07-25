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
3. **在场断言（B-003a）**：`with_text` 必须真的包含候选规则的定义。找不到就以
   "候选规则不存在"终止。没有这条，剔除是 no-op 时 `strip(A) == A == B`，一对完全
   相同的运行会冒充合法对照，把"ID 写错/规则不在树里"误报成"规则无效果"。
   core 文件的 marker 区只有约 16 条 Key Detailed Rules，所以 core 侧剔除对多数候选
   本来就是 no-op —— no-op 是常态，不是异常。
4. **非平凡断言（B-003b）**：`len(with_text) > len(without_text)`，且被删 span 必须以
   `## <ID>:` 起始。
5. **差集断言（B-003c）**：`with_text` 按同样规则剔除候选定义之后，必须与
   `without_text` **逐字节相等**。这条同时证明了"候选被移除"和"其他什么都没变"。
6. **定义位点 token 断言**：`without_text` 中不得出现候选的**定义位点**
   （`## <ID>:` 小节标题、core 表格行）。

**断言范围为什么不是全文（B-012）**：规则之间存在跨文件交叉引用。实测全仓 127 条规则
定义中，**19 条**被其它规则文件的正文引用，例如 `U-32` 出现在
`rules/claude-rules/common/security.md:121`、`:178`、`:202`。小节级剔除后这些引用仍在
`without_text` 里，一条 `\b<ID>\b` 全文断言会让门对这 19 条规则**无条件终止** ——
其中就包括 `U-32`，也就是本 issue 用来论证自身动机的那条规则。

这些交叉引用**无法消除**：删掉它们会改动其它规则的正文，直接违反 B-001 的"其余规则
完全一致"。因此它们是已知残留，必须在报告中逐条列出（`文件:行号`）并计入结果的
caveat —— 显式声明，不能装作不存在。

### 2. 与 `run_eval` 的集成方式

`run_eval` 无返回值、跳过样本会 `sys.exit(2)`、指标口径把跳过样本剔出分母——三点
都与本门冲突，所以**不复用 `run_eval` 顶层函数**。配对运行器复用的是它的下层组件：

- `load_rules` / `build_system_prompt` / `sha256_text` / `file_digest` / `sample_set_digest`
- `evaluate_sample`（逐样本调用与打分）
- `load_dataset`

自建评测循环，自算通过率。`run_eval.py` 不做任何修改，"不改 `run_eval.py`"的承诺
因此成立，但代价要写明：本门与单次评测路径共享组件、不共享指标实现。

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
- 非目标样本：来自独立的 `non-target` 数据集（见 D1 结论）。

### 5. 两条证据轴与判定

| 轴 | 判定 |
| --- | --- |
| 目标场景改善 | `pass_rate(A1) - pass_rate(B1) > min_target_delta`（**严格大于**） |
| 非目标不回归 | `pass_rate(B2) - pass_rate(A2) <= max_non_target_drop` |

目标轴用严格大于：`>= 0.0` 会让一条毫无可测效果的规则通过，那正是弱门冒充强门。

整体判定 = 两轴合取。任一轴 `inconclusive` → 整体 `inconclusive`。

### 6. 跳过样本与可比性

- 分母**始终**是请求的样本数，不是成功返回的样本数。不复用 `model_summary_metrics`。
- 任一次运行的跳过率超过 `max_skip_rate` → `inconclusive`。
- with 与 without 的跳过率之差超过 `max_skip_delta` → `inconclusive`：跳过率偏差会
  直接主导 delta，输入身份相等不等于产出可比。

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
  "calibrated": false
}
```

`calibrated: false` 时整体判定**强制降级为 `inconclusive`，永不输出 `pass`**。
只打一行 warning 是不够的——那样未标定的门仍会被下游当作已标定的门引用。

当前 `calibrated` 是单个布尔，覆盖文件中**全部**阈值键。`max_skip_rate` 与
`max_skip_delta` 同样是新拍的数字。标定其中一项就把整个文件翻成 `true`，会顺带把仍
未标定的其余阈值洗白 —— 若将来分项标定，改为逐键标注。

未标定阶段本门恒定输出 `inconclusive`，因此规则 PR 在这一阶段可接受的证据形态是
**inconclusive 报告加两轴 delta 数值与样本量**，不是 `pass`（B-009）。

### 8. 离线 dry-run

不调用模型，输出：四次运行的规则摘要与在场/非平凡/差集三条断言的结果、交叉引用残留
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
- **D2（打分方式）→ 仍需维护者裁定。** 见下。

## D2 为什么是真问题

`eval/dataset.py:105-118` 强制 `type ∈ {tp,fp}`，且 `fp` 样本必须
`rule="NONE"` + `expected_action="allow"`；现有 grader 只产出 detection rate 与
false-positive rate。也就是说复用既有 grader 时，非目标轴实际度量的是**误报漂移**，
不是 product.md 说的"普通编码任务的质量没有下降"。

两条路：把非目标轴的口径收敛为"误报率不上升"（复用现有 grader，便宜且确定），
或引入 pairwise judge 才能测"质量"（更贵、更接近 issue 原意）。这决定数据集形态和
打分实现，必须先定。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 | 同轴内非候选文本一致 | `bash tests/test_paired_eval.sh`（非候选规则文本逐字节一致；整文件删除必须被拒） |
| B-002 | 按轴配对的摘要相等断言 | `bash tests/test_paired_eval.sh` |
| B-003 | 在场 + 非平凡 + 差集 + 定义位点 token | `bash tests/test_paired_eval.sh`（候选不存在时终止；core 文件仍含候选时终止；no-op 剔除必须被拒） |
| B-004 | 精确匹配的目标/非目标划分 | `bash tests/test_paired_eval.sh` |
| B-005 | 合取判定 | `python3 eval/test_paired_eval.py`（单轴通过不得整体通过） |
| B-006 | 任一轴样本量下限 → inconclusive | `python3 eval/test_paired_eval.py` |
| B-007 | 分母口径 + 跳过率与跳过率差 | `python3 eval/test_paired_eval.py` |
| B-008 | dry-run 无需密钥 | `bash tests/test_paired_eval.sh` |
| B-009 | `templates/pull_request.md` | `bash tests/test_eval_contract.sh` 内新增模板断言段 |
| B-010 | `calibrated: false` 强制 inconclusive | `python3 eval/test_paired_eval.py` |
| B-011 | 真实运行的 inconclusive 非零退出 | `python3 eval/test_paired_eval.py` |
| B-012 | 交叉引用残留逐条列出 | `bash tests/test_paired_eval.sh`（U-32 这类被引用规则必须能跑完并列出残留） |

## 数据流

```
候选规则 ID
        |
        +-- with:    rules/claude-rules/  +  claude-md/vibeguard-rules.md   --> text_A
        +-- without: <tmp 规则树, 剔除该 ## <ID>: 小节>
                   + <tmp core 文件, 剔除该 ID 表格行>                       --> text_B
        |
        |   断言 1: text_A 含候选定义        (否则"候选不存在"终止)
        |   断言 2: len(text_A) > len(text_B)  (剔除非平凡)
        |   断言 3: strip_candidate(text_A) == text_B   (逐字节)
        |   断言 4: text_B 不含候选的定义位点  (非全文 token)
        |   报告:   其它规则对该 ID 的交叉引用清单 (已知残留)
        v
   同一模型 ID
        |
        +-- 目标数据集   (rule == candidate, 精确匹配)  --> A1, B1
        +-- 非目标数据集 (独立 non-target 集)           --> A2, B2
        |
        |   分母 = 请求样本数; 跳过率与跳过率差超阈值 -> inconclusive
        v
   目标轴:   pass(A1) - pass(B1) >  min_target_delta
   非目标轴: pass(B2) - pass(A2) <= max_non_target_drop
        |
        v
   整体 = 合取; 任一 inconclusive -> inconclusive; calibrated=false -> inconclusive
   inconclusive 与 fail 均以非零退出码结束
```

## 风险与权衡

- **成本**：4 次模型运行，且有采样噪声。因此是按需的规则 PR 门，不进默认 CI。
- **与单次评测路径共享组件而非共享指标**：`run_eval.py` 零修改，但两条路径的指标口径
  会不同（本门把跳过样本留在分母）。这是有意的，必须在实现中注释说明，否则后来者会
  以为其中一处是 bug。
- **差集断言的代价**：要求剔除逻辑对两个来源都精确。这正是它存在的理由——一次没有
  真正移除候选规则的"对照"比没有对照更危险，因为它会产出看起来合法的数字。
