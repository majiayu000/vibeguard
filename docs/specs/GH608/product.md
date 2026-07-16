# Product Spec

## Linked Issue

GH-608

## 用户问题

直接运行仓库自带的 `scripts/verify/compliance_check.sh` 时，默认的 VibeGuard 安装根目录
被解析为仓库的 `scripts/` 子目录。Layer 1 与 Layer 2 随后在不存在的
`scripts/guards/` 下寻找随仓库提供的 duplicate 与 naming guards，并把实际可用的能力
报告为 `not found`。这会制造错误的合规告警，使用户无法区分真实缺失与检查器自身的
路径错误。

## 目标

- 默认调用始终从检查器自身位置解析仓库根目录，并找到随仓库提供的 guards。
- 从任意当前工作目录调用时行为一致。
- 显式提供的 `VIBEGUARD_DIR` 继续优先于自动解析结果。
- 用聚焦回归测试固定具名 guard 的来源路径，不依赖开发者本机配置。

## 非目标

- 除纠正 bundled guard discovery 结果外，不改变 Layer 1 至 Layer 7 的判断规则、
  PASS/WARN/FAIL 文案、计数算法或退出码语义；汇总数值随正确分类自然变化。
- 不调整 `find_guard` / `find_quality_guard` 的搜索顺序或支持矩阵。
- 不修改 `scripts/metrics/metrics_collector.sh` 或其他脚本的根目录解析。
- 不安装、复制或生成 guard 文件，也不修改用户的 Claude/VibeGuard 配置。

## Behavior Invariants

1. B-001 未设置 `VIBEGUARD_DIR` 时，检查器必须相对于自身脚本位置解析 VibeGuard
   仓库根目录；不得把 `scripts/` 当作仓库根目录。
2. B-002 默认调用的 Layer 1 必须把仓库内实际存在的
   `guards/python/check_duplicates.py` 报告为 available，而不是错误的 not-found WARN。
3. B-003 默认调用的 Layer 2 必须把仓库内实际存在的
   `guards/python/check_naming_convention.py` 报告为 available，而不是错误的 not-found
   WARN。
4. B-004 B-001 至 B-003 不得依赖调用者当前工作目录；从仓库外目录用绝对脚本路径
   调用必须得到相同的 guard discovery 结果。
5. B-005 调用者显式设置 `VIBEGUARD_DIR` 时，该值必须保持最高优先级，包括路径含空格
   的有效目录；自动解析不得覆盖它。
6. B-006 本变更只修正检查器传给共享 guard discovery 的默认根目录。项目本地 fallback、
   其余 Layer、summary 计数算法以及现有退出码 contract 必须保持兼容；Layer 1/2 被正确
   分类后，PASS/WARN 汇总数值必须如实反映新结果。
7. B-007 验证必须断言具名 guard 的 available/not-found 状态与实际来源路径；不得只断言
   总 PASS/WARN 数量，也不得读取真实用户的 HOME 配置来制造通过结果。

## 验收标准

- [ ] 在隔离 HOME 与项目 fixture 下，未设置 `VIBEGUARD_DIR` 的检查器找到两项 bundled
      Python guards。
- [ ] 从仓库外任意工作目录调用绝对脚本路径时，两项 guard discovery 结果不变。
- [ ] 显式 `VIBEGUARD_DIR` 指向独立 fixture 时，输出证明该目录优先于自动仓库根目录。
- [ ] 聚焦测试对 duplicate 与 naming guard 分别做具名断言，并进入 unit test runner。
- [ ] shell syntax、focused unit、文档路径和 broad local contract 验证通过。

## 边界情况清单

| 类别 | 判定（covered: B-xxx / N/A + 原因） |
| --- | --- |
| 空/缺失输入 | covered: B-001, B-006（未传 project 参数与未设置环境变量沿用现有默认行为） |
| 错误与失败路径 | covered: B-002, B-003, B-006（真实缺失仍按共享 discovery 与现有 WARN 语义报告） |
| 授权/权限 | N/A：检查器只读取本地路径，本变更不改变权限模型 |
| 并发/竞态 | N/A：单进程只读检查，无共享可变状态 |
| 重试/幂等 | covered: B-004, B-006（相同输入重跑结果一致） |
| 非法状态转换 | N/A：不持久化 workflow 状态 |
| 兼容/迁移 | covered: B-005, B-006 |
| 降级/回退 | covered: B-006（项目本地 fallback 搜索保持原样） |
| 证据与审计完整性 | covered: B-007 |
| 取消/中断 | N/A：无写入，中断后可安全重跑 |

## 发布说明

这是 compliance checker 的路径正确性修复。仓库内置的 duplicate 与 naming guards 将在
默认调用中被准确发现；显式配置、其余检查层和退出码不变。
