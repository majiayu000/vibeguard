# Tech Spec

## Linked Issue

GH-629

## Product Spec

See `product.md`.

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Shipped example | `templates/vibeguard-config.json.example:1` | 定义 6 组 runtime keys | schema 字段基线 |
| Parse validation | `vibeguard-runtime/src/runtime_config.rs:28` | 只验证文件可读、UTF-8 与 JSON | schema/semantic validation 缺口 |
| Getter fallback | `vibeguard-runtime/src/runtime_config.rs:95` | type/path 不匹配时返回 default | silent degradation 根因 |
| Runtime policy | `vibeguard-runtime/src/runtime_policy.rs:32` | hook policy 前调用 parse-only validator | 适合承载一致 validation decision |
| Shell bridge | `hooks/_lib/config.sh:115` | 调用 Rust runtime-config getters | 必须消费相同 validation contract |
| Regression evidence | `tests/hooks/test_runtime_config.sh:74` | 断言 invalid `write_mode` fallback warn | 需要翻转为 fail-visible negative test |
| Setup seed | `scripts/setup/install.sh:294` | 从 template 创建用户 config | setup check 应验证同一 schema |

## 设计方案

在 `schemas/` 新增独立 runtime-config schema 作为公开 machine-readable contract，
`additionalProperties: false` 应用于根与嵌套对象。Rust runtime 继续作为 production validator：
用 typed/manual validation 实现 schema 等价约束，复用现有 `RuntimeConfigError` exit-code
边界，不在 hook 热路径引入通用 JSON Schema 引擎依赖。

推荐 Route A（Rust typed validator + schema parity test）。Route B 在运行时加载并解释 JSON
Schema，单一来源更直接，但会增加解析复杂度、依赖和 hook latency；不符合当前 Rust-only、
低依赖路径。parity test 读取 schema/template 与 Rust 声明的 field inventory，阻断字段漂移。

兼容策略：文件缺失和 `{}` 合法；`version` 缺失按 legacy v1 读取，显式 `version` 只能为 1。
数字字段要求非负/正值按当前有效默认与 guard 语义确定，并增加 `u16.warn_limit <= u16.limit`
跨字段约束。未知字段和未来 version 拒绝。

`validate_runtime_config_file` 返回 parsed validated config 或至少复用一次 validator；getter 不得
再次以 `.ok()?` 静默吞掉同一文件错误。runtime policy、直接 getter CLI 与 setup check 共享
错误格式，只打印文件与 JSON path，不打印 value。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 | new schema + inventory | schema meta-validation；template validates |
| B-002 | Rust validator default/legacy branch | missing file、`{}`、partial valid fixtures |
| B-003 | typed validator | malformed/type/unknown/range/cross-field negatives return nonzero |
| B-004 | `write_mode` enum | invalid-mode hook test expects config error |
| B-005 | parity checker | template/schema/Rust field-set mutation fixtures |
| B-006 | policy/getter/setup adapters | same fixture matrix through three entrypoints |
| B-007 | version handling | missing v1、explicit v1 pass；future version fails |
| B-008 | error rendering | secret-like value absent from stderr/payload assertions |

## 数据流

setup 可从 template seed 文件；hook/runtime entrypoint 定位 config，读取一次、解析并验证为
typed config，再按 env-over-JSON-default 优先级取值。validation failure 进入现有 policy error
输出并停止对应 hook；无新持久层。

## 风险

- Security: 错误不得泄露配置值；unknown keys fail closed。
- Compatibility: 过去被忽略的非法值会变成错误，需清晰迁移说明。
- Performance: validator 应单次解析并复用，不在每个字段 getter 重复读盘。
- Maintenance: schema/Rust 双实现由 parity gate 约束。

## 测试计划

- [ ] Rust unit: full positive/negative config matrix 与 redacted errors。
- [ ] Shell integration: `bash tests/hooks/test_runtime_config.sh`、runtime policy config errors。
- [ ] Setup: focused `--check` invalid/valid user config fixtures。
- [ ] Required: `cargo check --manifest-path vibeguard-runtime/Cargo.toml` 与 `cargo test --manifest-path vibeguard-runtime/Cargo.toml`。
- [ ] Contracts: `bash tests/test_manifest_contract.sh`。

## 回滚方案

可回滚 schema、Rust validator 与 adapters。若兼容性问题出现，只能对经规格确认的合法旧格式
增加明确 migration rule；不得恢复“解析失败/非法值 -> default”静默降级。
