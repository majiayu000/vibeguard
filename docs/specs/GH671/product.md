# Product Spec — U-16 baseline-aware enforcement

## Linked Issue

GH-671

complexity: medium

## 用户问题

U-16 目前只看变更后的源码行数是否超过硬上限，导致维护遗留超大文件时，即使
编辑保持同样行数或减少行数也会被阻断。同时，pre-commit 和 CI 没有用 Git
基线检查新导入的超大源码文件，绕过了 AI 写入 hook 的边界。

## 目标

- 对 U-16 使用 before/after 基线判定，而不是只看新行数。
- 允许遗留超大源码文件做同尺寸修复或递减拆分，并给出可审计的债务告警。
- 阻断新超大源码、从限制内跨到限制外的源码、以及遗留超大源码继续增长。
- 让 pre-edit、pre-write、git pre-commit 和 CI 共用同一套阻断判定。
- 保持显式 U-16 exemption 在所有 enforcement 路径上一致。

## 非目标

- 不在本 issue 中拆分现有遗留大文件。
- 不新增隐式 generated/vendor 路径猜测。
- 不改变 U-16 默认 `warn_limit=400` 与 `limit=800` 配置语义。
- 不改变 test path 豁免规则。

## Behavior Invariants

1. B-001: 新的非测试源码文件超过已解析 U-16 hard limit 时必须阻断。
2. B-002: 已存在且原本不超过 hard limit 的源码，变更后超过 hard limit 时必须阻断。
3. B-003: 已存在且原本超过 hard limit 的源码，变更后行数增加时必须阻断。
4. B-004: 已存在且原本超过 hard limit 的源码，变更后行数不增加但仍超过 hard limit 时必须允许，并发出 `U16_LEGACY_DEBT` 告警。
5. B-005: 已存在且原本超过 hard limit 的源码，变更后降到 hard limit 以内时必须允许，且不发出 `U16_LEGACY_DEBT`。
6. B-006: 未参与本次 diff 的遗留超大源码不得阻断无关提交。
7. B-007: rename 保留旧路径基线；无增长时允许，有增长时阻断。
8. B-008: 只有显式配置的 U-16 exemption 可以提高 hard limit，且所有路径共用同一解析结果。

## 验收标准

- [ ] pre-edit 和 pre-write 覆盖 legacy shrinking/same-size/growth。
- [ ] git pre-commit 覆盖新超大文件、跨线、遗留增长、遗留递减、未变遗留文件、初始提交、rename 和显式 exemption。
- [ ] CI changed-file check 调用同一 runtime 判定并在 PR/push 中运行。
- [ ] Rust unit tests 覆盖核心判定矩阵。

## 边界情况清单

| 类别 | 判定（covered: B-xxx / N/A + 原因） |
| --- | --- |
| 空/缺失输入 | covered: B-006；无 changed source 输出 OK |
| 错误与失败路径 | covered: B-001-B-003；缺失 Git blob 或 merge-base fail visible |
| 授权/权限 | N/A — 本地 hook/CI 只读 Git 内容 |
| 并发/竞态 | covered: B-006；判定只读 staged index 或指定 head |
| 重试/幂等 | covered: B-001-B-008；同一 diff 输出稳定 |
| 非法状态转换 | N/A — 不修改 workflow 状态机 |
| 兼容/迁移 | covered: B-004-B-005；遗留文件可增量修复 |
| 降级/回退 | covered: B-008；无隐式 generated/vendor fallback |
| 证据与审计完整性 | covered: B-004；legacy debt 有明确机器信号 |
| 取消/中断 | N/A — 无持久化写入 |

## 发布说明

已安装的 hook 需要用户重新运行 `setup.sh` 后才会获得 pre-commit enforcement
更新；CI 在仓库 workflow 更新后立即生效。
