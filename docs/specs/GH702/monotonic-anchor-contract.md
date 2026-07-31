# Monotonic Anchor Contract — External CAS 与本地镜像恢复

## Linked Issue

GH-702

## Status

Draft。本文是 [`product.md`](product.md) 与 [`tech.md`](tech.md) 的 supporting contract；
它不批准任何 backend、平台、provisioning 或 trust 选择，也不创建 implementation tasks。

## Scope

本文只定义 policy generation、installation generation 和 trusted-time
`clock_epoch/sequence/high_water` 三类 monotonic leaf 的共同持久化协议。目标是同时保证：

- external authenticated root 是唯一 anti-rollback authority；HOME 内 pointer、floor、state
  和 attestation 都只是 mirror；
- external CAS 已成功、进程却在任一本地写入前崩溃时，可从预写 intent 确定性 roll forward，
  不会永久停在 `runtime_guard_unavailable`；
- external root 未前进时可以安全放弃 prepared mirror；已前进后绝不 rollback external root；
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
- `per_leaf_authority_id = H("vibeguard.gh702.anchor-leaf-authority.v1", root_identity,
  leaf_identity)`；
- `from_leaf = (leaf_counter, leaf_digest, leaf_attestation_digest)`；
- `target_leaf = (leaf_counter, leaf_digest, leaf_attestation_digest)`，counter 必须是该 leaf
  authority 认可的唯一 successor；
- `authorized_operation_digest`、`target_authorization_digest` 与 `authorizer_key_id`；
- `mirror_generation_id`、mirror `file_digest`、previous mirror generation/digest；
- owner transaction/runtime operation、policy/installation generation 与适用 lock/fence identities。

## Per-leaf concurrency and target authorization

本合同选择 **independent authenticated per-leaf authority**。external root 必须为每个
`per_leaf_authority_id` 暴露独立、non-rollback、atomic successor CAS register；CAS precondition 和
recovery equality 只使用 exact `root_identity + per_leaf_authority_id + from_leaf/target_leaf`。backend
可以在 receipt 中报告 aggregate root epoch/digest 供审计，但它不是 leaf CAS precondition、phase digest
或 recovery equality 的一部分。另一个 policy/install/time leaf 推进 aggregate root 时，本 leaf 的
attestation 仍可验证，旧 mirror 与 lost response recovery 必须继续按本 leaf exact from/target 判定。
无法提供独立 authenticated leaf register、只能比较一个全局 mutable root digest 的 backend 不满足
H-010 official-block conformance。

同一 leaf 仍由 Core service recovery-first 串行化：unfinished intent 完成 barrier 前不得接受该 leaf
的下一 successor。若 fresh attestation 显示本 leaf exact from，CAS 尚未发生；exact target 则
roll forward；既非 from 也非 target 才是 same-leaf divergence 并进入 `needs_repair`。其他 leaf 的
counter/digest/attestation 变化必须被 test fixture 并发注入，且不能改变这三个结果。

客户端没有 target authority。本地可重算 payload/hash、durable intent 或 authenticated caller 都不能
单独授权 CAS。客户端只提交 closed `authorized_operation`；Core service 验证 IPC peer/session、当前
H-010/evaluation-policy identity、root/leaf/from attestation、lock/fence 和 operation-specific subject，
再按 leaf kind 重构 target 并逐字段验证唯一合法 transition：policy/install 是 exact successor +
approved committed identity，time 是同 epoch sequence/high-water monotonic advance，clock reconciliation
另需 approved evidence 且 exact epoch successor。

服务生成 closed `target_authorization` envelope：

```text
digest_domain = "vibeguard.gh702.anchor-target-authorization.v1"
authorization_body = {
  backend_identity, root_identity, per_leaf_authority_id,
  from_leaf, target_leaf, anchor_operation_id, authorized_operation_digest,
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

本地 closed persistence set 新增：

```text
anchor/
  intents/<anchor_operation_id>.json       durable pre-CAS intent
  commits/<anchor_operation_id>.json       append/replace commit journal
  mirrors/<leaf_storage_key>/
    current.json                           durable mirror-generation pointer
    generations/<mirror_generation_id>.json
```

mirror generation 使用 closed envelope。`mirror_body` 保存 generation identity、exact external
attestation identity、leaf payload 与 previous generation/digest，但不含自己的 digest；outer
`schema_version` 是 envelope 的 semantic version，不能只作为 parser hint。
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

```text
prepared_phase_digest = H(prepared_domain, operation, target_authorization_digest, mirror_file_digest, from_leaf, target_leaf)
external_advanced_phase_digest = H(external_advanced_domain, prepared_phase_digest, target_leaf)
selected_phase_digest = H(selected_domain, external_advanced_phase_digest, mirror_generation_id, mirror_file_digest)
barrier_complete_phase_digest = H(barrier_complete_domain, selected_phase_digest, target_leaf, barrier_id)
```

这里每行的 `domain` 均是该 literal phase 的独立 domain tag。backend receipt 是 `target_leaf` 的
认证证据而不是 digest 输入；journal record 保存 receipt digest、phase name、该 phase digest 与
predecessor phase digest。`current.json` 保存 target generation/`file_digest` 和
`selected_phase_digest`。任一 phase 名、digest、predecessor 或 immutable identity 不 exact 时不得构造
后继 phase。schema golden vectors 必须从 envelope bytes 独立提取 outer `schema_version` + body、重算
`file_digest`，再从 intent 的 named fields 重算四个 phase digest；因此 crash recovery 只有一个合法
结果。outer-version-only mutation（body 与旧 digest 均不变）必须 digest mismatch；若同时重算 digest，
所有 phase digest 也必须变化，旧 intent/journal/pointer 不能接受它。

## Ordered write protocol

调用者先按 `tech.md` 的 canonical order 取得该 leaf 所需 policy/ownership/target/runtime locks，
并从 backend 读取 fresh authenticated `from_leaf`；只接受 exact backend/root/per-leaf authority identity
以及 current mirror 与 attestation 全等的 base。

1. Core service 先从 authenticated `authorized_operation` 重构 target、验证 leaf transition 并签发
   `target_authorization`。生成 closed pre-CAS intent，绑定 authorization raw bytes/digest、上述全部
   identity、target mirror canonical body/`file_digest`、expected successor、commit-journal path、
   barrier ID 与四个合法 phase digest；写入临时文件并 fsync，
   rename 后 fsync intent file 与 parent directory。intent durable 前禁止 external CAS。
2. 将 target 写入 inactive mirror generation；fsync file 与 generations directory。不得覆盖
   current/previous generation，current pointer 保持旧值。
3. exclusive service 紧邻调用前重验 target authorization，再调用 per-leaf compare-and-swap，比较 exact
   `from_leaf` 并推进到 exact `target_leaf`。CAS response 必须是 backend-authenticated receipt，且其
   operation/root/per-leaf/from/target/authorization identities 与 intent exact 相等；aggregate root
   observation 只能作 diagnostic。
4. 将 receipt 与 exact `external_advanced_phase_digest` append/replace 到 commit journal，record
   predecessor 必须是 intent 的 `prepared_phase_digest`；fsync journal file 与 parent directory。
   若进程在 CAS response 后、此 fsync 前崩溃，durable intent + backend current attestation 仍足以
   重构同一个 external-advanced record；不得要求内存 response 才能恢复。
5. target mirror 保持 byte-immutable；重验其 body/`file_digest` 后，atomic rename `current.json` 到绑定
   target generation/`file_digest` 与 exact `selected_phase_digest` 的新 pointer，重开校验并 fsync pointer
   与 parent directory；再把同一 selected phase append/replace 到 journal 并 fsync。
6. barrier verifier 重新读取 backend current per-leaf attestation、authorization、intent、commit journal、
   immutable target mirror 与 current pointer；leaf target、authorization、四个预绑定 phase digest、
   journal predecessor chain、pointer selected phase 和 mirror bytes/digest 全部 exact 相等后，append/replace exact
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
| intent durable，backend leaf exact `from_leaf` | CAS 未发生；重验 target authorization 后可删除 prepared target 或重试同一 leaf CAS，不得选 target mirror |
| backend leaf exact `target_leaf`，journal 缺 receipt | 验证 authorization、intent 与 immutable prepared target `file_digest`，重算 intent-bound external-advanced phase，向 journal 补写 backend current leaf attestation 并 roll forward |
| backend leaf exact target，journal 已 external_advanced，pointer 仍 previous | 重验 immutable target generation，重算 exact selected phase 后重复 current-pointer rename + file/dir fsync |
| pointer 已 target，external-advanced journal durable 但 selected journal 缺失 | 重验 pointer `selected_phase_digest`、immutable mirror `file_digest` 与 intent；以 external-advanced 为 predecessor 幂等重建 selected record，fsync journal file+parent、重开 exact 校验后才可进入 barrier |
| pointer 与 selected journal 已 target，barrier 未完成 | 重读五方 identity；全等则补写/fsync barrier，否则按下述 mismatch 失败 |
| barrier complete，intent/旧 mirror 未清 | 保持 committed，幂等清理；不得重做 CAS |
| 仅 unrelated leaf/aggregate root observation 前进，本 leaf 仍 exact from/target | 忽略 unrelated change，分别执行同一 retry/roll-forward；不得 `needs_repair` |
| 同一 backend/root/per-leaf authority 的 leaf 既非 exact from 也非 exact target | `needs_repair`；保留两代 mirror、intent、journal，不猜测或覆盖 external leaf |

若 backend 已到 target，但 target mirror 缺失/损坏，说明 pre-CAS durability contract 被破坏；
必须 `needs_repair`，不得退回 previous mirror。若 target 完整，journal 或 pointer 丢失/仍旧则必须
按 intent 重建 roll-forward 路径；这类可证明的 local lag 不得永久报告 unavailable。

多个 unfinished intent 指向同一 leaf 时，只接受 leaf counter 链与 previous/target digest
严格相邻的唯一序列；fork、重复 successor、equal-counter different-digest 或跨 backend/root
identity 一律 `needs_repair`。recovery 按 counter 顺序逐个完成 barrier，不能跳到最大 generation。

## Runtime behavior

每次 hook 的 trusted-time advance 也使用相同 protocol，不得只有 management mutation 才写
external root。hook 在 barrier 前不得执行依赖该 observation 的 committed block；backend/CAS/
IPC 超时或 attestation invalid 时执行既有 conservative denial。经验证的 target-local-lag recovery
可以在 bounded retry 内完成；超过预算返回 nonzero 并留下可由 management recovery 继续的 exact
intent/journal，不得删除或从 previous mirror 放行。

## Implementation ownership

H-010 获批后，下列 owner map 必须一一落到 `tech.md` planned-change manifest；owner 不得互相
重做 identity、CAS 或 recovery 判断：

| Concern | Single owner | Required surfaces |
| --- | --- | --- |
| Hook/management client | Rust `guard_pack::anchor::client` | bounded IPC、request identity、attestation validation；不得直接读 backend |
| Local persistence | Rust `guard_pack::anchor::{mirror,recovery}` | intent、commit、mirror schemas；file/dir fsync、two-generation GC、barrier state machine |
| IPC protocol | Rust `guard_pack::anchor::ipc` | versioned closed request/response schema、peer/session binding、timeouts、replay rejection |
| Core service | Rust `guard_pack::anchor::service` + `scripts/setup/guard-pack-anchor-service/` | endpoint lifecycle、selected platform packaging/health/status；不拥有 H-010 choices |
| External backend | Rust `guard_pack::anchor::backend` | H-010 selected adapter、atomic successor CAS、attested current read、device/backend identity |
| Provision/lifecycle | Rust `guard_pack::anchor::provision` + setup/release integration | create/reattach/rotate/reinstall/device replacement/reset plan、confirmation、receipt、rollback/repair |
| Public schemas | `schemas/guard-pack-anchor-{intent,commit,mirror,ipc,authorization}.schema.json`, `guard-pack-h010-decision` and `guard-pack-anchor-perf-{budget,batch,result}` | closed versions/domains、no self-reference、identity mutation corpus |
| Status renderer | existing `guard_pack::render` | backend/root/leaf/counter、barrier/repair/availability without secret/key material |

Platform service assets 只能进入 manifest 已预留的 setup directory；H-010 必须先选择 supported
platform/backend/service model 并在 approved artifact 固定该目录 inventory。在该 approval 前不得
生成 `tasks.md` 或把 generic service module 冒充为 macOS/Linux/Windows availability。

## Verification manifest

| Gate | Required fresh evidence |
| --- | --- |
| Schema parity | Rust/Python readers share positive/negative corpus for intent/commit/mirror/IPC and closed H-010/budget/batch/result envelopes；unknown, duplicate, empty, mutable phase and cross-record identity mismatch fail visibly |
| Phase construction | golden vectors independently recompute outer-version+body `file_digest` and all four intent-bound phase digests；outer-version-only、mirror body、phase name/order/predecessor、receipt identity or pointer mutations cannot construct the next phase |
| Target authorization | wrong/expired/self-signed authorization, client-chosen target, operation reconstruction drift and every leaf-transition field mutation fail before CAS；valid signed target binds intent/mirror/request/receipt |
| Barrier crash matrix | deterministic fault after every temp fsync, rename, directory fsync, leaf CAS response, commit-journal phase write, pointer selection, barrier and cleanup；exact from retries, exact target reconstructs and rolls forward, same-leaf divergence needs_repair |
| Lost-response recovery | leaf CAS advances but response/journal write is lost while unrelated leaves advance；durable authorization+intent+target mirror+fresh leaf attestation complete barrier without permanent unavailable |
| Cross-platform availability | every H-010 claimed release OS/architecture provisions real selected backend/service, restarts and completes CAS；unclaimed platform reports explicit unsupported and cannot block |
| IPC trust | wrong executable/user/principal, stale session, replayed response, protocol downgrade, endpoint substitution, malformed attestation and service restart all fail closed |
| Identity/lifecycle | fresh provision, idempotent reattach, key/backend rotation, same-device reinstall, Core reinstall, backup restore and device replacement follow each exact H-010 choice；identity ambiguity never auto-resets |
| Failure/repair | backend locked/full/unavailable, IPC timeout, partial provision, forked intents, target mirror corruption and reset interruption preserve evidence and expose the approved repair authority |
| Every-hook performance | canonical [`docs/reference/hook-latency-contract.md`](../../reference/hook-latency-contract.md) `hook_e2e_ms` gate runs every anchor-enabled Claude `~/.vibeguard/run-hook.sh` and Codex `~/.vibeguard/run-hook-codex.sh` installed-snapshot path through real IPC/read/CAS/barrier；reports p50/p95/p99/max plus timeout/queue contention against exact H-010 budgets，not a direct repo hook, mock anchor or management-only path |
| Concurrency | parallel hooks on different leaf authorities advance independently despite aggregate-root changes；same-leaf operations remain recovery-first serialized with unique successors, no forked mirrors and bounded nonzero failure |
| Identity mutation closure | generated `one_field_at_a_time` negatives cover every registered anchor/H-010 identity plus budget/batch/domain/version/signature fields；registry coverage fails when a new identity is unlisted |
| Packaging | verified payload contains client/service/backend/provision modules, schemas and selected platform service assets；fresh no-checkout install proves peer identity and service target |

### Closed H-010 decision and result schemas

所有对象使用 RFC 8785 JCS、closed fields、literal domain 和 semantic outer schema version；digest
始终是 `sha256(JCS({digest_domain, schema_version, body}))`，只排除同 envelope 的 sibling digest 与
signature，body 内不得反向包含自己的 digest。缺字段、unknown/duplicate key、wrong domain/version、
非 canonical bytes 或 digest/signature mismatch 均 nonzero。

```text
h010_decision_envelope = {
  digest_domain: "vibeguard.gh702.h010-decision.v1",
  approved_h010_schema_version,
  h010_decision_body: {
    product_spec_digest, tech_spec_digest, anchor_contract_digest,
    approved_by: [maintainer_id], approved_at, expires_at,
    platform_profiles: [{
      platform_id, backend_profile_id, service_profile_id,
      per_leaf_authority_mode: "independent_authenticated_leaf_v1",
      target_authorizer_profile_id, authorizer_key_id,
      provision_ipc_lifecycle_decisions,
      fixture_budgets: [{
        fixture_id, host_kind, installed_wrapper_path, workload_schedule_digest, runs,
        hook_e2e_p50_ms, hook_e2e_p95_ms, hook_e2e_p99_ms, hook_e2e_max_ms,
        cas_timeout_ms, ipc_timeout_ms, queue_wait_budget_ms,
        contention_total_budget_ms, contention_retry_limit_count
      }]
    }]
  },
  h010_decision_artifact_digest,
  signatures: [{signer_key_id, signature_algorithm, signature}]
}
```

`approved_h010_schema_version` 来自 envelope outer field；
`h010_decision_artifact_digest = sha256(JCS({digest_domain:
"vibeguard.gh702.h010-decision.v1", approved_h010_schema_version, h010_decision_body}))`，preimage
不含 sibling `h010_decision_artifact_digest` 或 `signatures`。`approved_by` 与 `signatures` 均按 ID
排序且 ID 唯一；signer/quorum/algorithm 必须匹配 repository maintainer trust configuration。维护者签名
验证和 validity window 成功后才是 exact approved H-010，Recommended
prose、环境探测或 result 自报均不是来源。

`evaluation_policy_digest` 来自 authoritative active evaluation-policy envelope 的 literal
`vibeguard.gh702.evaluation-policy.v1` domain + schema version + policy body digest；其 body 必须引用 exact
`h010_decision_artifact_digest`。`authoritative_policy_generation` 来自 external policy leaf attestation，
`policy_validity_evidence_digest` 来自该 policy 的 closed signed validity-evidence envelope。三者在运行前/
后 under policy lock exact 相等，不能从 result、budget 或 wall clock推导。

fixture-specific objects 按无环顺序构造：

```text
authority_base_body = {
  approved_h010_schema_version, h010_decision_artifact_digest,
  evaluation_policy_digest, authoritative_policy_generation,
  policy_validity_evidence_digest
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
  confirmation: batch_body(phase=confirmation)|null,
  confirmation_digest: batch_digest(confirmation)|null,
  decision: pass|cleared_transient|confirmed_regression|confirmation_error
}
result_body_digest = H("vibeguard.gh702.anchor-perf-result.v1", schema_version, result_body)
result_envelope = {digest_domain, schema_version, result_body, result_body_digest}
```

这里 `H(domain, version, body)` 是上述 named closed object 的 JCS digest，不是位置字符串拼接。
`budget_body` 必须逐字段重构自 signed H-010 中 exact selected platform/fixture budget，不能接受 result
echo 或 CLI override；`successor_baseline = {per_leaf_authority_id, from_leaf_counter,
from_leaf_digest, target_leaf_counter, target_leaf_digest}`，且 workload schedule 的 closed body digest
必须 exact 等于 H-010 的 `workload_schedule_digest`。所有 `metric_summary`、budget/batch/result field
都是 closed、required 且不允许 alias；confirmation
两字段只能同时为 null（initial 无 breach）或同时为 exact confirmation body/digest。`initial`/
`confirmation` 保存 exact `batch_body`，其 sibling digest 不进入自身 body；result 引用 batch digest，
所以 swap/relabel batch、budget 或 authority 会改变 result digest。`decision_artifact_digest` 的唯一来源
是 literal `vibeguard.gh702.anchor-perf-decision.v1` fixture decision body，不是 H-010 artifact 的 alias，
也不进入自己的 preimage。

### Latency result and decision contract

每个 H-010 approved fixture 产生一个 closed result。identity fields 至少是 `fixture_id`、
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

initial 的 hook 四分位/max 分别比较同名预算；CAS/IPC max 分别比较 timeout，queue/contention max
分别比较其 millisecond budget，contention retry max 比较 count limit。任一 numeric breach 触发同一
fixture identity、inputs、runs、backend/profile 与 workload schedule 的完整 confirmation batch；每批
使用记录的 successor baseline/non-overlapping leaf，禁止为“相同状态” rollback external root。confirmation 必须重测
并保留全部 fields，只有全部回到预算内才是 `cleared_transient`，任一项仍超限即
`confirmed_regression` 并使 CI nonzero。missing/null/non-integer、identity/budget drift、sample error 或
任何 timeout count 非零是 `confirmation_error` 并立即 nonzero，不得用 confirmation 清除。result、budget、
initial、confirmation 与运行前/运行后 authoritative policy read 必须 exact 同一上述 identity；H-010/
policy/budget rotation、generation/validity/decision artifact drift 或任一 mismatch 都立即 nonzero，旧
result 不得 grandfather、重标或由 confirmation 清除，只能用新 identity 重跑全部 fixture。

`tests/test_hook_perf_contract.sh` 必须逐 field 断言 closed shape/units、budget echo、initial 与
confirmation 保留、breach path 与 blocking decision；对 P50/P95/P99/max、CAS、IPC、queue、
contention-time、retry-count 分别注入唯一 breach 并要求 gate nonzero；还要逐一 mutate H-010、policy、
generation、validity evidence、decision artifact 与 budget echo identity 并要求立即 nonzero，再证明仅 numeric transient
且 confirmation 全字段通过时才清除。它还必须固定每个 anchor-enabled Claude/Codex installed fixture
ID 在 runner/budget table/CI/result 中各恰好一次，并用 wrapper 与 anchor-service sentinels 证明真实
installed path 已执行。

schema registry 必须导出下列 exhaustive identity field sets，fixture generator 以
`one_field_at_a_time` 对每个 field 执行 change/delete/cross-record-swap，并证明所有 consumer nonzero；
新增 identity field 却未进入 registry 本身也是 contract failure：

```text
anchor_identity_fields = {
  backend_kind, backend_instance_id, device_key_digest, protocol_version,
  root_id, root_schema_version, principal_id, core_installation_id,
  per_leaf_authority_id, leaf_identity,
  from_leaf_counter, from_leaf_digest, from_leaf_attestation_digest,
  target_leaf_counter, target_leaf_digest, target_leaf_attestation_digest,
  anchor_operation_id, authorized_operation_digest,
  target_authorization_digest, authorizer_key_id, authorization_nonce,
  authorization_expires_at, lock_fence_identity, mirror_generation_id,
  mirror_file_digest, previous_mirror_generation_id, previous_mirror_file_digest,
  prepared_phase_digest, external_advanced_phase_digest, selected_phase_digest,
  barrier_complete_phase_digest, barrier_id
}
h010_identity_fields = {
  product_spec_digest, tech_spec_digest, anchor_contract_digest,
  approved_h010_schema_version, h010_decision_artifact_digest,
  approved_by, approved_at, expires_at, signer_key_id, signature_algorithm,
  evaluation_policy_digest, authoritative_policy_generation,
  policy_validity_evidence_digest, authority_base_digest, fixture_id,
  platform_id, backend_profile_id, service_profile_id,
  per_leaf_authority_mode, target_authorizer_profile_id, authorizer_key_id,
  provision_ipc_lifecycle_decisions, fixture_budgets,
  host_kind, installed_wrapper_path, anchor_enabled, surface,
  workload_schedule_digest, successor_baseline, runs,
  budget_digest, decision_artifact_digest, initial_digest,
  confirmation_digest, result_decision, result_body_digest
}
```

negative corpus 还必须逐项 mutate 每个 budget value、batch phase/runs/metric/timeout/error/breach path、
literal domain、outer schema version、signature/key 与 from/target leaf pairing；同时覆盖 valid unrelated-leaf
advance fixture `unrelated_leaf_advance`（必须成功）和 same-leaf unexpected successor（必须
`needs_repair`），避免把所有 mutation 都粗暴
归类为 global-root mismatch。

planned **tests/test_guard_pack_anchor.sh** owns schema/IPC/lifecycle/crash/concurrency fixtures；planned
**tests/perf_guard_pack_anchor.sh** 可保留 anchor fault attribution 专项，但不得自建发布 SLA gate。
canonical distribution/budget evidence 必须接入 `tests/bench_hook_latency.sh`，并由
`tests/test_hook_perf_contract.sh` 固定每个 anchor-enabled Claude/Codex installed fixture ID、H-010 每项
budget 的 result/confirmation/blocking/CI contract。CI 必须在每个 H-010 claimed platform 运行真实 backend
conformance 或明确、获批且 fail-closed 的 hardware/service fixture；单一 Linux mock 不能证明
cross-platform availability。

本文不规定 backend 实现、平台支持集合、provision/reinstall/device-replacement policy、IPC peer
authentication 或 latency budget；这些必须由 product spec 的未批准 H-010 决定，并由
`tech.md` 的 manifest/verification matrix 证明后才可实现。
