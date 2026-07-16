# Product Spec

## Linked Issue

GH-629

## 用户问题

用户 runtime config `~/.vibeguard/config.json` 只有示例文件，没有 machine-readable
schema。当前 runtime policy 只验证 UTF-8/JSON 语法，字段类型、枚举、范围和未知 key
会在 getter 中被忽略并回退默认值；例如 `write_mode: invalid` 会静默变成 `warn`。

## 目标

- 为用户 runtime config 建立独立、版本化、严格的 schema contract。
- 存在但无效的配置 fail visibly；缺失配置继续使用默认值。
- template、Rust runtime 与 shell consumers 使用同一字段集合。

## 非目标

- 不合并 `.vibeguard.json` 与用户 runtime config。
- 不改变环境变量高于 JSON config 的优先级。
- 不新增 Python/Node 或第三方运行时依赖。
- 不把“配置文件不存在”变成错误。

## Behavior Invariants

1. B-001 repository 必须发布独立 runtime-config schema，覆盖当前 template 的 version、
   `u16`、`circuit_breaker`、`w14`、`paralysis` 与 `write_mode` 字段及其嵌套结构。
2. B-002 配置文件不存在时继续使用现有默认值；存在的空对象可按向后兼容规则使用默认值，
   但显式字段必须通过类型、枚举和范围验证。
3. B-003 malformed JSON/UTF-8、错误类型、未知字段、非法 enum、负数/越界值和违反跨字段
   约束的配置必须返回可见错误与非零状态，不得回退为默认值后成功。
4. B-004 `write_mode` 只接受声明闭集；现有 `invalid -> warn` 行为必须改为配置错误。
5. B-005 template、schema 与 production getters 的字段路径必须由同步门禁证明一致；新增
   config key 不能只接入其中一层。
6. B-006 runtime policy、直接 runtime-config getter 与 setup `--check` 必须对同一文件给出
   一致 validation decision；不能出现某入口拒绝、另一入口静默接受。
7. B-007 合法 version-1 配置与历史无 `version` 配置必须按明确迁移规则兼容；未知未来
   version 必须拒绝并指出支持范围。
8. B-008 错误输出不得打印配置全文或可能的敏感值，只包含文件、字段路径和失败类别。

## 验收标准

- [ ] 发布独立 schema，模板通过，全部负例被拒绝。
- [ ] 缺失配置与合法历史配置保持兼容。
- [ ] runtime policy/getters/setup check decision 一致。
- [ ] invalid `write_mode` focused test 改为非零可见错误。
- [ ] schema/template/getter drift test 通过。

## 边界情况清单

| 类别 | 判定（covered: B-xxx / N/A + 原因） |
| --- | --- |
| 空/缺失输入 | covered: B-002 |
| 错误与失败路径 | covered: B-003, B-004, B-008 |
| 授权/权限 | N/A：只读用户配置，不改变写权限 |
| 并发/竞态 | N/A：每次读取 immutable snapshot；原子写由现有 setup 保持 |
| 重试/幂等 | covered: B-006 |
| 非法状态转换 | covered: B-007（schema version） |
| 兼容/迁移 | covered: B-002, B-007 |
| 降级/回退 | covered: B-003；无效显式值不得 fallback |
| 证据与审计完整性 | covered: B-005, B-006 |
| 取消/中断 | N/A：短生命周期读取/验证 |

## 发布说明

这是配置错误可见性增强。曾依赖拼写错误或非法值自动回退的用户会收到明确错误，需要修正
config；缺失文件和合法旧配置不受影响。
