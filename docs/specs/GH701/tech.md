# Tech Spec — versioned host adapter registry 与第三 host proof

## Linked Issue

GH-701

## Product Spec

[`product.md`](product.md)

## Codebase Context

以下锚点在 round-3 修订开始时的 PR #712 HEAD
`568967c4f5d76e2f32e2a37734ed3f9d3b27c72b` 复核。

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Public first screen | `README.md:5`; `README.md:11`; `README.md:13`; `README.md:26` | PR #705 已提供 firewall 定位、demo GIF、当前 clone 安装与拦截清单；没有 required one-command block 或 benchmark 表 | PR #705 是四个 required blocks 中前两块完成的 partial baseline；额外块去留等待 H-004，GH-699/GH-700 证据到位前不能提前改写事实 |
| Hook registration source | `hooks/manifest.json:2`; `hooks/manifest.json:3`; `hooks/manifest.json:45`; `hooks/manifest.json:51` | schema v1 manifest 明确自称 Claude/Codex source of truth，每个 hook 固定有 `claude`、`codex` 两个对象 | 当前模型不能通过 registry 加 host，需 versioned generalization |
| Manifest schema/reader | `schemas/hooks-manifest.schema.json:24`; `schemas/hooks-manifest.schema.json:33`; `scripts/lib/hooks_manifest.py:95`; `scripts/lib/hooks_manifest.py:120`; `scripts/lib/hooks_manifest.py:253` | schema 强制两列；reader 分别提供 `claude_specs` / `codex_specs`，validator 只遍历两种 platform | host capability、协议版本和 closed support 状态需统一 contract，同时保留现有 consumer |
| Canonical hook core | `vibeguard-runtime/src/hook_orchestrator.rs:22`; `vibeguard-runtime/src/hook_orchestrator.rs:69`; `vibeguard-runtime/src/hook_orchestrator.rs:75` | runtime 按 canonical `HookKind` 读取 stdin 并进入共享 hook checks/orchestrators | adapter seam 应在进入这里之前归一化、在 decision 输出之后编码，避免 core 分叉 |
| Claude wrapper/config | `hooks/run-hook.sh:8`; `hooks/run-hook.sh:15`; `hooks/run-hook.sh:16`; `hooks/run-hook.sh:115`; `scripts/setup/targets/claude-home.sh:396`; `scripts/setup/targets/claude-home.sh:424`; `scripts/setup/targets/claude-home.sh:590` | Claude wrapper 声明 source config/protocol 并调用共享 hooks；Claude target 负责 config、check 与 clean | generalization 必须保持 Claude profile 与配置 ownership |
| Codex input/output adapter | `hooks/run-hook-codex.sh:2`; `hooks/run-hook-codex.sh:66`; `hooks/run-hook-codex.sh:70`; `hooks/run-hook-codex.sh:116`; `hooks/run-hook-codex.sh:139`; `hooks/_lib/codex_runner.sh:27`; `hooks/_lib/codex_runner.sh:56`; `hooks/_lib/codex_runner.sh:71`; `vibeguard-runtime/src/codex_hooks_adapter.rs:85` | Codex wrapper 识别 namespaced hook，normalizer 可输出多行并逐行调用 canonical hook，再把 Claude-style outputs 转回 Codex；当前没有 host-neutral batch result/priority contract | 现有多项循环证明 seam 必须是 Vec/batch，而不是单 request；aggregation、correlation 与 multi-block 需要从 codex-specific runner 提炼 |
| Codex install/check | `scripts/setup/targets/codex-home.sh:39`; `scripts/setup/targets/codex-home.sh:60`; `scripts/setup/targets/codex-home.sh:90`; `scripts/setup/targets/codex-home.sh:179` | target 合并 VibeGuard entries、保留第三方 hooks、启用 feature flag并检查 capability | proof host target 必须采用同样的 atomic ownership/check/clean contract，不能复制 core |
| Caller evidence | `vibeguard-runtime/src/hook_orchestrator_context.rs:72`; `vibeguard-runtime/src/hook_orchestrator_context.rs:87`; `vibeguard-runtime/src/hook_orchestrator_context.rs:94`; `vibeguard-runtime/src/hook_orchestrator_context.rs:100` | caller identity fallback 只识别 Claude/Codex，其余归为 unknown | 新 host 必须由 adapter 提供 bounded identity/protocol evidence，不能靠环境猜测 |
| Existing contract tests | `tests/test_manifest_contract.sh:319`; `tests/setup/install_flow_tests.sh:755`; `tests/setup/install_flow_tests.sh:761`; `tests/hooks/test_log_timer.sh:85` | 已覆盖 Codex manifest/schema 负例、安装结果、第三方 preservation 与 caller identity | 新 registry/proof host 需要同密度 fixtures，并保留现有回归 |

## 设计方案

### 1. Recommended proposals 与 approval gate

实现开始前必须取得 machine-readable decision record，但它只能记录维护者在
H-001 / H-002 / H-003 / H-004 上的明确选择，不能把本 spec 的 recommendation
当成 approval。

- Recommended H-001 为 Gemini CLI proof host。依据是其官方 hook 文档已经定义
  synchronous `BeforeTool`、structured deny 与 extension 内 hooks/hooks.json
  packaging（[Writing hooks](https://github.com/google-gemini/gemini-cli/blob/main/docs/hooks/writing-hooks.md)；
  [Extension hooks](https://github.com/google-gemini/gemini-cli/blob/main/docs/extensions/reference.md)）；
  record 必须固定官方文档 URL、Gemini CLI exact release、hook protocol
  snapshot/digest、支持/不支持事件与 blocking response。若维护者选择 opencode
  或 Cursor CLI，必须用等价 native blocking evidence 替换这些字段。
- Recommended H-002 为 `--host gemini` opt-in；discover 不写入，plan 后显示
  exact diff 并走高上下文确认。互斥的 auto-detect install 只有被明确批准后才能
  替代，不得两个策略同时 enabled。
- Recommended H-003 为删除 stale remote branch。唯一备选
  `readonly_retain` 必须在 decision record 里包含 `owner`、`expires_at` 与
  `expected_head: c77253b4...`；expiry 到达或 remote head 漂移即 gate failure。
- Recommended H-004 为 `strict_four`：首屏只渲染 positioning、demo、GH-699
  one-command 与 GH-700 benchmark，PR #705 的 clone install/拦截清单移到首屏
  后。互斥备选 `preserve_pr705_extras` 只有在 GH-701 issue acceptance 已由维护者
  同步、明确列出额外块与证据要求后才有效；record 必须绑定该 issue update 的
  immutable node、source URL、updated_at 与 acceptance digest。未选、双选或未
  同步均 blocked。

decision record 还固定 adapter contract version、host protocol range、config
path/format、runtime pin、真实 CLI fixture 命令和 stop conditions。缺任一批准
字段时 route 仍是 `needs_human`。

decision contract 的 planned fixed surfaces 为：

- schema：schemas/gh701-maintainer-decisions.schema.json
- collected record：artifacts/evidence/GH701/maintainer-decisions.json
- detached attestation bundle：
  artifacts/evidence/GH701/maintainer-decisions.intoto.jsonl
- read-only collector：checks/collect_gh701_maintainer_evidence.py
- offline gate：checks/gh701_decision_gate.py
- negative harness：tests/test_gh701_decision_gate.sh

record 对 H-001–H-004 各保存 closed `decision_id`/`selected_option`，以及 GitHub
`actor_login`、`author_association`（只接受 OWNER/MEMBER）、immutable
`source_node_id`、canonical `source_url`、`source_created_at`、
`approved_head_sha` 和 selection-specific fields。collector 只接受 PR/issue 编号，
从 GitHub API 只读查询 structured maintainer decisions；actor、association、
node/URL/head/time/option 均不得由 argv、环境变量或现有 artifact 注入。collector
必须运行在受保护 default-branch workflow，以 GitHub artifact attestation 对
record digest、collector workflow/ref/SHA 与 run identity 签名；实现分支不能
自称 trusted collector。

trusted workflow identity 固定为
`.github/workflows/gh701-maintainer-evidence.yml@refs/heads/main`，权限仅
`contents/issues/pull-requests: read` 与生成 attestation 所需的 `id-token: write`；
gate pin GitHub OIDC issuer、repository、workflow path、`refs/heads/main` 与
collector commit SHA，拒绝 pull-request ref 或同名 feature-branch workflow。
H-004 的 `preserve_pr705_extras` record 还包含 collector 从 issue acceptance
structured marker 解析出的 canonical JSON snapshot（闭集 block ID + evidence
gate）、issue node/URL/updated_at 与 JCS SHA-256；H-004 decision source 必须晚于
该 update 并引用同一 digest。离线 gate 与 renderer 都从 attested snapshot 重算
digest，不需要信任实现者提供的 issue body 副本。

offline gate 先验证 attestation bundle 的签名、certificate identity、workflow
ref/SHA、record SHA-256，再验证四项互斥选择、GitHub node/URL/time、association、
approved head 与当前 candidate 的 ancestry/binding。`preserve_pr705_extras` 额外
验证 issue acceptance digest/node。`checks/route_gate.py` 的 `plan_tasks` 与
`implement` 路由、以及 task manifest validator 都必须在本次调用中执行该 gate，
绑定 `decision_record_sha256`、`attestation_sha256` 与 candidate HEAD；禁止只读
缓存的 allowed JSON、口头批准或另一 HEAD 的 task plan。任一项未获批准时保持
`needs_human`，本 spec 不代替维护者选择。

### 2. Manifest v2：top-level hosts + per-hook mappings

`hooks/manifest.json` 升级为 `schema_version: 2`，结构责任明确分两层：

- top-level `hosts` 是以 `snake_case host_id` 为 key 的非空 object。每个 host
  必须声明 `adapter_contract_version`、`protocol_version_range`、
  `wrapper`、`config`（path kind、format、ownership）、closed capabilities 与
  lifecycle strategy。`claude`、`codex` 和获批 proof host 都在这里恰好一次。
- 仅 `kind: hook` 的 executable hook 带 `host_mappings`。mapping key 必须与
  top-level hosts **完全相等**，每个值声明 B-004 support、profiles 与有序
  event mappings；`native/partial` 必须至少有一个 event 和 encoder，
  `unsupported/not_applicable` 禁止携带可执行 command。
- `library`、`manual`、`git-hook` 不经 host dispatch，必须没有
  `host_mappings`。现有 `run-hook-codex` wrapper metadata 移到
  `hosts.codex.wrapper`；wrapper 不是可被 core 执行的 hook。manifest docs 对
  non-host entry 单独渲染，不伪造每-host `not_applicable` 行。
- validator 拒绝 undeclared/extra/missing mapping、重复 event+matcher、
  unknown profile、invalid protocol range、mapping 指向 non-hook、
  `native` 无 blocking encoder、unsupported 带 command，以及 host wrapper /
  canonical script identity 不一致。

`scripts/lib/hooks_manifest.py` 提供单一
`host_specs(manifest, host_id, profile)` / capability view。v1 reader 保留为
deprecated compatibility input：只把现有 Claude/Codex 两列规范化成 v2 in-memory
view，打印一次 bounded deprecation warning；所有 writer/generator 只输出 v2，
v1 不得声明第三 host/active proof。GH-701 不删除 v1 reader，未来删除必须新 spec。

Unknown matrix 固定为：

| Surface | Condition | Result | Config/core side effect |
| --- | --- | --- | --- |
| manifest validation | mapping host 未在 top-level hosts 声明 | contract error / nonzero | none |
| discovery | 检测到未注册 executable/config | `unsupported` | zero write, core not run |
| known adapter | host 已注册但 protocol/version 越界 | `incompatible` | zero write, core not run |
| blocking runtime | 已注册 blocking event 但 event/payload 无法 decode | fail-closed host response | sanitized failure log only |

### 3. Batch canonical adapter seam

adapter 接口不是一对一：

```text
decode_host_event(native_event) -> Result<Vec<CanonicalHookRequest>, AdapterError>
evaluate_batch(Vec<CanonicalHookRequest>) -> Vec<CanonicalHookDecision>
encode_host_response(batch, decisions) -> Result<HostResponse, AdapterError>
```

- `CanonicalHookRequest` 固定 `batch_id`、`request_id`、`request_index`、host /
  protocol identity、canonical event/tool、core 消费的 tool input、session/cwd
  与 enforcement metadata。一个 multi-file/apply-patch native event 按 host
  payload 顺序产生 N 个 requests；空 Vec 只允许 mapping 显式
  unsupported/not-applicable，其他空 batch 为 adapter error。
- core 严格按 request_index 依次运行现有 `HookKind`、checks、orchestrators、
  rules 与 guards，每项产生恰好一个 decision；proof adapter 不得复制
  rm/U-16/L1 classifier。每项日志带 batch/request/index，fix instruction 也绑定
  request_id。
- batch aggregator 固定优先级
  `block > correction > escalate > gate > warn > pass`。任一 block 存在时禁止
  auto-apply correction；primary decision 是最高优先级中 request_index 最小者。
  所有 block 都必须写 log，不能只写 primary；fixes 按 request_index 去重并以固定
  `MAX_FIX_ITEMS = 8`、`MAX_FIX_BYTES = 4096` 合并，primary fix 优先，其余保持输入
  顺序；不拆分一个 fix，超限项整体省略并记录 `omitted_fix_count` 与
  `fixes_truncated: true`，不得泄漏被省略 raw text。
- primary block 的第一条 fix 是例外安全契约：若缺失、编码失败或单项大于
  `MAX_FIX_BYTES`，不能按普通超限项省略。encoder 必须保持 block 并返回常量
  `PRIMARY_FIX_FALLBACK`（UTF-8 小于 256 bytes，只包含 closed reason class 与
  request_id，不包含 payload），同时设置 `primary_fix_fallback: true`、
  `fixes_truncated: true`、`omitted_fix_count` 和原 fix 的随机 `fix_id`；原文及
  content-derived digest 不得写入 response、project/global log 或 proof。其余
  oversize fix 仍整体省略。
- host 只允许一个 response 时，response 引用 primary request，同时携带有界 fixes
  与 `decision_count`；每条日志和 proof artifact 都能由 batch_id/request_id 回查。
  duplicate/missing/cross-batch ID、decision 数与 request 数不同或 response 无 primary
  log 都 fail loud。
- `batch_id` 在 adapter boundary 由 128-bit CSPRNG 生成且不含 payload；request_id
  固定为 batch_id 加 request_index，不能从 host-provided ID 直接复用。重试是新
  batch，并通过独立 `retry_of_batch_id` 关联，避免重复 ID 混淆旧日志。
- decoder/encoder 只持久化 closed diagnostics；raw payload、prompt、command、
  content、parser free text 与 secret sentinel 在 project/global logs、proof 与
  host response diagnostic 中均不得出现。

### 4. Transactional host lifecycle

shared lifecycle 必须实现完整状态机：

1. `discover`：只读解析 executable/version/config/permissions，输出当前 digest；
2. `plan`：基于 digest 生成 exact target、managed operations、第三方 preserved
   entries 与 candidate digest，不写磁盘；
3. `lock`：对全部目标 config 的 canonical absolute path 排序并取得 bounded
   exclusive locks；超时为可见失败；
4. `snapshot`：持锁后重新读取并验证 plan base digest，保存原始 bytes、mode 与
   digest，写 `pending` journal；TOCTOU drift 立即停止；
5. `apply`：在同目录写 temp、保持权限、flush/fsync 后 atomic rename；多文件按
   排序应用，每步更新 journal；
6. `probe`：重新读取 candidate，校验 semantic ownership、host protocol 与一次
   bounded native probe；
7. `commit`：仅 probe 成功后原子写 install evidence/committed marker，再删除
   snapshot/journal 并释放 locks；
8. `rollback`：任一 apply/probe 失败时，仅当当前 digest 等于本 transaction
   candidate 才从 snapshot 原子恢复；若外部 actor 已改写，保留当前内容并输出
   `broken/needs_human`、snapshot path 与 digest，禁止覆盖未知更改。

崩溃后下一次 lifecycle 在任何新 plan 前读取 journal：pre-apply journal 可安全
丢弃；部分/全部 apply 的 journal 按上述 digest rule rollback；已写 committed
marker 但未 cleanup 只做幂等 cleanup。相同 config 的 writer 串行，不同 config
可并行；全局排序避免多 config deadlock。clean 也使用相同 transaction，只删除
managed identity。`active` evidence 必须来自 committed transaction + current
bounded probe，历史 event/executable discovery 不足以证明 active。

journal/snapshot 固定写到用户本地 VibeGuard state 下的 transactions/<tx_id>，
目录 mode 0700、文件 mode 0600；snapshot bytes 不进入 stdout/stderr/event logs。
commit 后删除，external-drift needs-human 时保留并只输出 path+digest。

### 5. Deterministic README claim evidence

实现新增一个闭集 schema 和 gate：

- planned schema：schemas/readme-claim-evidence.schema.json
- fixed evidence paths：
  docs/evidence/GH699/readme-install.json 与
  docs/evidence/GH700/readme-benchmark.json
- planned validator：checks/readme_claim_gate.py
- planned negative harness：tests/test_readme_claim_gate.sh

两份 evidence 共用 required envelope：
`schema_version`、closed `claim_id`、`issue_number`、`source_head_sha`、
`release_tag`、`release_manifest_sha256`、`verified_at`、`inputs_digest`、
`rendered_claim` 与 claim-specific payload。source head 必须等于 validator 对该
claim 固定 input allowlist 执行“latest relevant change commit”得到的 commit，且是
current HEAD ancestor；`inputs_digest` 覆盖同一 producer/config/fixture allowlist，
不包含 evidence 自身，任何受影响输入变化都会同时造成 head/digest stale。validator
完全离线，读取 fixed path、schema、git ancestry/current inputs 与 README marker，
重新计算 latest relevant head、digest 和 rendered value；README 不能手写第二份
数字/命令。

- GH-699 payload 固定 argv、clean-home marker、platform、release payload/runtime
  digest、`repo_clone_present: false`、install/verify exit codes 与 bounded output
  digest；任一非零、clone、未覆盖 supported platform 或 release mismatch 拒绝。
- GH-700 payload 固定 released `vibeguard bench` argv、dataset/config/toolchain
  digest、sample counts、interception/false-positive/latency 的 numerator /
  denominator 与 rendered table digest；历史 Hook Latency CI、示例/空数据、手工
  数字或不可重算浮点值拒绝。
- negative fixtures 必须 schema-valid 后再触发 semantic gate，覆盖 missing path、
  wrong issue/claim、non-ancestor/stale head、changed inputs、wrong release、
  tampered output/rendered README、GH-699 clone/nonzero 与 GH-700 historical
  latency/zero-sample/digest mismatch。

README renderer 在读取 GH-699/GH-700 evidence 前必须执行 H-004 decision gate，
并把 `decision_record_sha256`、`attestation_sha256`、`approved_head_sha` 与
`selected_option` 写入 generated marker。`strict_four` 输出恰好四块：PR #705
定位、PR #705 demo、GH-699 one-command、GH-700 benchmark；当前 clone 安装与
拦截清单移到首屏之后。`preserve_pr705_extras` 则只允许额外输出 H-004 所绑定
GH-701 issue acceptance 中逐项命名且有 deterministic source 的 PR #705 块；
renderer 重算 acceptance digest，不能把任意现有 README 文本当作已批准额外块。
H-004 缺失/双选、head 或 digest 漂移时 renderer nonzero 且不写 README。

### 6. Fixed third-host proof gate

第三 host 使用以下固定 contract，不由实现者临时选路径：

- planned schema：schemas/host-adapter-proof.schema.json
- runtime artifact path：artifacts/evidence/GH701/third-host-proof.json
- maintainer witness schema：schemas/gh701-maintainer-witness.schema.json
- collected witness path：artifacts/evidence/GH701/maintainer-witness.json
- witness attestation bundle：
  artifacts/evidence/GH701/maintainer-witness.intoto.jsonl
- read-only collector：checks/collect_gh701_maintainer_evidence.py
- planned gate：checks/host_adapter_proof_gate.py
- planned negative harness：tests/test_host_adapter_proof_gate.sh

runtime proof required fields 包括 `schema_version: 1`、`issue_number: 701`、
非 `claude/codex` 的 `host_id`、exact host/protocol/adapter versions、
`candidate_head_sha`、`observed_at`、native `event_id` / event digest、
host binary SHA-256、VibeGuard runtime SHA-256、config digest、batch/request IDs、
primary/all decision summaries、fix correlation、project/global log digests 与
redaction result。redaction result 必须列出固定 secret sentinels 且
`matches: 0`，不能只写 boolean “safe”。runtime proof schema 明确禁止
maintainer actor、association、source URL/node 与 witnessed time 字段，防止
实现者把自填 witness 嵌入运行时输出。

proof 由真实 released host session 产生，direct wrapper/runtime/demo 不能生成
`proof_kind: native_session`。artifact 不提交进 source commit，所以 gate 可要求
`candidate_head_sha == git rev-parse HEAD`；proof 与 gate query 的间隔必须满足
`0 <= age <= 7 * 24h`，future timestamp 拒绝。

maintainer witness 是单独 artifact，由第 1 节同一个受保护 default-branch
collector 从 fresh GitHub review/comment 只读生成。collector 只接受 PR/issue
编号，从结构化 `observed_native_block` maintainer statement 取得
`source_node_id`、canonical `source_url`、actor、OWNER/MEMBER association、
`witnessed_at`、`candidate_head_sha`、`event_id` 与 runtime proof SHA-256；这些
字段不得由 CLI 参数、环境变量或 runtime proof填入。受保护 workflow 对 witness
digest、collector workflow/ref/SHA 与 run identity 生成 detached GitHub artifact
attestation；implementer 在 feature branch 运行同名脚本或手写 witness JSON 都
没有受信 certificate identity，必须被拒绝。

gate 分别 schema-validate runtime proof 与 witness，再离线验证 witness
attestation 的签名/certificate identity/workflow SHA/record digest，最后绑定
immutable node、canonical URL、同一 event_id、exact candidate head、runtime proof
SHA 与时间顺序；`observed_at <= witnessed_at <= gate_time` 且两者均在 7×24 小时
freshness window。之后再验证 host/runtime file SHA、当前 config digest、
event/log/fix correlation 与 dual-log redaction。negative fixtures覆盖 missing
witness、embedded/self-filled witness、untrusted workflow/certificate、tampered
attestation、wrong node/association、stale/future、wrong head/event/proof SHA、
host/runtime/config digest drift、duplicate IDs、missing secondary block、secret
sentinel、direct-wrapper proof。只有 gate allowed 才能把 proof host 标为 active 或
声明 GH-701 third-host slice complete。allowed 后只上传 sanitized runtime proof、
witness 与 attestation bundle 作为 exact-head CI/PR artifacts，并在 gate result
记录各自 SHA-256；source tree 不提交 runtime artifact，也不上传 raw
config/payload/log content。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 | README wording + generated capability matrix | `bash scripts/ci/validate-hook-behavior-docs.sh`；人工确认 README supported-host 列表与当前 registry evidence 一致 |
| B-002 | H-004-aware README required-block renderer + GH-699 gate | `bash scripts/ci/validate-doc-paths.sh`；README claim negative fixture 断言 PR #705 只满足 positioning/demo required blocks，缺 GH-699 evidence 时仍显示当前真实 install path |
| B-003 | GH-700 evidence renderer/gate | `bash scripts/ci/validate-doc-command-paths.sh`；README claim negative fixture 断言缺 evidence、历史 latency、zero-sample 均不生成 benchmark 表 |
| B-004 | host registry schema + validator | `bash tests/test_manifest_contract.sh`；`bash scripts/ci/validate-hooks-manifest.sh` |
| B-005 | batch canonical request/decision golden fixtures | `cargo test --manifest-path vibeguard-runtime/Cargo.toml`；同一 fixture 的 Claude/Codex/proof-host common decision parity |
| B-006 | separate runtime proof + trusted maintainer-evidence gate | 运行 host-adapter proof gate；受保护 collector witness 绑定真实 native event、exact HEAD、deny/fix 与 matching sanitized dual logs |
| B-007 | capability registry + unsupported-event fixtures | `bash tests/test_manifest_contract.sh`；`bash tests/test_setup.sh` 的 proof-host unsupported-event fixture |
| B-008 | unknown matrix + decode failure paths | `cargo test --manifest-path vibeguard-runtime/Cargo.toml`；`bash tests/test_setup.sh` 覆盖 unknown executable/protocol/event 四类结果 |
| B-009 | decoder diagnostics + dual-log sentinel fixtures | `cargo test --manifest-path vibeguard-runtime/Cargo.toml`；`bash tests/test_setup.sh` 的 proof-host fixture 断言 secret sentinel 不在 project/global logs |
| B-010 | transactional lifecycle upsert/clean ownership | `bash tests/test_setup.sh`；重复 transaction/clean fixture 检查 managed identity、第三方 bytes/order 与 config digest |
| B-011 | snapshot/apply/probe/rollback | `bash tests/test_setup.sh` 的 malformed、readonly、phase-failure、probe-failure 与 external-drift fixtures |
| B-012 | ordered locks + host-scoped state/caller identity | `bash tests/test_setup.sh`；`bash tests/hooks/test_log_timer.sh`；同 config contention、多 config reverse-order 与 multi-host fixtures |
| B-013 | adapter I/O/privacy review | `bash tests/test_behavior_eval.sh`；`git diff --check`；人工审查新增 adapter 无 network/telemetry/secret reader |
| B-014 | v2 Claude/Codex compatibility consumers | `bash tests/test_setup.sh`；`bash tests/test_codex_runtime.sh`；v1/v2 golden configs semantic equivalent |
| B-015 | registry protocol/runtime compatibility resolver | `bash tests/test_manifest_contract.sh`；version below/above/unknown negative fixtures |
| B-016 | journal crash recovery/retry | `bash tests/test_setup.sh`；每个 transaction phase kill fixture 后重试，断言 safe rollback 或 needs_human 且无 duplicate registration |
| B-017 | check/doctor bounded probe evidence | `bash tests/test_setup.sh`；对六个 evidence state 的 fixtures 运行 check/doctor |
| B-018 | H-004-aware README renderer + dependency gates + journey | decision gate 与 README-claim gate；`strict_four`/`preserve_pr705_extras` positive fixtures 精确渲染，未选/双选/acceptance digest mismatch nonzero；维护者在 fresh home 计时 install → verify → real-host interception |
| B-019 | decoder `Vec<CanonicalHookRequest>` | `cargo test --manifest-path vibeguard-runtime/Cargo.toml` 的 empty/single/multi-file ordered batch fixtures |
| B-020 | deterministic batch aggregator | `cargo test --manifest-path vibeguard-runtime/Cargo.toml` 的 all pairwise mixed decisions、multi-block、fix dedupe/cap fixtures |
| B-021 | batch/request/log/fix correlation | `cargo test --manifest-path vibeguard-runtime/Cargo.toml`；duplicate/missing/cross-batch ID 与 missing-primary-log negative fixtures |
| B-022 | v2 top-level hosts/per-hook mappings/non-host entries | `bash tests/test_manifest_contract.sh`；`bash scripts/ci/validate-hooks-manifest.sh` 的 key-set、non-host、contradiction negative fixtures |
| B-023 | v1 compatibility/deprecation | `bash tests/test_manifest_contract.sh`：v1 read+warning、v1 third-host reject、v2-only writer 与 v1/v2 Claude/Codex golden parity |
| B-024 | complete unknown matrix | `bash tests/test_manifest_contract.sh`；`bash tests/test_setup.sh`；`cargo test --manifest-path vibeguard-runtime/Cargo.toml` 分别固定 contract/discovery/protocol/runtime outcomes |
| B-025 | full lifecycle phase machine | `bash tests/test_setup.sh`：每 phase success/failure、TOCTOU drift、commit-only-after-probe、无 false active evidence |
| B-026 | lock/deadlock/crash/external-drift recovery | `bash tests/test_setup.sh`：bounded contention、canonical lock order、partial apply crash、candidate-safe rollback、external drift needs_human |
| B-027 | GH-699/GH-700 evidence schema/gate | 运行 README-claim negative harness；schema-valid semantic negative matrix 全部 nonzero，两个 valid fixtures 精确渲染 README |
| B-028 | separate fixed runtime-proof/witness schemas and gate | 运行 host-adapter proof negative harness；valid current-head runtime proof + attested witness allowed，stale/future/wrong SHA/digest/event/redaction/witness fixtures nonzero |
| B-029 | stale branch closure gate | read-only `git ls-remote` fixture：deleted allowed；readonly retain 仅 exact head + owner + unexpired UTC allowed；new push/third state/missing/expired field blocked |
| B-030 | H-004 mutually exclusive decision + issue acceptance binding | decision-gate fixtures：strict-four allowed；preserve only with matching immutable issue node/digest allowed；missing/double/unsynced/re-witness-missing blocked |
| B-031 | fixed decision schema/record/attestation + route/task binding | `bash tests/test_gh701_decision_gate.sh`；route `plan_tasks`/`implement` 与 task-manifest fixtures 对 current HEAD/digests allowed，self-filled/stale/cached/wrong-head records blocked |
| B-032 | protected read-only maintainer evidence collector | host-proof harness 验证 separate runtime/witness artifacts、trusted workflow attestation、node/event/head/time/proof-SHA binding；embedded or implementer-filled witness blocked |
| B-033 | closed oversize-primary fix fallback | `cargo test --manifest-path vibeguard-runtime/Cargo.toml` 的 schema-valid primary fix 4097-byte fixture：response remains block、bounded constant fallback/flags/original fix_id present、raw/content digest absent from response/log/proof |

## 数据流

1. protected collector 只读取得 H-001–H-004 decisions，decision gate 离线验证
   attestation/head/digest；route 与 task gate allowed 后，lifecycle 才读取已批准
   selection 与 manifest v2 registry，只读 discover 并生成绑定 base digest 的
   exact plan。
2. ordered locks + snapshots 建立 pending transaction；apply candidate 后运行 native
   probe，成功才 commit active evidence，失败按 digest-safe rule rollback。
3. host 发送 native event；decoder 校验 host/protocol/version，产生带 batch/request
   correlation 的 ordered canonical request Vec。
4. core 按 index 独立判定每个 request 并逐项写 sanitized log；aggregator 按固定
   priority 选 primary、保留所有 blocks、合并有界 fixes。
5. encoder 输出唯一 host-native response；runtime proof producer 只对照 response、
   project/global logs 与 binary/config digests 生成 runtime artifact。受保护
   collector 另行获取 fresh GitHub maintainer witness 和 attestation；proof gate
   离线绑定 node/event/head/time/proof digest。
6. README-claim gate 分别读取 GH-699/GH-700 tracked evidence，重算 inputs/rendered
   digest；renderer 同时消费 approved H-004：strict 模式形成恰好四块，preserve
   模式只加入 issue acceptance 明确批准的额外块。

## 备选方案

- 为 proof host 复制 `run-hook-codex.sh` 与 core classification：拒绝。这样只能
  证明第三份 fork，不证明 adapter seam，并会造成 policy/privacy 漂移。
- 直接在现有 manifest 每个 hook 增加第三个固定字段：拒绝。下一 host 仍需 schema、
  reader、validator 与 docs 的横向改造，无法形成 registry contract。
- 让 decoder 只返回一个 canonical request：拒绝。Codex apply-patch 与第三 host
  multi-file event 会丢请求，无法定义 mixed decision 或多个 block 的证据。
- “最后一个 decision 胜出”或只记录 primary block：拒绝。输入排序会改变安全结果，
  secondary blocks/fixes 无法审计。
- 用 generic shell command adapter 接任何未知 host：拒绝。无法证明 protocol、
  blocking semantics、config ownership 与 caller identity，会把 unsupported
  伪装成 native。
- 用 temp+rename 但没有 lock/journal/probe：拒绝。单文件原子替换不能处理
  plan/apply TOCTOU、多文件 partial commit 或 crash recovery。
- 由 README 手工复制 GH-699/GH-700 命令/数字：拒绝。source evidence 与 rendered
  claim 会漂移，必须由单一 validator 重算。

## 风险

- Security：host payload 可能含 prompt、源码、命令与 token；decoder diagnostic
  必须 closed/structured，双日志 sentinel 锁定无泄露。高上下文 config 写入需要
  人工确认、ordered lock、digest-safe rollback；proof 记录 only digests/closed
  summaries，不记录 raw payload。
- Compatibility：manifest v2/registry 可能破坏 Claude/Codex config generation；
  v1 normalized compatibility view、deprecation warning 与 v1/v2 golden outputs
  必须先落地，GH-701 不删除 v1 reader。
- Performance：adapter 不得新增网络 I/O 或第二次 core evaluation；protocol
  decode/encode、N request evaluation 与 bounded probe 必须有 batch-size/timeout/
  latency limits 和 evidence。
- Maintenance：若 lifecycle、capability 或 decoder 继续按 host 散落，seam 会
  退化；registry/common traits 是单一 ownership，host 文件只含协议差异。
- Release coordination：README 最终形态跨 GH-699/GH-700；缺任一 released
  evidence、H-004 approval 或 validator mismatch 时保持窄而真实的 partial
  baseline；不得从 README 现状猜测 strict/preserve mode。
- Recovery：external writer 在 apply 后改 config 时不能安全自动 rollback；必须
  保留外部内容、snapshot/digests 并 needs_human，不能用“恢复旧配置”覆盖新更改。
- Branch ownership：stale branch 只能 approved delete，或 readonly retain with
  owner+expiry；任何新 push 使 closure gate 失败。
- Evidence authority：实现者可产生 runtime proof，但不能产生维护者决策/witness
  的可信身份。只接受受保护 default-branch collector attestation；collector
  identity、record/witness digest、node/event/head/time 任一不匹配都 fail closed。

## 测试计划

- [ ] Unit tests：v2 registry constraints、v1 compatibility、complete unknown
  matrix、batch empty/single/multi、pairwise decision priority、multi-block、
  correlation/fix cap、oversize primary closed fallback、malformed/privacy 与
  encode failure。
- [ ] Lifecycle tests：discover/plan/lock/snapshot/apply/probe/commit/rollback 每阶段
  故障、TOCTOU、lock contention/deadlock order、crash journal、external drift、
  repeated install、third-party preservation 与 clean。
- [ ] Evidence tests：README-claim schema/gate 的 GH-699/GH-700 positive/negative
  matrices；H-004 strict/preserve/unsynced issue matrix；decision record 与
  separate host-proof/witness 的 exact head/7-day/node/event/SHA/config/redaction/
  attestation matrix；negative fixtures 先通过 schema 再被 semantic gate 拒绝。
- [ ] Real host acceptance：获批 released CLI/session 的 native multi-request
  blocking event 与 fresh-home journey；模拟、direct wrapper/runtime/demo 不能
  生成 proof kind 或替代 maintainer witness。
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

回滚前必须对 rollback target HEAD 重新运行 decision gate，并读取获批 H-004；
不得默认使用本 spec 推荐的 `strict_four`。`strict_four` 回滚保持 PR #705 的
positioning/demo 两个首屏块并把其余 partial-baseline 内容留在首屏之后；
`preserve_pr705_extras` 回滚还必须保留其绑定 issue acceptance 明确列出的额外块。
H-004 缺失、过期或与 target HEAD/acceptance digest 不匹配时停止为
`needs_human`，不得猜测布局或重写 README。两种模式都保留 v1 Claude/Codex read
compatibility。proof host 出现问题时，用 lifecycle transaction 移除其 registry
entry/wrapper/managed config，并让 check/doctor 显示
`unsupported/not_installed`；不得删除第三方配置。若 v2 reader 影响 Claude/Codex，
恢复 v1 input normalization + golden config，但 writer 继续停止生成损坏的 v2，
并保留 privacy、journal/digest-safe rollback 与 truthful unknown matrix。

GH-699/GH-700 任一 evidence/gate 失败时只移除对应 README generated block，不
删除仍有效的另一块或 approved H-004 要求保留的 PR #705 块；禁止恢复手写 claim。
third-host proof 或独立 maintainer witness/attestation 失效时撤销 active/完成声明，
不伪造刷新 timestamp。回滚 stale branch decision 也只能在 approved `deleted` 与
`readonly_retain(owner, expiry)` 两态间重新获批，不能恢复可写 branch。
