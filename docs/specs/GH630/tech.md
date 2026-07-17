# Tech Spec

## Linked Issue

GH-630

## Product Spec

See `product.md`.

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Alias mapping | `eval/run_eval.py:32` | hardcode haiku 4.5、sonnet 4.6、opus 4.6 | 需要单一 baseline source |
| Resolution | `eval/run_eval.py:245` | alias 命中 map，否则完整 ID passthrough | 保留历史复现行为 |
| CLI default | `eval/run_eval.py:556` | 默认 `haiku` | 成本边界不得改变 |
| Behavior gate | `eval/run_behavior_eval.py:532` | 另设默认 `haiku` 并调用 run_eval | 需要共享 contract |
| Benchmark wrapper | `scripts/benchmark.sh:25` | 接受 alias 并转给 run_eval | help/解析必须同步 |
| Eval contract tests | `tests/test_eval_contract.sh:71` | dry-run 验证 snapshot/digest，不验证 resolved model | freshness/可见性缺口 |

## 设计方案

新增一个小型、版本化的 eval model-baseline manifest（放在 `eval/` 现有 contract surface），
包含 alias map、default alias、official source URL、`verified_at` 与 review window。`run_eval.py`
读取并严格验证该 manifest；behavior gate 与 benchmark 不再维护第二份映射，只把用户值传入
同一 resolver/default。

当前第一方官方证据为 Anthropic Models overview：
<https://platform.claude.com/docs/en/about-claude/models/overview>，列出
`claude-sonnet-5`、`claude-opus-4-8` 与 Haiku 4.5 API ID
`claude-haiku-4-5-20251001`。manifest 必须记录核实日期 `2026-07-17`，alias map 固定为
`haiku` -> `claude-haiku-4-5-20251001`、`sonnet` -> `claude-sonnet-5`、
`opus` -> `claude-opus-4-8`。Haiku 选择 dated ID 而不是官方短 alias
`claude-haiku-4-5`，保证默认低成本路径也能固定复现；4.6 及之后的 dateless API ID 本身是
Anthropic 定义的 pinned snapshot，不是 evergreen alias。

离线 validator 检查 schema、alias 闭集、default membership、URL、日期格式和 age window。
review window 固定为 90 个 UTC calendar day。生产 check 使用 UTC 当前日期计算
`age_days = current_utc_date - verified_at`：0..90（闭区间）有效，负数（future date）无效，
91 及以上 stale。纯 validator 必须允许测试显式注入 as-of UTC date，覆盖 future、day 0、
day 89、day 90 与 day 91，避免 CI runner 本地时区改变判定。validator 只要求人工重新核实
并更新 commit，不抓取网页、不调用 Models API。

dry-run 输出 requested input、resolved ID、verified date/source；help 输出 default alias、完整
alias -> resolved ID 表与 verified date/source。真实 run artifact 继续只用既有
`metadata.model` 记录 resolved ID。本 issue 禁止新增或重命名 artifact 字段、提升 schema
version 或修改 reader；requested input 与 baseline evidence 仅进入 dry-run/help 文本输出。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 | baseline manifest + resolver | `sonnet`/`opus` resolution unit assertions |
| B-002 | manifest default + CLI parser | no-arg/dry-run resolves dated Haiku ID；help snapshot |
| B-003 | passthrough resolver + artifacts | arbitrary full ID remains unchanged and is recorded |
| B-004 | offline freshness validator | missing/invalid/future/day-91 fixtures nonzero；day-90 valid |
| B-005 | validator network boundary | tests run with network unavailable；无 remote call code path |
| B-006 | shared entrypoints | behavior/benchmark integration assertions use same resolver/default |
| B-007 | dry-run/help renderer | dry-run request/resolution/evidence；help default/table/evidence |

## 数据流

CLI requested model -> local manifest resolver -> resolved first-party ID -> dry-run display 或
Anthropic client call -> existing run artifact。freshness validator 只读 manifest 与当前日期，
不触发网络。

## 风险

- Security: 不新增 secret 处理；官方 URL 是 evidence，不被执行。
- Compatibility: alias 语义升级，完整 ID passthrough 保留复现路径；artifact schema 不变。
- Performance: 读取一个小 JSON/YAML 文件，非 hook hot path。
- Maintenance: time-based gate 会主动要求复核，窗口需避免无意义频繁红灯。

## 测试计划

- [ ] Unit: manifest validation、精确 alias/default/passthrough、UTC future/day-0/89/90/91 dates。
- [ ] Integration: `bash tests/test_eval_contract.sh`。
- [ ] Python: `python3 -m unittest discover -s eval -p 'test_*.py'`。
- [ ] Manual: `python3 eval/run_eval.py --dry-run --model sonnet` 与 `--model opus`，不发 API 请求。

## 回滚方案

可回滚 manifest/resolver 与 alias ID，artifact schema 无需迁移。若新模型暂不可用，应要求
用户显式 full ID 或经 review 调整 baseline；不得把 API failure 静默降级到旧模型。
