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

1. B-001 repository 必须发布独立 runtime-config schema，覆盖完整 production field inventory：
   template 现有的 `version`、`u16`、`circuit_breaker`、`w14`、`paralysis`、`write_mode`，
   以及 getters 已支持但 template 尚未声明的 `write_escalate_threshold`、
   `circuit_breaker.lock_timeout_seconds`、`learn.metrics_tail_bytes`；template 必须补齐这些
   已支持字段，不能用 schema 删除既有 production capability。
2. B-002 配置文件不存在时继续使用现有默认值；存在的空对象可按向后兼容规则使用默认值，
   但显式字段必须通过类型、枚举和范围验证。
3. B-003 存在但不可读或不是普通文件，以及 malformed JSON/UTF-8、错误类型、未知字段、
   非法 enum、负数/越界值，必须让 runtime validator、policy 与 getter 返回可见错误和
   非零状态，不得当成“文件缺失”或回退为默认值后成功；setup 的进程退出码仅按 B-006
   的既有 mode contract 映射，不能改变同一 `INVALID` decision。
4. B-004 `write_mode` 只接受声明闭集；现有 `invalid -> warn` 行为必须改为配置错误。
5. B-005 template、schema 与 production getters 的字段路径必须由同步门禁证明一致；新增
   config key 不能只接入其中一层。
6. B-006 runtime policy、直接 runtime-config validator/getter 与 setup health check 必须对
   同一文件给出一致 `MISSING` / `VALID` / `INVALID` decision；不能出现某入口拒绝、另一
   入口静默接受。`setup.sh --check`、`doctor`、`--quiet`、`--no-summary` 保持既有兼容退出
   码 0，但必须把 `INVALID` 渲染为 redacted `[FAIL] User runtime config invalid`；`--strict`、
   `--json`、`verify-project`、`verify-dev-repo`、`--install`、`verify-install` 必须把同一
   `INVALID` 计为 broken 并退出 2。`MISSING` 在全部 mode 中保持合法 defaults 状态和退出 0。
7. B-007 合法 version-1 配置与历史无 `version` 配置必须按明确迁移规则兼容；未知未来
   version 必须拒绝并指出支持范围。
8. B-008 错误输出不得打印配置全文或可能的敏感值，只包含文件、字段路径和失败类别。

## 验收标准

- [ ] 发布独立 schema，模板通过，全部负例被拒绝。
- [ ] 缺失配置与合法历史配置保持兼容。
- [ ] runtime policy/validator/getters/setup check decision 一致，且 setup 各 mode 保持既有退出语义。
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
config；缺失文件和合法旧配置不受影响。此前虽可解析但超过本规格安全上界的数值属于
不安全配置，不属于合法旧配置；setup/runtime 会报告字段路径与允许范围。
