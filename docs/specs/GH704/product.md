# Product Spec — 分层语义防御与运行时 W-rule 信号

## Linked Issue

GH-704

complexity: large

Status: Draft；本文件不批准任何模型、供应商、联网、隐私、延迟、精度、阻断或学习策略，
也不授权创建 `tasks.md` 或开始实现。

## 用户问题

VibeGuard 当前的生产防御主要依赖正则、AST、路径与会话历史等确定性证据。它们能快速、
可解释地阻止已知坏形状，但无法可靠判断两类需要项目语义的风险：

- 代码引用了当前依赖版本中并不存在的 API，却在文本层看起来完全合法；
- 测试改动仍保留 assertion 语法，却实质放宽或删除了被验证的行为。

同时，W-rule 中有些规则已经有部分运行时实现：W-12 会阻止测试基础设施写入，现有
deterministic guard 会识别一部分 assertion/skip 变化，W-16 会在没有验证证据时给出
stop advisory，W-02、W-13、W-14、W-15 也有相邻的会话历史信号。因此 GH-704 不能把
“已有 runtime hook”重新包装成新增能力；它必须说明每一条具名 W-rule 的当前 baseline、
新增信号、判定严重度和验证证据。

此外，当前 Rust 事件写入虽然声明了 `rule_id` 字段常量，却没有为所有 runtime W-rule
事件写入结构化 rule identity；已有 precision projection 仍可能从 free-text reason
提取 rule ID。若直接增加模型判定，precision、审计与 Learn 可能形成三个互不一致的
事实源。

## 目标

- 在批准的 feature flag 后提供 L2 语义检查，同时保持 L1 确定性检查的行为和延迟事实
  独立可见。
- 为 invented API 与 semantic test weakening 建立真实 Core production detector，
  不创建仅供 eval 或 benchmark 使用的假实现。
- 选择至少两条具名 W-rule，记录现有 baseline，并只把可证明的新增 delta 计入 GH-704。
- 用闭集、结构化、可追溯的 signal/result/evidence 合同连接 runtime、precision、
  metrics 与 Learn。
- 让跨会话观察只生成可人工采纳和复核的 `defense_gap` candidate；禁止自动改规则、
  自动提升 severity 或自动发布。
- 在任何默认启用或阻断之前，用批准的 corpus、ground truth、延迟和 precision 合同
  证明效果。

## 非目标

- 不替换现有 L1 regex/AST/path/history 防御，也不把 L1 与 L2 指标混成一个数字。
- 不在本 issue 建立任意第三方可执行 pack、第二套 pack trust/precision policy 或新的
  host registry。
- 不把 GH-686 的 prompt with/without eval、GH-700 的公开 benchmark 或现有 aggregate
  scorecard 当作 L2 production precision 证据。
- 不把现有 W-12/W-16/W-02 等能力原样计作“新增两个 runtime W-rules”。
- 不允许模型执行工具、代码、shell、网络动作或直接修改 policy、配置、规则、测试和
  Learn state。
- 不在 spec approval 前选择具体模型、provider、权重、license、网络策略、阈值或
  fail-open/fail-closed 行为。

## 待维护者确认的产品与安全决策

以下每项均为 **UNAPPROVED human decision**。Recommended proposal 只是为了给出一条
可审阅的完整路径，不是批准；`tech.md` 的 H-015–H-020 技术选择同样未批准。任何一项
未批准时，相关能力必须保持 disabled，且不得进入 `tasks.md`。

1. **H-001 — rollout 与默认值（未批准）**：flag 的名称、默认值、project/global
   scope、host/event/language 范围、kill switch、用户 override 与 rollback。
   **Recommended proposal（未批准）：默认 `off`，只允许 project-scoped 显式启用；
   首阶段仅 advisory，独立 kill switch 可立即回到纯 L1。**
2. **H-002 — provider 与执行形态（未批准）**：embedded local model、release-managed
   local sidecar、OS service 或 remote API；是否允许用户自带 provider。
   **Recommended proposal（未批准）：只允许 VibeGuard release 管理、签名校验的
   local sidecar；不接受任意命令、插件或 remote provider。**
3. **H-003 — 模型供应链（未批准）**：exact model/weights/version/license/provenance、
   下载与更新、digest/signature/attestation、revoke、支持 OS/arch 和 CPU/GPU/内存/
   磁盘预算。**Recommended proposal（未批准）：版本与 digest 固定、release manifest
   绑定、无 floating alias，缺失或撤销时不可用。具体 model 尚未选择。**
4. **H-004 — 输入与隐私边界（未批准）**：允许读取的 source/diff/dependency graph、
   path 和 metadata；redaction、retention、raw prompt/output logging、HOME/secret
   boundary。**Recommended proposal（未批准）：只传当前变更的最小 synthetic view
   与本地解析的 closed dependency inventory；不持久化 raw source/prompt/output。**
5. **H-005 — 网络与 offline 行为（未批准）**：runtime、install/update、feedback
   是否允许网络；API key 与 proxy 边界；offline cache freshness。
   **Recommended proposal（未批准）：runtime 零网络、零 API key；只有显式 install/
   update 管理动作可下载获批签名资产，feedback 只本地导出。**
6. **H-006 — latency 与资源预算（未批准）**：trigger、cold/warm P50/P95/P99/max、
   `core_us` 与 `hook_e2e_ms`、timeout、OOM、并发、队列、缓存和现有 hook SLA 是否调整。
   **Recommended proposal（未批准）：不放宽现有 hook E2E SLA；首阶段使用同步
   post-edit advisory，当前 hook invocation 在 hard timeout 内等待结果并在同一次响应中
   返回 advisory，不创建后台队列或延迟投递。未证明 path-specific E2E 预算前保持
   disabled，未获单独批准前不进入同步 block path。**
7. **H-007 — failure semantics（未批准）**：timeout、model unavailable、malformed/
   unknown output、inventory 缺失、cache stale、event append failure 分别是 allow、
   advisory、block 还是 feature unavailable。**Recommended proposal（未批准）：
   L2 基础设施失败不阻断用户代码，但必须 fail visible 为 `unavailable/error`，不得伪装
   成 pass；L1 继续独立执行。security-critical fail-closed 例外需另行批准。**
8. **H-008 — precision/recall promotion contract（未批准）**：ground-truth reviewer
   独立性、TP/FP/FN/TN、precision/recall/F1 公式、minimum classified samples、
   freshness、平台/语言分层、block floor、promotion/demotion 与 re-audit。
   **Recommended proposal（未批准）：先 advisory；每 detector/model/policy identity
   分开统计，未分类样本不进 precision 分母且单列，缺失/过期/低样本不得 block。数值
   floor 与样本数尚未选择。**
9. **H-009 — 两类 L2 检查的语义边界（未批准）**：invented API 的 package manager、
   version/features/generated/dynamic APIs；test weakening 的 before/after behavior、
   test/source mapping、skip/exception/tolerance/coverage 语义。
   **Recommended proposal（未批准）：v1 只支持具有 pinned dependency inventory 的
   closed language/package-manager 集合；test weakening 只判断 deterministic guard
   未覆盖的 before/after semantic delta。**
10. **H-010 — 初始 W-rule delta（未批准）**：至少两条具名规则、现有 baseline、新增
    signal、window/identity/reset/threshold/cooldown/suppression 与 decision severity。
    **Recommended proposal（未批准）：W-02 只新增“同一 hypothesis + fresh failing
    verification 的重复修复”信号；W-12 只新增“assertion 仍存在但 behavior contract
    被放宽”的语义信号。现有 W-16 advisory、W-12 test-infra block 或 edit-count
    heuristic 不计作新增。**
11. **H-011 — host 与 trigger 范围（未批准）**：Claude/Codex parity、unsupported
    host、PreToolUse/PostToolUse/Stop、同步或异步、取消/中断语义。
    **Recommended proposal（未批准）：先走已有 Claude/Codex post-edit adapter 的同一
    canonical Rust path，并同步等待 bounded provider 后在当前 PostToolUse response 返回
    advisory；不启动 detached worker、daemon 或跨 hook delivery。unsupported host 明确
    unavailable。**
12. **H-012 — cross-session learning（未批准）**：candidate stable ID、去重、project
    scope、retention、correction label、人工 adopt/verify、precision feedback 与删除。
    **Recommended proposal（未批准）：扩展现有 Signal Inbox → Adoption Compiler →
    Outcome Evaluator；只产生 `defense_gap` candidate，显式 adopt 后才能改 guard，后续
    fresh window 才能 verified。**
13. **H-013 — GH-700/GH-702 接口（未批准）**：GH-700 如何消费 production mapping，
    GH-702 pack 如何引用 sealed Core capability、以及 pack default eligibility 是否
    允许复用 L2 evidence。**Recommended proposal（未批准）：GH-704 独立交付 Core
    detector；GH-700 只消费其 closed mapping；GH-702 只能在自身 H-002/H-006/H-007/
    H-009 获批并合并后按 capability ID 引用，不携带模型或 executable。**
14. **H-014 — observability 与数据保留（未批准）**：结构化字段、raw evidence、digest、
    本地 retention、doctor/status、export/delete 和多 agent/session 隔离。
    **Recommended proposal（未批准）：只保留 closed reason、rule/signal/model/policy
    identities、evidence digest、latency 与 outcome；不记录 raw source、prompt、model
    output、secret 或完整用户路径。不新增 semantic 专用命令：安装/config/model/provider
    eligibility 复用 public `setup.sh doctor`/`--check`，per-run human/JSON 复用 public
    `vibeguard-runtime hook-status`。若维护者选择新命令，必须先改写并批准 H-014。**

## Behavior Invariants

1. B-001: GH-704 在 H-001–H-020 对应决定未批准、批准证据缺失或批准 digest 与运行时
   policy 不一致时必须保持 disabled；不得由实现、环境变量、README、pack 或 provider
   自行补默认值。project opt-in 的 project identity 必须只来自当前 hook payload 的
   canonical cwd，字段优先级闭集固定为 `cwd > params.cwd > workspace.cwd >
   workspace.current_dir`；ambient process cwd、env cwd、相邻 project 或外部 config
   都不能启用。被选字段必须是非空 absolute directory；relative（包括 `.`/`..`）、
   非目录、无法 canonicalize/求 git root 时必须在首个 provider/cache/metrics 动作前
   返回可见 `unavailable/error`，不得相对 ambient cwd 解析。求 git root 必须清除所有
   inherited `GIT_*` repository/config-selection variables，不能被 `GIT_DIR`/
   `GIT_WORK_TREE` 等重定向。Git 返回的 canonical root 还必须是 canonical payload cwd
   自身或其 component-aware ancestor；repo-local gitdir/`core.worktree` 把 root 指到
   payload ancestry 外时拒绝。四个 payload cwd 字段全部缺失表示不存在合法 enable source，
   必须直接保持 off 和 L1 输出 parity，不能读取 ambient project 或生成 L2 error。
2. B-002: flag 为 off 时不得加载模型、启动 sidecar/service、建立网络、读取超出 L1
   所需的 source/dependency 数据或写 L2 cache/metrics；现有 L1 decision、输出和
   latency gate 仍按原合同运行。off/kill switch 生效时不得打开或重放既有 L2 WAL/
   journal；pending backlog 原样冻结，只能由单独批准的 maintenance drain 处理。重新
   enable 后先 bounded reconciliation，排空前不得启动新 L2。
3. B-003: L1 与 L2 必须保留独立的 decision、reason、latency、error 与 evidence identity；
   最终组合 decision 只能来自获批的闭集 precedence table。L2 缺失、错误或超时不得
   被记录成 L2 pass，也不得覆盖 L1 block。
4. B-004: L2 配置、provider、model、policy 和 protocol 输入必须是 versioned closed
   schema。缺失、空值、未知字段/枚举、duplicate key、越界、floating model alias 或
   identity mismatch 必须在首个 inference 前 fail visible，且零模型执行。
5. B-005: production model identity 必须绑定 provider kind、exact model/weights
   version、digest、license/provenance、runtime protocol、policy digest 与适用
   platform。任何字段不可用时状态为空值加 `unavailable`，不得写 `latest`、`unknown`
   或沿用旧身份。
6. B-006: 模型/sidecar 输出是不可信输入，只能通过 closed result schema 返回
   `{check_id, outcome, confidence/evidence fields, reason_code, identity digests}`；模型
   文本不得执行命令、调用工具、修改文件/配置/state，也不得把用户代码中的指令当控制
   指令。
7. B-007: 每次检查只能读取 H-004 明确允许且与当前 project/change 绑定的最小输入。
   source、diff、dependency inventory、path、prompt 和 raw output 的持久化、上传与
   日志必须遵循同一获批 policy；不满足 redaction/ownership 时零 inference。
8. B-008: runtime 网络、资产下载、API key、proxy、feedback upload 和 cache 使用必须
   严格遵循 H-005 的 closed policy。未批准时 runtime 网络请求数为零；不得静默切换
   provider、model、endpoint、cache 或 unofficial mode。
9. B-009: 每个 inference 必须有 hard timeout、可取消的 child/service call、bounded
   input/output、memory/concurrency/queue 上限和独立 request ID。timeout/OOM/cancel/
   crash 后不得遗留进程、锁、临时原文或继续启动新请求。
10. B-010: cold/warm `core_us` 与每个真实 installed hook path（至少 direct 与
    Codex wrapper）的 `hook_e2e_ms` 必须作为独立 fixture/result 分开测量 P50/P95/P99/
    max、样本数、platform、model identity 与 cache state。core fixture 固定为
    `semantic-defense-core-cold-cache` / `semantic-defense-core-warm-cache`，installed
    fixture 固定为 direct/wrapper × cold/warm；core 与 installed path 不得合并计时、
    共用结果或互相替代。initial 与 confirmation 两个 batch 中，**每一个** cold sample
    都必须在计时边界外清空 exact project/session cache、重置 provider-start state 并证明
    state 为空；每一个 warm sample 都必须在计时边界外预热 exact identity cache 并证明
    命中前提。任一 reset/prewarm/assertion 失败必须使 runner nonzero，不能把后续样本
    伪报为 cold/warm。未达到 H-006 或现有 hook SLA 时相关 rollout 状态不得提升。
11. B-011: cache key 必须绑定 exact input digest、dependency inventory digest、
    detector/model/protocol/policy identity、项目 scope 与 `session_id`；source/dependency/
    model/policy/project/session 改变必须失效。仅同一 project + session 内的并发相同请求
    至多产生一个权威结果；不同 project 或 session 不得互相读取或复用。
12. B-012: invented API 检查只允许对 H-009 获批的 language/package-manager/version/
    feature 范围下、由 production dependency inventory 证明的 symbol 作结论。dynamic/
    generated/conditional/ambiguous 或 inventory 缺失必须返回 closed `unknown/
    unavailable`，不得猜“存在”或“不存在”。
13. B-013: invented API 的 detector 必须是 Core production surface；eval 与 GH-700
    benchmark 只能调用这一入口。fixture-only detector、hard-coded case ID、模型自报
    ground truth 或把“不存在文件”改名为 invented API 均不算验收。
14. B-014: test weakening 必须比较 before/after test behavior evidence，并先运行现有
    deterministic W-12 guard。只有 deterministic baseline 明确未覆盖的 semantic delta
    才能算 L2 新增；删除 assertion、skip 与 test-infra 写入等已有命中必须保留原
    detector identity。
15. B-015: test weakening 对 generated tests、parameterized/property tests、snapshot/
    golden updates、tolerance/range changes、exception widening 与 test-to-source mapping
    只能按 H-009 获批范围判定；不支持或无法建立 before/after mapping 时返回
    `unknown/unavailable` 而不是 block。
16. B-016: 每个 detector 的 ground truth、fixtures、production mapping 和 reviewer
    evidence 必须相互独立、versioned、digested，并同时包含 matched positive/negative
    controls。production 输出不得反推 ground truth；任一侧为空或 evidence 漂移时不得
    promotion。
17. B-017: 每个 exact `{detector, model, protocol, policy, corpus, platform/language
    scope}` identity 必须单独报告 TP/FP/FN/TN、classified/unclassified/error counts、
    precision/recall/F1 与 evidence age；零分母使用空值加状态，不能显示 0%、pass 或
    复用 aggregate/旧结果。
18. B-018: promotion/demotion 只接受 H-008 批准的公式、floor、样本量、freshness 与
    independent review。低样本、过期、低 precision、unknown/error 或 identity 改变
    至少降为 advisory/off；模型 confidence 本身不能授权 block。
19. B-019: 任一 detector 进入 block 前必须同时满足 approved rollout、provider/model
    provenance、privacy/network、latency、precision、host/trigger 与 failure-semantics
    gate；缺一项不能 block。local override 只能降级，除非 H-001 明确批准具名的人工
    promotion 流程。
20. B-020: runtime W-rule signal 必须使用 closed、versioned schema，至少含 stable
    `rule_id`、`signal_id`、project/session/event identity、detector/model/policy
    identity（适用时）、evidence digest、window、decision、status 与 closed reason；
    禁止从 free-text reason 正则猜 rule identity。
21. B-021: GH-704 只把 H-010 批准的具名 W-rule delta 计入“新增”。每条必须列出现有
    baseline、exact new signal、输入证据、window/state transition、severity 和
    verification corpus；已有 advisory/block 或仅改 reason 文案不计数。
22. B-022: 至少两条获批 W-rule delta 必须分别通过 positive/negative/malformed/
    missing-history/concurrency/retry fixtures；二者不能只是同一底层 signal 换两个 rule ID，
    也不能只靠模型文本输出。
23. B-023: W-02 若被批准，必须绑定同一 project/session、同一 stable hypothesis
    identity、按序的真实 fix attempts 与 fresh failing verification。仅 edit count、
    elapsed time、旧 build failure 或不同 hypothesis 的失败不能触发新增 W-02 delta。
24. B-024: W-12 若被批准，必须把现有 test-infra block、deterministic assertion/skip
    detector 与新增 semantic weakening 分别归因。L2 不得弱化现有 block，也不得把
    assertion 存在本身当作测试仍有效的证据。
25. B-025: history 缺失、截断、malformed、越界、跨 project、跨 session、事件乱序或
    schema 不兼容时不得产生 false W-rule finding；必须按 H-007 返回可见 degraded/
    unavailable 状态，且 L1 独立结果仍保留。
26. B-026: W-rule state machine 的 window、threshold、reset、cooldown、suppression 与
    retry 必须由获批 policy 唯一决定。相同 ordered evidence 重放结果幂等；并发追加不得
    双重 escalation 或跨 agent 污染。
27. B-027: runtime event append、precision projection 或 audit write 失败及其间任一
    process crash 必须 fail visible；canonical event 必须先以 durable `pending`
    状态落盘。project lock acquisition 本身必须纳入同一 positive deadline，使用
    nonblocking/try-lock、bounded backoff 与可验证 owner nonce/liveness；contended、
    abandoned、malformed lock 都不能无限等待或盲删。project lock 下的 write-ahead
    recovery intent 必须先完整记录 bounded
    pending body/digest 与 expected journal offset 并 fsync/commit，之后才允许 append +
    fsync project journal，再以 durable `journaled` transition 完成；每个边界 crash 后
    都必须通过 expected offset + digest 在有界 I/O 内判断“补 append”或“只补 marker”，
    不得留下未索引 pending 或重复 event。reconciliation 只能通过 fixed-header、
    cursor/length-bounded 的 project queue/WAL，按 oldest first 在 H-006/H-007 批准且
    policy-bound 的正整数 `reconcile_batch_max`、`reconcile_deadline_ms` 与
    `reconcile_io_max_bytes` 三重上限内重放；上限覆盖 open/stat、index parse、journal
    offset read、consumer 与 receipt write，禁止在同步 hook 前加载完整 index、扫描完整
    journal、其它 project 或 HOME。缺少合法上限、index/WAL 损坏、consumer 不可用或
    batch 后仍有 backlog 时必须显示 `needs_repair/reconciliation_backlog/unavailable`、
    pending count 与 oldest age（损坏时不可证明的字段为空），停止 provider 并停止追加
    新的 GH-704 L2 pending event，直到后续 bounded pass 排空或 H-016 批准的显式人工
    repair 完成；禁止自动删除、猜测或无界 rebuild。
    L1 仍运行且既有 L1 block 保留。projector 必须拥有单一 durable group-commit state
    machine；三个 consumer 只能按 group/event/digest 写不可见 staged/provisional version。
    closed transition 是 `prepared → journaled → staged → commit_prepared → activating →
    all_activated → projection_prepared → projection_queued → done → projection_done`；
    barrier 前允许 durable abort + 幂等 rollback，barrier 后只允许向前恢复。canonical
    outcome、任一 consumer activation、precision、Learn 与 aggregate 单独都不可见；
    **所有 reader 只 join 同一 `all_activated` barrier digest**。barrier 绑定 decision、
    ordered stage/activation receipts、schema/identity 与前序 digest；partial activation
    必须按 exact key/digest 幂等补齐或回滚。每一 transition/consumer 的 before/after
    crash 都必须有“不可见且不计数”的负例。完成前不得声称 tracked precision、Learn
    candidate 或 block eligibility；日志失败不得删除用户数据或无界扫描恢复。
28. B-028: runtime、precision tracker、session metrics 与 Learn 必须消费同一 canonical
    **project-scoped typed journal**；它是 GH-704 semantic pending/group-commit/
    `all_activated` record 的唯一权威事实源。pending、consumer receipt 与 barrier 都
    绑定同一 event/signal/group digest，不得同时保留 Rust structured path、global mirror
    或 shell free-text projection 作为第二权威源。既有 L1 dual logging 行为不变；
    GH-704 global event/status 只允许从 `all_activated` barrier 做 idempotent derived
    projection，绑定 source event ID/barrier digest 与 durable projection receipt。
    project WAL 在 queue append 前先 durable `projection_prepared`，保存 expected queue offset 与 bounded
    derived body/digest；exact-offset append/fsync 后才写 `projection_queued` 并允许
    semantic `done`。global worker 必须先由跨 project/shard 的唯一 deadline-bounded
    allocator 原子 reservation offset，且 reservation 自身携带 bounded body；再以该 offset/
    digest 写 bounded keyed `projection_prepared`、append/fsync、applied state 与 project
    receipt。projection receipt 前不得丢弃。恢复只按 exact key/offset/digest 判断，禁止
    扫描 project/global log。
    derived projection 失败必须显示 `projection_lag` 并可重放、去重、最终收敛，不能
    反向推断 eligibility、重写 project journal 或伪称 global view 已同步。
29. B-029: cross-session learning 只能把合格 correction 聚合成 project-scoped、
    stable、deduplicated `defense_gap` candidate，并携带原始 evidence digest、recurrence
    counts、time window、privacy class 与建议 action；显示 candidate 本身只读。
30. B-030: 模型可以解释 candidate，但不得负责 raw JSONL parsing、project scoping、
    event counting、fingerprinting、triage transition、规则生成/启用或 precision
    promotion。模型错误或不可用不得改变 candidate identity/state。
31. B-031: candidate 只有经过现有 Learn 的显式 adopt/skip/snooze 流程才能变更 state；
    adoption 必须记录 action、artifacts、verification、regression check、baseline、
    expected later observation 与 rollback。自动 rule mutation、自动 publish/issue close
    禁止。
32. B-032: adopted candidate 只有在后续 fresh observation 或 targeted reproduction
    证明 recurrence 下降且没有新增 FP/regression 后才能 `verified`；否则保持 adopted
    或变成 regressed。删除/retention/export 必须按 H-012/H-014 且不上传 raw source。
33. B-033: GH-700 只能消费 GH-704 已合并 production detector 的 closed production
    mapping，不能创建 benchmark-only substitute；GH-704 也不能把 GH-700 headline 或
    paired-eval aggregate 当 production precision。
34. B-034: GH-702 若暴露 L2，只能引用已合并 sealed Core capability。其 Draft 中
    H-002/H-006/H-007/H-009 的 executable、precision、default 与 network recommendation
    在获批合并前均不是 GH-704 授权；pack 不得携带模型、任意 provider 或 executable。
35. B-035: human、JSON、status/doctor、event log、precision 与 Learn 输出必须对同一
    run 使用同一状态和 identities，并区分 `off/unavailable/error/unknown/advisory/
    block/pass`。无数据为空值；不得隐藏 L2 error、raw source、secret、完整 HOME path
    或未脱敏 model output。completed advisory/block/pass 只能从 canonical project
    `all_activated` barrier 渲染，且所有 consumer reader/aggregate 必须 join 同一 barrier
    digest；已持久化但 barrier 前的 failure 从 bounded WAL/queue
    渲染。lock/WAL open/initial prepare 之前的 failure，以 typed in-memory error 作为仅限
    当前 hook response 的权威源，标记 `persistence_unavailable`、`finalized=false`、
    empty decision/event ID；后续 status 不得伪造历史，只显示 durable no-data + current
    storage health。两类 failure 都不能进入 precision/Learn。global/aggregate view 若尚未投影同一 barrier digest，必须显示
    `projection_lag` 和空数据，不能沿用旧 mirror 结果。
36. B-036: 正常、失败、timeout 与 interruption 都必须清理 GH-704 自建的 bounded
    temporary state；取消后停止新 inference，保留最小 structured audit，返回与 H-007
    一致的非伪造状态。rollback/kill switch 后纯 L1 路径与其原有验证必须恢复。

## 验收标准

- [ ] H-001–H-020 逐项由维护者批准或改写，并以可审计 digest 进入最终 spec；没有批准
      时不创建 implementation tasks。
- [ ] feature flag off 的 fresh fixture 证明零模型/sidecar/network/L2 state，且现有
      L1 behavior 与 latency gates 不回归；kill switch + pending backlog 冻结且零
      consumer/metrics/precision/Learn write，只有显式 maintenance route 可 drain。
- [ ] process cwd 与 absolute hook payload cwd 指向不同 project、process cwd + payload `.`
      以及 payload cwd 缺失/relative/非法、`GIT_DIR` + `GIT_WORK_TREE` 指向另一 opted-in
      project、repo-local gitdir + external `core.worktree`、redirected `.vibeguard.json`
      fixtures，证明只有 no-follow、ancestry-bound payload project 可以请求 opt-in；
      Codex app-server 必须把 trusted thread cwd 写入 canonical payload，而不是只设 child
      process cwd；cwd 全缺失保持 off/L1 parity，其它错误路径零 provider/cache/metrics。
- [ ] invented API 与 semantic test weakening 均通过真实 Core production path 的
      positive、matched negative、unknown、malformed 和 failure fixtures；没有
      benchmark-only detector。
- [ ] 至少两条具名 W-rule 的 baseline 与新增 delta 分别通过 closed signal/state
      corpus；现有实现未被重复计数。
- [ ] 每个获批 detector/model/policy identity 提供独立、fresh latency 与 precision/
      recall 证据；任何 block rollout 通过 B-019 的全部 gate。
- [ ] canonical structured `rule_id/signal_id/evidence_digest` 从 runtime 唯一投影到
      precision、metrics 和 Learn；project journal 是唯一权威，bounded reconciliation
      对超大/失败 backlog 停止新 L2 增长，global projection failure 可见且重放收敛，
      单一 group-commit 的 `all_activated` barrier 是所有 reader/aggregate 唯一可见点，
      partial activation 可幂等补齐/回滚，durable projection prepare/queue/allocator 不
      丢失 payload 或重用 offset，free-text/global mirror 不再是权威路径。
- [ ] cross-session correction 只产生 read-only `defense_gap` candidate；adopt/verify/
      regressed 仍需现有 Learn 人工门。
- [ ] GH-700/GH-702 contract tests 证明只消费已合并 Core capability/mapping，未批准的
      Draft recommendation 不会成为默认行为。
- [ ] U-22 证据分别证明 runtime 与 sidecar 各自至少 80% line coverage；final
      reducer/orchestration、inventory 及 adapter verdict、semantic test-weakening verdict、
      runtime W-rule state machine、metrics eligibility、project config/context/event identity、
      project cache/journal recovery，以及 protocol/provider/sandbox 的所有 decision、
      isolation、durability 分支达到 100% line 与 branch/condition coverage。独立 closed
      critical-file inventory 与合同测试必须拒绝遗漏、未知或新增但未分类的关键模块；
      聚合 line coverage 不能掩盖未执行的 conditional arm、short-circuit operand、关键
      文件或故障路径。
- [ ] Rust runtime、hook/manifest/workflow、eval/precision、Learn 和 latency 的 focused
      tests 及对应 broad gates fresh green。

## 边界情况清单

| 类别 | 判定（covered: B-xxx / N/A + 原因） |
| --- | --- |
| 空/缺失输入 | covered: B-004, B-005, B-012, B-015, B-017, B-025, B-035 |
| 错误与失败路径 | covered: B-003, B-007–B-010, B-018, B-025, B-027, B-036 |
| 授权/权限 | covered: B-001, B-006–B-008, B-018, B-019, B-031, B-034 |
| 并发/竞态 | covered: B-009, B-011, B-026, B-036 |
| 重试/幂等 | covered: B-011, B-026, B-029, B-036 |
| 非法状态转换 | covered: B-001, B-018, B-019, B-021, B-026, B-031, B-032 |
| 兼容/迁移 | covered: B-002–B-005, B-020, B-028, B-033, B-034 |
| 降级/回退 | covered: B-003, B-007, B-018, B-019, B-025, B-035, B-036 |
| 证据与审计完整性 | covered: B-005, B-010, B-016–B-022, B-027–B-035 |
| 取消/中断 | covered: B-009, B-026, B-036 |

## 发布说明

GH-704 首先只能作为 disabled Draft capability 进入开发。任何默认启用、block promotion、
新 provider/model asset、runtime network、feedback export、GH-700 public claim 或
GH-702 pack exposure 都是独立发布/安全决定。kill switch 必须能恢复纯 L1 路径；schema、
model、policy、corpus 或 signal identity 发生不兼容变化时必须提升版本并重新审计，不能
沿用旧 precision、latency 或 approval。
