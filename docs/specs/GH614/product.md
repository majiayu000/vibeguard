# Product Spec

## Linked Issue

GH-614: https://github.com/majiayu000/vibeguard/issues/614

## 用户问题

GH614 的首次修复把必需 `validate-and-test` 作业上限从 30 分钟提高到 45 分钟，
但新的真实运行证明这仍不足。PR #727 head
`3947abd7583ac90a93516ee8476d807c3856dfca` 的 run `30651857110`、
macOS job `91226778977` 从 19:44:43Z 运行至 20:30:02Z，耗时 45 分 19 秒后
被取消。前 63 个步骤全部通过，其中 `Setup regression tests` 完整通过且耗时约
34 分钟；第 64 步 `Guard unit tests` 被取消，后续 precision、performance 与
benchmark 步骤未运行。这是同一类总作业上限回归，因此 Issue 重开而非另建问题。

## 目标

- 为健康的 macOS 全量回归保留明确且有界的执行余量。
- 保持 `bash tests/test_setup.sh` 完整、阻塞、失败可见。
- 保持现有三个受分支保护的 `CI (*-latest)` check 名称与覆盖面。
- 用仓库内 contract test 防止超时余量或 setup 阻塞语义回退。

## 非目标

- 不修改 setup 产品行为、fixture、断言或覆盖范围。
- 不把 setup 测试改成 advisory、`continue-on-error` 或条件跳过。
- 不在本次工作中拆分 required check、重排 CI 测试或优化 setup 内部性能。
- 不修改 Windows、Self-Application、release 或 hook latency 的超时与预算。

## Behavior Invariants

1. B-001 — 在已观测的健康 macOS 时长波动范围内，必需 CI 不得再因旧的
   45 分钟总作业上限取消；新上限仍必须是有限值。
2. B-002 — `bash tests/test_setup.sh` 必须继续在 macOS 必需 CI 中完整执行，
   且非零退出必须使该 check 失败。
3. B-003 — `CI (ubuntu-latest)`、`CI (macos-latest)` 与
   `CI (windows-latest)` 的稳定名称及其分支保护兼容性不得改变。
4. B-004 — setup 之后的既有 macOS 回归与 benchmark 命令必须继续保持阻塞；
   不得用跳过或 advisory 状态换取绿灯。
5. B-005 — 任何真实测试失败或异常挂起仍必须在有限上限内失败可见，不能
   静默吞掉或无限等待。
6. B-006 — Windows、Self-Application、release 与 GH611 hook latency
   confirmation 的超时、样本数和预算不因本改动变化。
7. B-007 — workflow contract 必须在总作业上限回退、macOS matrix 覆盖被删除、
   setup 命令被删除或被标为 `continue-on-error` 时确定性失败。

## 验收标准

- [ ] `validate-and-test` 使用 60 分钟的有限上限，为已记录的 45 分 19 秒取消点
      提供 14 分 41 秒余量。
- [ ] `bash tests/test_setup.sh` 仍是 `validate-and-test` 中的精确阻塞命令。
- [ ] Ubuntu/macOS matrix、Windows job、Self-Application job 与
      `Benchmark Report` 依赖关系保持不变。
- [ ] 新 workflow contract 在实现前因 45 分钟旧值失败，在实现后通过。
- [ ] 实现 head 的本地 focused/broad gate 与完整 GitHub CI 全绿。

## 边界情况清单

| 类别 | 判定（covered: B-xxx / N/A + 原因） |
| --- | --- |
| 空/缺失输入 | N/A：workflow 使用固定仓库配置，不接受用户输入 |
| 错误与失败路径 | covered: B-002, B-004, B-005 |
| 授权/权限 | covered: B-003；不得绕过分支保护 check |
| 并发/竞态 | covered: B-001；runner 时长波动不能伪造回归 |
| 重试/幂等 | covered: B-001；同一 SHA 首跑与重跑应受同一有限契约约束 |
| 非法状态转换 | covered: B-002, B-007 |
| 兼容/迁移 | covered: B-003, B-006 |
| 降级/回退 | covered: B-004, B-005, B-007 |
| 证据与审计完整性 | covered: B-007 |
| 取消/中断 | covered: B-001, B-005 |

## 发布说明

这是 CI 可靠性修复，不改变用户安装、hook 行为或发布产物。实现 PR 需在说明中
记录旧上限、实测取消点、新余量、最大异常 runner 成本以及回滚方式。
