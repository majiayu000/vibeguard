# Product Spec

## Linked Issue

GH-

## 用户问题

描述用户可见的问题，以及为什么重要。

## 目标

-

## 非目标

-

## Behavior Invariants

用编号列表写可观察、可测试、无实现细节的行为契约。使用稳定 ID
（`B-001`、`B-002`…）；修订只追加，不重排、不复用。不变式优先使用 EARS
条件式触发写法（当/如果/若/WHEN/IF/WHILE），让每条契约写明触发条件。
长度启发式、密度规则与 worked example 见 `specrail-write-product-spec`
skill。trivial 变更在 Linked Issue 下声明 `complexity: trivial` 并保持最小
spec。

1. B-001

## 验收标准

- [ ]
- [ ]

## 边界情况清单

每一类要么由具名 invariant 覆盖，要么写明 N/A + 原因。特别注意组合边界
（如：已授权 + 前提证据缺失）。

| 类别 | 判定（covered: B-xxx / N/A + 原因） |
| --- | --- |
| 空/缺失输入 |  |
| 错误与失败路径 |  |
| 授权/权限 |  |
| 并发/竞态 |  |
| 重试/幂等 |  |
| 非法状态转换 |  |
| 兼容/迁移 |  |
| 降级/回退 |  |
| 证据与审计完整性 |  |
| 取消/中断 |  |

## 发布说明

描述迁移、兼容性或沟通要求。
