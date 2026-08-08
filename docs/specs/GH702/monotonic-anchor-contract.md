# Monotonic Anchor Contract — External CAS 与本地镜像恢复

## Linked Issue

GH-702

## Status

Draft。本文是 [`product.md`](product.md) 与 [`tech.md`](tech.md) 的 supporting contract；atomic launch
wire/process-template 子合同只由 [`atomic-launch-machine-contract.md`](atomic-launch-machine-contract.md)
定义；identity-pointer union 与 executable negative corpus 只由
[`anchor-identity-verification-contract.md`](anchor-identity-verification-contract.md) 定义。本文不批准
backend、平台、provisioning 或 trust 选择，也不创建 implementation tasks。

## Scope

本文只定义 policy generation、installation generation 和 trusted-time
`clock_epoch/sequence/high_water` 三类 monotonic leaf 的共同持久化协议。目标是同时保证：

- external authenticated root 下各自独立单调的 per-leaf register 是唯一 anti-rollback authority；
  HOME 内 pointer、floor、state 和 attestation 都只是 mirror；
- external CAS 已成功、进程却在任一本地写入前崩溃时，可从预写 intent 确定性 roll forward，
  不会永久停在 `runtime_guard_unavailable`；
- target leaf authority 未前进时可以安全放弃 prepared mirror；已前进后绝不 rollback 该 leaf；
- 同一 root 的其他 leaf 可以合法并发推进，不能使本 leaf 的 lost-response recovery 误报
  `needs_repair`；
- runtime/management 不从缺失记录、目录扫描、较大 generation 或“看起来最新”的时间猜状态。

## Closed identities and records

每次操作以 exact `anchor_operation_id` 绑定下列 identity：

- `backend_identity = (backend_kind, backend_instance_id, device_key_digest, protocol_version)`；
- `root_identity = (root_id, root_schema_version, principal_id, core_installation_id)`，是稳定 trust/
  provisioning container identity，不是所有 leaf 共用的 CAS version；
- `leaf_identity = policy/evaluation | installation/<installation_scope_id> |
  time/<installation_scope_id>`；
- `per_leaf_authority_id` 使用下列 semantic v1 body 与 exact preimage，不是位置 tuple：

```text
per_leaf_authority_body = {
  schema_version: 1,
  root_identity: {root_id, root_schema_version, principal_id, core_installation_id},
  leaf_identity: {leaf_kind: policy_evaluation|installation|time,
                  installation_scope_id: string|null}
}
per_leaf_authority_id = sha256(
  UTF8("vibeguard.gh702.anchor-leaf-authority.v1\0") ||
  UTF8(RFC8785_JCS(per_leaf_authority_body)))
```

  `installation_scope_id` 仅 `policy_evaluation` 时必须为 null，其他 kind 必须为 non-empty
  canonical ID；body closed，`schema_version` 是 digest 语义，字段名、null discriminant、domain bytes
  或 JCS bytes 任一变化都产生不同 ID，tuple/alias/省略字段均不接受；
- current leaf 的 stable state 与 refreshable proof 分离：

```text
from_leaf_state = {per_leaf_authority_id, leaf_counter, leaf_value_digest}
from_leaf_proof = {backend/root/per-leaf identity, from_leaf_state, nonce, signature, ...}
```

  `from_leaf_proof` 必须按 H-010 backend profile 验证并 exact cross-bind stable state，其 canonical
  envelope digest 记为 `from_leaf_proof_digest`；proof nonce/signature 刷新不改变 state equality，
  proof bytes/digest 不进入 CAS precondition、target authorization、mirror 或 phase identity；
- pre-CAS target 只含确定性数据：

```text
target_leaf_body = {schema_version: 1, target_leaf_counter, target_leaf_value_digest}
target_leaf_digest = sha256(
  UTF8("vibeguard.gh702.anchor-target-leaf.v1\0") ||
  UTF8(RFC8785_JCS(target_leaf_body)))
target_leaf = {target_leaf_body, target_leaf_digest}
```

  counter 必须是该 leaf authority 认可的唯一 successor；`post_cas_backend_attestation` 只能由 CAS
  成功响应或后续 authenticated current read 产生，并 exact 绑定 backend/root/per-leaf authority、
  `from_leaf_state`、`target_leaf_body`、`target_leaf_digest`、operation 与 authorization；其 verified envelope digest
  记为 `post_cas_backend_attestation_digest`，不得进入任何 pre-CAS target/authorization/intent/mirror；
- `authorized_operation_digest`、`target_authorization_digest` 与 `authorizer_key_id`；
- `mirror_generation_id`、mirror `file_digest`、previous mirror generation/digest；
- owner transaction/runtime operation、policy/installation generation 与适用 lock/fence identities。

## Per-leaf concurrency and target authorization

本合同选择 **independent authenticated per-leaf authority**。external root 必须为每个
`per_leaf_authority_id` 暴露独立、non-rollback、atomic successor CAS register；CAS precondition 和
recovery equality 只使用 exact `root_identity + per_leaf_authority_id + from_leaf_state/target_leaf`。backend
可以在 receipt 中报告 aggregate root epoch/digest 供审计，但它不是 leaf CAS precondition、phase digest
或 recovery equality 的一部分。另一个 policy/install/time leaf 推进 aggregate root 时，本 leaf 的
attestation 仍可验证，旧 mirror 与 lost response recovery 必须继续按 stable state exact from/target 判定。
无法提供独立 authenticated leaf register、只能比较一个全局 mutable root digest 的 backend 不满足
H-010 official-block conformance。

同一 leaf 仍由 Core service recovery-first 串行化：unfinished intent 完成 barrier 前不得接受该 leaf
的下一 successor。若 fresh proof 验证后显示 stable state exact from，CAS 尚未发生；exact target 则
roll forward；既非 from 也非 target 才是 same-leaf divergence 并进入 `needs_repair`。其他 leaf 的
counter/digest/attestation 变化，以及本 leaf 同 state 的 fresh nonce/signature proof，必须由 fixture
注入且不能改变这三个结果。

客户端没有 target authority。本地可重算 payload/hash、durable intent 或 authenticated caller 都不能
单独授权 CAS。客户端只提交下列 closed `authorized_operation` union；Core service 验证 IPC peer/session、当前
H-010/evaluation-policy identity、fresh proof 对 stable from state 的 binding、lock/fence 与 subject，
再按 leaf kind 重构 target 并逐字段验证唯一合法 transition：policy/install 是 exact successor +
approved committed identity，time 是同 epoch sequence/high-water monotonic advance，clock reconciliation
另需 approved evidence 且 exact epoch successor。

```text
authorized_operation = one_of_exact(
  {schema_version: 1, variant: "advance_policy_evaluation",
   from_policy_generation, target_policy_generation, committed_policy_digest,
   evaluation_policy_digest},
  {schema_version: 1, variant: "advance_installation_generation", installation_scope_id,
   from_installation_generation, target_installation_generation, committed_installation_digest},
  {schema_version: 1, variant: "advance_time_high_water", installation_scope_id,
   clock_epoch, from_sequence, target_sequence, from_high_water, target_high_water},
  {schema_version: 1, variant: "reconcile_clock_epoch", installation_scope_id,
   from_clock_epoch, target_clock_epoch, reconciliation_evidence_digest}
)
authorized_operation_digest = H(
  "vibeguard.gh702.authorized-anchor-operation.v1", 1, authorized_operation)
```

每个 object 的 key set 必须 exact；generation/sequence/epoch target 必须是其 from 的唯一 successor，
time high-water 不得下降。variant 唯一决定 `operation` literal 与 leaf kind。Core 从该 body 重构
`target_leaf_body.target_leaf_value_digest`；调用方提供的 target/operation/digest 只能作为必须 byte-equal
的断言，不能选择 transition。

服务生成 closed `target_authorization` envelope：

```text
digest_domain = "vibeguard.gh702.anchor-target-authorization.v1"
authorization_body = {
  backend_identity, root_identity, per_leaf_authority_id,
  from_leaf_state, target_leaf_body, target_leaf_digest,
  anchor_operation_id,
  operation: advance_policy_evaluation|advance_installation_generation|
             advance_time_high_water|reconcile_clock_epoch,
  authorized_operation_digest,
  h010_decision_artifact_digest, evaluation_policy_digest,
  authoritative_policy_generation, policy_validity_evidence_digest,
  lock_fence_identity, authorizer_key_id, authorization_nonce, authorization_expires_at
}
target_authorization_digest = sha256(RFC8785_JCS({digest_domain, schema_version, authorization_body}))
target_authorization = {digest_domain, schema_version, authorization_body,
                        target_authorization_digest, signature}
```

digest preimage 排除 sibling digest/signature；signature 必须由 H-010 provisioned、root-bound Core/backend
authorizer key 验证。backend 若不能原生验证 signature，Core service 必须是 backend exclusive principal，
并在调用 CAS 紧邻前重验 signature、expiry/nonce、policy identity 与逐 leaf transition。intent、mirror、
CAS request、backend receipt 和 phase chain 都绑定 exact authorization digest；无效、过期、自签、wrong
leaf/from/target/policy/key 或 operation reconstruction mismatch 必须在 CAS 前 nonzero，不能只记录 warning。
`operation` 是 authorization body 的 required literal discriminant；Core 必须从 closed
`authorized_operation` 的 variant 重构它，并验证该 variant 的 canonical digest exact 等于
`authorized_operation_digest`。四个值分别只允许 policy、installation、同 epoch time advance 与
clock-epoch reconciliation 的唯一 transition；跨 leaf 使用、alias、缺失或未知值均在签名/CAS 前拒绝。

本地 closed persistence set 新增：

```text
anchor/
  intents/<anchor_operation_id>.json       durable pre-CAS intent
  commits/<anchor_operation_id>.json       append/replace commit journal
  mirrors/<leaf_storage_key>/
    current.json                           durable mirror-generation pointer
    generations/<mirror_generation_id>.json
```

mirror generation 使用 closed envelope。`mirror_body` 不含自己的 digest；outer `schema_version` 是
envelope 的 semantic version，不能只作为 parser hint。prepared target
`mirror_body` 只保存 deterministic `target_leaf_body`/`target_leaf_digest`、generation identity、leaf
payload 与 previous generation/digest，不保存尚不存在的 `post_cas_backend_attestation`；该 attestation
及其 digest 只能进入 post-CAS commit journal。current mirror 的 external state 来自 immutable mirror；
journal proof 只记录 CAS/recovery observation，fresh proof refresh 不得改写 mirror 或改变 state equality。
`file_digest = sha256(UTF8(RFC8785_JCS({schema_version, mirror_body})))` 是 envelope 中与 body 同级的
sibling。完整文件必须 byte-equal `RFC8785_JCS({schema_version, mirror_body, file_digest})`，reader
拒绝 duplicate/unknown key、非 JCS bytes 或重算不等；digest preimage 包含 exact outer version + body，
只排除 sibling `file_digest` 自身。文件一旦 file+directory fsync 就
byte-immutable，不含 phase、receipt、selected flag 或 barrier flag，也不得原地改写。每个 leaf 至少
保留 current 与 immediately previous 两个 digest-valid generations；target barrier 完成前不得删除
previous，下一成功 successor barrier 前也不得删除 target 的 recovery predecessor。

phase 只存在于 durable intent 预先绑定的合法 digest、commit journal 的 predecessor-linked record，
以及 selected pointer 所引用的 `selected_phase_digest`。下式的 `H` 严格表示
`sha256(UTF8(RFC8785_JCS(closed_phase_object)))`；每个 object 都有不同 `digest_domain`、literal `phase`、
`schema_version` 与 named identity fields，不能使用位置 tuple 或字符串拼接。intent 在 CAS 前预计算
并绑定以下唯一链；这些 digest 都只使用 CAS 前已知的 exact identity，不吸收 backend 的随机
receipt bytes、wall clock、filename 或进程内状态：

四个 phase 的 `digest_domain` 是下列 exact ASCII literal，`phase` 是同名 literal，`schema_version`
恒为整数 `1`。每个 `closed_phase_object` 的 key set 必须与下表 exact 相等（无多余、无缺失），
JCS 排序由 RFC 8785 决定，实现不得追加字段或改写 literal：

| `phase` | `digest_domain` (exact ASCII) |
|---|---|
| `prepared` | `vibeguard.gh702.anchor-phase-prepared.v1` |
| `external_advanced` | `vibeguard.gh702.anchor-phase-external-advanced.v1` |
| `selected` | `vibeguard.gh702.anchor-phase-selected.v1` |
| `barrier_complete` | `vibeguard.gh702.anchor-phase-barrier-complete.v1` |

```text
prepared_phase_digest = sha256(UTF8(RFC8785_JCS({
  digest_domain: "vibeguard.gh702.anchor-phase-prepared.v1", phase: "prepared", schema_version: 1,
  operation, target_authorization_digest, mirror_file_digest, from_leaf_state,
  target_leaf_body, target_leaf_digest })))

external_advanced_phase_digest = sha256(UTF8(RFC8785_JCS({
  digest_domain: "vibeguard.gh702.anchor-phase-external-advanced.v1", phase: "external_advanced",
  schema_version: 1, prepared_phase_digest, target_leaf_digest })))

selected_phase_digest = sha256(UTF8(RFC8785_JCS({
  digest_domain: "vibeguard.gh702.anchor-phase-selected.v1", phase: "selected", schema_version: 1,
  external_advanced_phase_digest, mirror_generation_id, mirror_file_digest })))

barrier_complete_phase_digest = sha256(UTF8(RFC8785_JCS({
  digest_domain: "vibeguard.gh702.anchor-phase-barrier-complete.v1", phase: "barrier_complete",
  schema_version: 1, selected_phase_digest, target_leaf_digest, barrier_id })))
```

`from_leaf_state` 是 null discriminant 字段：genesis 写 JSON `null`，否则写前一 leaf 的
`target_leaf_body`。`operation` 是 literal string，取值域与 target authorization 的 `operation` 同一
closed union；prepared object 的 `operation`、`target_authorization_digest`、`target_leaf_body` 与
`target_leaf_digest` 必须 byte-equal authorization envelope 对应字段。上述四式是 golden vector 与
recovery reader 的唯一真源。

完整无环顺序是 `per_leaf_authority_body → per_leaf_authority_id` 与
`target_leaf_body → target_leaf_digest → target_authorization_digest → mirror_file_digest/prepared →
external_advanced → selected → barrier_complete`。`post_cas_backend_attestation` 只在 CAS 后向上游
`target_leaf_digest + target_authorization_digest` 提供 sibling evidence；它不反向进入 target、
authorization、mirror 或任何预计算 phase digest，因此 Core/backend authorization 与 recovery 都不依赖
未来 receipt/current attestation。

这里每行的 `domain` 均是该 literal phase 的独立 domain tag。`post_cas_backend_attestation` 是
`target_leaf` 的认证证据而不是预计算 phase digest 输入；journal record 保存
`post_cas_backend_attestation_digest`、phase name、该 phase digest 与
predecessor phase digest。`current.json` 保存 target generation/`file_digest` 和
`selected_phase_digest`。任一 phase 名、digest、predecessor 或 immutable identity 不 exact 时不得构造
后继 phase。schema golden vectors 必须从 envelope bytes 独立提取 outer `schema_version` + body、重算
`file_digest`，再从 intent 的 named fields 重算四个 phase digest；因此 crash recovery 只有一个合法
结果。outer-version-only mutation（body 与旧 digest 均不变）必须 digest mismatch；若同时重算 digest，
所有 phase digest 也必须变化，旧 intent/journal/pointer 不能接受它。

## Ordered write protocol

调用者先按 `tech.md` 的 canonical order 取得该 leaf 所需 policy/ownership/target/runtime locks，
并从 backend 读取 fresh `from_leaf_state + from_leaf_proof`；独立验证 proof 的 backend/root/
per-leaf identity 与 state binding，只要求 current mirror 与 stable state 全等。

1. Core service 先从 authenticated `authorized_operation` 重构 target、验证 leaf transition 并签发
   `target_authorization`。生成 closed pre-CAS intent，绑定 authorization raw bytes/digest、上述全部
   pre-CAS identity、`target_leaf_body`/`target_leaf_digest`、target mirror canonical
   body/`file_digest`、expected successor、commit-journal path、
   barrier ID 与四个合法 phase digest；写入临时文件并 fsync，
   rename 后 fsync intent file 与 parent directory。intent durable 前禁止 external CAS。
2. 将 target 写入 inactive mirror generation；fsync file 与 generations directory。不得覆盖
   current/previous generation，current pointer 保持旧值。
3. exclusive service 紧邻调用前重验 target authorization，再调用 per-leaf compare-and-swap，比较 exact
   `from_leaf_state` 并推进到 exact `target_leaf_body`/`target_leaf_digest`。CAS response 必须携带
   backend-authenticated `post_cas_backend_attestation`，且其 operation/root/per-leaf/from/target/
   authorization identities 与 intent exact 相等；aggregate root observation 只能作 diagnostic。
4. 将 `post_cas_backend_attestation` 及其 digest 与 exact `external_advanced_phase_digest`
   append/replace 到 commit journal，record
   predecessor 必须是 intent 的 `prepared_phase_digest`；fsync journal file 与 parent directory。
   若进程在 CAS response 后、此 fsync 前崩溃，durable pre-CAS authorization/intent/target mirror 加
   backend authenticated current read 返回的 exact target attestation 仍足以重构同一个
   external-advanced record；不得要求 intent 预知未来 attestation 或依赖内存 response 才能恢复。
5. target mirror 保持 byte-immutable；重验其 body/`file_digest` 后，atomic rename `current.json` 到绑定
   target generation/`file_digest` 与 exact `selected_phase_digest` 的新 pointer，重开校验并 fsync pointer
   与 parent directory；再把同一 selected phase append/replace 到 journal 并 fsync。
6. barrier verifier 重新读取 backend current stable state + fresh proof、authorization、intent、commit journal、
   immutable target mirror 与 current pointer；leaf target、authorization、四个预绑定 phase digest、
   journal predecessor chain、pointer selected phase 和 mirror bytes/digest 全部 exact 相等，且 fresh proof
   认证 exact target state（无需 proof digest 等于旧 journal observation）后，append/replace exact
   `barrier_complete_phase_digest`，fsync journal 与目录。
   只有此 barrier 后 leaf mutation 可向调用者报告 committed，policy/install pointer transaction
   才能继续其 own durable boundary，runtime time observation 才能使用新 high-water。
7. barrier 完成后 intent 可标 complete；清理 intent、过旧第三代 mirror 或临时文件是幂等
   maintenance。清理失败不能撤销 commit，也不能删除 current/previous recovery generations。

任何步骤不得把同树 journal signature、wall clock、filename generation 或未认证 IPC response
当作 external CAS 证明。

## Crash and recovery matrix

recovery 必须先取得同一 locks/fence，验证 backend/root/leaf identity，再读取 durable intent；
对每个 unfinished operation 只允许以下 closed transitions：

| Crash observation | Required transition |
| --- | --- |
| intent 不 durable | external CAS 不得发生；清理 private temp，不改变 current |
| intent durable，fresh proof 验证后 backend stable state exact `from_leaf_state` | CAS 未发生；重验 target authorization 后可删除 prepared target 或重试同一 leaf CAS，不得选 target mirror |
| backend leaf exact `target_leaf`，journal 缺 post-CAS attestation | 验证 authorization、intent 与 immutable prepared target `file_digest`，重算 intent-bound external-advanced phase，向 journal 补写 backend current leaf attestation 并 roll forward |
| backend leaf exact target，journal 已 external_advanced，pointer 仍 previous | 重验 immutable target generation，重算 exact selected phase 后重复 current-pointer rename + file/dir fsync |
| pointer 已 target，external-advanced journal durable 但 selected journal 缺失 | 重验 pointer `selected_phase_digest`、immutable mirror `file_digest` 与 intent；以 external-advanced 为 predecessor 幂等重建 selected record，fsync journal file+parent、重开 exact 校验后才可进入 barrier |
| pointer 与 selected journal 已 target，barrier 未完成 | 重读五方 identity；全等则补写/fsync barrier，否则按下述 mismatch 失败 |
| barrier complete，intent/旧 mirror 未清 | 保持 committed，幂等清理；不得重做 CAS |
| unrelated leaf/root 前进或本 leaf proof 刷新，但 stable state 仍 exact from/target | 忽略 proof bytes/digest 变化，分别执行同一 retry/roll-forward；不得 `needs_repair` |
| 同一 backend/root/per-leaf authority 的 leaf 既非 exact from 也非 exact target | `needs_repair`；保留两代 mirror、intent、journal，不猜测或覆盖 external leaf |

若 backend 已到 target，但 target mirror 缺失/损坏，说明 pre-CAS durability contract 被破坏；
必须 `needs_repair`，不得退回 previous mirror。若 target 完整，journal 或 pointer 丢失/仍旧则必须
按 intent 重建 roll-forward 路径；这类可证明的 local lag 不得永久报告 unavailable。

多个 unfinished intent 指向同一 leaf 时，只接受 leaf counter 链与 previous/target digest
严格相邻的唯一序列；fork、重复 successor、equal-counter different-digest 或跨 backend/root
identity/per-leaf authority 一律 `needs_repair`。recovery 按 counter 顺序逐个完成 barrier，不能跳到最大 generation。

## Runtime behavior

Core launch selector 先验证 shipped signed global registry artifact 并按 exact `platform_id` 选择 mode。
`authenticated_no_block_v1` 不要求 launch attestation/TCB，直接进入后续 release/profile binding；registry
invalid/missing/conflict 仍 fail-visible，不能 alias 为 anchor。只有 `anchor_block_v1` 才由 Core binary/
user-state 之外且旧 binary 无法绕过的 host adapter，按 `before_any_core_hook_v1` 验证 challenge-bound
`platform_launch_floor_attestation`；验证失败、adapter/Core version 低于 floor、generation mismatch 或 authority
不可用时 launch nonzero，Core hook 不得启动或产生 decision。release pin 只绑定 compatibility。anchor 只有在 external
nonrollback launch/version-floor authority 已成立且 attestation current 时才可进入 policy lock/fence，
再证明 policy/install per-leaf authority 与 pointer/floor current；任一失败都 nonzero fail closed。证明 current 后，warn/off/no-data
跳过 trusted-time leaf，只有 committed/promoted block candidate 推进 time leaf；其 backend/CAS/IPC
失败仍 conservative deny。`authenticated_no_block_v1` 是**从首次验证该 registry entry 的 conforming
release 起**的 backend-free warn/off ceiling；后续 conforming release 不允许同一 `platform_id` family
rename 或 anchor-block。它不要求不存在的 external authority，合法 warn/off 不得因 backend unavailable
升级成 denial；但本 Draft 不声称可以约束 entry 出现前的旧 binary 或与本地状态一起回滚的旧 release。任何 local
record/override 声称 block 都违反 global ceiling，必须 nonzero fail closed。expiry/release mismatch 只让
status stale/`audit_required`，不能让旧 no-block binary deny 或授权新 identity。block-basis
expiry/rollback fallback 仍先推进并锁存 trusted time，防止旧 block 复活。经验证的 target-local-lag recovery
可以在 bounded retry 内完成；超过预算返回 nonzero 并留下可由 management recovery 继续的 exact
intent/journal，不得删除或从 previous mirror 放行。

## Implementation ownership

H-010 获批后，下列 owner map 必须一一落到 `tech.md` planned-change manifest；owner 不得互相
重做 identity、CAS 或 recovery 判断：

| Concern | Single owner | Required surfaces |
| --- | --- | --- |
| Host launch adapter | Core 外的 H-010 selected platform adapter | 在任何 Core hook 前验证 nonrollback launch floor；old Core/adapter 不满足 floor 时拒绝启动且不产生 decision |
| Hook/management client | Rust `guard_pack::anchor::client` | 已通过 launch gate 的 anchor-block 执行 bounded IPC/attestation；no-block 验证 global family/release/install binding，且不得调用 backend/IPC |
| Local persistence | Rust `guard_pack::anchor::{mirror,recovery}` | intent、commit、mirror schemas；file/dir fsync、two-generation GC、barrier state machine |
| IPC protocol | Rust `guard_pack::anchor::ipc` | versioned closed request/response schema、peer/session binding、timeouts、replay rejection |
| Core service | Rust `guard_pack::anchor::service` + `scripts/setup/guard-pack-anchor-service/` | 仅 anchor-block 拥有 endpoint lifecycle/health；no-block 不安装或重启 service |
| External backend | Rust `guard_pack::anchor::backend` | 仅 anchor-block 使用 selected adapter、successor CAS、attested read、device/backend identity |
| Provision/lifecycle | Rust `guard_pack::anchor::provision` + setup/release integration | 仅 anchor-block 执行 provision/reattach/rotate/restart/CAS/repair；no-block 必须零 backend lifecycle |
| Public schemas | launch-floor/anchor schemas、H-010/global registry、mode-specific perf schemas | closed versions/domains、cross-release terminal registry、identity mutation corpus |
| Status renderer | existing `guard_pack::render` | no-block: global profile generation/install binding/warn ceiling/stale + no-block CI identity，backend/root/leaf=`not_applicable`；anchor-block: launch floor/backend/root/leaf/counter/barrier/repair |

Platform service assets 只能为 anchor-block 进入 manifest 已预留的 setup directory；no-block inventory
必须证明 backend/service absent。H-010 必须在 approved artifact 固定 selected inventory。在该 approval 前不得
生成 `tasks.md` 或把 generic service module 冒充为 macOS/Linux/Windows availability。
## Verification manifest

| Gate | Required fresh evidence |
| --- | --- |
| Schema parity | Rust/Python readers share positive/negative corpus for intent/commit/mirror/IPC and closed H-010/budget/batch/result envelopes；unknown, duplicate, empty, mutable phase and cross-record identity mismatch fail visibly |
| Phase construction | golden vectors independently recompute outer-version+body `file_digest` and all four intent-bound phase digests；outer-version-only、mirror body、phase name/order/predecessor、receipt identity or pointer mutations cannot construct the next phase |
| Target authorization | wrong/expired/self-signed authorization, client-chosen target, operation reconstruction drift and every stable leaf-transition field mutation fail before CAS；proof refresh with unchanged state remains valid，post-CAS attestation binds the same target/authorization |
| Barrier crash matrix | deterministic fault after every temp fsync, rename, directory fsync, leaf CAS response, commit-journal phase write, pointer selection, barrier and cleanup；exact from retries, exact target reconstructs and rolls forward, same-leaf divergence needs_repair |
| Lost-response recovery | leaf CAS advances but response/journal write is lost while unrelated leaves advance；durable pre-CAS state plus fresh authenticated proof reconstructs post-CAS journal；`refreshed_proof_same_state` changes nonce/signature/digest and still retries/rolls forward |
| Cross-platform availability | anchor-block OS/architecture proves external pre-Core launch-floor enforcement, provisions selected backend/service, restarts and completes CAS；no-block performs none and needs no hardware/service fixture |
| IPC trust | wrong executable/user/principal, stale session, replayed response, protocol downgrade, endpoint substitution, malformed attestation and service restart all fail closed |
| Identity/lifecycle | `forbidden_cross_release_mode_transition` rejects any no-block platform becoming block、family rename or migration target；anchor identity is valid only when an external nonrollback launch floor already prevents old Core/adapter execution |
| Failure/repair | anchor backend/IPC/provision/CAS failures preserve evidence；no-block expiry/pin/new-identity mismatch keeps warn/off ceiling while status is stale/nonzero，never backend fallback |
| Every-hook performance | canonical hook gate runs every claimed installed snapshot；anchor-block uses anchor budget/batch/result with real IPC/read/CAS/barrier，no-block uses independent zero-backend budget/batch/result with hook-only p50/p95/p99/max |
| Concurrency | parallel hooks on different leaf authorities advance independently despite aggregate-root changes；same-leaf operations remain recovery-first serialized with unique successors, no forked mirrors and bounded nonzero failure |
| `authority_mode_branch_matrix` | anchor-block requires launch-floor/provision/restart/CAS/IPC/full schemas；`no_block_status_without_backend` proves independent hook-only schemas, zero backend lifecycle, `not_applicable` anchor fields, and global generation/install binding/ceiling/stale status |
| Decision scope | global registry makes no-block terminal across subsequent conforming releases；negative fixture proves local observation is not claimed as whole-release rollback protection；release pin cannot change mode；`old_binary_prelaunch_rejected` is required only for an active block platform with external launch authority |
| `final_ci_authority_mode_branch` | anchor-block runs launch-authority + real hardware/service conformance；no-block runs zero-backend installed-hook/schema/status evidence and must not require hardware/service |
| Identity mutation closure | generated `one_field_at_a_time` negatives cover every registered anchor/H-010 identity plus top-level/nested breach mirrors、budget/batch/domain/version/signature fields；registry coverage fails when a new identity is unlisted |
| Packaging | anchor payload contains service/backend/provision assets；no-block omits them；fresh installs prove exact registry/profile branch inventory |
| Atomic launch closure | atomic-annex owner digest + all named request/response schemas；missing/unknown/conditional fields、peer/request mismatch、lost response and terminal respawn fail closed |
| Process-template closure | six canonical body/domain/preimage mutation corpus；environment collision/order、cwd object、principal/sandbox/IPC drift fail before transaction consumption |
| Tombstone retention | timeout/abort/create failure produce signed terminal tombstone；detail compaction/restart/old adapter cannot bypass permanent nonrollback transaction reuse guard |
### Closed H-010 decision and result schemas

所有对象使用 RFC 8785 JCS、closed fields、literal domain 和 semantic outer schema version；digest
始终是 `sha256(JCS({digest_domain, schema_version, body}))`，只排除同 envelope 的 sibling digest 与
signature，body 内不得反向包含自己的 digest。缺字段、unknown/duplicate key、wrong domain/version、
非 canonical bytes 或 digest/signature mismatch 均 nonzero。
```text
global_platform_registry_envelope = {
  digest_domain: "vibeguard.gh702.global-platform-registry.v1", schema_version,
  registry_body: {registry_generation, previous_registry_digest|null,
    entries: [{platform_id, platform_profile_family_id, global_profile_generation,
      authority_mode, transition_policy}]},
  global_platform_registry_digest,
  signatures: [{signer_key_id, signature_algorithm, signature}]
}
global_platform_registry_entry_digest =
  H("vibeguard.gh702.global-platform-registry-entry.v1", 1, exact entries[i])
```

`(authority_mode, transition_policy)` 是**单一 closed union 的两个投影**，不是两个可自由配对的
字段。exact 合法对只有下列两行；任何其它组合即使 signature 有效也是 malformed entry，
registry validation 必须在 mode selection 之前 fail-visible 拒绝，不得 alias、降级或按其中一半继续：

| `authority_mode` | `transition_policy` |
|---|---|
| `anchor_block_v1` | `external_launch_floor_anchor_v1` |
| `authenticated_no_block_v1` | `permanent_backend_free_no_block_v1` |

若无此约束，一个 validly signed 的矛盾 entry 可使 mode selection 授权 anchor branch，
而 terminality invariant 同时宣告该 platform 永久 backend-free——两条互斥路径同时为真。

```text
global_platform_registry_digest = sha256(JCS({digest_domain, schema_version, registry_body}))
launch_authority_profile_body = {
  schema_version: 1, launch_authority_profile_id,
  launch_authority_backend_identity: {
    backend_kind, backend_instance_id, device_key_digest, protocol_version
  },
  trusted_signers: [{signer_key_id, signature_algorithm, verification_key_digest}],
  signature_quorum, max_attestation_validity_ms, resume_token_min_entropy_bits, max_suspended_lifetime_ms, freshness_protocol: "challenge_compare_and_launch_v1", resume_protocol: "single_use_external_tcb_resume_v1"
}
launch_authority_profile_digest =
  H("vibeguard.gh702.launch-authority-profile.v1", 1, launch_authority_profile_body)
launch_policy_body、六个 process-template subdigest bodies/domains/preimages、current/process/attestation
identities，以及 named compare/recover/resume/query-or-abort messages 和 terminal tombstone/reuse guard，全部
由 [`atomic-launch-machine-contract.md`](atomic-launch-machine-contract.md) 唯一定义。本文不得重声明匿名
response、缩短 request 或为 platform 创建 alias；H-010 必须 exact 绑定该 annex digest。
h010_decision_envelope = {
  digest_domain: "vibeguard.gh702.h010-decision.v1",
  schema_version,
  h010_decision_body: {
    product_spec_digest, tech_spec_digest, anchor_contract_digest,
    atomic_launch_machine_contract_digest, anchor_identity_verification_contract_digest,
    approved_by: [maintainer_id], approved_at, expires_at,
    global_platform_registry_digest,
    platform_profiles: [{
      platform_id, platform_profile_family_id, global_profile_generation,
      global_platform_registry_entry_digest,
      authority_mode: anchor_block_v1|authenticated_no_block_v1,
      anchor_profile: {backend_profile_id, service_profile_id,
        launch_authority_profile_body, launch_authority_profile_digest,
        launch_policy_body, launch_policy_digest,
        per_leaf_authority_mode: "independent_authenticated_leaf_v1",
        target_authorizer_profile_id, authorizer_key_id,
        provision_ipc_lifecycle_decisions,
        fixture_budgets: [{
          fixture_id, host_kind, installed_wrapper_path, workload_schedule_digest, runs,
          hook_e2e_p50_ms, hook_e2e_p95_ms, hook_e2e_p99_ms, hook_e2e_max_ms,
          cas_timeout_ms, ipc_timeout_ms, queue_wait_budget_ms,
          contention_total_budget_ms, contention_retry_limit_count
        }]}|null,
      no_block_profile: {core_release_digest, release_pin_digest,
        maximum_effective_decision: warn,
        transition_policy: permanent_backend_free_no_block_v1,
        fixture_budgets: [{fixture_id, host_kind, installed_wrapper_path,
          workload_schedule_digest, runs, hook_e2e_p50_ms, hook_e2e_p95_ms,
          hook_e2e_p99_ms, hook_e2e_max_ms}]}|null
    }]
  },
  h010_decision_artifact_digest,
  signatures: [{signer_key_id, signature_algorithm, signature}]
}
```
`launch_authority_profile_body` 是 H-010 内唯一 signer trust source：`trusted_signers` 按 ID 严格排序且唯一，quorum 必须在 `1..=unique_signers`，attestation/suspended lifetime 与 token entropy bounds 必须为正；signer ID、algorithm、quorum 与 provisioned public-key material 的 canonical digest 全部签入 H-010；adapter 重算 verification key 后 exact 匹配。
`launch_policy_body` exact 绑定 profile、platform/family、registry entry、pre-hook stage、approved binaries、
canonical Core process template 与 tombstone retention digest；atomic annex 的六个 body/domain/preimage 任一
mismatch 都不得消费 transaction 或接受 attestation，只满足 minimum version 不算获批 process。
每次 launch 必须使用 annex 的 named request；backend 在一个 external-TCB linearization point compare exact
current state、永久消费 transaction 并创建 suspended exact process。recover 只向原 authenticated peer 返回
同一 handoff；resume/query/abort 使用 named conditional responses，pending timeout/失败形成 signed tombstone，
detail compaction 后仍永久保留 nonrollback reuse guard。任一 Core hook 在 signed resume receipt 前不得运行。
state 在线性化前推进使 compare 失败；其后推进不倒置已启动 process。cached/caller-reported/wrong nonce/session/transaction、predecessor/non-current state、missing quorum、自签、expired、floor rollback 或 replayed response 全部在 Core 前 nonzero。accepted state/commit/process identities 进入 receipt/status/perf authority；Core/HOME/local file 不能替代 external TCB。
`global_platform_registry_invariant` 是所有**实现该 contract 的 release**共同遵守的 append-only canonical contract；signatures
按 ID 严格排序且唯一，并 exact 匹配 repository maintainer trust keys/algorithms/quorum。entries 按
`platform_id` byte order 严格递增且 `platform_id` 全历史唯一；successor 必须保留该 platform 的 exact
family 与 mode，只有 generation 可递增。某 platform 一旦声明
`permanent_backend_free_no_block_v1`，任何后续 conforming release 都不得删除、复用、迁移或改成
anchor-block。缺少 Core 外、pre-launch、不可由旧 binary/adapter 绕过的 nonrollback launch authority
的平台必须为当前与后续 conforming release 选择该 branch，禁止 maintainer migration 或 official block。
`duplicate_platform_across_releases`、family rename/conflicting mode、registry predecessor/history drift 在 H-010
selection 前拒绝；runtime/release validator 不得 first/last-wins。release pin 不参与该 invariant。

**Latest-generation boundary（no-block branch）**：signatures 与 `previous_registry_digest` 只证明
lineage，不证明所提供 snapshot 是最新的。`authenticated_no_block_v1` 按定义没有 Core 外的 nonrollback
authority；HOME/Core 内的所谓 monotonic leaf 会随 coherent whole-release rollback 一起消失或变旧，
不能封闭该窗口。因此本 Draft 明确**不提供**“任意过去 release 都 obey 后来 no-block entry”的保证。

conforming release 仍必须保存下列 signed-registry observation，以检测 state 尚存时的普通 downgrade；
它是 durable mirror/diagnostic，不是 anti-rollback authority：

```text
registry_observation_body = {
  schema_version: 1,
  platform_id,
  observed_registry_generation,
  global_platform_registry_entry_digest
}
```

该 observation 使用 ordinary two-generation durable retention，语义为 per-`platform_id` best-known snapshot：

- `observed_registry_generation` 必须 `>=` 已存储高水位，等值时 `global_platform_registry_entry_digest`
  必须 byte-equal，否则是 fork，fail-visible 拒绝而非取任一侧；
- state 尚存时，严格更小的 generation 是 rollback：拒绝并以 nonzero 退出，不得 alias 为 missing
  platform、不得按旧 mode 继续，也不得静默重置 observation；
- observation 已记录某 `platform_id` 处于 `permanent_backend_free_no_block_v1` 时，任何提供
  anchor-block entry 的 snapshot 都在 mode selection 前拒绝。

observation 不进入本合同的 authenticated leaf union，也不替代 registry 签名。若产品需要抵抗
coherent whole-release rollback，H-010 必须先批准 Core/HOME 外、old-binary-unbypassable 的 registry-floor
authority；该平台随后应走可证明的 anchor profile，不能把 local observation 描述成 no-block 真源。
`anchor_profile` 与 `no_block_profile` 是 closed mutually-exclusive branches。`authenticated_no_block_v1`
只用于 registry 已永久声明 no conforming backend/no official block 的 family；它不伪造 backend identity：
`platform_profiles` 必须按 canonical `platform_id` byte order 严格递增且 ID 唯一；duplicate、乱序或同一
platform 同时出现两个 mode 在 mode selection 前拒绝，runtime 不得 first/last-wins。
```text
release_pin_body = {schema_version: 1, platform_id, core_release_digest}
release_pin_digest =
  H("vibeguard.gh702.core-release-pin.v1", 1, release_pin_body)
no_block_release_profile_body = {
  schema_version: 1, platform_id, platform_profile_family_id,
  global_profile_generation, global_platform_registry_entry_digest,
  core_release_digest, h010_decision_artifact_digest, release_pin_digest,
  maximum_effective_decision: "warn",
  transition_policy: "permanent_backend_free_no_block_v1"
}
no_block_release_profile_digest =
  H("vibeguard.gh702.authenticated-no-block-release-profile.v1", 1,
    no_block_release_profile_body)
no_block_installation_binding_body = {
  schema_version: 1, core_installation_id, global_platform_registry_entry_digest,
  no_block_release_profile_digest
}
no_block_installation_binding_digest =
  H("vibeguard.gh702.authenticated-no-block-installation.v1", 1,
    no_block_installation_binding_body)
```
global registry entry 是 terminality authority；per-release H-010/profile/pin 仅绑定该 release 的
compatibility。runtime 要求 signed `core_release_digest` exact 等于 current verified release，并重算 pin；
mismatch 显式 stale/nonzero，但不能改变已识别 no-block family 的 warn/off ceiling。每个 installation 从
global entry + release profile 派生 binding；HOME 自报 generation/binding 无权改 mode。no-block 的
backend/root/leaf 均为 `not_applicable`，不得 provision/restart/CAS/IPC 或把合法 warn/off/no-data 升为 denial。
official block 只能在已由 external launch/version-floor TCB 管辖、且当前 attestation 证明 old
Core/adapter 低于 floor 无法启动的平台 generation 上声明；new identity、maintainer authorization、
backend proof 或 Core 内检查均不能替代 launch floor。no-block platform/family 没有 migration-to-block
路径。active block platform 的 `two_release_whole_rollback` 必须使旧 binary/adapter 在任何 Core hook
前 nonzero 拒绝（`old_binary_prelaunch_rejected`），不能执行旧 warn/off、产生 decision 或把 block
receipt/profile 重解释成 no-block。launch authority/floor 失效时保持 pre-launch fail closed。
`approved_h010_schema_version = h010_decision_envelope.schema_version`，后者是 universal envelope 的
canonical outer key；`approved_h010_schema_version` 只是在 authority/result body 中引用该已验证值，
不是可接受的 outer alias。
`h010_decision_artifact_digest = sha256(JCS({digest_domain:
"vibeguard.gh702.h010-decision.v1", schema_version, h010_decision_body}))`，preimage
不含 sibling `h010_decision_artifact_digest` 或 `signatures`。`approved_by` 与 `signatures` 均按 ID
排序且 ID 唯一；signer/quorum/algorithm 必须匹配 repository maintainer trust configuration。维护者签名
验证和 validity window 成功后才是 exact approved H-010；anchor branch 还必须验证 H-010 引用的
profile/policy 下 challenge-bound launch-floor attestation current 且 exact binding，Recommended prose、环境探测或 result 自报均不能替代。
只有 global registry 已标 terminal no-block 的 embedded profile 到期时，runtime 才派生
`expired_profile_no_block_ceiling_v1`：继续 warn/off/no-data，status stale/`audit_required`/nonzero；expired
anchor profile 绝不能变成 no-block。expiry、pin mismatch 或 no-block profile mismatch 都不授予 block，
也不解除 global ceiling；current valid profile 仍优先。
`evaluation_policy_digest` 来自 authoritative active evaluation-policy envelope 的 literal
`vibeguard.gh702.evaluation-policy.v1` domain + schema version + policy body digest；其 body 必须引用 exact
`h010_decision_artifact_digest`。`policy_validity_evidence_digest` 来自该 policy 的 closed signed
validity-evidence envelope。三者在运行前/后 under policy lock exact 相等，不能从 result、budget 或
wall clock 推导。

`authoritative_policy_generation` 的来源**按 branch 分流**，因为 no-block branch 同时要求
backend/root/leaf authority 为 `not_applicable` 并禁止 backend IPC——若唯一来源是 external policy leaf
attestation，conforming no-block runner 只能去调用本 mode 明令禁止的 authority，或者伪造一个
canonical source 在外部的字段：

- `anchor_block_v1`：取自 external policy leaf attestation，与 launch floor 同一 authority。
- `authenticated_no_block_v1`：取自 evaluation-policy envelope **自身**签名 body 中的
  `policy_generation` 整数字段。它随 policy 一起被 maintainer 签名，与 `evaluation_policy_digest`
  出自同一 bytes，因此无需任何 backend IPC 即可在本地重算与验证。

两条 branch 都禁止从 result、budget、wall clock 或 host 状态推导该值。no-block branch 把
`policy_generation` 纳入 “Latest-generation boundary”的同一 ordinary durable observation：state 尚存时
严格更小的 generation 是 rollback并 fail-visible 拒绝，等值时签名 body 必须 byte-equal；这不扩大
对 coherent whole-release rollback 的保证。
仅 `anchor_block_v1` 的 anchor-enabled fixture 按无环顺序构造下列对象；no-block branch 不得伪造
`backend_profile_id`、anchor budget/result 或 CAS sample：
```text
authority_base_body = {
  approved_h010_schema_version, h010_decision_artifact_digest,
  evaluation_policy_digest, authoritative_policy_generation,
  policy_validity_evidence_digest, platform_launch_floor_attestation_digest,
  platform_launch_current_state_digest, current_platform_generation, backend_state_counter, monotonic_launch_floor,
  allowed_core_min_version, allowed_host_adapter_min_version
}
authority_base_digest = H("vibeguard.gh702.anchor-perf-authority.v1", schema_version,
                          authority_base_body)
budget_body = {
  authority_base_digest, fixture_id, platform_id, backend_profile_id, host_kind,
  installed_wrapper_path, workload_schedule_digest, runs,
  hook_e2e_p50_ms, hook_e2e_p95_ms, hook_e2e_p99_ms,
  hook_e2e_max_ms, cas_timeout_ms, ipc_timeout_ms, queue_wait_budget_ms,
  contention_total_budget_ms, contention_retry_limit_count
}
budget_digest = H("vibeguard.gh702.anchor-perf-budget.v1", schema_version, budget_body)
decision_body = {authority_base_digest, budget_digest, fixture_id, anchor_enabled: true,
                 surface: "hook_e2e_ms", confirmation_policy: "all_fields_v1"}
decision_artifact_digest = H("vibeguard.gh702.anchor-perf-decision.v1", schema_version,
                             decision_body)
metric_summary = {p50, p95, p99, max}  # each value is a non-negative integer millisecond/count
batch_body = {
  phase: initial|confirmation, authority_base_digest, budget_digest,
  decision_artifact_digest, fixture_id, platform_id, backend_profile_id, host_kind,
  installed_wrapper_path, anchor_enabled: true, surface: "hook_e2e_ms", runs,
  workload_schedule_digest, successor_baseline,
  hook_e2e_ms: metric_summary, anchor_cas_ms: metric_summary,
  anchor_ipc_ms: metric_summary, anchor_queue_wait_ms: metric_summary,
  anchor_contention_total_ms: metric_summary,
  anchor_contention_retry_count: metric_summary,
  cas_timeout_count, ipc_timeout_count, sample_error_count, ordered_breaches
}
batch_digest = H("vibeguard.gh702.anchor-perf-batch.v1", schema_version, batch_body)
result_body = {
  authority_base_body, authority_base_digest, budget_body, budget_digest,
  decision_body, decision_artifact_digest,
  initial: batch_body(phase=initial), initial_digest: batch_digest(initial),
  initial_breaches: initial.ordered_breaches,
  confirmation_applicability:
    required_numeric_breach|not_applicable_no_initial_breach|not_applicable_initial_error,
  confirmation: batch_body(phase=confirmation)|null,
  confirmation_digest: batch_digest(confirmation)|null,
  confirmation_breaches: confirmation.ordered_breaches|[],
  decision: pass|cleared_transient|confirmed_regression|confirmation_error
}
result_body_digest = H("vibeguard.gh702.anchor-perf-result.v1", schema_version, result_body)
result_envelope = {digest_domain, schema_version, result_body, result_body_digest}
```
`authenticated_no_block_v1` 使用另一组 closed schemas；它们不复用 anchor authority/budget/batch/result：
```text
no_block_authority_base_body = {
  approved_h010_schema_version, h010_decision_artifact_digest,
  global_platform_registry_entry_digest, no_block_release_profile_digest,
  no_block_installation_binding_digest, evaluation_policy_digest,
  authoritative_policy_generation, policy_validity_evidence_digest
}
no_block_authority_base_digest =
  H("vibeguard.gh702.no-block-perf-authority.v1", 1, no_block_authority_base_body)
no_block_budget_body = {
  no_block_authority_base_digest, fixture_id, platform_id, host_kind,
  installed_wrapper_path, workload_schedule_digest, runs,
  hook_e2e_p50_ms, hook_e2e_p95_ms, hook_e2e_p99_ms, hook_e2e_max_ms
}
no_block_budget_digest =
  H("vibeguard.gh702.no-block-perf-budget.v1", 1, no_block_budget_body)
no_block_decision_body = {
  no_block_authority_base_digest, no_block_budget_digest, fixture_id,
  authority_mode: "authenticated_no_block_v1", anchor_enabled: false,
  surface: "hook_e2e_ms", confirmation_policy: "hook_fields_only_v1"
}
no_block_decision_artifact_digest =
  H("vibeguard.gh702.no-block-perf-decision.v1", 1, no_block_decision_body)
no_block_batch_body = {
  phase: initial|confirmation, no_block_authority_base_digest,
  no_block_budget_digest, no_block_decision_artifact_digest,
  fixture_id, platform_id, host_kind, installed_wrapper_path,
  authority_mode: "authenticated_no_block_v1", anchor_enabled: false,
  surface: "hook_e2e_ms", runs, workload_schedule_digest,
  hook_e2e_ms: metric_summary, sample_error_count, ordered_breaches
}
no_block_batch_digest =
  H("vibeguard.gh702.no-block-perf-batch.v1", 1, no_block_batch_body)
no_block_result_body = {
  no_block_authority_base_body, no_block_authority_base_digest,
  no_block_budget_body, no_block_budget_digest,
  no_block_decision_body, no_block_decision_artifact_digest,
  initial: no_block_batch_body(phase=initial),
  initial_digest: no_block_batch_digest(initial),
  initial_breaches: initial.ordered_breaches,
  confirmation_applicability:
    required_numeric_breach|not_applicable_no_initial_breach|not_applicable_initial_error,
  confirmation: no_block_batch_body(phase=confirmation)|null,
  confirmation_digest: no_block_batch_digest(confirmation)|null,
  confirmation_breaches: confirmation.ordered_breaches|[],
  decision: pass|cleared_transient|confirmed_regression|confirmation_error
}
no_block_result_body_digest =
  H("vibeguard.gh702.no-block-perf-result.v1", 1, no_block_result_body)
no_block_result_envelope = {
  digest_domain: "vibeguard.gh702.no-block-perf-result.v1", schema_version: 1,
  no_block_result_body, no_block_result_body_digest
}
```
no-block budget/batch/result 只允许 `hook_e2e_*`、`hook_e2e_ms`、sample error 与 breach
字段；`backend_profile_id`、CAS/IPC/queue/contention metric、timeout/count/budget、successor baseline
等 anchor 字段必须 absent，不能填 null 或 zero。initial 无 error 且无 numeric breach 时
`confirmation_applicability=not_applicable_no_initial_breach`、confirmation/digest 为 null、
`confirmation_breaches=[]`、decision=pass；initial sample error 时使用
`not_applicable_initial_error` 并立即 `confirmation_error`。只有 initial hook numeric breach
使用 `required_numeric_breach` 且必须完整重跑 confirmation；全字段恢复才
`cleared_transient`，仍 breach 为 `confirmed_regression`，confirmation sample error 为
`confirmation_error`。initial/confirmation breach mirrors 必须分别 exact 等于其 batch
`ordered_breaches`；任何 applicability/body/digest/breach 组合不一致都 nonzero。
这里 `H(domain, version, body)` 是上述 named closed object 的 JCS digest，不是位置字符串拼接。
`budget_body` 必须逐字段重构自 signed H-010 中 exact selected platform/fixture budget，不能接受 result
echo 或 CLI override；`successor_baseline = {from_leaf_state, target_leaf_counter,
target_leaf_digest}`，且 workload schedule 的 closed body digest
必须 exact 等于 H-010 的 `workload_schedule_digest`。所有 `metric_summary`、budget/batch/result field
都是 closed、required 且不允许 alias；`initial_breaches` 必须 byte-equal `initial.ordered_breaches`；
confirmation body/digest 为 null 时 `confirmation_breaches` 必须是 empty array；否则三者必须是 exact
confirmation body/digest/`ordered_breaches`。`initial`/
`confirmation` 保存 exact `batch_body`，其 sibling digest 不进入自身 body；result 引用 batch digest，
所以 swap/relabel batch、budget 或 authority 会改变 result digest。`decision_artifact_digest` 的唯一来源
是 literal `vibeguard.gh702.anchor-perf-decision.v1` fixture decision body，不是 H-010 artifact 的 alias，
也不进入自己的 preimage。
### Latency result and decision contract

每个 H-010 approved anchor-enabled fixture 产生一个 closed result。identity fields 至少是 `fixture_id`、
`platform_id`、`backend_profile_id`、`host_kind`、exact `installed_wrapper_path`、`anchor_enabled=true`、
`surface=hook_e2e_ms`、`runs`，以及 exact `approved_h010_schema_version`、
`h010_decision_artifact_digest`、`evaluation_policy_digest`、`authoritative_policy_generation`、
`policy_validity_evidence_digest`、`decision_artifact_digest` 和上述 authority/budget digests。`budget`
必须原样记录该 exact H-010/
evaluation decision 为该 fixture 批准的
`hook_e2e_{p50,p95,p99,max}_ms`、`cas_timeout_ms`、`ipc_timeout_ms`、`queue_wait_budget_ms`、
`contention_total_budget_ms`、`contention_retry_limit_count`。
`initial` 与非空 `confirmation` 使用同一 closed shape：`hook_e2e_ms`、`anchor_cas_ms`、
`anchor_ipc_ms`、`anchor_queue_wait_ms`、`anchor_contention_total_ms` 各含 integer
`p50/p95/p99/max`，`anchor_contention_retry_count` 含 integer `p50/p95/p99/max`；另存
`cas_timeout_count`、`ipc_timeout_count`、`sample_error_count`。result 还必须保存按 exact field path
排序的 `initial_breaches`、`confirmation_breaches` 与 `decision`，不得用一个 P95 status 代表其他项。
initial 的 hook 四分位/max 分别比较同名预算；CAS/IPC max 比较 timeout，queue/contention max 比较
millisecond budget，contention retry max 比较 count limit。initial 无 error 且无 numeric breach 时必须是
`not_applicable_no_initial_breach` + null confirmation/digest + empty breaches + `pass`；initial sample error 或任一
timeout count 非零时必须是 `not_applicable_initial_error` + 同一 null/empty 组合 + `confirmation_error`。
只有 numeric breach 可使用 `required_numeric_breach`，并触发同一 fixture identity/inputs/runs/backend/profile/
workload schedule 的完整 confirmation batch；每批使用记录的 successor baseline/non-overlapping leaf，禁止为
“相同状态” rollback external root。confirmation 必须重测并保留全部 fields；全部回到预算内才是
`cleared_transient`，任一项仍超限即 `confirmed_regression` 并使 CI nonzero，confirmation sample error 则
`confirmation_error`。任一 applicability/body/digest/breach/decision 组合不一致、missing/null/non-integer 或
identity/budget drift 都立即 nonzero，不得用 confirmation 清除。result、budget、
initial、confirmation 与运行前/运行后 authoritative policy read 必须 exact 同一上述 identity；H-010/
policy/budget rotation、generation/validity/decision artifact drift 或任一 mismatch 都立即 nonzero，旧
result 不得 grandfather、重标或由 confirmation 清除，只能用新 identity 重跑全部 fixture。
`tests/test_hook_perf_contract.sh` 必须按 authority mode 分别验证两套 closed shape/units、budget echo、
initial/confirmation/applicability、breach path 与 blocking decision；anchor 对 P50/P95/P99/max、CAS、IPC、queue、
contention-time、retry-count 分别注入唯一 breach 并要求 gate nonzero；还要逐一 mutate H-010、policy、
generation、validity evidence、decision artifact 与 budget echo identity 并要求立即 nonzero，再证明仅 numeric transient
且 confirmation 全字段通过时才清除。no-block 对四个 hook fields、sample error、三种 applicability、
null/empty breach mirror 和任一 forbidden backend field 注入负例；每个 claimed installed fixture ID 在
runner/H-010/CI/result 中各恰好一次，anchor 用 service sentinel，no-block 用 zero-backend sentinel。
### Identity registry and semantic verification

The exhaustive identity-pointer registry, embedded-occurrence closure, mutation corpus, and executable
semantic-verification requirements are normatively defined by
[`anchor-identity-verification-contract.md`](anchor-identity-verification-contract.md). H-010 binds its
exact bytes through `anchor_identity_verification_contract_digest`; omitting or mismatching that owner
digest invalidates the decision artifact.
