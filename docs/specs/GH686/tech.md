# Tech Spec — prompt 注入规则的 with/without 配对评测（副作用门）

## Linked Issue

GH-686

## Product Spec

`docs/specs/GH686/product.md`

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| 单次 model-backed 评测 | `eval/run_eval.py:215` | `run_eval` 加载规则目录、构造 system prompt、逐样本调用模型 | 配对运行复用它，不重写评测循环 |
| 规则来源参数化 | `eval/run_eval.py:216-217` | `--rules-dir` 与 `--core-rules-file` 已经决定注入哪些规则文本 | without 运行靠替换规则来源实现，无需改 prompt 构造 |
| 输入身份 | `eval/run_eval.py:228-231` | 已计算 `rule_digest`、`dataset_digest`、`sample_set_digest` | B-002 的审计基础已经存在，直接复用 |
| 样本筛选 | `eval/run_eval.py:230`、`eval/samples.py` | `filter_samples` 支持按 `--rules` 前缀与 `--type` 筛选 | 目标 / 非目标划分的基础 |
| 数据集 schema | `eval/datasets/v1.jsonl` | 每条样本含 `rule`、`type`、`tags`、`expected_action` | 目标样本靠 `rule` 匹配，非目标集需要新标记 |
| 模型解析 | `eval/model_baseline.py`、`eval/run_eval.py:232` | `baseline.resolve(args.model)` 给出确定的模型 ID | 两次运行必须解析到同一 ID（B-002） |
| 确定性行为门 | `eval/run_behavior_eval.py`、`tests/test_behavior_eval.sh` | hook 强制规则的确定性门，已在 CI | 配对门是它的补充，不替换、不进默认 CI |
| 规则 PR 模板 | `templates/pull_request.md` | 未要求任何 prompt 规则副作用证据 | B-009 的落点 |

## 设计方案

### 1. 配对运行入口

在 `eval/` 下新增 `run_paired_eval.py`，不修改 `run_eval.py` 的既有语义：

```
python3 eval/run_paired_eval.py \
  --candidate-rule W-21 \
  --candidate-file rules/claude-rules/common/evidence-provenance.md \
  --non-target-dataset eval/datasets/non-target-v1.jsonl \
  --model haiku
```

流程：
1. 解析模型 ID、数据集摘要、样本划分一次，两次运行共用（B-001/B-002）。
2. **with 运行**：规则来源为完整的 `rules/claude-rules/`。
3. **without 运行**：把规则树复制到临时目录，删除候选规则文件（或从单文件中剔除
   候选规则的 `## <ID>:` 小节），再以该临时目录为 `--rules-dir`。
4. 断言 with 的规则文本包含 `## <ID>:` 标题、without 的不包含（B-003）。若断言
   失败则终止 —— 一次没有真正移除候选规则的"对照"是无效对照。
5. 断言两次运行的 `dataset_digest`、`sample_set_digest`、模型 ID 相等，
   `rule_digest` 不等（B-002）。

### 2. 两条证据轴

| 轴 | 样本来源 | 判定 |
| --- | --- | --- |
| 目标场景改善 | `rule == <candidate>` 的样本 | with 的通过率必须**高于** without，差值 ≥ `min_target_delta` |
| 非目标不回归 | `--non-target-dataset` 的固定集合 | with 的通过率相对 without 的下降不得超过 `max_non_target_drop` |

整体判定 = 两轴的合取（B-005）。任一轴 `inconclusive` 时整体为 `inconclusive`，
不是 `pass`（B-006）。

### 3. 样本量下限

在 `eval/paired/` 下新增 `thresholds.json`，与既有 `eval/behavior/thresholds.json` 平行：

```json
{
  "min_target_samples": 5,
  "min_non_target_samples": 30,
  "min_target_delta": 0.0,
  "max_non_target_drop": 0.0
}
```

`min_non_target_samples` 的初值是**占位**，必须由一次标定实验确定（见 product.md
开放问题 1）。在标定完成前，阈值文件中该项标注 `"calibrated": false`，运行时对
未标定阈值输出显式警告 —— 未标定的门不能冒充已标定的门。

### 4. 跳过样本的可见性

`run_eval` 已经有 `result["skipped"]` 路径。配对报告必须分别列出两次运行的跳过
数量，并且跳过率超过阈值时结果降级为 `inconclusive`（B-007）。分母始终是请求的
样本数，不是成功返回的样本数。

### 5. 离线 dry-run

`--dry-run` 不调用模型，输出：两次运行的规则摘要、候选规则在场/缺席的断言结果、
数据集与样本集摘要、目标/非目标样本划分与数量、解析后的模型 ID、以及阈值是否已
标定（B-008）。确定性测试只测这条路径。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 | `run_paired_eval.py` 共用输入构造 | `bash tests/test_paired_eval.sh`（dry-run 断言两次运行输入一致） |
| B-002 | 摘要相等性断言 | `bash tests/test_paired_eval.sh`（构造漂移数据集应终止） |
| B-003 | 候选规则在场/缺席断言 | `bash tests/test_paired_eval.sh` |
| B-004 | 目标/非目标划分 | `bash tests/test_paired_eval.sh`（两组皆空时非零退出） |
| B-005 | 合取判定 | `python3 eval/test_paired_eval.py`（单轴通过不得整体通过） |
| B-006 | 样本量下限 → inconclusive | `python3 eval/test_paired_eval.py` |
| B-007 | 跳过样本计入分母 | `python3 eval/test_paired_eval.py` |
| B-008 | dry-run 无需密钥 | `bash tests/test_paired_eval.sh`（在无 API key 环境下运行） |
| B-009 | `templates/pull_request.md` | `bash tests/test_eval_contract.sh` |

## 数据流

```
候选规则 ID + 规则树
        |
        +--> with:    rules/claude-rules/            --> rule_digest_A
        +--> without: <tmp copy minus candidate>     --> rule_digest_B
        |
        |   (断言: A 含 "## <ID>:", B 不含; A != B)
        v
     同一模型 ID + 同一样本集摘要
        |
        +--> 目标样本   (rule == candidate)      --> pass_rate_A_target,     pass_rate_B_target
        +--> 非目标样本 (non-target dataset)     --> pass_rate_A_nontarget,  pass_rate_B_nontarget
        |
        v
   目标轴: A - B >= min_target_delta
   非目标轴: B - A <= max_non_target_drop
        |
        v
   整体 = 合取; 任一 inconclusive -> inconclusive
```

## 风险与权衡

- **成本与不确定性**：每次配对运行是两倍的模型调用，且结果有采样噪声。因此它是
  按需的规则 PR 门，不进默认 CI；这与 `eval/behavior/` 的确定性门是不同性质的东西。
- **without 运行靠临时规则树**：需要保证复制是完整的、只少了候选规则。B-003 的
  在场/缺席断言就是为此设的机械检查，而不是依赖复制逻辑"应该是对的"。
- **未标定阈值**：在标定实验完成前，本门只能给出方向性信号。实现必须显式声明这一
  点（`"calibrated": false` + 运行时警告），否则一个未标定的门会被当成已标定的门引用。
- **不改 `run_eval.py`**：避免给单次评测路径引入配对专用的分支。代价是配对入口要
  自己组装参数；换来的是既有 CI 路径零风险。

## 未纳入实现的前置决策

product.md 的三个开放问题（非目标样本量、打分方式、非目标任务集来源）需要维护者
裁定。其中"非目标任务集从哪来"直接决定是否要新建 `eval/datasets/non-target-v1.jsonl`
以及它的规模，是实现前的必答项。
