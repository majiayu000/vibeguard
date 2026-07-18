# Tech Spec

## Linked Issue

GH-629

## Product Spec

See `product.md`.

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Shipped example | `templates/vibeguard-config.json.example:1` | 定义 6 组 runtime keys，但遗漏 3 个 production getter path | schema/template 漂移基线 |
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

完整 field inventory 以 production getters 与已发布 template 的并集为迁移输入：

| JSON path | Existing consumer/default | Inclusive v1 domain | Schema/template action |
| --- | --- | --- | --- |
| `version` | setup/template；legacy 缺失按 v1 | integer const 1 | optional；未来 version 拒绝 |
| `u16.warn_limit` | Rust/shell，400 | 0..1,000,000 | integer；保留 consumer clamp |
| `u16.limit` | Rust/shell，800 | 0..1,000,000 | integer |
| `circuit_breaker.threshold` | Rust/shell，3 | 0..1,000,000 | integer |
| `circuit_breaker.cooldown_seconds` | Rust/shell，300 | 0..31,536,000 | integer；最长一年 |
| `circuit_breaker.lock_timeout_seconds` | Rust/shell，5 | 0..300 | integer；补入 template；限制 mkdir retry 次数 |
| `w14.cooldown_seconds` | Rust，3600 | 0..31,536,000 | integer；最长一年 |
| `paralysis.threshold` | shell，7 | 0..1,000,000 | integer |
| `write_mode` | Rust/shell，`warn` | `warn` / `block` | string enum |
| `write_escalate_threshold` | Rust，5；0 表示禁用升级 | 0..1,000,000 | integer；补入 template |
| `learn.metrics_tail_bytes` | Rust，5242880；当前 0 会读取全文件 | 1..268,435,456 | integer；补入 template；最多读取 256 MiB；0 拒绝 |

这些上界同时避免 `usize` cast、shell signed arithmetic、`lock_timeout * 10` retry 与 tail-read
资源失控。schema 与 Rust inventory 必须共享表中常量；每个 tunable numeric path 都必须具名
覆盖 `minimum`、`max`、`max + 1`，并对允许 0 的 path 额外覆盖 0。`version` 覆盖 missing、
0、1、2；`learn.metrics_tail_bytes` 覆盖 0 rejection，禁止保留当前 0 -> unbounded full-read
分支。不得让 schema 接受而 getter truncate、wrap 或 fallback。此前虽被 parse-only getter
接受但超过这些范围或令 Learn 无界读取的值定义为 unsafe invalid config，不属于合法 legacy。

推荐 Route A（Rust typed validator + schema parity test）。Route B 在运行时加载并解释 JSON
Schema，单一来源更直接，但会增加解析复杂度、依赖和 hook latency；不符合当前 Rust-only、
低依赖路径。parity test 读取 schema/template 与 Rust 声明的 field inventory，阻断字段漂移。

兼容策略：文件缺失和 `{}` 合法；`version` 缺失按 legacy v1 读取，显式 `version` 只能为 1。
除 `learn.metrics_tail_bytes` 外，现有 getter 已接受 0，schema 保持相同 nonnegative 语义；
Learn 的 0 因现有实现跳过 seek 并读取完整日志而改为 invalid，不赋予“禁用”或“读取零字节”的
新行为。`u16.warn_limit > u16.limit` 是合法 legacy 输入，继续由现有 Rust/shell consumer
clamp 到 effective limit，不新增 cross-field rejection；必须有 regression 覆盖。未知字段、
未来 version 与表中 max+1 拒绝。

新增 `vibeguard-runtime runtime-config-validate <path>` 作为 setup 与直接诊断 adapter；
`validate_runtime_config_file` 返回 parsed validated config 或复用同一 typed validator，getter
不得再次以 `.ok()?` 静默吞掉同一文件错误。validation 必须先于 env-over-JSON-default 的字段
resolution，因此合法 env override 不能掩盖一个存在但 `INVALID` 的文件。runtime policy、
validator/getter CLI 与 setup check 共享错误格式，只打印文件、JSON path、失败类别和允许范围，
不打印 value。

文件状态矩阵如下；除真正 missing 外，不得用 `Path::is_file() == false` 归入 defaults：

| Config path state | Decision | Runtime validator/policy/getter | Setup rendering / exit |
| --- | --- | --- | --- |
| path 不存在且不是 symlink | `MISSING` | defaults，exit 0 | INFO/defaults，全部 mode exit 0 |
| readable regular file | `VALID` 或内容型 `INVALID` | 由同一 typed validator 判定 | 同一 decision，按 mode 映射 |
| readable symlink -> regular file | 与 target 相同 | 保留现有可读 symlink 兼容 | 与 target 相同 |
| directory 或其他 non-regular（FIFO/socket/device） | `INVALID` | `config_path_type_error`，非零；不得 open FIFO | `[FAIL]`；兼容 mode 0，strict/install mode 2 |
| dangling symlink | `INVALID` | `config_path_target_error`，非零 | `[FAIL]`；兼容 mode 0，strict/install mode 2 |
| unreadable regular file/target | `INVALID` | `config_read_error`，非零 | `[FAIL]`；兼容 mode 0，strict/install mode 2 |
| invalid UTF-8 | `INVALID` | `config_utf8_error`，非零 | `[FAIL]`；兼容 mode 0，strict/install mode 2 |

Setup 对 `INVALID` 始终记录同一个 broken decision；只由现有 mode precedence 决定进程状态：

| Fully-qualified invocation | Existing precedence to preserve | INVALID result |
| --- | --- | --- |
| `bash setup.sh doctor`；`bash setup.sh --check` | human compatibility，无 machine flag | redacted `[FAIL]`，exit 0 |
| `bash setup.sh doctor --quiet`；`bash setup.sh --check --quiet` | quiet 只过滤 healthy output | redacted problem row，exit 0 |
| `bash setup.sh doctor --project`；`bash setup.sh --check --project` | bare project 只增加 project hooks，不隐式 strict | redacted `[FAIL]`，exit 0 |
| `bash setup.sh doctor --no-summary`；`bash setup.sh --check --no-summary` | legacy no-summary | redacted `[FAIL]`，exit 0 |
| `bash setup.sh doctor --strict`；`bash setup.sh doctor --quiet --strict` | strict 胜过 human/quiet | broken，exit 2 |
| `bash setup.sh doctor --json` | JSON implies strict，只输出单行 JSON | broken verdict，exit 2 |
| `bash setup.sh doctor --install` | install machine status | broken required state，exit 2 |
| `bash setup.sh doctor --strict --no-summary`；`bash setup.sh doctor --install --no-summary` | direct doctor 保留 check.sh 的 no-summary 最终 exit 0 | redacted row，无 summary，exit 0 |
| `bash setup.sh --check --strict`；`bash setup.sh --check --quiet --strict` | alias 自动加入 project；strict 胜过 quiet | broken，exit 2 |
| `bash setup.sh --check --json` | alias 自动加入 project；JSON implies strict | broken verdict，exit 2 |
| `bash setup.sh --check --install` | install machine status | broken required state，exit 2 |
| `bash setup.sh verify-project`；`bash setup.sh verify-project --json` | 固定 `--strict --project` | broken / broken JSON，exit 2 |
| `bash setup.sh verify-dev-repo`；`bash setup.sh verify-dev-repo --json` | 固定 `--strict --dev-repo` | broken / broken JSON，exit 2 |
| `bash setup.sh verify-install` | 固定 `--install` | broken required state，exit 2 |
| `--json --quiet`、`--json --install`、`--json --no-summary` | check.sh 参数冲突 | usage error，exit 64 |
| `--check --strict|--json|--install` + `--no-summary`；任一 `verify-* --no-summary` | top-level machine alias 拒绝 legacy no-summary | usage error，exit 64 |

`--project`/`--dev-repo` 自身只选择检查范围；只有 fully-qualified verify alias 或显式 strict/json
才改变 health exit。JSON mode 不得把 validator stderr 或配置 value 混入 stdout。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 | new schema + complete getter/template inventory | schema meta-validation；template validates；3 个缺失 template path 已补齐 |
| B-002 | Rust validator default/legacy branch | missing file、`{}`、partial valid fixtures |
| B-003 | typed validator + path classifier | file-state matrix、malformed/type/unknown/range negatives；runtime entrypoints return nonzero |
| B-004 | `write_mode` enum | invalid-mode hook test expects config error |
| B-005 | parity checker | template/schema/Rust field-set mutation fixtures |
| B-006 | policy/getter/setup adapters | same decision matrix；setup compatibility modes exit 0，strict/install modes exit 2 |
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

- [ ] Schema/inventory: `bash tests/test_runtime_config_schema.sh` 与 `bash tests/test_manifest_contract.sh`。
- [ ] Rust/file matrix: `cargo test --manifest-path vibeguard-runtime/Cargo.toml runtime_config` 与 `cargo test --manifest-path vibeguard-runtime/Cargo.toml --test runtime_config_cli`。
- [ ] Policy/shell: `cargo test --manifest-path vibeguard-runtime/Cargo.toml --test runtime_policy_cli` 与 `bash tests/hooks/test_runtime_config.sh`。
- [ ] Setup modes: `bash tests/test_setup_check.sh` 逐行覆盖上述 fully-qualified doctor/`--check`/project/dev-repo/quiet/no-summary/strict/json/install/verify alias 与 exit-64 conflict matrix；`bash tests/test_setup.sh` 运行完整 setup gate。
- [ ] Required: `cargo check --manifest-path vibeguard-runtime/Cargo.toml`、`cargo test --manifest-path vibeguard-runtime/Cargo.toml`、`bash scripts/local-contract-check.sh --quick`、`git diff --check`。

## 回滚方案

可回滚 schema、Rust validator 与 adapters。若兼容性问题出现，只能对经规格确认的合法旧格式
增加明确 migration rule；不得恢复“解析失败/非法值 -> default”静默降级。
