# Tech Spec — 托管 skill 的持久化退出契约

## Linked Issue

GH-719

## 现状

`scripts/setup/lib.sh:install_manifest_skills()` 遍历 manifest 声明的 skill
链接，对每一个调用目标专属的安装函数。Codex 侧的
`install_codex_skill_copy()` 先 `rm -rf` 目标再拷贝源树，Claude 侧建立符号链接。
两条路径都不查询任何用户意图，也不区分「从未安装」与「装过但被删除」。

`~/.vibeguard/config.json` 已有一套集中式契约：字段在
`vibeguard-runtime/src/runtime_config/validation.rs` 的 `RUNTIME_CONFIG_FIELDS`
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

查询遇到 malformed/unsupported state 时非零退出。隔离前再调用
`setup-state-verify-managed-tree <state-file> <dest-dir> <source-prefix>`：只有每个
当前 leaf 都被跟踪、source prefix/type/checksum 一致、没有额外/缺失路径或 unsupported
path type 时输出 `OWNED`；其他正常否定输出 `UNOWNED:<reason>`。

`setup-state-quarantine-managed-tree` 在 rename 前持久化 intent，以 no-replace rename 把
精确托管树移动到同父目录隐藏 quarantine，fsync 后发布 locator；任何失败都保留至少一份
完整数据。`setup-state-release-quarantined-tree` 在 canonical source 重新安装后只释放
active locator，先前 quarantine 与 terminal transaction 继续保留。扫描 transaction 时，
与 active locator 精确匹配的 `intent`/`committed` transaction 仍验证 destination、nonce、
digest 与 sibling 路径，但其 source prefix 是创建隔离时的历史身份，可以不同于 manifest
当前 source prefix；没有 matching active record 的新 transaction 必须使用当前 source prefix。
`restored`/`released` 终态同样只验证自身结构与 sibling 路径，不能因 manifest 后续移动
source 而阻塞安装或重新启用。安装 preflight 还会扫描 skills 根下全部 canonical retained
transaction；损坏的 terminal transaction 必须在 installed snapshot 或 target mutation 前失败。
若 `released` record 同时存在于 current/previous generation，previous artifact 校验使用 current
generation 的 public-tree inventory，避免旧 checksum 阻塞 crash recovery。

### 3. 安装与检查（shell）

`scripts/setup/workflow-skills.sh` 承担：

- `disabled_skills()` — 调用 `runtime-config-get-list`，结果缓存在
  `_VG_DISABLED_SKILLS_CACHE`。读取失败时返回非零并打印错误，调用方随之失败。
- `skill_is_disabled <name>`
- `remove_disabled_skill <dest> <name> <dest-dir> <source-prefix>` — 隔离前用 `pwd -P`
  校验父目录边界，并调用 runtime 的 durable quarantine 命令；state 读取失败、ownership
  否定、rename/验证/locator 发布失败均非零返回且保留数据。
- `report_skill_restore <dest> <name>` — 目标缺失但 install-state 中有跟踪记录时，
  输出 `RESTORING` 告警并指明如何持久禁用。

`install_manifest_skills()` 用 target flag 只在 Codex 路径解析禁用列表，
循环内先处理禁用分支（quarantine + SKIP），再对未禁用的 skill 调用
`report_skill_restore` 后安装。

`scripts/lib/install-state.sh` 的 state 读取错误不得吞掉。`state_init()` 在任何写入前
验证 current/previous state 都是非 symlink regular JSON；previous snapshot 使用同目录
临时文件加 atomic rename。current/previous 的 complete/incomplete generation 排序在
preflight 阶段验证，而不是等到 `state_init()` 才验证。已经完成完整 capability probe 的
install-state runtime 在同一 shell lifecycle 内缓存；staged runtime 重新准备、候选上下文变化
或 cached path 消失时必须失效并重新验证。

`check_codex_home_installation()` 在 skill 循环内插入禁用分支：目标缺失或仍是
exact install-state-owned copy 时输出 `[DISABLED]`，不落到 `[MISSING]`；目标存在但不是
VibeGuard-owned copy 时输出 `[BROKEN]`，明确下一次安装会拒绝隔离，并在 strict check 中
非零退出。Claude 检查与安装都不消费该字段。`status_report.sh` 把 `[DISABLED]` 计入
summary/JSON event，但保持 healthy、quiet 中性；`[BROKEN]` 保持既有 broken 语义。

`scripts/setup/setup-lock.sh` 提供 HOME-scoped lifecycle lock。新 owner nonce 携带 Linux
boot-id/start-ticks 或 Darwin 秒/微秒出生身份；PID 存活且身份相同才算 active，PID 被复用
时可按 stale owner 回收，身份无法证明时 fail-closed。release 必须匹配 PID+nonce+出生身份。
runtime 先在 hidden sibling directory 写入并 fsync owner，再以 no-replace rename 原子发布整个
canonical lock directory；release 则先验证唯一 owner，再把整个 canonical directory 原子改名
到 retired sibling 后清理。任何中断都不会暴露 ownerless canonical lock。
`install.sh` 先在临时目录 stage runtime，再验证 `disabled_skills`，然后持锁覆盖 installed
snapshot、install-state、Claude/Codex mutation 与最终验证。

clean 前调用 `setup-state-quarantine-count`。只要 current/previous install-state 仍含 active
quarantine，`state_clean()` 就保留两个 generation 作为 ownership inventory，并输出 retained
数量与 state 路径；没有 active quarantine 时才删除 install-state。

`setup-state-check-drift` 把 active quarantine 覆盖的 public tracked path 映射到 quarantine
locator 后再做 type/checksum 校验。`state_init()` 重试同一个 incomplete generation 时，新的
profile/language state 保留其 quarantine records 以及对应 tracked file inventory，供 durable
transaction recovery 精确匹配；不得在 recovery 前清空 locator。若本次重试新增 disabled
skill，只续存该公开 skill 根下 type=copy 且当前 checksum 可验证的 incomplete inventory。

### 4. 运行时能力探测

`setup_runtime_supports()` 的子命令探测列表加入
`setup-state-list-tracked-under`、`setup-state-verify-managed-tree`、
`setup-state-quarantine-managed-tree`、`setup-state-release-quarantined-tree`、
`setup-state-quarantine-count` 与
`runtime-config-get-list`，并把 runtime 版本升到 `1.1.13`，避免选中一个缺少
新命令的旧 runtime 后在安装中途失败（U-26）。

## 影响文件

| 文件 | 变更 |
|---|---|
| `vibeguard-runtime/src/runtime_config/validation.rs` | `StringArray` 字段类型 + `disabled_skills` 声明 |
| `vibeguard-runtime/src/runtime_config/mod.rs` | `runtime_config_get_list` |
| `vibeguard-runtime/src/setup/install_state.rs` | `list_tracked_under` |
| `vibeguard-runtime/src/setup/managed_tree_remove.rs` | durable quarantine/release 与 terminal transaction recovery |
| `vibeguard-runtime/src/setup/quarantine_inventory.rs` | active quarantine count、drift locator 映射与 checksum-verifiable incomplete retry inventory carry |
| `vibeguard-runtime/src/setup/lock_lifecycle.rs` | canonical lock directory 的原子 acquire/release |
| `vibeguard-runtime/src/main.rs` | runtime 命令注册 |
| `scripts/setup/lib.sh` | source 专责模块、探测列表 |
| `scripts/setup/workflow-skills.sh` | 禁用列表读取、Codex-only 跳过/quarantine/恢复告警 |
| `scripts/setup/setup-lock.sh` | 带进程出生身份的 HOME-scoped lifecycle lock |
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
| setup 回归 | `bash tests/test_setup.sh` | 删除→重装恢复；durable quarantine；clean inventory retention；PID reuse；Codex-only 禁用；`[DISABLED]`；非法配置 preflight |
