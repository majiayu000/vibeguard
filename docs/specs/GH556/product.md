# Product Spec

## Linked Issue

GH-556

## User Problem

W-13 误报风暴（GH-554）说明：VibeGuard 已经有事件日志、triage、scorecard 和 session metrics，但维护者没有一张定期送到眼前的系统健康表。错误警告可以持续数周而无人注意，规则精度、未分类积压和闲置资产也缺少统一入口。

## Goals

- 每周输出一页系统健康报告，覆盖规则触发量、warn/block/pass 分布、精度风险和闲置资产。
- 复用已有数据源：`scripts/stats.sh`、`scripts/hook-health.sh`、`scripts/precision-tracker.py`、运行时 triage/scorecard 文件、`data/rule-scorecard.seed.json`、`vibeguard-runtime` observe/session metrics 和 Learn adoption 记录。
- 明确列出降级候选：连续 30 天零触发的规则，以及零使用或无 adoption 证据的 skill/资产。
- 将 W-13 类 false-positive blind spot 纳入报告，避免 rule id 缺失导致 precision pipeline 看不见真实风险。
- 在手动验证稳定后，才允许新增周度 launchd/cron 调度。

## Non-Goals

- 不新建数据库、服务端或前端。
- 不重写 precision tracker、observe summary 或 Learn adoption 的核心模型。
- 不在本规格内关闭 GH-541；健康报告只提供降级候选证据。
- 不绕过 GH-554/GH-555 的依赖：W-13 reset 和 rule-id triage 修复先行，否则报告不能宣称覆盖 W-13。

## Behavior Invariants

1. 无数据时报告必须清楚显示空状态，不能编造健康分数或 silently pass。
2. 任何源文件解析失败、schema 错误或命令失败必须让报告失败，不能 warning 后继续输出误导性摘要。
3. 报告必须区分 `pass`、`warn`、`block`、`gate`、`escalate`、`correction` 等 decision，不得只汇总为“风险数”。
4. 每条 precision 风险必须保留 rule id；缺 rule id 的 triage 候选必须进入 “unclassified backlog / schema gap” 区块。
5. 零触发规则和零使用 skill 只是降级候选，不能自动删除、禁用或移动规则。
6. 周度调度必须是 opt-in，并在手动命令稳定验证后才能启用。

## Report Sections

- Overview：时间窗口、数据源、总触发数、pass/risk 比例和数据完整性状态。
- Rule Trigger Distribution：按 rule/hook 汇总触发次数和 decision 分布。
- Precision Risk：FP 率、precision、样本数、最近 FP、unclassified backlog。
- Idle Assets：30 天零触发规则、零使用 skill、无 adoption 记录的 Learn 候选。
- Downgrade Candidates：可移入按需文档或低频包的候选，附证据和保守建议。
- Follow-up Actions：需要人工 triage、spec、实现或调度验证的下一步。

## Acceptance Criteria

- [ ] 新增或扩展一个手动命令，可以生成 7 天或 30 天健康报告，并支持 markdown 与 JSON 输出。
- [ ] 报告复用已有 observe summary/health、precision tracker、triage/scorecard 和 Learn adoption 数据；没有新增持久层。
- [ ] 报告包含每条规则的触发次数、decision 分布、precision/FP 风险和 unclassified 数量。
- [ ] 报告包含 30 天零触发规则和零使用 skill 的降级候选区块。
- [ ] 源数据缺失时输出明确空状态；源数据损坏或解析失败时命令失败。
- [ ] 周度调度文档或脚本只在手动验证通过后启用，默认不自动安装。

## Edge Cases

- 本地没有 `~/.vibeguard/events.jsonl` 或项目 scoped log：报告显示 no data，不回退到不相关项目。
- `data/triage.jsonl` 存在 malformed line：precision 区块失败并返回非零，避免错误 precision。
- W-13 事件没有 rule id：进入 schema gap/unclassified backlog，不计入 W-13 精度。
- 新 skill 尚未被触发：列为 zero-use 候选，但不自动判定为无价值。
- 只存在 global log 或只存在 project log：报告必须明确当前 scope。

## Rollout Notes

先以手动命令和文件输出落地，验证报告字段与真实 incident 一致后，再把周度调度作为 opt-in 配置接入。报告中的降级候选应服务 GH-541 的 U-32 约束预算治理，但不能替代人工规则评审。
