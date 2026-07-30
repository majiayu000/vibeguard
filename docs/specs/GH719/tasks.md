# Tasks — GH-719 托管 skill 的持久化退出

## Implementation Tasks

- [x] `SP719-T1` Owner: unassigned — 配置契约：在 `RUNTIME_CONFIG_FIELDS` 引入 `FieldKind::StringArray` 与 `disabled_skills` 声明，并同步 JSON schema、配置模板与 README 键表。Done when：schema/模板/Rust 注册表三方路径集合一致，数组类型、`maxItems`、`items.minLength` 边界均有断言，非法形状被拒。Verify: `cargo test && bash tests/test_runtime_config_schema.sh`
- [x] `SP719-T2` Owner: unassigned — 读取通道：新增 `runtime-config-get-list` 与 `setup-state-list-tracked-under`，并把两者加入 `setup_runtime_supports()` 探测列表。Done when：配置损坏时命令非零退出而非返回空列表；旧 runtime 因缺少子命令不会被选中。Verify: `cargo test`
- [x] `SP719-T3` Owner: unassigned — 安装与检查行为：`install_manifest_skills()` 跳过并删除被禁用的托管副本、对未记录退出的删除输出 `RESTORING` 告警；两个 target 的检查输出 `[DISABLED]` 而非 `[MISSING]`。Done when：删除→重装恢复并告警、禁用→重装删除、重复重装保持禁用、清空列表后恢复。Verify: `bash tests/test_setup.sh`
- [x] `SP719-T4` Owner: unassigned — 文档：`templates/vibeguard-config.README.md` 补键表条目与「保持 Codex workflow skills 卸载」示例，`setup.sh` 结尾提示新环境变量。Done when：文档路径校验通过。Verify: `bash scripts/ci/validate-doc-paths.sh`

## Verification

- 持久性 AC：记录退出 → 重跑默认安装器 → skill 仍不存在。
- 可见性 AC：未记录退出的删除被恢复时必须报告冲突并指明持久退出方式，不得静默。
- 区分性 AC：`setup.sh --check` 对被禁用 skill 报 `[DISABLED]`，不报 `[MISSING]`。
- 显式性 AC：从列表移除名字后重跑安装，skill 重新出现。
- Fail-visible AC：`disabled_skills` 形状非法时安装与检查均带 JSON 路径失败，不退化为空列表。

## Parallelization

- SP719-T1 与 SP719-T2 的 runtime 侧可并行；T3 依赖两者；T4 最后。
