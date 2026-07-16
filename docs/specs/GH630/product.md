# Product Spec

## Linked Issue

GH-630

## 用户问题

手动 eval 的 `sonnet`/`opus` 便捷名仍解析到 Claude 4.6，而 Anthropic 当前官方
Claude API 模型表已经列出 Sonnet 5 与 Opus 4.8。维护者使用稳定便捷名时会在没有提示
的情况下评估旧基线，benchmark 结果难以表达“历史复现”还是“当前能力”。

## 目标

- 让便捷名映射到仓库明确声明并定期复核的当前 Claude API baseline。
- 保留完整 model ID 作为历史复现/实验覆盖。
- 用离线 metadata 与 freshness gate 阻止 baseline 长期无说明地过期。

## 非目标

- 不改变默认 `haiku` 的低成本选择。
- 不在 CI 中调用 Anthropic API 或联网发现模型。
- 不承诺 Bedrock、Vertex 或其他 provider 与第一方 Claude API 同步可用。
- 不修改 eval scoring、dataset 或 artifact schema 的统计语义。

## Behavior Invariants

1. B-001 `sonnet` 与 `opus` 必须解析到 baseline manifest 声明的当前第一方 Claude API
   model ID；本规格基线分别为 `claude-sonnet-5` 与 `claude-opus-4-8`。
2. B-002 `haiku` 继续是默认 alias 与默认 CLI 选择；升级高阶 alias 不得把无参数 eval
   成本切换到 Sonnet/Opus。
3. B-003 用户传入不属于便捷名闭集的完整 model ID 时必须原样传给 API，并在 run artifact
   中记录 resolved ID，支持历史复现。
4. B-004 baseline 必须记录官方来源、verified date 与 freshness window；证据缺失、日期非法
   或超过窗口时，离线 contract check 必须失败并要求人工复核。
5. B-005 freshness check 不得联网或自动选择“最新”模型；人工更新 baseline 后必须经过
   code review，避免不可复现的 evergreen 解析。
6. B-006 `run_eval.py`、`run_behavior_eval.py` model gate 与 `scripts/benchmark.sh` 必须共享
   同一 alias mapping/default contract，不能各自硬编码不同代次。
7. B-007 dry-run/help 必须显示 alias、resolved ID 与 baseline evidence，使未发 API 请求的
   预检也能发现运行目标。

## 验收标准

- [ ] `sonnet`/`opus` 解析到官方当前 ID，默认仍为 `haiku`。
- [ ] 完整历史 ID 原样透传并记录。
- [ ] stale/missing baseline evidence 离线失败，无网络调用。
- [ ] 三个 eval/benchmark entrypoints 的 alias/default 契约一致。
- [ ] dry-run 与现有 artifact schema tests 通过。

## 边界情况清单

| 类别 | 判定（covered: B-xxx / N/A + 原因） |
| --- | --- |
| 空/缺失输入 | covered: B-002, B-004 |
| 错误与失败路径 | covered: B-004, B-007 |
| 授权/权限 | N/A：API key/调用授权不在模型映射范围 |
| 并发/竞态 | N/A：baseline 是 commit-pinned 文件 |
| 重试/幂等 | covered: B-003, B-005 |
| 非法状态转换 | covered: B-004（stale baseline） |
| 兼容/迁移 | covered: B-002, B-003 |
| 降级/回退 | covered: B-004；stale baseline 不得静默继续 |
| 证据与审计完整性 | covered: B-004, B-005, B-007 |
| 取消/中断 | N/A：离线解析可重跑；API run 行为不变 |

## 发布说明

便捷名升级会改变显式 `--model sonnet|opus` 的评估目标；需要固定历史结果时应传完整 ID。
默认无参数/`haiku` 路径保持低成本。
