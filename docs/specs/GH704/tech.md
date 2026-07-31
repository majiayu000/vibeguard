# Tech Spec — 分层语义防御与运行时 W-rule 信号

## Linked Issue

GH-704

## Product Spec

[`product.md`](product.md)

Status: Draft；本文件只描述 **Recommended proposal（未批准）** 的一条完整参考路径。
它不批准任何 H-001–H-020 决策，不创建 `tasks.md`，也不授权实现。

## Codebase Context

下表 14 个 codebase anchor 均在本 corrective branch 的 current base
`origin/main@ce5bada07bda1ae72b5488fcf08be8982185a115` 读取。最后两个相邻
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
    project identity + trusted session identity + policy/model + exact sidecar artifact identity
    分区的 content-addressed cache，per-key lock、atomic replace；只存 result/evidence
    digest，不存 raw source，不允许 cross-session reuse。trusted session 只来自 OS/runtime
    ownership boundary；inherited env/payload 只作 matching echo。**
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
批准记录/digest、config schema version、model/provider/protocol identities、实际 sidecar
artifact identity、trusted session/Git executable identities、允许的
checks/W-rules、host/trigger、privacy/network、latency、precision、failure semantics
和 rollout stage。

加载顺序固定：

```text
closed config
  → approval/policy digest join
  → trusted session/Git + provider/model/sidecar release provenance
  → host/trigger + privacy/network eligibility
  → detector/W-rule + latency/precision eligibility
  → effective off/advisory/block
```

任何 join 缺失、空值、未知、冲突或 drift 都在模型执行前产生 structured
`unavailable/error`。普通 env getter 不得覆盖 model digest、provider、network、
precision floor、session/cache partition、sidecar artifact 或 block eligibility；只有 H-001
明确列出的降级/kill-switch env 可生效。完整 identity 和 recovery 子协议见
[`runtime-integrity.md`](runtime-integrity.md)，该文件是这些字段与状态边的规范性来源。

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
`git_root_for(absolute_payload_cwd)` 前 no-follow 打开 payload directory，并把 Unix
device/inode/mount 或 Windows volume/file-ID handle 保持到 config open。helper child environment
从 closed allowlist 重建，删除所有 inherited `GIT_*`
变量（包括 `GIT_DIR`、`GIT_WORK_TREE`、`GIT_COMMON_DIR`、object/config/ceiling/discovery
overrides）以及 `PATH`/`PWD`/`CDPATH`，且只能从 installer/release receipt 取得 absolute、
no-follow、digest-bound Git executable capability，用参数数组执行
`<verified-git> rev-parse`；child cwd 由 retained fd/fchdir 或 Windows handle+file-ID handshake
设置，禁止 mutable-path-only `-C`、basename/shell/PATH lookup。Git 返回后重开 root handle、
比较 stable identity/containment，并拒绝执行中 swap-then-restore；再只接受 root 等于 payload 或为其
component-aware
ancestor；symlink-resolved payload 不在 returned root 内，或 repo-local gitdir/
`core.worktree` 把 root 重定向到 sibling/external path 时返回 `unavailable/error`，不能
读取该 root 配置。通过后以 root directory capability + exact relative name no-follow
打开 `.vibeguard.json`，拒绝 symlink/reparse point/非 regular file，并从同一 descriptor
`fstat` 后读取；canonical target/parent identity 必须仍在 validated root 内。
`hook_orchestrator` 必须在 `RuntimeContext::collect()`/config join 前解析 payload，把 typed root 传给 `evaluate_core`；ambient process
cwd、env cwd 与后续重新读取 current directory 都不能参与 enable 判定。四个 payload cwd
字段全部缺失时没有合法 enable source，必须在任何 semantic config/WAL/status read 前
short-circuit 为 off，保持 byte-for-decision L1 parity；即使 ambient project 的 key 为
missing/false/true 也不能读它或生成 L2 error。字段存在但为空、relative、非目录、无法
canonicalize 或无法求 git root 时返回可见 `unavailable/error`，且 provider/cache/
metrics activity 为零；override 指向 sibling/
external opt-in file 时保持 off。任何
`VIBEGUARD_SEMANTIC_DEFENSE*` enable env 同样无效且不能作为隐式默认。
Codex app-server adapter 的 actual session container/lifecycle router
`vibeguard-runtime/src/codex_app_server.rs` 必须持有 `codex_app_server_core.rs` 定义的
`SessionState`，并让 core 生成不可由 client thread ID/env 在 restart 后重现的 server-owned
session capability；semantic Core 在
owning Rust process 内消费 in-memory capability，Bash child 只运行 L1，不能从 stdin/env/cwd/file
获得 L2 capability。adapter 把 trusted thread cwd 复制到每个 pre/post payload top-level `cwd`；
只设 child cwd 不算 identity。thread cap 不得淘汰 pending completion；all-pending 时接受新 patch
前 typed backpressure，missing retained completion fail visible。payload/process cwd 冲突时 payload 胜出。
`schemas/vibeguard-project.schema.json`、`project_config.rs` 的 typed field/closed allowlist
与 semantic config join 必须同源；unknown/type mismatch 在 provider 启动前 fail visible。
同一 HOME 下 opt-in project 与无 key project 的双 fixture，以及 process cwd A +
payload absolute cwd B、process cwd A + payload `.`、四个 payload 字段 absolute A/B
precedence、missing cwd × ambient key missing/false/true、invalid payload cwd、
`GIT_DIR` + `GIT_WORK_TREE` 重定向到 opted-in B、external path/env enable negative fixtures，
repo-local gitdir + `core.worktree=B`、hostile PATH fake Git、Git/payload-directory replacement/
revoke、config symlink/reparse/rename-race、app-server cwd/thread-cap fixtures，必须证明只有
release-owned Git + ancestry-bound payload project 可请求 eligibility，其余路径零
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

semantic branch 首先要求 trusted host lifecycle phase 为 `completed`。Codex
`applyPatchApproval`/decline/apply-in-progress 即使沿 legacy child-Bash `run_post_hooks=true` 路径
运行 L1，也必须在 semantic cache/provider/WAL 前 short-circuit；只有 app-server-owned
completion event 绑定已应用的 exact before/after change identity 后，才可在 owning process
内进入下图。没有 completion callback
则该 host/trigger L2 `unavailable`，不得轮询 filesystem 猜完成。

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
                                      → single durable group commit
                                           ├─ staged/provisional session metrics
                                           ├─ staged/provisional precision
                                           └─ staged/provisional Learn candidate
                                      → project all_activated barrier
                                      → release barrier-joined hook decision
                                      → idempotent derived global projection
```

L1 总是先独立得出结果。L2 只有在全 gate eligible 时运行；off/unavailable/error 不被
归一为 pass。最终 decision reducer 是 exhaustive pure function，输入包括 L1 result、
L2 result/status、approved severity、failure mode 和 eligibility；未知组合拒绝而不是
fallback。L2 block eligibility 还要求同一 event 的 `all_activated` barrier；pending/replay
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
policy、exact sidecar artifact、corpus/ground-truth/production mapping、platform/language、input/evidence digest
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
lock deadline 从首次 nonblocking `try_lock` 前开始，并覆盖 bounded backoff、owner record
读取与后续 I/O；owner record 绑定 nonce、PID/start token 与 process identity。只有在
owner liveness 明确不存在且 compare-and-swap 仍匹配同一 nonce 时才可接管 abandoned
lock；活跃 holder、deadline、malformed owner 或无法证明 stale 都返回
`reconciliation_backlog/unavailable`，保留 L1 且不启动 provider/append，禁止无限等待或
按 mtime/PID 猜测后删除。取得同一 project journal lock 后的 append protocol固定为：

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

group/barrier/recovery/global 的规范状态机在 [`runtime-integrity.md`](runtime-integrity.md)：唯一
coordinator 推进 `prepared → journaled → staged → commit_prepared → activating[bitmap] →
projection_prepared → all_activated → projection_queued → done → projection_done`；activation
receipts 齐备后以 global lease/reserved slot/checksummed generation 串行发布 inert registration；
worker 验证 barrier。orphan 由 coordinator 恢复后，以 digest receipt CAS ready/tombstone；无
global→project lock inversion。barrier + registration durable 才能 done。reconcile policy 必须先
通过 byte floor 与 `deadline >= max_atomic_recovery_ms(schema,platform,storage) + guard`；time max 取 normal completion 与每个 fault-prefix + operation deadline + cancel/escalate/terminate/join/reap + durable-boundary/no-background-write verification 的最大值，remaining admission 也包含 teardown + guard。
projector 从 registry 即可发现 dormant work；唯一 append lease 覆盖 reservation 到 exact append/
fsync、applied、tail 与 receipt outbox 原子 commit，earlier 未 applied 禁止 later append。worker
须持 matching source effective epoch 的 shared delivery lease并核对 config digest。ready CAS offset-independent seed；sequencer 分配 offset并原子创建 full reservation + retained allocator claim-binding + completed/quarantine tokens；每个 quarantine token 初始预留 closed-max A/B generations/body。active absent 才重建，仅 matching off 可 freeze；frozen ref digest-bind timestamp/retention bucket/registry global-lag offset/query scope。pre-barrier route 永久不可达时先 fsync per-source bounded-body admin entry，再以只含 root/digest/query metadata 的 global stub 替换 live slot；closed permanent route 同样先 fsync quarantine 再发 stub；source corruption 不阻塞 global，rebind 从 body 恢复 exact registration/reservation并重取 completed capacity。
receipt worker 只 fsync/create keyed slot、提交 global applied/reclaim/`receipt_delivered` 并保留 token；source coordinator 按 shared delivery lease → project lock fsync `projection_done`，global CAS `project_acknowledged` 后才释放 token；ack 前 permanent/retention 原子转 `quarantine_ack_pending`。A/B replacement 走 inactive stage→stub repoint→old reclaim，one-entry-full 不需第二 token。
retirement 走 global pending→source retired proof→global release。未 ack locator 必须 pin/计 backpressure或原子移入可枚举 lag index，retention GC 不得 age-delete；只有 rebind+ack retirement 或 source-lock terminal discard proof 才可 release。off drain 将 durable keyed receipt 直接 handoff 到 query-scoped per-source admin ref并释放 shared token；completed `receipt_delivered`/pending 是 off-blocking 且 handoff 前 capacity-bearing，retained `project_acknowledged` history 不阻塞；新 request 以 adopt-all 或 per-ref terminal-discard-all 二选一闭合旧 set，present/absent config identity 均须 stable parent-capability no-follow 重验。
off 用 exclusive lease → project lock，避免 late marker/deadlock。crash 只按 registry/reservation/
outbox/quarantine exact route/key/offset/digest 恢复，禁止扫描、覆盖、永占 registry 或猜测；lag 保持空。既有 L1 dual logging 不变；
legacy free text 只可显示为 `legacy_untracked`。

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
  `semantic_status`、rule/signal/model/policy identities 与 evidence digest。finalized
  outcome 仅从 project-journal `all_activated` barrier 渲染，且每个 consumer/version
  必须 join exact barrier digest；persisted pre-barrier failure 从 exact bounded
  WAL/queue record 渲染。lock/WAL open/initial prepare 前没有 durable record 时，typed
  in-memory error 是仅限当前 response 的权威源，带 `persistence_unavailable`、
  `finalized=false` 与 empty decision/event ID；后续 status 显示 durable no-data + current
  storage health，不重建不存在的历史。两者均不进入 precision/Learn；
- event log、precision 与 Learn 只消费上述 canonical project typed event。project-local canonical
  status 只 join barrier；bounded project enforcement/history 再 join local `projection_done`。doctor 的
  latest project status 也从该 event/status contract 读取；`observe-output` 以 discriminator
  `oneOf` 保留 exact closed v1，v2 必需 `semantic_projection {state,finalized,barrier_refs,barrier_set_digest,projection_watermark,lag_refs}`；global 成功 refs 只来自独立 retention/capacity-bounded、per-source-quota success-history plane 的 `project_acknowledged`，marker-before-ack 的 live completed ref 仍 lag。
  bounded sorted refs 逐 event 绑 source/event/barrier/receipt/offset，set digest 绑 query + ordered barrier/lag refs + global root 与 registry/allocator/outbox/completed-index subgenerations/tail，watermark 携带同一 snapshot；scan 前后 generations 必须不变，drift 只 bounded retry 或 lag/unavailable + empty；mixed lag/proof-overflow 全部 empty。
  current writer 只发 v2；v1 reader 映射 legacy-untracked/empty。project-local history 可 join `projection_done`；Codex/global status、quality grader、constraint-frequency 与 global Rust hook/log enforcement-history readers 只能 join `project_acknowledged`；pending/aborted/frozen/quarantined/receipt-delivered/lag 不得成为 success/grade/rule hit/history decision。`hook_orchestrator_learn.rs` 的 log-tail/metrics error 必须 typed fail-visible、`finalized=false`、零 suggestion/candidate，不得 `unwrap_or_default`。

`tests/test_setup_check.sh` 固定 doctor/`--check` human/JSON、exit 和 no-data 语义；
`tests/test_hook_status.sh` 及 Rust `hook_status_tests.rs` 固定 per-run human/JSON/schema
identity equality。若维护者选择新 semantic 命令，先改写 H-014 与本 manifest；tasks
不得局部改路由。

### 9. Privacy、process、cache 与 interruption

Recommended local-sidecar path（未批准）使用参数数组和 closed stdio protocol；child
环境 allowlist 不含 token/proxy/HOME secrets，cwd 指向专用 temp root，禁止网络和任意
filesystem traversal。sidecar 必须从 verified executable capability 启动，实际 artifact 的
version/digest/target/protocol/manifest/attestation/revoke identity 与 approval、request/result、
cache、precision、status 使用同一 digest；任一 drift 在 exec 前失效。stderr 先分类/redact，
再进入 bounded diagnostic。

request 在 deadline/cancel 时终止 child 并回收；cache/journal 只在记录的 dedicated root
下 atomic write/cleanup。cache value 不含 raw source/prompt/output。cache identity 和
storage partition 都包含 project identity + trusted session identity + input/inventory/model/
protocol/policy/sidecar-artifact digests。trusted session 只能来自 OS-authenticated runtime
boundary 或 app-server owned `SessionState` capability；inherited `VIBEGUARD_SESSION_ID`/
payload 只作 matching echo，冲突在 cache/provider/state 前失败。仅同一 project/session 的
并发同 key 使用 bounded lock，不同 session 即使输入相同也不能读写同一 result；没有 trusted
session source 时整个 L2 `unavailable`，禁止 uncached fallback。kill switch 不删除 L1 state，
关闭后不再启动任何 L2 request。

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
计时边界外预先写入同一 exact input/inventory/detector/model/protocol/policy/sidecar-artifact/
project/trusted-session identity 的合法 cache，并断言 warm hit 前提后才计时。reset/prewarm/assertion
任一失败使 runner nonzero。两者使用同一 sealed provider-result fixture，使差值只归因于
core cache path。

core runner 必须输出 versioned JSON，逐 fixture 记录 `surface=core_us`、exact fixture ID、
P50/P95/P99/max、runs、platform、cache state、detector/model/protocol/policy/sidecar-artifact/
trusted-session identities、
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
H-001–H-020 已批准。当前共 147 条唯一 repo paths：106 条 existing、41 条 planned。
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
    "vibeguard-runtime/src/codex_app_server.rs",
    "vibeguard-runtime/src/codex_app_server_core.rs",
    "vibeguard-runtime/src/codex_app_server_file_changes.rs",
    "vibeguard-runtime/src/codex_app_server_hooks.rs",
    "vibeguard-runtime/src/codex_app_server_strategies.rs",
    "vibeguard-runtime/src/codex_app_server_strategies_tests.rs",
    "vibeguard-runtime/src/git_root.rs",
    "vibeguard-runtime/src/project_config.rs",
    "vibeguard-runtime/src/runtime_config.rs",
    "vibeguard-runtime/src/runtime_config_validation.rs",
    "vibeguard-runtime/src/event_schema.rs",
    "vibeguard-runtime/src/hook_orchestrator.rs",
    "vibeguard-runtime/src/hook_orchestrator_context.rs",
    "vibeguard-runtime/src/hook_orchestrator_post_edit.rs",
    "vibeguard-runtime/src/hook_orchestrator_post_edit_history.rs", "vibeguard-runtime/src/hook_orchestrator_post_edit_history_unit_tests.rs", "vibeguard-runtime/src/hook_orchestrator_post_edit_history_tests.rs",
    "vibeguard-runtime/src/hook_orchestrator_stop.rs", "vibeguard-runtime/src/hook_orchestrator_learn.rs", "vibeguard-runtime/src/hook_checks.rs", "vibeguard-runtime/src/hook_checks_history.rs", "vibeguard-runtime/src/hook_checks_tests.rs", "vibeguard-runtime/src/log_query.rs",
    "vibeguard-runtime/src/session_metrics/signals.rs",
    "vibeguard-runtime/src/session_metrics/engine.rs",
    "vibeguard-runtime/src/hook_status.rs",
    "vibeguard-runtime/src/hook_status_render.rs",
    "vibeguard-runtime/src/hook_status_tests.rs",
    "vibeguard-runtime/src/observe/aggregate.rs", "vibeguard-runtime/src/observe/mod.rs", "vibeguard-runtime/src/observe/model.rs", "vibeguard-runtime/src/observe/prometheus.rs",
    "vibeguard-runtime/src/observe/read.rs", "vibeguard-runtime/src/observe/render.rs", "vibeguard-runtime/src/observe/stats_summary.rs", "vibeguard-runtime/tests/observe_cli.rs", "vibeguard-runtime/tests/cli_hook_checks.rs", "vibeguard-runtime/tests/cli_log_commands.rs",
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
    "schemas/hook-status.schema.json", "schemas/observe-output.schema.json",
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
    "scripts/precision-tracker.py", "scripts/report-false-positive.py", "scripts/health-report.py", "scripts/quality-grader.sh", "scripts/constraints/count_active_constraints.py",
    "scripts/gc/reflection_digest.py",
    "scripts/stats.sh",
    "scripts/learn/analyze.py",
    "scripts/learn/adoption.py",
    "scripts/ci/self-application/check-u22-coverage.sh",
    "scripts/ci/self-application/u22-critical-files.json",
    "setup.sh",
    "scripts/setup/check.sh", "scripts/setup/targets/codex-home.sh",
    "scripts/setup/install.sh",
    "scripts/setup/runtime-install.sh",
    "scripts/setup/runtime_config_health.sh",
    "scripts/lib/project_config_validate.py",
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
    "tests/test_gc_config.sh",
    "tests/test_gc_scheduled.sh",
    "tests/test_observe.sh", "tests/test_stats.sh", "tests/test_health_report.sh", "tests/test_codex_status.sh", "tests/test_quality_grader.sh", "tests/hooks/test_count_active_constraints.sh",
    "tests/test_u22_coverage.sh",
    "tests/test_precision_tracker.sh", "tests/test_report_false_positive.sh",
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
    "docs/specs/GH704/runtime-integrity.md",
    "docs/specs/GH704/verification.md",
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
| Project-scoped opt-in + trusted execution identity | `schemas/vibeguard-project.schema.json`; `scripts/lib/project_config_validate.py`; `tests/test_gc_config.sh`; `tests/test_setup.sh`; `vibeguard-runtime/src/{git_root,project_config,codex_app_server,codex_app_server_core,codex_app_server_file_changes,codex_app_server_hooks,codex_app_server_strategies,codex_app_server_strategies_tests,hook_orchestrator,hook_orchestrator_context,hook_orchestrator_post_edit}.rs`; `vibeguard-runtime/tests/project_config_cli.rs`; planned **vibeguard-runtime/src/semantic_defense/{config,identity,cache,provider}.rs**; planned **tests/hooks/test_semantic_defense.sh** | actual wrapper owns `SharedState` session container/router；core owns capability semantics；pending-safe thread cap；Bash L1-only；Git executable + retained payload-directory identity；no-follow ancestry config |
| Canonical project journal + bounded reconciliation | `vibeguard-runtime/src/event_schema.rs`; `vibeguard-runtime/src/hook_orchestrator.rs`; `vibeguard-runtime/src/hook_orchestrator_post_edit.rs`; planned **vibeguard-runtime/src/semantic_defense/runtime_signal.rs**; `schemas/event-log.schema.json`; planned **tests/hooks/test_runtime_rule_signals.sh**; `tests/test_observability_schemas.sh`; `docs/specs/GH704/runtime-integrity.md` | one group writer；pre-barrier bounded global registration；serialized append；receipt worker never writes project marker；eligibility lease freezes off backlog；bounded recovery |
| Install/config doctor | `setup.sh`; `scripts/setup/check.sh`; `scripts/setup/runtime_config_health.sh`; `scripts/lib/status_report.sh`; `tests/test_setup_check.sh`; `tests/test_setup.sh` | doctor/`--check` human/JSON/exit/no-data identity matrix and installed payload route |
| Per-run status | `vibeguard-runtime/src/hook_status.rs`; `hook_status_render.rs`; `hook_status_tests.rs`; `schemas/hook-status.schema.json`; `tests/test_hook_status.sh` | human/JSON/schema carry exact semantic state and identities from one canonical event |
| Typed reader/schema migration | `schemas/observe-output.schema.json`; schemas/fixtures；observe modules/CLI；`vibeguard-runtime/src/{hook_checks,hook_checks_history,hook_checks_tests,log_query,hook_orchestrator_learn,hook_orchestrator_post_edit_history,hook_orchestrator_post_edit_history_unit_tests,hook_orchestrator_post_edit_history_tests}.rs`; `vibeguard-runtime/tests/{cli_hook_checks,cli_log_commands}.rs`; `scripts/{stats.sh,health-report.py,quality-grader.sh,gc/reflection_digest.py,report-false-positive.py,constraints/count_active_constraints.py,setup/targets/codex-home.sh}` plus focused tests | exact v1 + aggregate-verifiable v2 fixtures；project canonical joins barrier；project history joins `projection_done`；global aggregate/status joins `project_acknowledged`；pending/aborted/lag empty；Learn errors typed/zero candidate |
| Learn signal contract | `vibeguard-runtime/src/hook_orchestrator_learn.rs`; `schemas/learn-signal.schema.json`; `tests/test_workflow_contracts.sh`; `tests/test_learn_adoption.sh` | new semantic-defense signal/typed source positives and invalid classification/action/path preserve action space；log-tail/metrics errors fail-visible，never no-data |
| Semantic release assets | `.github/workflows/release.yml`; `.github/workflows/semantic-assets.yml`; `tests/test_release_workflow.sh`; `tests/test_payload.sh`; `scripts/release/payload-manifest.txt` | release contract fixes same-tag checksums, attestations, dependency metadata, target matrix, explicit install provenance and revoke/rollback behavior for every semantic artifact |
| U-22 measured coverage | planned **scripts/ci/self-application/u22-critical-files.json**; `scripts/ci/self-application/check-u22-coverage.sh`; tests/manifests/Cargo/CI | runtime/sidecar each ≥80%；100% line+branch: runtime `{git_root,project_config,codex_app_server,codex_app_server_core,codex_app_server_file_changes,codex_app_server_hooks,codex_app_server_strategies,hook_orchestrator_context,hook_orchestrator,hook_orchestrator_post_edit,hook_orchestrator_post_edit_history,hook_orchestrator_learn,hook_checks,hook_checks_history,log_query,event_schema}.rs`、`observe/{aggregate,prometheus,read,render,stats_summary}.rs`、`semantic_defense/{mod,config,identity,protocol,provider,inventory,inventory_adapters/mod,inventory_adapters/typescript_npm,test_weakening,runtime_signal,cache,metrics}.rs`、sidecar `{protocol,sandbox}.rs`；每个 critical file 恰一次携带非空 exact `owner_suites`，gate 双向核对 [verification.md](verification.md) 的 Product-to-Test mapping/Cargo exact name/shell selector，missing/empty/unknown/duplicate/zero-match/rename-drift/无反向 owner、condition arms 与 aggregate masking 均失败；independent B-001/B-003/B-009/B-011–B-015/B-017–B-020/B-022–B-028/B-035/B-037 matrices map every branch ID |

## Verification contract and data flow

Exact Product-to-Test ownership、zero-match-fail selector contract 与 end-to-end 数据流移至
[verification.md](verification.md)，作为本设计的同级 normative verification supplement。

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

Unit、integration、regression、performance、manual security review 与 required broad
verification 的完整清单移至 [verification.md](verification.md)。该迁移不改变任何验证要求。

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
