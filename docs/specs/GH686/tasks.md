# Task Plan — GH686

## Linked Issue

GH-686

## Implementation

PR #696 implements SP686-T1 through SP686-T12.

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## 前置决策

初版列了三条；核对代码并取得维护者裁定后，三项均已确定（依据见 `tech.md` 的
「前置决策的结论」）：

| 决策 | 结论 | 状态 |
| --- | --- | --- |
| D1 非目标任务集来源 | 必须新建；v1.jsonl 只有 4 条 `NONE`，下限是 30，划分方案在算术上不成立 | 已定 |
| D3 标定实验 | 先落地方向性门；`calibrated: false` 强制 `inconclusive` | 已定 |
| D2 打分方式 | 目标轴复用 structured-JSON grader；非目标轴使用盲化、换序复核的 pairwise judge | 已定 |

## 实现任务

- [x] `SP686-T1` 在 `eval/` 下新增 `run_paired_eval.py`，实现候选规则的双来源剔除与四条断言。Covers: B-001, B-002, B-003, B-012. Owner: implementation agent. Done when: 规则树按小节剔除、core 文件按表格行剔除；小节边界是下一条 canonical 规则定义而非任意 Markdown `##`；逐文件差分（仅一个文件不同且差异恰为候选小节，不在拼装文本上重放剔除）、在场断言（候选不存在则终止）、定义计数断言（复用独立 canonical `RULE_ID_HEADING_RE`，覆盖含三个 TASTE ID 在内的 127 条定义；差恰为 1 且删除 span 内无第二条 canonical 规则定义，专抓删多了）、定义位点 token 断言四条齐备；断言范围限定在定义位点而非全文，交叉引用残留逐条列出且超 `max_cross_refs` 判 inconclusive；匿名 compact L1-L7 仍保留等价语义的已知候选在付费调用前明确拒绝；整文件删除、no-op 剔除、贪婪多删一节均被拒；候选位于文件末节和正文含普通 `##` 标题时必须能跑通；任一断言失败非零退出。Verify: `bash tests/test_paired_eval.sh`。
- [x] `SP686-T2` 目标 / 非目标样本划分与新建 non-target 数据集。Covers: B-004, B-015. Owner: implementation agent. Done when: 目标样本用精确 `==` 匹配、不复用 `filter_samples`（它是前缀匹配且强制混入 `NONE`）；non-target 数据集独立于 `v1.jsonl`、使用普通任务输入、质量 rubric 与候选 `excluded_rules`，而非复用 tp/fp schema；候选相关样本从该次非目标轴排除，且排除 ID 必须存在于当前规则树 canonical inventory；两组皆空时非零退出。Verify: `bash tests/test_paired_eval.sh`。
- [x] `SP686-T3` 四次 producer 运行、pairwise judge、指标计算、合取判定与退出码语义。Covers: B-002, B-005, B-007, B-011, B-015. Owner: implementation agent. Done when: 目标轴复用 structured-JSON grader；非目标轴不复用 code-review JSON system prompt，而是用同一 producer 模型与规则文本生成普通任务响应，再对每个样本盲化 A/B 并换序调用 judge 两次；producer 空白响应按 skipped 处理，不得送入 judge；真实运行显式要求 `--judge-model`，严格解析 `winner ∈ {A,B,tie}`，judge 失败计入 skipped 且 malformed raw 仍保留，映射结论不一致时轴为 `inconclusive`；保存 producer/judge model ID、judge prompt digest、两次原始判定和映射结果；读取评测输入前固定 commit，规则树/core/数据集/阈值/模型基线/评估器本地实现在输入准备前后都必须由该提交跟踪且干净；首个模型调用前预留可写报告路径，commit 无法解析、输入 dirty/untracked/仓外或目标不可写时零客户端创建/零调用失败；不复用 `model_summary_metrics`（它把跳过样本剔出分母）；分母为请求样本数；跳过率与跳过率差超阈值判 `inconclusive`；Ctrl-C 停止新请求、保留已付费响应并将未完成项记为 skipped，写出带 interruption stage 的 partial report；目标轴用严格大于；单轴通过不得整体通过。真实运行的 `inconclusive` 与不通过均非零退出。Verify: `bash tests/test_paired_eval.sh`。
- [x] `SP686-T4` 离线 dry-run 路径。Covers: B-008. Owner: implementation agent. Done when: 无 API 密钥可运行，输出四次运行的输入身份、四条断言结果、交叉引用与空壳文件残留清单、样本划分；**dry-run 不产出判定，正常完成退出 0**，不受 B-010/B-011 约束。Verify: `bash tests/test_paired_eval.sh`。
- [x] `SP686-T5` 在 `eval/paired/` 下新增 `thresholds.json` 与未标定强制降级。Covers: B-006, B-010. Owner: implementation agent. Done when: 任一轴样本量不足或为空报 `inconclusive`；两个最小样本阈值必须是正整数，`max_cross_refs` 必须是非负整数，比例阈值必须是 0–1 的有限数；`calibrated: false` 时整体强制 `inconclusive`、永不输出 `pass`。Verify: `bash tests/test_paired_eval.sh`。
- [x] `SP686-T6` 规则 PR 模板加入配对评测证据要求与受限豁免。Covers: B-009, B-015. Owner: implementation agent. Done when: `templates/pull_request.md` 要求附结果；豁免仅限非 prompt 注入类改动且需维护者批准记录；写明 `calibrated: false` 阶段可接受的证据形态是 inconclusive 报告加两轴 delta、样本量、producer/judge model ID 与 judge prompt digest，而非 `pass`。Verify: 在 `bash tests/test_eval_contract.sh` 内新增模板断言段（仓库已有 `tests/test_issue_template_contract.sh` 这类模板契约测试可参照，勿另建新脚本）。

- [x] `SP686-T7` 断言独立性的**突变测试**（最高优先）。Covers: B-003, B-012. Owner: implementation agent. Done when: 存在一组故意破坏的剔除实现，参数化跑同一套断言，每种破坏被**指定的那一条**断言拒绝，且断言的是哪一条也被验证：no-op→定义位点；贪婪吃候选+后 1 节→**计数断言**；贪婪吃到 EOF→计数；整文件删除→逐文件差分+计数；只删 core 行→定义位点；只删小节→定义位点；删标题留正文→逐文件差分；删正文留标题→定义位点；tmp 树漏拷/多拷文件→文件集合相等；CRLF 或末尾换行变动→逐字节。其中"贪婪吃 1 节"必须**额外**验证：把 `extract_section` 换成与 `strip_candidate` 同源的实现后逐文件差分会漏，但计数断言仍拒绝。Verify: `python3 eval/test_paired_eval.py`。
- [x] `SP686-T8` 全规则遍历 smoke。Covers: B-003, B-012. Owner: implementation agent. Done when: 对全仓 127 条规则 ID（含三个 TASTE ID）各跑一次 dry-run（无模型调用，秒级），全部跑完；位于文件末节的 18 条规则（含 `rules/claude-rules/common/evidence-provenance.md` 的 W-21、`rules/claude-rules/common/no-silent-degradation.md` 的 U-29 与 `rules/claude-rules/rust/quality.md` 的 TASTE-PANIC-MSG）不越界；10 个单规则文件剔除后的空壳残留出现在报告中；按当前 `main` 实测被交叉引用的 30 条规则跑完并列出残留而非崩溃。Verify: `bash tests/test_paired_eval.sh`。
- [x] `SP686-T9` 计数正则的校准锚点与文件集合断言。Covers: B-003. Owner: implementation agent. Done when: 使用现有独立 canonical `scripts/lib/vibeguard_manifest.py:35` 的 `RULE_ID_HEADING_RE`；常数锚点测试断言它在 `rules/claude-rules/**` 上的匹配数等于当前定义总数（本会话实测 **127**）、含三个 TASTE ID且无重复 ID；`set(real_files) == set(tmp_files)` 是独立于内容比较的先行断言。Verify: `python3 eval/test_paired_eval.py`。理由：计数断言是"删多了"方向的唯一非同源兜底，正则漏匹配会让它静默失真而不是报错。
- [x] `SP686-T10` `max_cross_refs` 边界的可见性断言。Covers: B-012. Owner: implementation agent. Done when: 显式断言 U-32 按当前 `main` 有 13 处候选小节外引用，超过 `max_cross_refs: 4` 时判为 `inconclusive`；另以 4 处与 5 处 fixture 分别断言允许边界和超界行为。默认阈值不因规则树内容增长而放宽，且仍受 `calibrated: false` 总门约束，不得据此输出 pass。Verify: `python3 eval/test_paired_eval.py`。
- [x] `SP686-T11` 安慰剂对照与长度混杂的可见性。Covers: B-013, B-014. Owner: implementation agent. Done when: 报告输出 with/without 规则文本字符数与差值，与两轴 delta 并列；标定流程含不同于候选且按完整 `load_rules` prompt 删除差（含 core 行）计算后长度差比例不超过 `max_placebo_length_ratio` 的 placebo 运行；placebo 命中匿名 compact 等价语义或交叉引用残留超过 `max_cross_refs` 时在付费调用前拒绝。Verify: `bash tests/test_paired_eval.sh`。
- [x] `SP686-T12` 退出码两条路径各一测试，均在 `calibrated: false`（当前默认）下跑。Covers: B-008, B-011. Owner: implementation agent. Done when: dry-run 正常完成退出 0；真实运行 inconclusive 非零。理由：默认阈值下这两条直觉相反，最容易被实现成统一的 `sys.exit(1)`。Verify: `bash tests/test_paired_eval.sh`。

## 并行拆分

T1 / T4 与 T3 / T5 都写 `run_paired_eval.py`，因此**不拆并行写 lane**，由单 agent
串行完成（W-14）。可并行的只读 review lane：双来源剔除与差集断言审查、指标口径审查、
阈值标定方法审查。

## 验证

```bash
python3 checks/check_workflow.py --repo . --spec-dir=docs/specs/GH686
python3 checks/check_workflow.py --repo . --all-specs
bash tests/test_paired_eval.sh
python3 eval/test_paired_eval.py
bash tests/test_eval_contract.sh
bash tests/test_behavior_eval.sh
bash scripts/ci/validate-doc-paths.sh
```
