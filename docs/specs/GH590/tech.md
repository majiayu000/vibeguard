# Tech Spec

## Linked Issue

GH-590

## Product Spec

`docs/specs/GH590/product.md`

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Production entry | `hooks/post-edit-guard.sh:1-48` | Thin wrapper 查找 executable runtime 后 `exec ... hook post-edit`；找不到 runtime 时显式失败 | 证明本次 contract 是 Rust production path，不存在 shell fallback dispatch |
| W-14 orchestration | `vibeguard-runtime/src/hook_orchestrator_post_edit_history.rs:101-128`, `:217-248` | `detect_w14` 对每个 `recent_overlap` 都 push 完整 warning 并 append warn event；history 只读最后 500 行，坏 JSON 行被忽略 | cooldown decision、shown/suppressed event 与 fail-open 边界的主修改面 |
| Overlap/path/history helpers | `vibeguard-runtime/src/hook_checks_history.rs:118-193`, `:211-225` | recent-overlap 使用 30 分钟窗口并比较 normalized path；bounded tail reader 提供 500 行输入 | 必须复用现有 candidate/path 语义，不能顺带改变 detection |
| Final warning composition | `vibeguard-runtime/src/hook_orchestrator_post_edit.rs:40-104` | history/stateless warnings 合并；无 warning 记录 pass，有 warning 可能升级并输出 context | suppressed W-14 不能抹掉同 run 的其他 warning，telemetry failure 必须回到 visible warning |
| Event vocabulary | `vibeguard-runtime/src/event_schema.rs:44-70` | decision 闭集含 `pass/warn/...`，status 另含 `skipped`；没有 `info` decision | suppressed telemetry 使用 `decision=pass,status=skipped`，不发明非法 enum |
| Runtime config | `vibeguard-runtime/src/runtime_config.rs:100-170` | nonnegative env → JSON path → default；config path 有明确 precedence | 新 key 复用同一 resolver，不另写一套环境/config 解析 |
| Key digest helper | `vibeguard-runtime/src/setup_support.rs:58-66` | 已提供 deterministic full/short SHA-256 text digest | 可对长度明确的 session/file tuple 生成 opaque `w14_key`，避免解析任意 session 文本 |
| Observability aggregation | `vibeguard-runtime/src/observe/aggregate.rs:33-66` | 所有 event 都计 decision/hook，reason 中 rule ID 不要求 negative decision | `pass/skipped` W-14 可保留 raw frequency，同时不进入 warn/escalate |
| Config distribution | `templates/vibeguard-config.json.example:1-14`, `templates/vibeguard-config.README.md:8-27`, `tests/test_setup.sh:97-113` | setup 首次 seed 示例 config，文档声明 env/config/default precedence | 新 key 必须可发现且不能覆盖存量用户 config |
| Focused production fixture | `tests/hooks/test_post_edit_w14.sh:8-30`, `tests/test_hooks.sh:40` | 当前只验证 absolute/relative overlap 与 worktree hint | 扩展现有真实 wrapper fixture，不新增重复 harness |
| Dormant compatibility helper | `hooks/_lib/post_edit_history.sh:139-155`, `tests/hooks/test_post_edit_churn.sh:17` | helper 定义 shell W-14，但生产 wrapper不 source；测试直接 source 其他 history helpers | 明确 forbidden scope：不能把未接线 helper 写成 production parity |

## 设计方案

### 1. 保持 candidate detection，新增独立 cooldown decision

`recent_overlap` 继续唯一负责 30 分钟 overlap candidate、peer session、agent/tool/hook 与
现有路径归一化。它返回 candidate 后，W-14 orchestration 才读取
`VIBEGUARD_W14_COOLDOWN_SECONDS` / `w14.cooldown_seconds`，默认 `3600`。
`cooldown_seconds == 0` 直接走现有 visible warning path，不扫描 prior cooldown evidence。

有向 key 的原始 tuple 为 `(current_session, peer_session, normalized_file)`。实现用无歧义的
长度前缀或 NUL 分隔序列交给现有 full SHA-256 helper，生成 64 字符 lowercase
`w14_key`；不能把 basename、agent name 或自由文本 reason 当 key。当前或 peer session
为空、`?`、`unknown` 时不生成可 suppress key。

### 2. 用专用 shown event 作为唯一 suppression 资格

首次展示 W-14 时，先/同时记录一个专用 evidence event：

- `hook=post-edit-guard`, `decision=warn`, `status=warn`；
- reason 以 `[W-14] overlap shown` 开头；
- detail 保留现有 file path 作为 `first_detail_path`，并追加 `||w14_key=<digest>`。

Cooldown lookup 只接受最后 500 条 history 中这个专用 shown event；legacy free-text W-14、
最终 aggregate warning event 与 suppressed event 均不能授权 suppression。匹配条件为同一
current session、精确 `w14_key`、可解析 timestamp，且 `0 <= age < cooldown_seconds`。
遍历时选择最近一次 valid shown evidence。这样升级前的旧记录最多多产生一次 warning，
不会因模糊文本解析而静默隐藏新冲突。

`suppressed` event 不作为下一次 shown evidence，所以每个窗口从实际可见 warning 开始，
不会因高频编辑无限续期。年龄等于 cooldown 或 timestamp 在未来时 lookup 返回 false。

### 3. suppression 必须先写审计 event，再省略可见 warning

命中有效 prior shown evidence 后，尝试 append：

- `decision=pass`, `status=skipped`；
- reason 前缀 `[W-14] overlap suppressed cooldown`；
- detail 继续携带 file path 与同一 `w14_key`。

只有 append 成功才不把 W-14 加入 `warnings`。写失败时改走完整 W-14 path；不能沿用当前
`append_history_event` 的 ignored-result 模式完成 suppression。可以为 W-14 增加返回
`Result` 的窄 helper，不要求借本 issue 重构 CHURN/W-15 的既有 logging。

若同 run 仍有其他 warning，最终 orchestrator 按这些 warning 决定输出/decision；若没有，
沿用正常 pass path。专用 suppressed event 是额外的审计 signal，但它自身不得增加
`count_prior_warn_events`，因为该函数只统计 `decision=warn`。

### 4. bounded-history 与异常输入一律 fail-open

不新增 state 文件，继续读取 `POST_EDIT_HISTORY_LINES=500`。以下情况都视为“没有 prior
shown evidence”：read error、坏 JSON 行、字段缺失、错误 hook/decision/reason、key 不匹配、
timestamp parse 失败/未来/过期、shown event 已离开 500 行窗口。这里的 fail-open 是
“candidate 已存在时再次展示 W-14”，不改变 candidate detection 在整个 log 不可读时的
现有行为。

500 行窗口是明确的 durability 边界，而不是“每小时绝对最多一次”的无限保证。高吞吐
导致 shown evidence 提前离开窗口时，额外 warning 是安全降级；不得扩大扫描到无界文件，
也不得用 suppressed event 代替 shown evidence。

### 5. config、distribution 与 observability

在示例 config 新增：

```json
"w14": { "cooldown_seconds": 3600 }
```

README 表格记录 env/config/default/`0` 语义。`runtime_config_cli` fixture 使用子进程验证
env > JSON > default、invalid env → JSON、wrong-type/negative JSON → default 和 `0`；不在
Rust unit test 内修改 process-global environment。setup fixture 只验证 fresh seed 包含 key，
并保留 existing config 不覆盖断言。

Suppressed reason 保持 `[W-14]` token，使 `observe/aggregate` 的现有 rule extractor 能将其
计入 W-14；新增 fixture 同时证明 decision count 为 pass、status 为 skipped、negative
rule-repeat/prior-warn 计数不增加。本次不更改 `reflection_digest.py` 的展示格式，也不声称
当前 digest 已有独立 suppressed-W14 区块。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 | `detect_w14` shown path、专用 shown event | `bash tests/hooks/test_post_edit_w14.sh`：first candidate 含完整 FIX，log 有 `[W-14] overlap shown` |
| B-002 | tuple digest、现有 normalize path | Rust unit fixture 比较 relative/absolute 同 key、A/B 与 B/A 不同 key |
| B-003 | prior shown lookup + injected `now` pure helper | Rust unit fixture 覆盖 inside、exact boundary、expired、suppressed-event-no-renewal |
| B-004 | `runtime_config_int_value` 调用、config CLI fixture | `cargo test --manifest-path vibeguard-runtime/Cargo.toml --test runtime_config_cli` 覆盖 precedence、invalid、default、0 |
| B-005 | suppressed append、event schema、observe aggregate | production hook fixture 断言无可见 W-14 且 JSONL 为 pass/skipped；Rust observe fixture 断言 W-14 rule count 保留 |
| B-006 | bounded lookup/filter | Rust fixtures 覆盖 missing/unknown session、bad JSON/key/ts、future ts、>500 行截断，均不 suppress |
| B-007 | result-bearing W-14 append path | focused injectable append-failure unit/integration fixture 断言 W-14 可见且不返回 silent pass |
| B-008 | exact key match | production/Rust fixtures 覆盖 other file、other peer、reverse pair、same agent 不共享 key |
| B-009 | warnings aggregation | production fixture 同时触发 repeat W-14 与一个现有 stateless warning，断言只隐藏 W-14、最终仍 warn |
| B-010 | templates/setup compatibility | `bash tests/test_setup.sh` 覆盖 fresh seed key 与 existing config 不覆盖；文档 validators 通过 |

## 数据流

1. Rust post-edit wrapper 解析 input 并收集 stateless warnings。
2. bounded history 通过现有 `recent_overlap` 产生 W-14 candidate；无 candidate 时不进入 cooldown。
3. resolver 读取 cooldown；`0` 直接展示。其余情况构造 current/peer/normalized-file digest。
4. lookup 在最近 500 行中查找同 session/key 的 valid shown evidence。
5. 无 evidence 或任何不可信状态 → 完整 W-14 + shown event；有效 evidence → 先 append
   pass/skipped telemetry，成功后才省略 W-14，失败则完整展示。
6. orchestrator 合并剩余 warnings，按既有逻辑输出并记录最终 hook event。

## 备选方案

- 新建 mutable watermark/state 文件：拒绝。增加锁、清理和损坏恢复面；bounded event evidence
  已足够实现安全降噪，超出窗口时再次 warning 是可接受 fail-open。
- 解析任意旧 W-14 reason：拒绝。自由文本与未知 session 容易误匹配，升级后多提示一次更安全。
- 用 `decision=info`：拒绝。schema 无此值；会破坏 typed consumers。
- 把 suppressed repeat 记为 `warn`：拒绝。仍会污染 warning rate、prior escalation 与 digest。
- 同步修改 shell helper：拒绝。当前生产 path 没有调用它，制造“声明-执行鸿沟”。
- 让 suppressed event 延长窗口：拒绝。高频编辑会永久隐藏 ownership reminder。

## 风险

- Security: session/path 只进入固定 digest 与结构化 event 参数；不拼 shell 命令、不 `eval`。
- Compatibility: 旧 event 无 `w14_key` 会 fail-open 多提示一次；旧 config 无 `w14` 自动默认。
- Performance: 在已读取的 500 条 Value 内单次逆序查找和一个 SHA-256；不新增全文件扫描。
- Maintenance: reason prefix、detail metadata、config key 与 stable IDs 是 contract，测试必须锁定。
- Data integrity: append 失败不能授权 suppression；坏/未来/截断 evidence 不得看起来像成功 cooldown。

## 测试计划

- [ ] Unit: tuple key、time boundary、history filtering、suppressed no-renewal、append failure、observe counting。
- [ ] Integration: `tests/hooks/test_post_edit_w14.sh` 通过真实 Rust wrapper 覆盖 first/repeat/
      different key/other warning/config 0/path normalization。
- [ ] Config/setup: runtime config CLI precedence 与 `tests/test_setup.sh` seed/no-overwrite。
- [ ] Rust gates: fmt、clippy `-D warnings`、check、完整 test，均使用 manifest path。
- [ ] Repository gates: hook validators、local contract、doc path/command、workflow packet、diff check。

## 回滚方案

运行时可先设置 `VIBEGUARD_W14_COOLDOWN_SECONDS=0` 或 config key `0` 恢复每次提示；该开关
不删除历史 event。代码回滚应原子移除 cooldown lookup、shown/suppressed metadata、config
distribution 与对应 tests，保留原有 recent-overlap detection 和完整 W-14 文案。
