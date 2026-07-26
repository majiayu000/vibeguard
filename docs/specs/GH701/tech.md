# Tech Spec — versioned host adapter registry 与第三 host proof

## Linked Issue

GH-701

## Product Spec

[`product.md`](product.md)

## Codebase Context

以下锚点均在 spec 写作时的 HEAD
`a685f8a0b85ce86d202b4b5d5d073920089bd4ac` 核实。

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Public first screen | `README.md:5`; `README.md:11`; `README.md:13`; `README.md:26` | PR #705 已提供 firewall 定位、demo GIF、当前 clone 安装与拦截清单；没有 benchmark 表 | 已完成 slice 必须保持；GH-699/GH-700 证据到位前不能提前改写事实 |
| Hook registration source | `hooks/manifest.json:2`; `hooks/manifest.json:3`; `hooks/manifest.json:45`; `hooks/manifest.json:51` | schema v1 manifest 明确自称 Claude/Codex source of truth，每个 hook 固定有 `claude`、`codex` 两个对象 | 当前模型不能通过 registry 加 host，需 versioned generalization |
| Manifest schema/reader | `schemas/hooks-manifest.schema.json:24`; `schemas/hooks-manifest.schema.json:33`; `scripts/lib/hooks_manifest.py:95`; `scripts/lib/hooks_manifest.py:120`; `scripts/lib/hooks_manifest.py:253` | schema 强制两列；reader 分别提供 `claude_specs` / `codex_specs`，validator 只遍历两种 platform | host capability、协议版本和 closed support 状态需统一 contract，同时保留现有 consumer |
| Canonical hook core | `vibeguard-runtime/src/hook_orchestrator.rs:22`; `vibeguard-runtime/src/hook_orchestrator.rs:69`; `vibeguard-runtime/src/hook_orchestrator.rs:75` | runtime 按 canonical `HookKind` 读取 stdin 并进入共享 hook checks/orchestrators | adapter seam 应在进入这里之前归一化、在 decision 输出之后编码，避免 core 分叉 |
| Claude wrapper/config | `hooks/run-hook.sh:8`; `hooks/run-hook.sh:15`; `hooks/run-hook.sh:16`; `hooks/run-hook.sh:115`; `scripts/setup/targets/claude-home.sh:396`; `scripts/setup/targets/claude-home.sh:424`; `scripts/setup/targets/claude-home.sh:590` | Claude wrapper 声明 source config/protocol 并调用共享 hooks；Claude target 负责 config、check 与 clean | generalization 必须保持 Claude profile 与配置 ownership |
| Codex input/output adapter | `hooks/run-hook-codex.sh:2`; `hooks/run-hook-codex.sh:66`; `hooks/run-hook-codex.sh:70`; `hooks/run-hook-codex.sh:116`; `hooks/run-hook-codex.sh:139`; `vibeguard-runtime/src/codex_hooks_adapter.rs:85` | Codex wrapper 识别 namespaced hook，规范化 input、调用 canonical hook，再把 Claude-style output 转回 Codex | 这是现有可复用 seam 证明，也是需要从 codex-specific 命名提炼的边界 |
| Codex install/check | `scripts/setup/targets/codex-home.sh:39`; `scripts/setup/targets/codex-home.sh:60`; `scripts/setup/targets/codex-home.sh:90`; `scripts/setup/targets/codex-home.sh:179` | target 合并 VibeGuard entries、保留第三方 hooks、启用 feature flag并检查 capability | proof host target 必须采用同样的 atomic ownership/check/clean contract，不能复制 core |
| Caller evidence | `vibeguard-runtime/src/hook_orchestrator_context.rs:72`; `vibeguard-runtime/src/hook_orchestrator_context.rs:87`; `vibeguard-runtime/src/hook_orchestrator_context.rs:94`; `vibeguard-runtime/src/hook_orchestrator_context.rs:100` | caller identity fallback 只识别 Claude/Codex，其余归为 unknown | 新 host 必须由 adapter 提供 bounded identity/protocol evidence，不能靠环境猜测 |
| Existing contract tests | `tests/test_manifest_contract.sh:319`; `tests/setup/install_flow_tests.sh:755`; `tests/setup/install_flow_tests.sh:761`; `tests/hooks/test_log_timer.sh:85` | 已覆盖 Codex manifest/schema 负例、安装结果、第三方 preservation 与 caller identity | 新 registry/proof host 需要同密度 fixtures，并保留现有回归 |

## 设计方案

### 1. 人工决策与 runtime pinning gate

实现开始前生成并审查一个 proof-host decision record，至少包含：

- `host_id`（稳定 `snake_case`）、官方产品/version、官方 hook/event 文档快照；
- config path/format、支持 event、blocking response、timeout 与 clean ownership；
- 最低/最高已验证 host protocol/version、VibeGuard runtime pin；
- 选择理由、未支持能力与真实 CLI fixture 的运行方式；
- `docs/gh701-readme-first-screen` 的 owner 与处置（delete / archive /
  owner-rebuild）。

若候选没有 native、可自动验证的 blocking event，则不能用它满足 B-006；维护者
必须选择其他 host 或缩小 issue，而不是用模拟输出替代。安装触发策略也必须在
decision record 中明确。当前未知项保持 human gate，不在 tech spec 中猜 host
协议或配置路径。

### 2. Versioned host adapter registry

- 将 hook manifest 从每个 hook 固定的 `claude` / `codex` 字段提升为 versioned
  host registry。registry 的 host entry 固定包含 `host_id`、adapter contract
  version、protocol/version range、config ownership、support 状态与 event
  mappings；support 枚举使用 B-004 的闭集。
- 保留 schema migration 的单向兼容：实现可以先让 reader 把现有 v1 两列规范化
  为 registry view，再由 v2 manifest 持久表达；禁止让 consumer 在多个地方各自
  解释 legacy shape。schema 与 reader 对缺字段、未知 host/support/event、
  duplicate mapping、`native` 但无 blocking response 等矛盾 fail loud。
- `hooks_manifest.py` 提供 generic `host_specs(manifest, host_id, profile)` 与
  registry/capability 查询；`claude_specs`、`codex_specs` 在迁移期仅作薄兼容
  consumer，最终生成的 Claude/Codex config 必须 byte/semantic equivalent。
- generated hook documentation 从 registry 渲染 capability matrix，不再只有
  Codex 单列；未支持能力原样显示，不能省略。

### 3. Canonical request/decision seam

- 在 runtime 建立 host-neutral、内部专用的 canonical request/decision 类型，
  字段仅覆盖 rule/guard core 真正消费的 event、tool class、tool input、
  session/cwd 与 enforcement metadata。host adapter 负责
  `decode_host_event -> CanonicalHookRequest` 和
  `CanonicalHookDecision -> encode_host_response`。
- 现有 `HookKind`、hook checks、orchestrators、rules、guards 与 decision
  semantics 保持单一实现。Claude 的现有 payload 可通过 identity adapter 进入；
  Codex 当前 normalize/output logic 改为 registry-bound adapter，但先用
  golden fixtures 锁定输出。
- proof host 只新增 host-specific decoder、encoder、wrapper/entrypoint 与
  config target；禁止在 proof adapter 中重新实现 rm/U-16/L1 等分类规则。
- decoder 对未知/malformed 输入使用 closed error category，禁止把 raw payload、
  prompt、command、content、parser free text 或 secret 写入日志。若已进入声明
  blocking 的 event，decode/encode/runtime failure 生成该 host 的 fail-closed
  response；无法建立可信 host/protocol 时不修改配置、不启动 core，并返回
  incompatible/unsupported。

### 4. Host lifecycle adapter

- 抽出 install/check/doctor/clean 的 shared lifecycle contract：discover 只读、
  plan 显示目标与 diff、apply 原子写入 VibeGuard-owned entries、verify 重新读取
  当前配置并运行 bounded probe、clean 只删除 managed identity。
- Claude/Codex target 逐步消费 shared contract，不改变各自配置格式。proof host
  target 在人工决策后选择具体文件路径；必须保留第三方 entries 与顺序，使用
  atomic temp+rename/restore，且写高上下文配置前执行用户确认策略。
- lifecycle evidence 使用闭集
  `active|partial|unsupported|incompatible|broken|not_installed`，绑定
  `host_id`、adapter/protocol/runtime version、config checksum 与 probe
  timestamp。仅 executable discovery 或历史 event 不得产出 `active`。
- 多 host 安装由各自 target 持有 config ownership；共享安装 state 记录 host
  entry 的稳定 identity。锁/原子提交防止并发写同一 config；中断留下的 temp
  文件不作为后续成功 evidence。

### 5. Proof host 与 README dependency gate

- 增加 protocol fixtures：common canonical golden fixture、host native event
  fixtures、deny/block response、unsupported event、malformed/secret sentinel、
  version mismatch 与 timeout。
- 在 disposable config/home 中覆盖 install twice、third-party preservation、
  config malformed/readonly、interrupted write、clean 与 Claude+Codex+proof-host
  任意顺序。
- 最终 acceptance 必须使用选定 host 的真实 released CLI/session 运行一次
  blocking event，并保存命令、host/runtime version、config evidence、输出与
  sanitized log；直接调用 adapter 只算 integration test，不算 B-006。
- README 保持 PR #705 baseline。只有 GH-699 的 released one-command install
  evidence 与 GH-700 的 released `vibeguard bench` evidence 各自可复现后，才把
  对应事实移入首屏；CI 对未完成依赖维持 absence assertion，避免占位数字或命令
  漂移成承诺。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 | README wording + generated capability matrix | `bash scripts/ci/validate-hook-behavior-docs.sh`；人工确认 README supported-host 列表与当前 registry evidence 一致 |
| B-002 | README first-screen dependency gate | `bash scripts/ci/validate-doc-paths.sh`；GH-699 未完成 fixture 下断言首屏仍是当前真实 install path |
| B-003 | README benchmark dependency gate | `bash scripts/ci/validate-doc-command-paths.sh`；GH-700 未完成 fixture 下断言无 headline effectiveness number |
| B-004 | host registry schema + validator | `bash tests/test_manifest_contract.sh`；`bash scripts/ci/validate-hooks-manifest.sh` |
| B-005 | canonical request/decision golden fixtures | `cargo test --manifest-path vibeguard-runtime/Cargo.toml`；`bash scripts/ci/validate-hooks.sh` |
| B-006 | proof-host adapter + real-host acceptance | 维护者在 disposable project 运行记录中的真实 host command，确认 native event → block/deny + fix instruction + matching sanitized event log |
| B-007 | capability registry + unsupported-event fixtures | `bash tests/test_manifest_contract.sh`；`bash tests/test_setup.sh` 的 proof-host unsupported-event fixture |
| B-008 | discovery/version/decode failure paths | `cargo test --manifest-path vibeguard-runtime/Cargo.toml`；`bash tests/test_setup.sh` |
| B-009 | decoder diagnostics + dual-log sentinel fixtures | `cargo test --manifest-path vibeguard-runtime/Cargo.toml`；`bash tests/test_setup.sh` 的 proof-host fixture 断言 secret sentinel 不在 project/global logs |
| B-010 | lifecycle upsert/clean ownership | `bash tests/test_setup.sh`；重复 install/clean fixture 检查 managed identity 与第三方顺序 |
| B-011 | atomic config writer + verification rollback | `bash tests/test_setup.sh` 的 malformed、readonly、interrupted-write fixtures |
| B-012 | host-scoped config/state/caller identity | `bash tests/test_setup.sh`；`bash tests/hooks/test_log_timer.sh`；多 host 顺序/并发 fixture |
| B-013 | adapter I/O/privacy review | `bash tests/test_behavior_eval.sh`；`git diff --check`；人工审查新增 adapter 无 network/telemetry/secret reader |
| B-014 | Claude/Codex compatibility consumers | `bash tests/test_setup.sh`；`bash tests/test_codex_runtime.sh`；`bash scripts/ci/validate-hooks.sh` |
| B-015 | registry compatibility resolver | `bash tests/test_manifest_contract.sh`；version below/above/unknown negative fixtures |
| B-016 | lifecycle transaction/retry | `bash tests/test_setup.sh`；kill-before-rename fixture 后重试并断言无 duplicate registration |
| B-017 | check/doctor bounded probe evidence | `bash tests/test_setup.sh`；对六个 evidence state 的 fixtures 运行 check/doctor |
| B-018 | README dependency gates + five-minute journey | `bash scripts/ci/validate-doc-command-paths.sh`；依赖均 released 后由维护者在 fresh home 计时执行 install → verify → real-host interception |

## 数据流

1. setup lifecycle 读取 registry 与已批准的 host selection，只读 discover 当前
   host/config/version，生成用户可见 plan。
2. apply 只把 VibeGuard-owned registration 原子合并进目标 host config；verify
   重新读取 config 并运行 bounded probe，写 host-scoped install evidence。
3. host 发送 native event；decoder 校验 host/protocol/version，把 event 归一化
   为 canonical request，并设置 bounded caller identity。
4. canonical request 进入现有 `HookKind` / orchestrator / rule/guard core；core
   产生 canonical decision。
5. encoder 把 decision 转为 host-native response；sanitized event 进入现有本地
   project/global logs，check/doctor 据当前 config+probe 报告状态。
6. docs generator 从同一 registry 输出 capability matrix；README 另由
   GH-699/GH-700 dependency evidence gate 控制安装与 benchmark 事实。

## 备选方案

- 为 proof host 复制 `run-hook-codex.sh` 与 core classification：拒绝。这样只能
  证明第三份 fork，不证明 adapter seam，并会造成 policy/privacy 漂移。
- 直接在现有 manifest 每个 hook 增加第三个固定字段：拒绝。下一 host 仍需 schema、
  reader、validator 与 docs 的横向改造，无法形成 registry contract。
- 用 generic shell command adapter 接任何未知 host：拒绝。无法证明 protocol、
  blocking semantics、config ownership 与 caller identity，会把 unsupported
  伪装成 native。
- 在 proof host 未确定前任选 opencode/Cursor/Gemini 实现：拒绝。官方 event
  surface、版本与权限是产品决策，必须先有维护者选择和当前文档证据。

## 风险

- Security：host payload 可能含 prompt、源码、命令与 token；decoder diagnostic
  必须 closed/structured，双日志 sentinel 锁定无泄露。高上下文 config 写入需要
  人工确认与原子回滚。
- Compatibility：manifest v2/registry 可能破坏 Claude/Codex config generation；
  先建立 v1 normalized view 与 golden outputs，再迁移 producer。
- Performance：adapter 不得新增网络 I/O 或第二次 core evaluation；protocol
  decode/encode 与 bounded probe 必须有 timeout 和 latency evidence。
- Maintenance：若 lifecycle、capability 或 decoder 继续按 host 散落，seam 会
  退化；registry/common traits 是单一 ownership，host 文件只含协议差异。
- Release coordination：README 最终形态跨 GH-699/GH-700；缺任一 released
  evidence 时保持窄而真实的现状。
- Branch ownership：`docs/gh701-readme-first-screen` 非 main ancestor；未决前
  任何复用、rebase、push、删除都可能覆盖 owner 意图。

## 测试计划

- [ ] Unit tests：registry/schema closed enums、duplicate/contradictory mapping、
  protocol/version resolver、canonical request/decision、malformed/privacy 与
  encode failure。
- [ ] Integration tests：Claude/Codex golden parity、proof-host native fixture、
  unsupported event、timeout/fail-closed、caller identity 与 project/global log。
- [ ] Setup tests：discovery、explicit confirmation、atomic apply/rollback、
  repeated install、third-party preservation、clean、multi-host order/concurrency、
  all six health states。
- [ ] Real host acceptance：released CLI/session 的 native blocking event 与
  five-minute fresh-home journey；模拟或 direct wrapper invocation 不能替代。
- [ ] Full focused verification：
  `cargo fmt --manifest-path vibeguard-runtime/Cargo.toml -- --check`、
  `cargo check --manifest-path vibeguard-runtime/Cargo.toml`、
  `cargo test --manifest-path vibeguard-runtime/Cargo.toml`、
  `bash scripts/ci/validate-hooks.sh`、
  `bash scripts/ci/validate-hooks-manifest.sh`、
  `bash tests/test_manifest_contract.sh`、
  `bash tests/test_setup.sh`、
  `bash tests/test_codex_runtime.sh`、
  `bash tests/test_behavior_eval.sh`、
  `bash scripts/ci/validate-doc-paths.sh`、
  `bash scripts/ci/validate-doc-command-paths.sh`、
  `bash scripts/local-contract-check.sh --quick`、`git diff --check`。

## 回滚方案

先保留 PR #705 首屏 baseline 与现有 v1 Claude/Codex manifest consumer。registry
迁移采用可独立回滚的 compatibility layer：proof host 出现问题时移除其 registry
entry、wrapper 与 managed config entry，并让 check/doctor 显示
`unsupported/not_installed`；不得删除第三方配置。若 v2 reader 影响 Claude/Codex，
恢复 v1 producer/consumer 与 golden config，但保留已经修正的 privacy、atomic
write 和 truthful capability 检查。任何回滚都不得把未知/不兼容 host 报告为
active，也不得用 README 宣称未由 GH-699/GH-700 证明的安装或 benchmark 事实。
