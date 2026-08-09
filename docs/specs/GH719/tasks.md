# Tasks — GH-719 托管 skill 的持久化退出

## Implementation Tasks

- [x] `SP719-T1` 配置契约：在 `RUNTIME_CONFIG_FIELDS` 引入 `FieldKind::StringArray` 与 `disabled_skills` 声明，并同步 JSON schema、配置模板与 README 键表。Covers: persistent opt-out input contract. Owner: implementation agent. Done when: schema/模板/Rust 注册表三方路径集合一致，数组类型、`maxItems`、`items.minLength`、名称 pattern 边界均有断言，非法形状被拒。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml`; `bash tests/test_runtime_config_schema.sh`。
- [x] `SP719-T2` 读取通道：新增 `runtime-config-get-list` 与 `setup-state-list-tracked-under`，并把两者加入 `setup_runtime_supports()` 探测列表。Covers: fail-visible config and state reads. Owner: implementation agent. Done when: 配置或 state 损坏时命令非零退出而非返回空列表；旧 runtime 因缺少子命令不会被选中。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml`。
- [x] `SP719-T3` 安装与检查行为：`install_manifest_skills()` 跳过并隔离被禁用的 Codex 托管副本、对未记录退出的删除输出 `RESTORING` 告警；Codex 检查对缺失或 exact-owned 目标输出 `[DISABLED]` 而非 `[MISSING]`，对存在但 unowned 的同名目标输出 `[BROKEN]`。Covers: persistent disable/re-enable and visibility. Owner: implementation agent. Done when: 删除→重装恢复并告警、禁用→重装 durable quarantine、重复重装保持禁用、清空列表后 canonical re-enable 且隔离数据保留；unowned disabled 目标在 strict check 中失败且不承诺可隔离。Verify: `bash tests/test_setup.sh`; `bash tests/test_setup_check.sh`。
- [x] `SP719-T4` 文档：`templates/vibeguard-config.README.md` 补键表条目与「保持 Codex workflow skills 卸载」示例，`setup.sh` 结尾提示新环境变量。Covers: public operator guidance. Owner: implementation agent. Done when: 文档路径与命令路径校验通过。Verify: `bash scripts/ci/validate-doc-paths.sh`; `bash scripts/ci/validate-doc-command-paths.sh`。
- [x] `SP719-T5` corrective ownership：新增 exact managed-tree runtime verifier 与 durable quarantine transaction；损坏 state、额外/修改文件、symlink/special path 与 quarantine error 全部 fail-visible。Covers: unmanaged-content preservation. Owner: Codex. Done when: 只有 source/type/checksum/leaf inventory 全部一致才输出 `OWNED`，所有否定路径保留目录且不声称 `QUARANTINED`。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml`。
- [x] `SP719-T6` corrective lifecycle：配置 preflight 前不改 active install，previous state 同目录原子替换，HOME-scoped setup lock 覆盖 target mutation；lock 记录强进程出生身份；payload archive 固定 LF conversion。Covers: atomicity, PID reuse, concurrency, and deterministic distribution. Owner: Codex. Done when: malformed config/state 和 snapshot symlink 在 mutation 前失败，真实 active owner 阻塞第二个 setup，PID 复用 owner 可回收，payload marker digest 与 archive manifest 一致。Verify: `bash tests/test_setup.sh`; `bash tests/test_payload.sh`。
- [x] `SP719-T7` corrective scope/reporting：禁用只作用 Codex；显式空 env override 生效；消息标注 provenance；`[DISABLED]` 进入 summary/JSON 且保持中性，unowned disabled 目标使用 `[BROKEN]`。Covers: target scope and status contract. Owner: Codex. Done when: Claude 同名 skill 保留，env/config 文案可区分，status summary/JSON/quiet/exit 均有断言；exact-owned 与 unowned disabled 目标的检查结果被分别锁定。Verify: `bash tests/test_setup_check.sh`。
- [x] `SP719-T8` corrective retention：clean 保留 active quarantine 的 install-state ownership inventory 并明确报告；terminal old-source transaction 不阻塞新的 canonical source；drift 与 incomplete-generation retry 持续追踪 quarantine bytes。Covers: quarantine ownership continuity and source-path evolution. Owner: Codex. Done when: clean 后 quarantine bytes 与 state locator 均存在，released/restored 旧 source transaction 被安全忽略，retained transaction 损坏在 mutation 前失败，released crash retry 用 current inventory 校验 previous record，strict check 不误报 public path 缺失，重试不清空 locator/tracked inventory。Verify: `bash tests/test_setup.sh`; `cargo test --manifest-path vibeguard-runtime/Cargo.toml --test setup_managed_tree_remove_cli`; `cargo test --manifest-path vibeguard-runtime/Cargo.toml --test setup_quarantine_inventory_cli`。

## Verification

- 持久性 AC：记录退出 → 重跑默认安装器 → skill 仍不存在。
- 可见性 AC：未记录退出的删除被恢复时必须报告冲突并指明持久退出方式，不得静默。
- 区分性 AC：`setup.sh --check` 对不存在或 exact-owned 的被禁用 skill 报中性
  `[DISABLED]`，不报 `[MISSING]`；对 unowned/modified 同名路径报 `[BROKEN]` 且 strict/JSON
  非零退出。
- 显式性 AC：从列表移除名字后重跑安装，skill 重新出现。
- Fail-visible AC：`disabled_skills` 形状非法时安装与检查均带 JSON 路径失败，不退化为空列表。
- Ownership AC：用户同名目录、修改过的托管树或损坏 state 永不被删除，且 setup 非零退出；clean 不丢 active quarantine locator。
- Concurrency AC：同一 HOME 同时只有一个 setup 可越过 preflight；stale lock 仅在 owner
  已死亡或 PID 出生身份已变化且 metadata 完整时回收。

## Parallelization

- SP719-T1 与 SP719-T2 的 runtime 侧可并行；T3 依赖两者；T4 最后。
