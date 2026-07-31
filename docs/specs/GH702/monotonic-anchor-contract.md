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
- runtime/management 不从缺失记录、目录扫描、较大 generation 或“看起来最新”的时间猜状态。

## Closed identities and records

每次操作以 exact `anchor_operation_id` 绑定下列 identity：

- `backend_identity = (backend_kind, backend_instance_id, device_key_digest, protocol_version)`；
- `root_identity = (root_id, root_schema_version, principal_id, core_installation_id)`；
- `leaf_identity = policy/evaluation | installation/<installation_scope_id> |
  time/<installation_scope_id>`；
- `from_external = (counter, root_digest, leaf_digest)`；
- `target_external = (counter, root_digest, leaf_digest)`，counter 必须是 backend 认可的唯一 successor；
- `mirror_generation_id`、mirror payload digest、previous mirror generation/digest；
- owner transaction/runtime operation、policy/installation generation 与适用 lock/fence identities。

本地 closed persistence set 新增：

```text
anchor/
  intents/<anchor_operation_id>.json       durable pre-CAS intent
  commits/<anchor_operation_id>.json       append/replace commit journal
  mirrors/<leaf_storage_key>/
    current.json                           durable mirror-generation pointer
    generations/<mirror_generation_id>.json
```

mirror generation 保存 exact external attestation identity、leaf payload、own digest、previous
generation/digest 和状态 `prepared | external_advanced | selected | barrier_complete`。每个 leaf
至少保留 current 与 immediately previous 两个 digest-valid generations；target barrier 完成前
不得删除 previous，下一成功 successor barrier 前也不得删除 target 的 recovery predecessor。

## Ordered write protocol

调用者先按 `tech.md` 的 canonical order 取得该 leaf 所需 policy/ownership/target/runtime locks，
并从 backend 读取 fresh authenticated `from_external`；只接受 exact backend/root/leaf identity
以及 current mirror 与 attestation 全等的 base。

1. 生成 closed pre-CAS intent，绑定上述全部 identity、target mirror bytes/digest、expected
   successor、commit-journal path 和 barrier ID；写入临时文件并 fsync，rename 后 fsync intent
   file 与 parent directory。intent durable 前禁止 external CAS。
2. 将 target 写入 inactive mirror generation；fsync file 与 generations directory。不得覆盖
   current/previous generation，current pointer 保持旧值。
3. 调用 external compare-and-swap，比较 exact `from_external` 并推进到 exact
   `target_external`。CAS response 必须是 backend-authenticated receipt，且其 operation/root/leaf/
   previous/target identities 与 intent exact 相等。
4. 将 receipt 和状态 `external_advanced` 写入 commit journal，fsync journal file 与 parent
   directory。若进程在 CAS response 后、此 fsync 前崩溃，durable intent + backend current
   attestation 仍足以证明 target 是否已提交；不得要求内存 response 才能恢复。
5. 把 target mirror 更新为 `external_advanced`，校验/fsync generation；atomic rename
   `current.json` 到 target generation，重开校验并 fsync pointer 与 parent directory。
6. barrier verifier 重新读取 backend current attestation、intent、commit journal、target mirror
   与 current pointer；五者 exact 相等后 append/replace `barrier_complete`，fsync journal 与目录。
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
| intent durable，backend exact `from_external` | CAS 未发生；可删除 prepared target 或重试同一 CAS，不得选 target mirror |
| backend exact `target_external`，journal 缺 receipt | 验证 intent 与 prepared target digest，向 journal 补写 backend current attestation 并 roll forward |
| backend exact target，journal 已 external_advanced，pointer 仍 previous | 重验 target generation 后重复 current-pointer rename + file/dir fsync |
| pointer 已 target，barrier 未完成 | 重读五方 identity；全等则补写/fsync barrier，否则按下述 mismatch 失败 |
| barrier complete，intent/旧 mirror 未清 | 保持 committed，幂等清理；不得重做 CAS |
| backend 既非 exact from 也非 exact target | `needs_repair`；保留两代 mirror、intent、journal，不猜测或覆盖 external root |

若 backend 已到 target，但 target mirror 缺失/损坏，说明 pre-CAS durability contract 被破坏；
必须 `needs_repair`，不得退回 previous mirror。若 target 完整，journal 或 pointer 丢失/仍旧则必须
按 intent 重建 roll-forward 路径；这类可证明的 local lag 不得永久报告 unavailable。

多个 unfinished intent 指向同一 leaf 时，只接受 external counter 链与 previous/target digest
严格相邻的唯一序列；fork、重复 successor、equal-counter different-digest 或跨 backend/root
identity 一律 `needs_repair`。recovery 按 counter 顺序逐个完成 barrier，不能跳到最大 generation。

## Runtime behavior

每次 hook 的 trusted-time advance 也使用相同 protocol，不得只有 management mutation 才写
external root。hook 在 barrier 前不得执行依赖该 observation 的 committed block；backend/CAS/
IPC 超时或 attestation invalid 时执行既有 conservative denial。经验证的 target-local-lag recovery
可以在 bounded retry 内完成；超过预算返回 nonzero 并留下可由 management recovery 继续的 exact
intent/journal，不得删除或从 previous mirror 放行。

本文不规定 backend 实现、平台支持集合、provision/reinstall/device-replacement policy、IPC peer
authentication 或 latency budget；这些必须由 product spec 的独立未批准 H decision 决定，并由
`tech.md` 的 manifest/verification matrix 证明后才可实现。
