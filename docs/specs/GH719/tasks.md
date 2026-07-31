# Tasks — GH-719 托管 skill 的持久化退出

## Implementation Tasks

- [x] `SP719-T1` 配置契约：在 `RUNTIME_CONFIG_FIELDS` 引入 `FieldKind::StringArray` 与 `disabled_skills` 声明，并同步 JSON schema、配置模板与 README 键表。Covers: persistent opt-out input contract. Owner: implementation agent. Done when: schema/模板/Rust 注册表三方路径集合一致，数组类型、`maxItems`、`items.minLength`、名称 pattern 边界均有断言，非法形状被拒。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml`; `bash tests/test_runtime_config_schema.sh`。
- [x] `SP719-T2` 读取通道：新增 `runtime-config-get-list` 与 `setup-state-list-tracked-under`，并把两者加入 `setup_runtime_supports()` 探测列表。Covers: fail-visible config and state reads. Owner: implementation agent. Done when: 配置或 state 损坏时命令非零退出而非返回空列表；旧 runtime 因缺少子命令不会被选中。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml`。
- [x] `SP719-T3` 安装与检查行为：`install_manifest_skills()` 跳过并删除被禁用的 Codex 托管副本、对未记录退出的删除输出 `RESTORING` 告警；Codex 检查输出 `[DISABLED]` 而非 `[MISSING]`。Covers: persistent disable/re-enable and visibility. Owner: implementation agent. Done when: 删除→重装恢复并告警、禁用→重装删除、重复重装保持禁用、清空列表后恢复。Verify: `bash tests/test_setup.sh`。
- [x] `SP719-T4` 文档：`templates/vibeguard-config.README.md` 补键表条目与「保持 Codex workflow skills 卸载」示例，`setup.sh` 结尾提示新环境变量。Covers: public operator guidance. Owner: implementation agent. Done when: 文档路径与命令路径校验通过。Verify: `bash scripts/ci/validate-doc-paths.sh`; `bash scripts/ci/validate-doc-command-paths.sh`。
- [x] `SP719-T5` corrective ownership：新增 exact managed-tree runtime verifier，损坏 state、额外/修改文件、symlink/special path 与 removal error 全部 fail-visible。Covers: unmanaged-content preservation. Owner: Codex. Done when: 只有 source/type/checksum/leaf inventory 全部一致才输出 `OWNED`，所有否定路径保留目录且不声称 `REMOVED`。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml`。
- [x] `SP719-T6` corrective lifecycle：配置 preflight 前不改 active install，previous state 同目录原子替换，HOME-scoped setup lock 覆盖 target mutation。Covers: atomicity and concurrency. Owner: Codex. Done when: malformed config/state 和 snapshot symlink 在 mutation 前失败，active owner 阻塞第二个 setup，合法 stale owner 可回收。Verify: `bash tests/test_setup.sh`。
- [x] `SP719-T7` corrective scope/reporting：禁用只作用 Codex；显式空 env override 生效；消息标注 provenance；`[DISABLED]` 进入 summary/JSON 且保持中性。Covers: target scope and status contract. Owner: Codex. Done when: Claude 同名 skill 保留，env/config 文案可区分，status summary/JSON/quiet/exit 均有断言。Verify: `bash tests/test_setup_check.sh`。

## Verification

- 持久性 AC：记录退出 → 重跑默认安装器 → skill 仍不存在。
- 可见性 AC：未记录退出的删除被恢复时必须报告冲突并指明持久退出方式，不得静默。
- 区分性 AC：`setup.sh --check` 对被禁用 skill 报 `[DISABLED]`，不报 `[MISSING]`。
- 显式性 AC：从列表移除名字后重跑安装，skill 重新出现。
- Fail-visible AC：`disabled_skills` 形状非法时安装与检查均带 JSON 路径失败，不退化为空列表。
- Ownership AC：用户同名目录、修改过的托管树或损坏 state 永不被删除，且 setup 非零退出。
- Concurrency AC：同一 HOME 同时只有一个 setup 可越过 preflight；stale lock 仅在 owner
  已死亡且 metadata 完整时回收。

## Parallelization

- SP719-T1 与 SP719-T2 的 runtime 侧可并行；T3 依赖两者；T4 最后。
