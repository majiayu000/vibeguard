# Tech Spec — 分层语义防御与运行时 W-rule 信号

## Linked Issue

GH-704

## Product Spec

[`product.md`](product.md)

Status: Draft；本文件只描述 **Recommended proposal（未批准）** 的一条完整参考路径。
它不批准任何 H-001–H-020 决策，不创建 `tasks.md`，也不授权实现。

## Codebase Context

下表 14 个 codebase anchor 均在本 corrective branch 的 current base
`origin/main@1bf5018ec2de4d28e080f1f56be79d4d9e4f8120` 读取。最后两个相邻
workstream row 额外记录已合并 PR 的完整 source-head SHA，作为来源 provenance；两个
source head 都是该 current main 的祖先，不是替代 baseline。

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Runtime dependency/dispatch | `vibeguard-runtime/Cargo.toml:8-16`; `vibeguard-runtime/src/main.rs:68-516` | 仅有 JSON/regex/libc/toml 依赖和现有 hook/metrics/setup/config 命令；没有 model、inference、network client 或 semantic-defense command | L2 是新 Core production capability，不能声称已有 provider |
| Runtime config | `vibeguard-runtime/src/runtime_config.rs:11-104,106-171,174-223`; `schemas/vibeguard-runtime-config.schema.json:1-114` | config 被进程缓存；int/string/list getter 可由 env override；schema 新增 managed-skill opt-out，但没有 semantic tier/model/provider/network policy | 新配置必须 closed、fail-visible，并阻止未批准 env/provider 改 trust policy |
| Runtime event identity | `vibeguard-runtime/src/event_schema.rs:9-41`; `vibeguard-runtime/src/hook_orchestrator.rs:650-688` | `RULE_ID` 常量存在，但 canonical Rust append 没写 `rule_id`/`signal_id`，仍写 free-text reason/detail | precision、metrics、Learn 需要一条结构化权威投影 |
| Existing W-12 | `vibeguard-runtime/src/hook_orchestrator.rs:231-241`; `guards/universal/check_test_weakening.sh:105-165,211-232`; `rules/claude-rules/common/workflow.md:100-125` | runtime 阻止 test-infra 写入；deterministic guard 识别 assertion/skip/source/test surface | L2 只能增加 baseline 未覆盖的 semantic delta，不能重复实现或降低 block |
| Existing W-02/W-15 | `vibeguard-runtime/src/hook_orchestrator_post_edit_history.rs:103-159,355-390` | edit count + consecutive build failures 给 W-02 相邻提示；shrinking radius 已给 W-15 runtime warning | H-010 必须选择 exact delta；edit count 本身不能证明同一 hypothesis 失败 |
| Existing W-16 | `vibeguard-runtime/src/hook_orchestrator_stop.rs:61-135` | source edit 后无 verification 会 advisory；读取历史失败或 malformed event 会跳过 | 这是 baseline，不可重新计作 GH-704 的第二条新增 W-rule |
| Session metrics | `vibeguard-runtime/src/session_metrics/signals.rs:14-177`; `vibeguard-runtime/src/session_metrics/engine.rs:49-193`; `schemas/session-metrics.schema.json:1-45` | correction signals 是 free-text string；metrics write error 被忽略 | 必须迁到 typed signal，写失败可见，不能从字符串重建 rule identity |
| Precision | `scripts/precision-tracker.py:42-60,273-331`; `data/rule-scorecard.seed.json` | repo-local tracker 用现有固定阈值和 TP/FP/acceptable；它不是 model/policy/corpus-bound L2 approval | H-008 需新 evidence binding；旧 threshold 不得自动复用 |
| Eval | `eval/run_paired_eval.py:13-40`; `eval/paired/thresholds.json:1-10`; `eval/model_baseline.py:17-21` | paired eval 是 commit-pinned prompt rule evaluator；thresholds 未 calibrated，Claude alias 是 eval provider | 不能当 production L2 provider、precision 或 latency 证据 |
| Learn | `docs/specs/learn-first-class-signal-inbox.md:86-104,123-131,299-314`; `schemas/learn-signal.schema.json:7-24,44-67,119-147`; `scripts/learn/analyze.py:287-316,323-390`; `scripts/learn/adoption.py:17-25,92-122` | 已有 Signal Inbox → Adoption Compiler → Outcome Evaluator；stable ID 当前仍可能以 reason text 归一化；禁止自动 mutation | GH-704 必须扩展该合同，不建第二套 learning state |
| Latency | `tests/bench_hook_latency.sh:1-67,360-458,460-506`; `tests/test_hook_perf_contract.sh:1-28`; `docs/reference/hook-latency-contract.md:5-23,27-47` | canonical runner 执行真实 direct/wrapper hook，记录 P50/P95/P99/max、budget 与 confirmation；contract test 固定 runner/gate 语义 | cold/warm L2 必须成为这个 runner 的具名 fixtures，并由 contract test 固定，不能只改 wrapper 或另造 microbench |
| Doctor/status | `setup.sh:24-36,115-175`; `scripts/setup/check.sh:1-23,34-41,754-799`; `scripts/setup/runtime_config_health.sh:1-36`; `scripts/lib/status_report.sh:1-28,120-158,195-280`; `vibeguard-runtime/src/main.rs:168-173`; `vibeguard-runtime/src/hook_status.rs:1-90,428-459`; `vibeguard-runtime/src/hook_status_render.rs:7-39,159-209`; `schemas/hook-status.schema.json:1-82` | `doctor`/`--check` 是 public install/config health route；`hook-status` 已提供 per-run human/JSON 和 closed schema | H-014 推荐复用这两个 route；B-035 需要把 semantic state/identities 接入同一 canonical event/status renderer，而不是只在 hook 文本中显示 |
| GH-700 (separate PR evidence) | PR #713 merged source head `215a45157b1e7de94fcd813c745f8ac70e047072`, `docs/specs/GH700/product.md:65-74,104-118` | Spec 明确真正的 dependency/API inventory detector 尚不存在，benchmark 禁止 test-only detector | GH-704 生产 detector 是 GH-700 后续消费依赖；spec merge 不是实现或 precision 批准 |
| GH-702 (separate spec evidence) | PR #716 merged source head `4d431c22dcbe56b9d3ce10d96b28ed8c215d6f37`, `docs/specs/GH702/product.md:69-73,94-112,295-310,322-324,352-368` | pack executable/capability、precision/default、network/offline 仍是未批准 H 决策；current invariants 继续要求 per-rule eligibility、显式 feedback export 与 stale/offline 降级 | GH-704 只交付 sealed Core；不得提前批准 pack 暴露或第二套 policy |

## 技术决策门（全部未批准）

除 product 的 H-001–H-014 外，以下实现选择也是 **UNAPPROVED human decisions**。
Recommended proposal 只定义 manifest 中的一条完整参考路径；任一项改变都必须先修订
product/tech 和 planned-changes manifest，再写 tasks。

15. **H-015 — process/transport protocol（未批准）**：sidecar 生命周期、stdin/stdout
    framing、request/response schema、握手、health、cancel、exit/status code、stderr 与
    sandbox。**Recommended proposal（未批准）：每次 bounded request 通过参数数组启动
    release-managed local sidecar，length-prefixed JSON over stdio，closed handshake，
    无 shell、无 inherited secret env、无 daemon。**
16. **H-016 — state/cache/locking（未批准）**：cache root、ownership、atomic write、
    lock 粒度、TTL/size、crash recovery 与 cleanup。**Recommended proposal（未批准）：
    project-hash + session ID + policy/model digest 分区的 content-addressed cache，
    per-key lock、atomic replace；只存 result/evidence digest，不存 raw source，不允许
    cross-session reuse。**
17. **H-017 — event/schema migration（未批准）**：event-log version bump、旧 reader、
    dual write/read、free-text precision projection 退役与 corrupt history policy。
    **Recommended proposal（未批准）：新增 typed optional `rule_signal` object 并提升
    schema；迁移期 reader 显式区分 legacy/untracked，但不 dual-write 两个权威事实源。**
18. **H-018 — dependency inventory adapters（未批准）**：首批 language/package
    manager、lockfile/source of truth、feature/version resolution、generated/dynamic API
    状态和 adapter ownership。**Recommended proposal（未批准）：v1 只支持
    TypeScript + npm-compatible lockfile，并从 exact installed package 的 declaration/
    export map 建立 inventory；其它 ecosystem 返回 unsupported。**
19. **H-019 — eval/scoring architecture（未批准）**：corpus schema、review separation、
    scorer、platform/language slices、calibration、evidence signing 和 CI/release gate。
    **Recommended proposal（未批准）：独立 semantic dataset/ground-truth/mapping，
    production binary 重放；scoring deterministic，model 不参与 ground-truth/judge。**
20. **H-020 — packaging/update/revoke（未批准）**：model/sidecar 是主 payload、可选
    release asset 或独立 installer component；download confirmation、checksum/
    attestation、rollback、revoke 与 no-clone smoke。**Recommended proposal（未批准）：
    复用 GH-699 最终 verified release identity，semantic asset 为显式 opt-in、同 tag
    签名的可选 component；GH-699 actual launcher 未完成前只能 unofficial。**

## 设计方案

### 1. Approval gate 与 canonical policy

实现入口先加载一个 closed `semantic-defense-policy`。policy 必须绑定 H-001–H-020 的
批准记录/digest、config schema version、model/provider/protocol identities、允许的
checks/W-rules、host/trigger、privacy/network、latency、precision、failure semantics
和 rollout stage。

加载顺序固定：

```text
closed config
  → approval/policy digest join
  → provider/model/release provenance
  → host/trigger + privacy/network eligibility
  → detector/W-rule + latency/precision eligibility
  → effective off/advisory/block
```

任何 join 缺失、空值、未知、冲突或 drift 都在模型执行前产生 structured
`unavailable/error`。普通 env getter 不得覆盖 model digest、provider、network、
precision floor 或 block eligibility；只有 H-001 明确列出的降级/kill-switch env 可生效。

H-001 Recommended project opt-in（仍未批准）的唯一 enable surface 是当前 hook payload
所指 repository root 的 `.vibeguard.json`：planned `semantic_defense` object 只接受 required boolean
`enabled`，且 `additionalProperties: false`。key 缺失或 `enabled: false` 均为 off；
`enabled: true` 只是请求 eligibility，仍必须通过上述 approval/policy/model 等全部 join。
`~/.vibeguard/config.json`、普通 env、README、pack 与相邻 project 都不能启用；获批的
global kill switch 只能把 true 降为 off。现有 `VIBEGUARD_PROJECT_CONFIG` path override
仍可服务通用 config validation/test，但不得成为 semantic enable source：semantic join
必须先解析 current hook payload，并按闭集优先级 `cwd > params.cwd > workspace.cwd >
workspace.current_dir` 选择 cwd。被选值必须是 non-empty absolute path；在调用
`canonicalize`/`git_root_for` 前先用 `Path::is_absolute` 拒绝 `.`、`..` 与其它 relative
值，禁止它们相对 ambient process cwd 解析。随后用 existing
`git_root_for(absolute_payload_cwd)` 从 canonicalized payload directory 求 git root，再
只接受该 root 下 exact `.vibeguard.json` 的 typed value。`hook_orchestrator` 必须在
`RuntimeContext::collect()` 和 semantic config join
之前解析 payload，并把这个 typed project root 传给 `evaluate_core`；ambient process
cwd、env cwd 与后续重新读取 current directory 都不能参与 enable 判定。payload cwd
缺失、空、relative、非目录、无法 canonicalize 或无法求 git root 时返回可见
`unavailable/error`，且 provider/cache/metrics activity 为零；override 指向 sibling/
external opt-in file 时保持 off。任何
`VIBEGUARD_SEMANTIC_DEFENSE*` enable env 同样无效且不能作为隐式默认。
`schemas/vibeguard-project.schema.json`、`project_config.rs` 的 typed field/closed allowlist
与 semantic config join 必须同源；unknown/type mismatch 在 provider 启动前 fail visible。
同一 HOME 下 opt-in project 与无 key project 的双 fixture，以及 process cwd A +
payload absolute cwd B、process cwd A + payload `.`、四个 payload 字段 absolute A/B
precedence、missing/invalid payload cwd、external path/env enable negative fixtures，
必须证明只有 absolute payload-precedence project 可请求 eligibility，其余路径零
provider/cache/metric activity。

### 2. Recommended Core module boundary

未批准的参考模块：

```text
semantic_defense/
  mod.rs              orchestration; no provider-specific policy
  config.rs           closed approved policy/config join
  identity.rs         model/protocol/policy/input/evidence identities
  protocol.rs         untrusted request/response validation
  provider.rs         sealed local-sidecar adapter and cancellation
  inventory.rs        approved dependency/API inventory adapters
  test_weakening.rs   deterministic-baseline join + semantic delta
  runtime_signal.rs   typed W-rule evidence/state machine
  cache.rs            project-scoped content-addressed result cache
  metrics.rs          latency/outcome projection without raw input
```

`vibeguard-runtime/src/lib.rs` 必须公开唯一
`vibeguard_runtime::semantic_defense::evaluate_core` production entrypoint；`main.rs` 只注册
canonical semantic command/handler 并调用该 library entrypoint，benchmark 也 import 同一
entrypoint。binary-private duplicate module、`#[path]` 重载、复制 reducer 或 benchmark-only
实现均禁止。Claude/Codex hook adapter 均调用同一 Rust orchestration。provider 不接受
arbitrary command/path/endpoint；模型输出先经 protocol validator，再经 deterministic
policy reducer，不能直接选择最终 block。

### 3. Hook data flow 与 precedence

```text
host hook event + canonical project/session identity
  ├─ existing L1 deterministic checks ───────────────┐
  └─ approved trigger                                │
       → minimal diff/inventory view                 │
       → input digest + cache lookup                 │
       → bounded local provider request              │
       → closed L2 result validator                  │
       → detector/W-rule deterministic reducer       │
       → typed rule_signal + precision evidence      │
                                                     ▼
approved precedence table → candidate hook decision
                                      → project canonical durable pending event
                                      → bounded idempotent reconciliation
                                           ├─ session metrics
                                           ├─ precision projection
                                           └─ Learn analyzer candidate
                                      → project finalized receipt
                                      → release finalized hook decision
                                      → idempotent derived global projection
```

L1 总是先独立得出结果。L2 只有在全 gate eligible 时运行；off/unavailable/error 不被
归一为 pass。最终 decision reducer 是 exhaustive pure function，输入包括 L1 result、
L2 result/status、approved severity、failure mode 和 eligibility；未知组合拒绝而不是
fallback。L2 block eligibility 还要求同一 event 的 finalized receipt；pending/replay
状态只能显示为 degraded/error，不能阻止既有 L1 block 返回。

H-006/H-011 Recommended 首阶段明确是 synchronous advisory：post-edit handler 在当前
hook invocation 内执行 bounded provider request、投影并返回 advisory，hard timeout/
cancel 后立即回收 child 并返回可见 unavailable/error。没有 detached worker、daemon、
durable inference queue 或 later-hook delivery；因此 canonical installed-hook latency
fixture 必须包含 provider wait 与当前 response rendering。若维护者改选 async，必须先
新增 queue/delivery/recovery contract 并改写 H-006/H-011、manifest 与测试，不得在 tasks
中局部实现。

### 4. Invented API production detector

`inventory.rs` 只加载 H-018 获批 adapter 的 closed inventory artifact。artifact 至少绑定
project/dependency lock digest、language/ecosystem、package/version/features、symbol
namespace、generator/dynamic flags、schema/adapter version 和 provenance。

detector 输入是 resolved call/reference + exact inventory snapshot；输出只允许
`exists/not_found/unknown/unavailable/error` 和 closed reason。dynamic/generated/
conditional/ambiguous 进入 unknown，而不是让 model 猜。semantic provider 可以对
source reference 与 inventory candidate 做分类，但最终 `not_found` 必须由 deterministic
inventory join 支撑。GH-700 以后只能调用这个 production handler 和 mapping。

### 5. Semantic test-weakening delta

现有 `check_test_weakening.sh` 先保留为 baseline contract。Recommended path 把可共用的
deterministic diff classification 收敛到 Rust `test_weakening.rs`，shell guard 变成同一
Core handler 的薄 adapter，避免 Python/hook path 和 Rust L2 分叉。迁移前后现有 W-12
positive/negative corpus必须 byte-for-decision 等价。

只有 baseline outcome 为“未命中且输入受支持”时，才创建最小 before/after semantic
view。L2 result 必须说明 weakened behavior identity 与 evidence digest；最终 reducer
还需 deterministic proof that assertion/test mapping existed before and after。unsupported
framework、generated/snapshot ambiguity、mapping failure 都返回 unknown。

### 6. Typed W-rule signal 与 state machine

新增 `rule_signal` closed object，不再把 `reason` 当 identity：

```text
schema_version
rule_id
signal_id
signal_kind
project_hash
session_id
ordered_event_ids
window {start, end, attempts}
detector/model/protocol/policy identities | null
evidence_digest
decision
status
reason_code
```

H-010 推荐 W-02/W-12 仍未批准。若批准：

- W-02 reducer 只消费同一 stable hypothesis 的 ordered attempts，每次 attempt 必须有
  edit/action evidence 和随后 fresh verification failure；旧 edit-count/churn 只可作为
  candidate context。
- W-12 reducer 将 test-infra block、deterministic weakening、semantic weakening 作为
  三个 closed signal kinds；同一 change 由 precedence 去重，不重复计数/升级。

现有 W-16、W-13、W-14、W-15 signal 同步迁到结构化 identity 可以作为必要迁移，但除非
H-010 明确批准新的行为 delta，不计入 GH-704 的“新增两条”。

state machine 的 window/threshold/reset/cooldown/suppression 全来自 approved policy。
event history read/parse/append error 产生结构化 degraded/error；不能像当前部分 reader/
metrics writer 一样静默跳过后仍声称完整证据。

### 7. Precision 与 semantic eval

新 semantic evidence 与现有 aggregate scorecard 分离命名，但由一个 canonical
projection 消费 runtime event。每条 evidence 绑定 detector/check/rule、model/protocol/
policy、corpus/ground-truth/production mapping、platform/language、input/evidence digest
和 reviewer identities。

semantic eval 运行真实 production binary：

```text
versioned fixtures
  + independently reviewed ground truth
  + closed production mapping
  → exact release/runtime + semantic asset
  → per-case raw production result
  → deterministic scorer
  → TP/FP/FN/TN + unclassified/error + latency slices
  → signed/digested eligibility evidence
```

GH-686 paired thresholds、GH-700 headline、model confidence、aggregate pack precision 与
当前 `precision-tracker.py` 常量都不是 H-008 approval。tracker 可以显示/导入经过 schema
验证的 semantic evidence，但不能用旧 denominator 或阈值自动 promotion。

### 8. Metrics、Learn 与 global view 的唯一权威投影

GH-704 semantic records 的唯一权威源是 current payload project 下的 typed journal。
同一 project journal lock 下的 append protocol 固定为：

1. 读取 journal tail offset，构造 bounded typed pending body/digest；
2. 向 project `reconciliation.wal` 追加 `prepared` recovery intent，其中包含 event/signal
   ID、完整 bounded body、digest、expected journal offset 与 schema version；fsync WAL，
   再提交新的 checksummed queue-metadata generation；
3. 只在 expected offset 追加 typed `rule_signal` pending event 并 fsync project journal；
4. 向 WAL 追加 `journaled` transition 并 fsync/提交 queue metadata，然后才投影 consumer。

crash 在 step 2 commit 前只会留下可截断的 uncommitted WAL tail，不存在 canonical event；
step 2 commit 后/step 3 前由 recovery intent 补 append；step 3 后/step 4 前只读取 expected
offset 的 bounded record 并比较 event ID + digest，匹配则补 marker，不匹配则
`needs_repair`，禁止盲目追加。这样 journal 一旦出现 pending 就总有先行 recovery intent，
同时 WAL 只负责 recovery、不成为可查询的第二 semantic authority。随后唯一 projector
投影到：

- session metrics：closed signal aggregates，而不是 `Vec<String>`；
- precision：exact identity 的 outcome/evidence record；
- Learn：project-scoped `defense_gap` candidate input。

每个 consumer 必须以 event/signal ID 幂等，并持久化自身 applied receipt；三个 consumer
均成功后 projector 才向 project journal 追加 finalized receipt，其中绑定 pending event
ID、consumer schema/version 与 applied receipt digests，并以 WAL `done` transition 推进
head cursor。queue metadata 使用两个 checksummed generations，只保存 committed
head/tail cursor、pending count 与 oldest timestamp；每条 WAL record 有 closed maximum
length。startup 与每次 hook 在启动新 provider前只读取 fixed-size metadata header，再从
head cursor oldest-first 处理，直到 policy 中 H-006/H-007 已批准的正整数
`reconcile_batch_max`、`reconcile_deadline_ms` 或 `reconcile_io_max_bytes` 任一先到；
deadline/byte counter 从 open/stat/header/WAL parse 与 expected-offset journal read 就开始，
不得先反序列化完整 index，也不得扫描完整 journal、其它 project 或 HOME。缺少合法
limits、两个 metadata generation 均 corrupt、record length/offset/digest 非法、consumer
unavailable 或 batch 后仍有 pending 时，本次状态为 `needs_repair/
reconciliation_backlog/unavailable`；可证明时输出 pending count 与 oldest age，损坏时
对应值为空并标明原因。所有这些状态都保留 durable WAL/L1 decision，且不启动 provider、
不追加新的 GH-704 pending event。后续 hook 仍先尝试 bounded batch，使正常 backlog 可
排空而不让同步路径无界增长；corrupt 状态不得自动删除、猜测或 full-scan rebuild，只能由
`setup.sh doctor`/`--check` 指出项目、损坏 generation/reason 与 H-016 批准的显式人工
repair 要求，在该决定批准前保持 L2 disabled。重放不得重复计数、candidate 或 escalation；
crash 可发生在 WAL prepare/metadata commit/journal append/journaled marker、任一 consumer
write 或 finalized/done transition 前后，恢复后都必须在 bounded I/O 内收敛或明确
`needs_repair`。

既有 L1 project/global dual logging 行为不属于 GH-704 migration，保持原合同。GH-704
typed pending/applied/finalized record 禁止独立 dual append；project finalized record
才可进入 global derived projector。derived record 必须绑定 source project hash、event
ID、finalized digest 和 projection schema version；project-scoped durable cursor/receipt
以该 identity 幂等。project finalized fsync 与 global append 之间失败时报告
`projection_lag`；global append 后、projection receipt 前失败时重放必须 dedupe。global
status/aggregate 不得从 mirror 推断 L2 eligibility，只能 join canonical finalized digest，
未同步时返回 lag + 空值。global projection 不是 project finalization consumer，不能
反写或改变 canonical decision。legacy free-text event 可以显示为 `legacy_untracked`，
但禁止正则猜 rule identity 后进入 block precision。

Learn 扩展现有 schema，新增一个 closed semantic-defense signal type和 typed source
identity；stable ID 使用 project + rule/signal/evidence class，不使用可变 reason 文本。
`analyze.py` 继续做 deterministic scoping/count/dedupe；`adoption.py` 继续约束
`defense_gap` action space。模型只能生成解释候选字段，不能写 triage/adoption state。

H-014 Recommended reference path（未批准）不新增第三个 semantic status 命令：

- `setup.sh doctor`/`--check` 继续作为 public install/config health route；
  `scripts/setup/runtime_config_health.sh` 读取 canonical semantic config/model/provider/
  policy eligibility，`scripts/lib/status_report.sh` 保持 human/JSON 同源；
- `vibeguard-runtime hook-status` 继续作为 per-run public status route；`HookStatusEntry`、
  human renderer、JSON renderer 与 `schemas/hook-status.schema.json` 增加同一份
  `semantic_status`、rule/signal/model/policy identities 与 evidence digest；
- event log、precision 与 Learn 只消费上述 canonical project typed event。doctor 的
  latest project status 也从该 event/status contract 读取；global derived view 只有
  finalized digest 匹配时才可显示数据，否则显示 `projection_lag`，不能从 free-text 或
  stale mirror 重建、自行改变状态。

`tests/test_setup_check.sh` 固定 doctor/`--check` human/JSON、exit 和 no-data 语义；
`tests/test_hook_status.sh` 及 Rust `hook_status_tests.rs` 固定 per-run human/JSON/schema
identity equality。若维护者选择新 semantic 命令，先改写 H-014 与本 manifest；tasks
不得局部改路由。

### 9. Privacy、process、cache 与 interruption

Recommended local-sidecar path（未批准）使用参数数组和 closed stdio protocol；child
环境 allowlist 不含 token/proxy/HOME secrets，cwd 指向专用 temp root，禁止网络和任意
filesystem traversal。stderr 先分类/redact，再进入 bounded diagnostic。

request 在 deadline/cancel 时终止 child 并回收；cache/journal 只在记录的 dedicated root
下 atomic write/cleanup。cache value 不含 raw source/prompt/output。cache identity 和
storage partition 都包含 project hash + session ID + input/model/protocol/policy digests；
仅同一 project/session 的并发同 key 使用 bounded lock，不同 session 即使输入相同也不能
读写同一 result。kill switch 不删除 L1 state，关闭后不再启动任何 L2 request。

独立 `core_us` 证据由 planned **tests/bench_semantic_core.sh** 驱动 planned
**vibeguard-runtime/benches/semantic_defense_core_us.rs** 的同进程 harness，并 import
`vibeguard_runtime::semantic_defense::evaluate_core`；fixture ID
固定为 `semantic-defense-core-cold-cache` 与 `semantic-defense-core-warm-cache`。
harness 必须调用 production `semantic_defense` core 入口，不得复制 reducer、按 case ID
返回或使用 eval-only detector。计时边界只包含 inventory-bound semantic reducer、typed
result validation、eligibility join 与 bounded cache lookup/write；不包含 Cargo/process
startup、hook wrapper、stdio/config discovery、event projection、sidecar process 或模型
执行。initial 与 confirmation batch 的每一个 cold sample 都必须在计时边界外删除并
重建其 exact project/session cache root、重置 provider-start state，随后断言 cache/provider
state 为空才开始计时；不能只在 fixture 或 batch 开头清空一次。每一个 warm sample 都在
计时边界外预先写入同一 exact input/inventory/detector/model/protocol/policy/project/
session identity 的合法 cache，并断言 warm hit 前提后才计时。reset/prewarm/assertion
任一失败使 runner nonzero。两者使用同一 sealed provider-result fixture，使差值只归因于
core cache path。

core runner 必须输出 versioned JSON，逐 fixture 记录 `surface=core_us`、exact fixture ID、
P50/P95/P99/max、runs、platform、cache state、detector/model/protocol/policy identities、
approved budget、initial/confirmation batches 与 decision。H-006 批准前 budget 为空且不得
作为 promotion evidence；批准后缺 budget/identity、零样本或字段不匹配必须 nonzero。
healthy initial P95 breach 只允许用同 identity/workload 的 fixture-local confirmation
batch 清除；confirmed breach、confirmation error 或 environment distortion 都不得被
写成 pass。`tests/test_hook_perf_contract.sh` 必须固定两个 exact IDs 在 harness、runner、
`docs/reference/hook-latency-contract.md`、benchmark design、CI/result contract 中各一次，
并运行 compile-only smoke，防止 “running 0 benchmarks” 或只生成 Criterion report
冒充 B-010 的 percentile evidence。

L2 installed-path latency 必须接入 `tests/bench_hook_latency.sh` 的 canonical
`hook_e2e_ms` runner，
fixture IDs 固定为 `semantic-defense-direct-cold-cache`、
`semantic-defense-direct-warm-cache`、`semantic-defense-codex-wrapper-cold-cache` 与
`semantic-defense-codex-wrapper-warm-cache`。每个 fixture 只测量一个真实 installed
hook path 的完整 config/provider/logging/cleanup 路径，不得把 direct 与 wrapper 合并
计时；每次结果都包含 synchronous provider wait 和同一次 hook response，不能在 provider
完成前停止计时。initial 与 confirmation batch 的每一个 installed cold sample 都必须在
计时边界外清空 exact session-scoped cache、终止并重置 provider-start state，再以 canary
证明二者为空；每一个 warm sample 都必须在计时边界外预热并验证同一 project/session/
input/model/protocol/policy identity 的合法 cache。任一 reset/prewarm/canary 失败使 runner
nonzero，不能继续采样或把 warm process/cache 伪报为 cold。
`tests/test_hook_perf_contract.sh` 必须断言四个 ID 在 runner、
`docs/reference/hook-latency-contract.md` budget table、CI/result output contract 中各恰好
登记一次，并固定 cache 前提、H-006 批准后的 P95 budget、confirmation、CI wiring 与
path-specific 结果字段；缺少任一 installed path、把两个 path 聚合、只跑 `core_us` 或
新增旁路 runner 都不能满足 B-010。这里固定 fixture identity，不批准 H-006 的任何
budget 数值。

### 10. 相邻 workstream 边界

- **GH-700**：GH-704 负责真实 Core invented-API production detector 和 mapping；
  GH-700 只消费已合并接口。其 Draft corpus/metric 口径不能反向批准 GH-704 precision。
- **GH-702**：GH-704 不依赖 Draft pack 实现即可交付 Core。未来 pack 只能在 GH-702
  H-002/H-006/H-007/H-009 获批合并后引用 sealed capability ID；不能携带 executable、
  model/provider 或改变 Core eligibility。
- **GH-699**：H-020 推荐路径依赖其最终 actual launcher、verified optional component
  与 no-clone native smoke。该能力合并前，semantic asset 只能标 unofficial/dev。
- **Learn**：扩展现有 Signal Inbox/Adoption/Outcome，不新建第二个 state file 或自动
  mutation pipeline。
- **Existing runtime W-rules**：结构化 schema migration 是基础设施；只有 H-010 批准的
  observable delta 才算 GH-704 新行为。

### 11. Planned affected files

下列 manifest 对 **Recommended local-sidecar + TypeScript/npm reference path（仍未批准）**
是一条完整 implementation ownership map。它不是 tasks 或实施授权。`semantic-sidecar/`
包含 provider executable source；exact model/weights 不进入 git，其 identity/provenance
写入 planned **data/semantic-model-manifest.json**，获批权重是由
`.github/workflows/semantic-assets.yml` 生成并绑定 release 的外部 asset。这样
`complete: true` 只表示该 reference path 的 repo source、schema、policy、asset build/
install、doctor/status、canonical latency runner、tests 与 docs surface 无遗漏，不表示
H-001–H-020 已批准。当前共 103 条唯一 repo paths：63 条 existing、40 条 planned。
`semantic-sidecar/` 是新 product root，因此 `docs/directory-map.md` 必须同步登记。任一
决定改变 provider、ecosystem、host、packaging、policy、status route 或 tests 时，
必须先修订此 manifest；`tasks.md` 不得增加未列 surface。

<!-- specrail-planned-changes -->
```json
{
  "issue": 704,
  "complete": true,
  "paths": [
    "vibeguard-runtime/Cargo.toml",
    "vibeguard-runtime/Cargo.lock",
    "vibeguard-runtime/benches/semantic_defense_core_us.rs",
    "vibeguard-runtime/src/lib.rs",
    "vibeguard-runtime/src/main.rs",
    "vibeguard-runtime/src/project_config.rs",
    "vibeguard-runtime/src/runtime_config.rs",
    "vibeguard-runtime/src/runtime_config_validation.rs",
    "vibeguard-runtime/src/event_schema.rs",
    "vibeguard-runtime/src/hook_orchestrator.rs",
    "vibeguard-runtime/src/hook_orchestrator_context.rs",
    "vibeguard-runtime/src/hook_orchestrator_post_edit_history.rs",
    "vibeguard-runtime/src/hook_orchestrator_stop.rs",
    "vibeguard-runtime/src/session_metrics/signals.rs",
    "vibeguard-runtime/src/session_metrics/engine.rs",
    "vibeguard-runtime/src/hook_status.rs",
    "vibeguard-runtime/src/hook_status_render.rs",
    "vibeguard-runtime/src/hook_status_tests.rs",
    "vibeguard-runtime/src/semantic_defense/mod.rs",
    "vibeguard-runtime/src/semantic_defense/config.rs",
    "vibeguard-runtime/src/semantic_defense/identity.rs",
    "vibeguard-runtime/src/semantic_defense/protocol.rs",
    "vibeguard-runtime/src/semantic_defense/provider.rs",
    "vibeguard-runtime/src/semantic_defense/inventory.rs",
    "vibeguard-runtime/src/semantic_defense/inventory_adapters/mod.rs",
    "vibeguard-runtime/src/semantic_defense/inventory_adapters/typescript_npm.rs",
    "vibeguard-runtime/src/semantic_defense/test_weakening.rs",
    "vibeguard-runtime/src/semantic_defense/runtime_signal.rs",
    "vibeguard-runtime/src/semantic_defense/cache.rs",
    "vibeguard-runtime/src/semantic_defense/metrics.rs",
    "vibeguard-runtime/tests/project_config_cli.rs",
    "schemas/vibeguard-project.schema.json",
    "schemas/vibeguard-runtime-config.schema.json",
    "schemas/event-log.schema.json",
    "schemas/session-metrics.schema.json",
    "schemas/hook-status.schema.json",
    "schemas/semantic-defense-policy.schema.json",
    "schemas/semantic-defense-model.schema.json",
    "schemas/semantic-defense-result.schema.json",
    "schemas/runtime-rule-signal.schema.json",
    "schemas/semantic-defense-evidence.schema.json",
    "schemas/learn-signal.schema.json",
    "data/semantic-defense-policy.json",
    "data/semantic-model-manifest.json",
    "semantic-sidecar/Cargo.toml",
    "semantic-sidecar/Cargo.lock",
    "semantic-sidecar/src/main.rs",
    "semantic-sidecar/src/model.rs",
    "semantic-sidecar/src/protocol.rs",
    "semantic-sidecar/src/sandbox.rs",
    "guards/universal/check_test_weakening.sh",
    "scripts/precision-tracker.py",
    "scripts/learn/analyze.py",
    "scripts/learn/adoption.py",
    "scripts/ci/self-application/check-u22-coverage.sh",
    "setup.sh",
    "scripts/setup/check.sh",
    "scripts/setup/install.sh",
    "scripts/setup/runtime-install.sh",
    "scripts/setup/runtime_config_health.sh",
    "scripts/lib/status_report.sh",
    "scripts/release/payload-manifest.txt",
    "hooks/manifest.json",
    "eval/semantic/dataset-v1.jsonl",
    "eval/semantic/ground-truth-v1.json",
    "eval/semantic/production-mapping-v1.json",
    "eval/semantic/thresholds-v1.json",
    "eval/semantic/fixtures/typescript_npm/",
    "eval/run_semantic_eval.py",
    "eval/test_semantic_eval.py",
    "tests/hooks/test_semantic_defense.sh",
    "tests/hooks/test_runtime_policy_json.sh",
    "tests/hooks/test_runtime_rule_signals.sh",
    "tests/fixtures/semantic_defense/typescript_npm/",
    "tests/setup/semantic_asset_install_tests.sh",
    "tests/unit/test_sec11_review_guards.sh",
    "tests/test_runtime_config_schema.sh",
    "tests/test_u22_coverage.sh",
    "tests/test_precision_tracker.sh",
    "tests/test_learn_adoption.sh",
    "tests/test_manifest_contract.sh",
    "tests/test_observability_schemas.sh",
    "tests/fixtures/observability-schemas/",
    "tests/test_payload.sh",
    "tests/test_release_workflow.sh",
    "tests/test_setup.sh",
    "tests/test_setup_check.sh",
    "tests/test_hook_status.sh",
    "tests/test_workflow_contracts.sh",
    "tests/bench_semantic_core.sh",
    "tests/bench_hook_latency.sh",
    "tests/test_hook_perf_contract.sh",
    ".github/workflows/ci.yml",
    ".github/workflows/release.yml",
    ".github/workflows/semantic-assets.yml",
    "docs/command-schemas.md",
    "docs/directory-map.md",
    "docs/internal/benchmarks/benchmark-design.md",
    "docs/reference/hook-latency-contract.md",
    "docs/how/semantic-defense.md",
    "README.md",
    "docs/README_CN.md",
    "CHANGELOG.md"
  ],
  "spec_refs": [
    "docs/specs/GH704/product.md",
    "docs/specs/GH704/tech.md",
    "docs/specs/GH704/tasks.md"
  ]
}
```

Complete-path cross-check：

| Concern | Planned affected files | Focused proof |
| --- | --- | --- |
| New product root | `semantic-sidecar/`; `docs/directory-map.md` | directory-map/doc-path validators plus semantic sidecar cargo checks |
| Canonical L2 core latency | `vibeguard-runtime/src/lib.rs`; planned **vibeguard-runtime/benches/semantic_defense_core_us.rs**; planned **tests/bench_semantic_core.sh**; `tests/test_hook_perf_contract.sh`; `docs/internal/benchmarks/benchmark-design.md`; `docs/reference/hook-latency-contract.md`; `.github/workflows/ci.yml` | `main.rs` and in-process runner import the same public production entrypoint；runner executes cold/warm `core_us` fixtures exactly once；every initial/confirmation cold sample resets and proves empty cache/provider state outside timing, every warm sample prewarms and proves exact-identity hit；contract test rejects duplicate/path-loaded core implementations and fixes IDs/timing boundary/identity/cache/budget/confirmation/result/CI wiring and compile-only smoke |
| Canonical L2 installed latency | `tests/bench_hook_latency.sh`; `tests/test_hook_perf_contract.sh`; `docs/reference/hook-latency-contract.md`; `.github/workflows/ci.yml` | canonical runner executes four path-specific direct/wrapper × cold/warm `hook_e2e_ms` installed-hook fixtures exactly once；every cold sample independently resets cache/provider-start state and every warm sample proves prewarm outside timing；contract test fixes IDs/path/budget/cache/confirmation/CI/result wiring |
| Project-scoped opt-in | `schemas/vibeguard-project.schema.json`; `vibeguard-runtime/src/project_config.rs`; `vibeguard-runtime/tests/project_config_cli.rs`; planned **vibeguard-runtime/src/semantic_defense/config.rs**; `vibeguard-runtime/src/hook_orchestrator.rs`; `vibeguard-runtime/src/hook_orchestrator_context.rs`; `tests/hooks/test_runtime_policy_json.sh`; planned **tests/hooks/test_semantic_defense.sh** | schema/parser allowlists match；payload cwd must be non-empty absolute before canonicalization，closed precedence and canonical git-root resolution happen before ambient context collection；missing/relative/invalid payload cwd、process/payload absolute cwd mismatch、four-field precedence、same-HOME two-project matrix、external opt-in/env negatives prove only payload project config true requests eligibility |
| Canonical project journal + bounded reconciliation | `vibeguard-runtime/src/event_schema.rs`; `vibeguard-runtime/src/hook_orchestrator.rs`; planned **vibeguard-runtime/src/semantic_defense/runtime_signal.rs**; `schemas/event-log.schema.json`; planned **tests/hooks/test_runtime_rule_signals.sh**; `tests/test_observability_schemas.sh` | write-ahead recovery intent closes every WAL/journal crash boundary；fixed metadata + cursor/record length and policy-bound batch/deadline/I/O byte caps bound open/parse/replay without full index/journal/HOME scans；corruption is explicit `needs_repair`；project finalized record is authoritative and global view is idempotent derived projection |
| Install/config doctor | `setup.sh`; `scripts/setup/check.sh`; `scripts/setup/runtime_config_health.sh`; `scripts/lib/status_report.sh`; `tests/test_setup_check.sh`; `tests/test_setup.sh` | doctor/`--check` human/JSON/exit/no-data identity matrix and installed payload route |
| Per-run status | `vibeguard-runtime/src/hook_status.rs`; `hook_status_render.rs`; `hook_status_tests.rs`; `schemas/hook-status.schema.json`; `tests/test_hook_status.sh` | human/JSON/schema carry exact semantic state and identities from one canonical event |
| Observability schema migration | `schemas/event-log.schema.json`; `schemas/session-metrics.schema.json`; `docs/command-schemas.md`; `tests/test_observability_schemas.sh`; `tests/fixtures/observability-schemas/` | docs declare the new schema/version and typed signal/receipt fields；legacy/current positives plus missing/unknown/malformed negatives prove compatibility and fail-visible parsing |
| Learn signal contract | `schemas/learn-signal.schema.json`; `tests/test_workflow_contracts.sh`; `tests/test_learn_adoption.sh` | new semantic-defense signal/typed source positives and invalid classification/action/path cases preserve the classification-bound action space before adoption |
| Semantic release assets | `.github/workflows/release.yml`; `.github/workflows/semantic-assets.yml`; `tests/test_release_workflow.sh`; `tests/test_payload.sh`; `scripts/release/payload-manifest.txt` | release contract fixes same-tag checksums, attestations, dependency metadata, target matrix, explicit install provenance and revoke/rollback behavior for every semantic artifact |
| U-22 measured coverage | `scripts/ci/self-application/check-u22-coverage.sh`; `tests/test_u22_coverage.sh`; `vibeguard-runtime/Cargo.toml`; planned **semantic-sidecar/Cargo.toml**; `.github/workflows/ci.yml` | pinned `cargo-llvm-cov` runs runtime and sidecar manifests separately at ≥80% line coverage so aggregate coverage cannot hide either crate；JSON file coverage requires 100% for runtime `semantic_defense/{mod,config,identity,protocol,provider,inventory,test_weakening,runtime_signal,cache}.rs` and sidecar `protocol.rs`/`sandbox.rs`，including final reducer/orchestration、inventory verdict、semantic weakening verdict、W-rule transitions、project/session isolation and every WAL/cache/journal recovery branch；`tests/test_u22_coverage.sh` must reject any omitted critical module, missing/malformed report, aggregate masking, path-normalization miss or critical file below 100%，while the focused B-003/B-009/B-011–B-015/B-019/B-020/B-022–B-028 suites exercise each decision、isolation and injected-failure path before coverage is accepted |

## Product-to-Test Mapping

Planned shell/Python test entrypoints below must accept the named case selector and reject unknown
selectors nonzero。Rust names are exact full test names to create in the planned modules；每条
focused Rust command 必须传 `-- --exact`，且 `tests/test_manifest_contract.sh` 必须先解析本表，
对 `cargo test -- --list` 的 exact full-name count 断言为 1。零匹配、重名或 rename drift
均须 nonzero，不能依赖 libtest 的 “running 0 tests” 成功退出。因此 tasks 不能把这些验证
退化成“人工观察”、substring-only filter 或无 selector 的 broad suite。

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 approval gate | payload project identity + config/policy join | `cargo test --manifest-path vibeguard-runtime/Cargo.toml semantic_defense::config::tests::approval_gate_matrix -- --exact`、`cargo test --manifest-path vibeguard-runtime/Cargo.toml --test project_config_cli project_config_validate_accepts_semantic_defense_opt_in -- --exact`、`bash tests/hooks/test_semantic_defense.sh project_scoped_opt_in`、`bash tests/hooks/test_semantic_defense.sh payload_cwd_is_authoritative` 与 `bash tests/hooks/test_semantic_defense.sh project_scoped_opt_in_env_rejection`，并由 `bash tests/hooks/test_runtime_policy_json.sh` 固定 adapter payload cwd precedence；missing/false/unknown/type mismatch、missing/empty/relative/non-directory/unresolvable payload cwd、process cwd A + payload `.`、process cwd A + absolute payload B、四个字段指向 absolute A/B 的 precedence、同 HOME 两 project、user-global enable、external config/env、stale H-001–H-020 全部断言只有 absolute payload-precedence project 可请求 eligibility，其余路径零 provider/cache/metrics activity |
| B-002 flag-off parity | hook orchestration | `bash tests/hooks/test_semantic_defense.sh flag_off_parity`；覆盖 project key missing/false 和 kill switch，再跑 `bash tests/test_hook_perf_contract.sh`，child/network/cache canary 均为空 |
| B-003 L1/L2 precedence | policy reducer | `cargo test --manifest-path vibeguard-runtime/Cargo.toml semantic_defense::tests::l1_l2_precedence_total_function -- --exact` |
| B-004 closed inputs | config/protocol schemas | `bash tests/hooks/test_semantic_defense.sh closed_schema_inputs` 与 `bash tests/test_runtime_config_schema.sh` |
| B-005 exact model identity | identity/provenance + release contract | `bash tests/hooks/test_semantic_defense.sh model_identity_provenance`、`bash tests/setup/semantic_asset_install_tests.sh provenance` 与 `bash tests/test_release_workflow.sh`；逐字段 removal/digest/platform/license/protocol mismatch，并证明每个 same-tag semantic asset 的 checksum、attestation、dependency metadata、target matrix 与 install provenance |
| B-006 untrusted output | protocol/provider sandbox | `bash tests/hooks/test_semantic_defense.sh untrusted_provider_output`；malformed/extra/injection/tool/oversize fixture 的 mutation canary 不变 |
| B-007 input privacy | request builder/redactor | `bash tests/hooks/test_semantic_defense.sh input_privacy_redaction`；比较 request/log golden 并扫描 secret/path canary |
| B-008 network policy | provider/install boundary | `bash tests/hooks/test_semantic_defense.sh runtime_network_and_fallback` 与 `bash tests/setup/semantic_asset_install_tests.sh explicit_network_only` |
| B-009 bounded execution | provider/cache | `bash tests/hooks/test_semantic_defense.sh timeout_oom_crash_cancel`；逐项断言 child reaped、无后续 request、bounded root clean |
| B-010 latency evidence | synchronous canonical core + installed-hook runners and metrics contract | `bash tests/bench_semantic_core.sh --runs=30 --confirmation-runs=30 --fail-on-regression` 必须各执行一次 `semantic-defense-core-cold-cache`、`semantic-defense-core-warm-cache`，以 `core_us` versioned result 固定 production entrypoint、timing boundary、cache state、identity、P50/P95/P99/max、approved budget 与 confirmation；`bash tests/bench_hook_latency.sh --runs=3 --confirmation-runs=3 --fail-on-regression` 必须各执行一次 `semantic-defense-direct-cold-cache`、`semantic-defense-direct-warm-cache`、`semantic-defense-codex-wrapper-cold-cache` 与 `semantic-defense-codex-wrapper-warm-cache` installed-hook fixture；两个 runner 的 initial/confirmation batch 都必须逐 sample 记录 timing 外的 cold reset-empty 或 warm prewarm-hit evidence，任一 reset/prewarm/canary 失败 nonzero；`bash tests/test_hook_perf_contract.sh` 对两类 surface 的六个 exact IDs、compile-only smoke、budget table、CI/result contract、per-sample cache/provider reset、identity/confirmation wiring 做 exact-count 检查，缺任一类证据或互相替代均失败；`bash tests/hooks/test_semantic_defense.sh synchronous_advisory_delivery` 证明 provider 完成前不返回、advisory 在同一次 response 且无后台 queue/later delivery；`latency_evidence_shape` 校验 path-specific identity-bound result |
| B-011 cache identity | cache module | `cargo test --manifest-path vibeguard-runtime/Cargo.toml semantic_defense::cache::tests::identity_invalidation_and_isolation -- --exact`；同 project/session 并发去重，不同 project 或 session 即使 exact input 相同也必须 cache miss 且不能读取对方 result |
| B-012 API scope | TypeScript/npm inventory resolver | `bash tests/hooks/test_semantic_defense.sh typescript_npm_inventory_scope`；覆盖 supported/unknown/generated/dynamic/feature/version/missing inventory |
| B-013 production-only API detector | Core handler + GH-700 adapter | `python3 eval/test_semantic_eval.py production_entrypoint_only`；拒绝 test-only/case-ID/path-existence mapping |
| B-014 deterministic W-12 baseline | test-weakening join | `bash tests/unit/test_sec11_review_guards.sh` 与 `bash tests/hooks/test_semantic_defense.sh w12_baseline_identity` |
| B-015 semantic weakening edges | semantic test detector | `bash tests/hooks/test_semantic_defense.sh semantic_test_weakening_edges`；覆盖 parameterized/property/snapshot/tolerance/generated/unsupported |
| B-016 independent evidence | semantic eval schemas | `python3 eval/test_semantic_eval.py independent_evidence_and_reviewers`；覆盖 empty side、digest mismatch、ground-truth-from-output |
| B-017 honest metrics | deterministic scorer | `python3 eval/test_semantic_eval.py metric_arithmetic_and_slices`；覆盖 TP/FP/FN/TN/unclassified/error/zero-denominator |
| B-018 promotion/demotion | eligibility pure function | `cargo test --manifest-path vibeguard-runtime/Cargo.toml semantic_defense::metrics::tests::eligibility_matrix -- --exact` |
| B-019 complete block gate | policy reducer | `cargo test --manifest-path vibeguard-runtime/Cargo.toml semantic_defense::tests::block_requires_every_gate -- --exact` |
| B-020 typed signal | runtime-rule-signal + observability schemas | `bash tests/hooks/test_runtime_rule_signals.sh schema_identity` 与 `bash tests/test_observability_schemas.sh`；`docs/command-schemas.md` 与 legacy/current fixtures 固定 schema version、typed signal/pending/applied/finalized receipt，missing/unknown/free-text-only/malformed 均失败 |
| B-021 baseline/delta ownership | rule registry | `bash tests/hooks/test_runtime_rule_signals.sh baseline_delta_registry`；reason-only delta 不计数 |
| B-022 two distinct rules | W-rule corpus | `bash tests/hooks/test_runtime_rule_signals.sh two_distinct_rule_deltas`；覆盖两套独立正负/错误/history/retry 与 duplicate signal negative |
| B-023 W-02 evidence | W-02 reducer | `bash tests/hooks/test_runtime_rule_signals.sh w02_hypothesis_attempt_evidence` |
| B-024 W-12 attribution | W-12 reducer | `bash tests/hooks/test_runtime_rule_signals.sh w12_signal_attribution`；三种 signal kind 与去重 precedence |
| B-025 corrupt history | history reader | `bash tests/hooks/test_runtime_rule_signals.sh corrupt_and_cross_scope_history` |
| B-026 W state machine | runtime signal module | `cargo test --manifest-path vibeguard-runtime/Cargo.toml semantic_defense::runtime_signal::tests::transition_replay_concurrency_matrix -- --exact` |
| B-027 fail-visible writes | project WAL/event writer + bounded reconciler | `bash tests/hooks/test_runtime_rule_signals.sh projection_write_failures_preserve_l1` 与 `bash tests/hooks/test_runtime_rule_signals.sh bounded_reconciliation_backlog`；在 WAL prepare append、queue metadata commit、journal append fsync、journaled marker、每个 consumer write、finalized/done transition 的前后逐边界注入 write error/process crash，断言 prepared-only 会补 journal、journal-without-marker 由 expected offset + digest 只补 marker、无未索引/重复 event；用超大 WAL、oversize/corrupt record、双 metadata corruption、batch cap、deadline、I/O byte cap、persistent consumer failure 和 missing limits 证明 open/header/parse/replay 全程有界、oldest-first、backlog/`needs_repair` 可见、停止新 provider/L2 append、正常后续重放收敛且 L1 block 保留；对完整 index/journal、其它 project/HOME 的 read/scan canary 必须为零 |
| B-028 single authority + derived global projection | canonical project journal + global projector | `bash tests/hooks/test_runtime_rule_signals.sh one_canonical_projection` 与 `bash tests/hooks/test_runtime_rule_signals.sh derived_global_projection_recovery`；比较 project pending、三个 consumer applied 与 finalized receipt 的 event/signal identity，证明 legacy/L1 dual log 不成为 GH-704 authority；分别在 project finalized fsync 后/global append 前、global append 后/projection receipt 前注入失败，断言 `projection_lag`、source finalized digest binding、replay dedupe 和最终 global convergence，且 global mirror 不能授权 eligibility |
| B-029 candidate identity | Learn schema/analyzer | `bash tests/test_workflow_contracts.sh` 与 `bash tests/test_learn_adoption.sh semantic_candidate_identity`；semantic-defense signal/typed source 的 valid fixture 与 invalid classification/action/path 全部固定，multi-session replay 后 ID/count/window/privacy 精确相等 |
| B-030 deterministic Learn core | Learn analyzer/model adapter | `bash tests/test_learn_adoption.sh semantic_candidate_without_model`；provider disabled/crash 时 identity/count/state 不变 |
| B-031 human adoption gate | Learn adoption | `bash tests/test_learn_adoption.sh semantic_candidate_human_gate`；preview read-only，仅 explicit adopt/skip/snooze 变更 |
| B-032 outcome verification | Learn outcome evaluator | `bash tests/test_learn_adoption.sh semantic_candidate_outcomes`；fresh/absent/regressed 与 raw-source export canary |
| B-033 GH-700 boundary | production mapping contract | `python3 eval/test_semantic_eval.py gh700_core_mapping_boundary`；拒绝 headline/paired/aggregate precision 输入 |
| B-034 GH-702 boundary | capability/policy contract | `bash tests/hooks/test_semantic_defense.sh gh702_sealed_core_boundary`；携带 executable/model/provider 或 unapproved policy 必须失败 |
| B-035 truthful rendering | existing public doctor + hook-status routes | `bash tests/test_setup_check.sh`、`bash tests/test_hook_status.sh` 与 `bash tests/hooks/test_semantic_defense.sh status_rendering_and_redaction`；同一 canonical project finalized event 的 human/JSON/doctor/hook-status/event/precision/Learn state 与 identities 精确相等；global projection 缺失或 stale digest 时必须显示 `projection_lag` + 空值，禁止沿用 mirror data |
| B-036 cleanup/rollback | provider/cache/hook lifecycle | `bash tests/hooks/test_semantic_defense.sh cleanup_interrupt_and_l1_rollback`；success/error/timeout/SIGINT matrix |

## 数据流

```text
approved config/policy + verified semantic asset
  → eligible runtime identity

hook event + project/session/change
  → L1 deterministic result
  → approved minimal semantic input + dependency inventory
  → input digest/cache
  → bounded local provider
  → closed semantic result
  → deterministic detector/W-rule reducer
  → candidate hook decision
  → project WAL prepared intent + queue-metadata commit (fsync)
  → project durable typed pending event at expected offset (fsync)
  → WAL journaled transition (fsync)
  → bounded idempotent reconciliation by event/signal ID
       ├─ latency/outcome metrics + applied receipt
       ├─ exact-identity precision evidence + applied receipt
       └─ deterministic Learn defense_gap candidate + applied receipt
  → project finalized receipt (all consumer receipt digests)
       ├─ release finalized hook decision/status
       ├─ expose finalized Learn candidate as read-only
       │      → explicit human adopt
       │      → later outcome verify/regressed
       └─ idempotent derived global projection
              → projection receipt or visible projection_lag
```

外部调用在 Recommended path 中仅存在于显式 semantic asset install/update；runtime 与
Learn 默认零网络。raw source/prompt/model output 不持久化。cache、event、precision 和
Learn state 的位置、retention 与 delete/export 仍由 H-004/H-005/H-012/H-014/H-016/
H-020 批准。

## 备选方案

- **纯 deterministic inventory/AST，不使用模型**：供应链、隐私和延迟风险最低，但不能
  满足 issue 所述 L2 semantic tier；可以成为对照 baseline，不是本 issue 替代实现。
- **embedded model library**：减少 process overhead，但把 native dependency、model ABI、
  memory/crash 和 release size 放进 hook runtime；须重新批准 H-002/H-003/H-006/H-020。
- **local daemon/OS service**：可能改善 warm latency，但引入生命周期、权限、stale state、
  multi-user isolation 和 repair；当前 Recommended path 不含，选择它必须改 manifest。
- **remote cheap API**：降低本地 asset 负担，但引入 source upload、key/network/provider
  outage、cost 与 jurisdiction；当前未授权，不能作为 fallback。
- **只用 model confidence 阻断**：缺少 ground truth、identity-bound precision 与
  deterministic evidence，违反 B-016–B-019，拒绝。

## 风险

- Security: 用户代码可对模型产生 prompt injection；model/sidecar 是新供应链与进程边界；
  remote provider 会扩大 secrets/source exposure。任何 auth/secrets/process/network
  变更需 SEC-11 人工安全审查。
- Compatibility: config/event/session/Learn schema、旧 free-text event、Claude/Codex
  adapters、GH-699 launcher、GH-700 mapping 与 GH-702 capability 都可能 drift。
- Performance: model cold start、inventory build、large diff、cache contention 与 child
  cleanup 都在 hook critical path；`core_us` 不能代替真实 E2E。
- Precision: dynamic/generated API 与复杂 test semantics 容易产生 unknown/FP；现有
  tracker/paired eval/aggregate scorecard不能授权 promotion。
- Data integrity: event append 与 metrics write 当前存在 identity/静默错误缺口；多事实源
  会造成 precision 与 Learn 错配。
- Maintenance: model/license/revoke、platform assets、adapter ecosystem 和 corpus review
  都是持续成本；H-020 必须明确 owner 和 rollback。

## 测试计划

- [ ] Unit tests: closed schemas、identity joins、protocol parser、precedence、inventory、
      semantic weakening、W state machine、cache、scorer、eligibility 与 redaction。
- [ ] Integration tests: Claude/Codex production hooks、real sidecar failure matrix、structured
      projection、precision/Learn、planned **tests/setup/semantic_asset_install_tests.sh** 的
      install/update/revoke、`tests/test_setup.sh`、payload/no-clone 和 interruption。
- [ ] Regression tests: 现有 W-12/W-16/W-02/W-13/W-14/W-15、runtime config/event schema、
      project opt-in schema/parser/isolation、precision tracker、Learn schema/adoption、
      observability legacy/current fixtures、release asset checksums/attestations/metadata、
      payload、hook manifest、两 crate 独立 ≥80% line coverage；final reducer/mod、
      inventory、test weakening、runtime signal、cache/journal recovery 与
      config/identity/protocol/provider/sandbox 所有 decision/isolation/durability 分支
      100% coverage，且 coverage contract 对遗漏模块、aggregate masking、path-normalization
      和每个关键文件低于 100% 都必须失败；以及 docs contracts。
- [ ] Performance tests: cold/warm core 和 installed hook P50/P95/P99/max、large diff/
      inventory、parallel sessions、timeout/cancel；cold/warm L2 必须分别通过
      planned **tests/bench_semantic_core.sh** core runner、`tests/bench_hook_latency.sh` installed
      runner 和 `tests/test_hook_perf_contract.sh` contract，不得静默调整现有 SLA。
- [ ] Manual security review: model/license/provenance、asset attestation、process sandbox、
      source/secret privacy、network/API key、prompt injection、feedback/export 与 release
      rollback。
- [ ] Required broad verification after implementation:
      `cargo check --manifest-path vibeguard-runtime/Cargo.toml`;
      `cargo test --manifest-path vibeguard-runtime/Cargo.toml`;
      `cargo check --manifest-path semantic-sidecar/Cargo.toml`;
      `cargo test --manifest-path semantic-sidecar/Cargo.toml`;
      `bash tests/test_u22_coverage.sh`;
      `bash scripts/ci/self-application/check-u22-coverage.sh`;
      `bash scripts/ci/validate-hooks.sh`;
      `bash scripts/ci/validate-hooks-manifest.sh`;
      `bash tests/setup/semantic_asset_install_tests.sh`;
      `bash tests/test_setup.sh`;
      `bash tests/test_setup_check.sh`;
      `bash tests/test_hook_status.sh`;
      `bash tests/test_observability_schemas.sh`;
      `bash tests/test_release_workflow.sh`;
      `bash tests/test_workflow_contracts.sh`;
      planned **bash tests/bench_semantic_core.sh --runs=30 --confirmation-runs=30 --fail-on-regression**;
      `bash tests/bench_hook_latency.sh --runs=3 --confirmation-runs=3 --fail-on-regression`;
      `bash tests/test_hook_perf_contract.sh`;
      `bash tests/test_manifest_contract.sh`;
      `bash tests/test_workflow_contracts.sh`;
      `bash scripts/local-contract-check.sh --quick`.

## 回滚方案

第一层回滚是 approved kill switch：关闭 L2 后零 provider/model/network/cache activity，
保留并重新验证纯 L1 behavior。第二层回滚是把 advisory/block eligibility 降为 off，
但保留脱敏 structured error/audit 供诊断。第三层是按 H-020 退回上一份 verified
sidecar/model/policy identity；不得用 floating alias 或未签名 cache。

若 event/schema migration 已发生，reader 必须按 H-017 的显式兼容表处理旧事件；不能
重新启用 free-text regex 作为 precision truth。rollback 不自动删除 Learn adoption、
用户配置或其他 project/session state；只清理 GH-704 在已记录 bounded roots 中拥有的
temporary/cache asset。任何 rollback 失败必须显示 `needs_repair/error`，不能 warning
后继续 block。
