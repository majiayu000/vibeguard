# Product Spec — malformed-input 诊断隐私与 block 计数契约

## Linked Issue

GH-706

complexity: medium

## 用户问题

一段 9 天事件窗口中，671 个 block 有 434 个来自 malformed hook input，但旧事件
缺少可区分 empty stdin、invalid JSON 与 required field 缺失的诊断。PR #707
补充了诊断与 human summary 拆分，却把 invalid JSON 的 payload head 持久化到
project/global logs，且 structured JSON、health report 与 human 输出仍不一致。
同一实现还把已成功解析、仅 U-16 baseline 文件不可读的事件误算成 protocol
error，导致隐私边界和统计口径都不可信。

## 目标

- 保持 pre-Bash / pre-Write malformed input 的 fail-closed 行为不变，同时用安全、
  可测试的结构诊断区分输入失败形状。
- 把全部 block 稳定拆为 `protocol_errors` 与 `rule_interceptions`，并让 human、
  observe JSON 与 health report 使用同一口径。
- 保持现有 `decision_counts` 兼容，并显式处理旧 runtime 与空窗口。

## 非目标

- 不改变非目标 `tool_name` payload 的放行策略；是否允许非目标工具通过留待真实
  payload shape 被安全捕获后的独立决策。
- 不降低 malformed input、baseline unreadable 或其他无法验证请求的拦截强度。
- 不迁移或重写已有 event logs，也不新增 health-report schema 文件或持久层。
- 不把普通 rule reason、command、file content 或 payload 文本纳入诊断。

## Behavior Invariants

1. B-001 pre-Bash / pre-Write 收到无法验证的 malformed input 时仍须 fail closed；
   本变更不得把 empty stdin、invalid JSON、required field 缺失/空/类型错误改成
   pass、warn 或 silent skip。
2. B-002 protocol diagnostic 的 `category` 只能是闭集
   `empty_stdin`、`invalid_json`、`missing_required_field`；空白 stdin 归入
   `empty_stdin`，JSON 解析失败归入 `invalid_json`，JSON 合法但
   `tool_input.command` / `tool_input.file_path` 缺失、为空或非字符串归入
   `missing_required_field`。
3. B-003 持久化 diagnostic 只能包含固定键及闭集枚举/布尔/非负数值等结构元数据，
   例如 category、required-field class、input size、已归一化的 tool/event
   class；project/global event logs 均不得包含或派生保存 raw stdin、payload
   head、command、content、任意 free-text 值、secret/token，未知名称必须归一化为
   `other` 或 `absent_or_invalid`，不得原样回显。
4. B-004 合法 Write JSON 在读取既有文件的 U-16 baseline 时失败，仍须 fail
   closed，但必须使用独立的 baseline-unreadable reason/category；它不是
   `protocol_errors`，且 diagnostic 不得原样持久化 file path 或读取错误文本。
5. B-005 对任意非空统计窗口，`total_blocks = protocol_errors +
   rule_interceptions`，三者均为非负整数；`total_blocks` 同时等于
   `decision_counts.block`（字段缺失时按 0）。
6. B-006 human `observe summary` 必须保留现有总 block 行并 additive 展示
   `protocol_errors` 与 `rule_interceptions`；`observe summary --json` 与
   `observe health --json` 必须 additive 返回同值的 optional `block_counts`
   对象，human 与 JSON 不得各自重算出不同结果。
7. B-007 现有 `decision_counts` 的字段名、计数语义与 presence 保持兼容；
   protocol split 不得从 `decision_counts.block` 扣除事件，也不得把 protocol
   error 改写成新的 decision。
8. B-008 health report 在收到 `block_counts` 时，markdown 与 JSON overview
   必须展示与 observe summary 相同的 `total_blocks`、`protocol_errors`、
   `rule_interceptions`，并明确标记该 split 为 available。
9. B-009 非空窗口使用缺少 `block_counts` 的旧 runtime 时，health report 必须在
   markdown 与 JSON 中显式标记 block split 为 `unavailable`；不得把全部 block
   猜成 rule interception、从 reason 文本自行重算或把 unavailable 伪装成 0。
10. B-010 event log 缺失或筛选窗口内无事件时，health report 必须保持显式
    `no_data`，不产出风险结论；新 runtime 的空窗口 observe JSON 可返回三个 0
    的 `block_counts`，但 health report 的 no-data 判定优先于 available/
    unavailable。
11. B-011 读取存量 event logs 时，既有 malformed Bash/Write reasons 仍须归入
    protocol error；PR #707 已写入、detail 表示 U-16 baseline unreadable 的
    legacy Write 事件必须从 protocol error 排除。兼容读取不得修改旧日志。
12. B-012 observe 与 health report 都是只读聚合；对同一日志与窗口重复执行必须
    返回相同计数且不追加事件，执行中断后重试不得制造重复 block。

## 验收标准

- [ ] adversarial malformed payload 在 project/global logs 中均只留下闭集结构
  元数据，secret、command、content、payload head 与未知 free text 均不可见。
- [ ] empty stdin、invalid JSON、missing/empty/non-string required field 的 Bash
  与 Write 路径都保持 block，并得到正确 category。
- [ ] baseline unreadable 有独立 reason/category、保持 block，且不计入
  `protocol_errors`。
- [ ] human summary、observe summary/health JSON、health-report markdown/JSON
  在混合 fixture 上满足同一计数关系并保持 `decision_counts`。
- [ ] 旧 runtime 非空输出显示 `unavailable`；缺失日志与空窗口显示 `no_data`。

## 边界情况清单

| 类别 | 判定（covered: B-xxx / N/A + 原因） |
| --- | --- |
| 空/缺失输入 | covered: B-001, B-002, B-010 |
| 错误与失败路径 | covered: B-001, B-004, B-009, B-010 |
| 授权/权限 | N/A：本地 hook 诊断与只读报告不引入授权决策；权限导致 baseline unreadable 由 B-004 覆盖 |
| 并发/竞态 | N/A：聚合读取一个已选定日志窗口，不引入共享可写状态 |
| 重试/幂等 | covered: B-012 |
| 非法状态转换 | N/A：本变更不定义 workflow 状态机或状态转换 |
| 兼容/迁移 | covered: B-007, B-009, B-011 |
| 降级/回退 | covered: B-009, B-010 |
| 证据与审计完整性 | covered: B-003, B-005, B-006, B-008, B-011 |
| 取消/中断 | covered: B-012 |

## 发布说明

`block_counts` 是 observe schema 的 additive optional 字段；`decision_counts`
继续作为兼容接口。health report 在新 runtime 上展示 block split，在旧 runtime
上显式展示 `unavailable`。无需迁移旧日志；任何回滚都必须保留“不持久化 raw
payload”的隐私边界和原有 fail-closed posture。
