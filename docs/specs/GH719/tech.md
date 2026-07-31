# Tech Spec — 托管 skill 的持久化退出契约

## Linked Issue

GH-719

## 现状

`scripts/setup/lib.sh:install_manifest_skills()` 遍历 manifest 声明的 skill
链接，对每一个调用目标专属的安装函数。Codex 侧的
`install_codex_skill_copy()` 先 `rm -rf` 目标再拷贝源树，Claude 侧建立符号链接。
两条路径都不查询任何用户意图，也不区分「从未安装」与「装过但被删除」。

`~/.vibeguard/config.json` 已有一套集中式契约：字段在
`vibeguard-runtime/src/runtime_config_validation.rs` 的 `RUNTIME_CONFIG_FIELDS`
注册表中声明，未声明的字段直接被拒绝（`config_unknown_field`），并与
`schemas/vibeguard-runtime-config.schema.json`、
`templates/vibeguard-config.json.example` 由
`tests/test_runtime_config_schema.sh` 和
`runtime_config_validation_tests.rs` 双向锁定。

## 变更

### 1. 配置字段（runtime）

`RUNTIME_CONFIG_FIELDS` 新增 `disabled_skills`，类型为新引入的
`FieldKind::StringArray { maximum_items: 256 }`。校验规则：必须是数组，条目必须匹配
`^[A-Za-z0-9][A-Za-z0-9._-]*$`，超过上限报 `config_range_error`。同步更新 JSON schema
（`type: array` / `maxItems: 256` / `items.type: string` / `items.minLength: 1` /
`items.pattern`）、
配置模板与 `templates/vibeguard-config.README.md` 的键表。

新增读取命令 `runtime-config-get-list <env-name> <json-path>`，逐行输出条目。它
复用 `loaded_runtime_config()`，因此整份配置在读取任何值之前已被校验：**配置损坏
时命令非零退出，而不是退化成空列表**。空列表会静默推翻用户的退出意图，正是本
issue 要修的缺陷类别（U-29）。

### 2. 安装状态查询（runtime）

新增 `setup-state-list-tracked-under <state-file> <dest-dir>`，输出 install-state
中位于该目录下的所有被跟踪路径（不限 install type）。托管 skill 副本是逐文件记录
的，因此「VibeGuard 是否装过这个 skill」等价于「该 skill 目录下是否有被跟踪路径」。
既有的 `setup-state-list-symlinks-under` 只覆盖 symlink，无法回答 Codex 侧的拷贝。

查询遇到 malformed/unsupported state 时非零退出。删除前再调用
`setup-state-verify-managed-tree <state-file> <dest-dir> <source-prefix>`：只有每个
当前 leaf 都被跟踪、source prefix/type/checksum 一致、没有额外/缺失路径或 unsupported
path type 时输出 `OWNED`；其他正常否定输出 `UNOWNED:<reason>`。

### 3. 安装与检查（shell）

`scripts/setup/workflow-skills.sh` 承担：

- `disabled_skills()` — 调用 `runtime-config-get-list`，结果缓存在
  `_VG_DISABLED_SKILLS_CACHE`。读取失败时返回非零并打印错误，调用方随之失败。
- `skill_is_disabled <name>`
- `remove_disabled_skill <dest> <name> <dest-dir> <source-prefix>` — 删除前用 `pwd -P`
  校验父目录边界，并要求 runtime 对 current/previous state 至少一个给出精确 `OWNED`；
  state 读取失败、ownership 否定或 `rm` 失败均非零返回。
- `report_skill_restore <dest> <name>` — 目标缺失但 install-state 中有跟踪记录时，
  输出 `RESTORING` 告警并指明如何持久禁用。

`install_manifest_skills()` 用 target flag 只在 Codex 路径解析禁用列表，
循环内先处理禁用分支（删除 + SKIP），再对未禁用的 skill 调用
`report_skill_restore` 后安装。

`scripts/lib/install-state.sh` 的 state 读取错误不得吞掉。`state_init()` 在任何写入前
验证 current/previous state 都是非 symlink regular JSON；previous snapshot 使用同目录
临时文件加 atomic rename。

`check_codex_home_installation()` 在 skill 循环内插入禁用分支，输出 `[DISABLED]`
而非落到 `[MISSING]`；Claude 检查与安装都不消费该字段。`status_report.sh` 把
`[DISABLED]` 计入 summary/JSON event，但保持 healthy、quiet 中性。

`scripts/setup/setup-lock.sh` 提供 HOME-scoped lifecycle lock。active owner 阻止第二个
setup；只有 owner PID 已不存在且 metadata 合法时才回收 stale lock；release 必须匹配
PID+nonce。`install.sh` 先在临时目录 stage runtime，再验证 `disabled_skills`，然后持锁
覆盖 installed snapshot、install-state、Claude/Codex mutation 与最终验证。

### 4. 运行时能力探测

`setup_runtime_supports()` 的子命令探测列表加入
`setup-state-list-tracked-under`、`setup-state-verify-managed-tree` 与
`runtime-config-get-list`，并把 runtime 版本升到 `1.1.13`，避免选中一个缺少
新命令的旧 runtime 后在安装中途失败（U-26）。

## 影响文件

| 文件 | 变更 |
|---|---|
| `vibeguard-runtime/src/runtime_config_validation.rs` | `StringArray` 字段类型 + `disabled_skills` 声明 |
| `vibeguard-runtime/src/runtime_config.rs` | `runtime_config_get_list` |
| `vibeguard-runtime/src/setup_install_state.rs` | `list_tracked_under` |
| `vibeguard-runtime/src/main.rs` | 两个新命令注册 |
| `scripts/setup/lib.sh` | source 专责模块、探测列表 |
| `scripts/setup/workflow-skills.sh` | 禁用列表读取、Codex-only 跳过/删除/恢复告警 |
| `scripts/setup/setup-lock.sh` | HOME-scoped lifecycle lock |
| `scripts/lib/install-state.sh` | fail-visible 查询、atomic previous snapshot、ownership 包装 |
| `scripts/setup/targets/codex-home.sh` | `[DISABLED]` 检查分支 |
| `scripts/setup/targets/claude-home.sh` | 明确不应用 Codex disabled list |
| `scripts/setup/install.sh` | 结尾环境变量说明 |
| `scripts/lib/status_report.sh` | 中性 `[DISABLED]` summary/JSON contract |
| `schemas/vibeguard-runtime-config.schema.json` | `disabled_skills` |
| `templates/vibeguard-config.json.example` | `disabled_skills: []` |
| `templates/vibeguard-config.README.md` | 键表 + 使用示例 |

## 验证

| 层 | 命令 | 覆盖 |
|---|---|---|
| runtime 单测 | `cargo test` | `StringArray` 校验、schema/模板/注册表三方一致、非法形状拒绝 |
| schema 契约 | `bash tests/test_runtime_config_schema.sh` | 数组类型、maxItems、minLength 边界 |
| setup 回归 | `bash tests/test_setup.sh` | 删除→重装恢复；Codex-only 禁用；ownership 保留；atomic state；lock；`[DISABLED]`；非法配置 preflight |
