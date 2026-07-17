# Product Spec

## Linked Issue

GH-628

## 用户问题

当前个人路径检查整体跳过 Markdown，导致被跟踪 plan 中的真实 `/Users/<name>/...`
路径在 CI 中不可见；文档路径 allowlist 又不验证条目是否仍被使用或是否只是在掩盖已删除
路径。维护者因此会看到“路径检查通过”，但仓库仍携带机器特定路径和僵尸豁免。

## 目标

- 检查所有适用的 Git 跟踪文本，包括 Markdown。
- 区分真实个人路径、明确占位符与必要的历史/测试示例。
- 让 doc path allowlist 自身具备 freshness 和最小化门禁。

## 非目标

- 不删除 `plan/` completed records 或改写其历史结论。
- 不扫描 `.git`、build output、用户未跟踪草稿或本地 artifact。
- 不禁止 `/path/to/...`、`/Users/<username>/...` 等明确占位符。

## Behavior Invariants

1. B-001 personal-path validator 必须覆盖适用的 Git 跟踪 Markdown 与代码文件；文件类型
   不能成为 blanket exemption。
2. B-002 `/Users/<literal-user>/...` 与 `/home/<literal-user>/...` 必须失败；明确占位符、
   正则模式说明和 validator 自身测试 fixture 只有在可判定分类时才允许。
3. B-003 历史 plan 与其他 tracked Markdown 中不可判定为明确占位符的机器路径必须替换为
   相对路径/明确占位符，或进入带路径、原因与范围的窄豁免；不得用“所有 Markdown”继续
   豁免。
4. B-004 doc-path allowlist 的每个 active entry 必须至少匹配一个当前允许场景；未使用、
   重复或仅指向已删除旧路径的条目必须使 CI 失败。
5. B-005 allowlist 不能同时允许迁移前和迁移后路径来掩盖错误引用；真实文档引用不存在
   时仍必须失败。
6. B-006 验证结果必须列出文件、行号与失败类别并返回非零；扫描/解析错误不得被当作
   “没有问题”。
7. B-007 相同 tracked tree 的结果必须确定性一致，且 untracked `artifacts/` 不影响 CI。

## 验收标准

- [ ] Markdown 中真实个人路径 negative fixture 被阻断，合法 placeholder fixture 通过。
- [ ] 当前 tracked Markdown 的个人路径不再依赖 blanket skip；历史 plan 与文档/示例中的
      literal user 均已机械改为相对路径或明确 placeholder。
- [ ] unused/stale/duplicate allowlist fixtures 被阻断。
- [ ] 当前 doc path 与 command path validators 继续通过有效引用。

## 边界情况清单

| 类别 | 判定（covered: B-xxx / N/A + 原因） |
| --- | --- |
| 空/缺失输入 | covered: B-004；空 allowlist 合法，空 entry 非法 |
| 错误与失败路径 | covered: B-006 |
| 授权/权限 | N/A：只读 tracked-tree 检查 |
| 并发/竞态 | N/A：基于单一 Git snapshot |
| 重试/幂等 | covered: B-007 |
| 非法状态转换 | N/A：无状态机 |
| 兼容/迁移 | covered: B-003, B-005 |
| 降级/回退 | covered: B-006；扫描失败不能假成功 |
| 证据与审计完整性 | covered: B-001, B-004, B-005 |
| 取消/中断 | N/A：重新运行离线检查即可 |

## 发布说明

这是 CI 证据完整性修复，可能要求一次性清理历史 plan 的机器路径和 doc allowlist。
不改变产品运行时或安装路径。
