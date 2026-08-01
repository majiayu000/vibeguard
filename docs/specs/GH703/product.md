# Product Spec — 默认周度价值摘要与隐私安全分享

## Linked Issue

GH-703

complexity: large

## 用户问题

VibeGuard 已有本地健康报告和 opt-in 周度调度，但默认安装不会生成任何周报。用户
因此很难持续看到产品已经带来的价值，也无法安全地分享“本周拦截了多少危险操作、
捕获了多少虚构 API”这类简洁事实。

现有 GH-556 合同面向维护者健康治理，包含 precision risk、idle assets 和
downgrade candidates，并明确要求 scheduler 为 opt-in。GH-703 拟议把一个更窄、
面向用户的周度价值摘要变成默认安装体验。这是对 GH-556 调度默认值的产品政策
变更，不是把现有 opt-in 脚本静默改成默认开启。

## 未批准的 Human Decisions

下表只给出 Draft recommendation；`推荐` 不等于批准。本 Draft 不选择任何一项。
维护者必须在 spec review 中逐项记录一个互斥选择，并在选择改变推荐方案时同步
更新本 spec 和 tech spec，之后才可进入 task planning 或 implementation。

| ID | 待批准选择 | Draft recommendation | 互斥备选 | 状态 |
| --- | --- | --- | --- | --- |
| H-001 | 默认与 consent 模式 | `install_confirmed_default_on`：受支持平台的完整安装计划明确列出本地周任务；用户确认整体安装后默认注册，并提供同层级 `--no-weekly-value` opt-out | `first_run_prompt`；维持 `opt_in_only` | 未批准 |
| H-002 | 平台与 scheduler | `macos_launchd_linux_systemd`；同一 owned value scheduler 同时承载本地 coverage-authority heartbeat，Draft cadence/expiry 为 5/15 分钟；批准时须固定正整数 cadence/jitter/expiry、`maximum_active_journal_entries`/`maximum_active_journal_bytes`/`maximum_active_journal_segments`，满足 `expiry > cadence + max_jitter`，并固定可信 suspend/resume/boot provider；Windows 明确 `unsupported`，不得回退 cron 或伪报成功 | Linux 继续 `cron`；仅 macOS；不同 heartbeat/active-journal/provider values | 未批准 |
| H-003 | 价值 taxonomy 与 decision 集 | `versioned_local_taxonomy`：独立、闭集、版本化；headline 只统计已批准的真实 rule `block`，与 GH-700 名称对齐但不等待其实现 | 与 GH-700 共用同一 taxonomy 并形成硬依赖；统计 `block+correction` | 未批准 |
| H-004 | window、scope、catch-up 与 snapshot budgets | `previous_local_calendar_week_global`：用户本地时区、上一个完整周、global scope；首次不足整周标 `partial_coverage`，missed run 最多补一次；空 headline 的 `empty_counts_representation` Draft recommendation 为 `json_null`（备选 `field_absent`）；批准时还必须固定该选择及正整数 `maximum_query_window_duration_seconds`、`maximum_catch_up_duration_seconds`、`max_source_files`、`max_uncompressed_bytes`、`max_snapshot_elapsed_ms`、`max_retained_archives`、`max_integrity_preflight_elapsed_ms`，本 Draft 不替维护者填写数值 | rolling 7 days；per-project 周报；UTC calendar week；`field_absent`；不同 bounded duration/budget values | 未批准 |
| H-005 | privacy 与 export | `allowlisted_local_export`：默认仅本地；分享文件只含闭集计数、窗口、coverage、`data_status`、`status_reason`、taxonomy version、`generated_at` 和摘要 digest；分享必须由用户显式导出，无网络/剪贴板副作用 | 不分享 `generated_at`；含 rule IDs 的扩展分享；显式上传集成 | 未批准 |
| H-006 | 用户 surface | `separate_value_summary`：简洁 value summary 与完整 maintainer health report 分离，均支持 Markdown/JSON | 在完整 health report 顶部增加可分享 section；仅 Markdown | 未批准 |
| H-007 | install/upgrade/disable/clean/retention 生命周期 | `transactional_owned_job`：只管理 VibeGuard-owned job 与独立 coverage-authority state，失败不报告安装完成，opt-out 跨升级保留，clean 移除 job 但默认保留报告；批准时还须固定正整数 `retention_horizon_seconds`、`hard_history_cap_entries`、`hard_history_cap_bytes` 及 `no_auto_delete|capability_attested` backend policy，本 Draft 不代填 | scheduler/authority 失败只降级为 warning；clean 默认删除报告；不同 retention/cap/backend policy | 未批准 |
| H-008 | host coverage | `canonical_log_all_supported_hosts`：统计所有能写 canonical event log 的当前受支持 host，不等待 GH-701；未知/不兼容 host 不进入 headline | 仅 Claude/Codex；等待 GH-701 adapter registry | 未批准 |

## 目标

- 默认安装在获批平台和 consent 模式下，无需第二次 setup 即可周期性生成本地周度
  价值摘要。
- 用可审计、互斥、版本化的分类计算 `dangerous_ops`、`invented_apis` 和其他
  拦截，禁止把 protocol error 或 operational failure 包装成产品价值。
- 生成一个 privacy-safe 的 shareable projection；本地完整证据仍可用于
  doctor/health，但不会进入分享文件。
- 让 install、upgrade、disable、verify 和 clean 对 scheduler 与报告状态给出
  一致、幂等、可恢复的行为。
- checkout 与 GH-699 verified payload/package-manager 安装最终具有同一周报行为。

## 非目标

- 不新增检测规则、修改 rule/guard blocking 语义或借周报宣称新的防护能力。
- 不把 GH-700 benchmark 的 corpus 命中率当作用户本机周度计数，也不等待
  GH-700 才能起草或实现独立 taxonomy。
- 不要求 GH-701 的第三 host adapter 才支持当前 canonical logs；未来 host 必须
  先满足同一事件合同才能进入统计。
- 不创建 SaaS、hosted dashboard、账号、远程 telemetry 或自动社交媒体分享。
- 不把 maintainer health report 的 precision、idle assets、项目名称、路径或
  free-text reason 直接复制到 shareable summary。
- 不在本 spec 中实现 GH-699 剩余 bootstrap、Homebrew、npm/bunx 或发布工作；
  只定义周报在这些安装入口中的一致合同。

## Behavior Invariants

1. B-001 H-001 至 H-008 必须各有且只有一个维护者批准值；推荐文本、issue 标题、
   agent 推断或部分选择均不构成批准。任一选择缺失、冲突或过期时，
   task planning 与 implementation 必须保持 blocked。
2. B-002 在 H-001/H-002 选定的受支持默认安装路径上，最终安装确认必须同时展示
   scheduler 类型、摘要周期、coverage heartbeat cadence/jitter/expiry、availability provider、输出目录和 opt-out；确认后无需另跑 setup 命令，
   下一次合格周期应自动生成摘要。
3. B-003 GH-703 对 GH-556 的 supersession 只限获批的“周度价值摘要默认调度”：
   GH-556 的 no-data、parse-error fail-loud、只读聚合和完整 maintainer health
   report 行为继续有效；未获批平台与独立手动 health-report 命令不得被静默改成
   default-on。
4. B-004 用户在安装时选择 opt-out 后，不得创建、加载或保留新的 value-summary
   scheduler；命令结束前必须显示 `disabled_by_user`，而不是把缺任务显示为成功
   enabled。
5. B-005 获批平台之外必须显示 `unsupported_platform` 和可执行的人工运行方式；不得创建
   其他 scheduler、不得把平台识别失败回退为 cron、不得报告 weekly summary active。
   人工方式必须使用独立、显式启动的 `manual_authority` lifecycle/epoch，不依赖
   scheduler `state=enabled`；只有被该 epoch 连续覆盖的 window 才能证明 complete。start 前与 seal 后
   结束的 window 分别显式 `manual_pre_start|manual_post_seal` partial，跨两边界固定以前者优先。
6. B-006 每个用户只能有一个 VibeGuard-owned value-summary job identity。重复
   install/enable 必须更新同一 owned job，不能重复注册或改变第三方 job 的内容、
   顺序、权限或执行周期。
7. B-007 scheduler 注册、加载、探测或持久化状态任一步失败时，必须回滚本次创建
   的 job/state，并让安装退出非零或进入明确 `broken`；不得输出“安装完成”或
   `active`。
8. B-008 每个摘要必须记录 half-open window `[window_start, window_end)`、时区、
   scope、`coverage_status` 和生成时间。窗口边界只能来自 H-004 获批策略，不能由
   renderer、本地语言或重试时间自行改变。
9. B-009 missed schedule 的 catch-up 只能按 H-004 获批策略生成尚不存在的同一
   window；同一 window 重试必须按 B-039 的稳定内容身份确认并复用既有 valid owned
   artifact，不能因重试时间变化而重复累计事件或产生多个相互矛盾的摘要。
10. B-010 `no_data` 只允许 coverage 已证明 complete 且窗口 event set 为空。authority activation必须在
    sequence-0 genesis前 create+fsync并 ledger空 source generation，因此无 caller的新安装仍有可证明空源；任何
    activation后 event log/ledger/archive 缺失优先于空集并必须显示
    `partial_coverage`。两种状态的 headline counts 都必须为空，不得把缺证据渲染为
    0 次危险操作、0 次虚构 API 或“本周安全”。
11. B-011 事件、retained archive、taxonomy、install state 或既有摘要损坏、schema 不合法、
    字段类型错误或读取失败时，生成必须 nonzero 且不发布新的 current/shareable artifact；
    query budget 前必须对所有 bounded retained archive完成 root/header/digest integrity preflight；
    `archive_corrupt|integrity_preflight_incomplete` 只能作为 closed terminal diagnostic/state reason。preflight
    成功后的 content `budget_exceeded` 才可发布无 headline partial；旧 valid artifact保留但标 stale。
12. B-012 每个 value summary 必须携带 closed `taxonomy_version` 和 closed
    category set。未知 category、缺版本或 taxonomy 与 producer 不匹配时不得生成
    headline。
13. B-013 每个被统计事件在同一 taxonomy version 下只能进入一个互斥 value
    category；若多个映射同时匹配，producer 必须 fail loud，不能依靠遍历顺序选择。
14. B-014 `dangerous_ops` 只能统计 H-003 明确批准的 decision 集与 closed
    rule/reason mapping；普通 `pass`、`warn`、protocol error、baseline unreadable、
    circuit-breaker 和其他 operational block 不得计入。
15. B-015 `invented_apis` 只能统计 H-003 明确批准且有 canonical evidence 的
    mapping；不得从 free-text reason、文件内容、prompt 或“可能 hallucinated”
    文案做 substring 推断。
16. B-016 `protocol_errors`、`operational_blocks`、`dangerous_ops`、
    `invented_apis` 与 `other_rule_blocks` 必须可审计地分开；GH-706 的
    `non_protocol_blocks` 不能直接改名为 `dangerous_ops` 或 `rule_hits`。
17. B-017 同一 canonical event identity 在一个 window 内最多计数一次；该 identity
    必须满足 B-037，不得由文件名、archive 名、byte offset 或其他可变存储坐标构成。
    不同重试只有在拥有不同 canonical event identity 时才可分别计数，renderer 不得按
    文本相似度猜测去重。
18. B-018 同一 source、window、scope 和 taxonomy 输入的 JSON、Markdown、本地
    current artifact 与 shareable projection 必须给出完全相同的计数和
    `summary_digest`；任何一个 renderer 不得自行重算分类。JSON 与 Markdown 必须先写入同一
    immutable generation，再用 JCS digest-linked closed pointer union `current_generation|no_current` 同时变为
    current/no-current；variant required/forbidden fields、genesis/predecessor、lifecycle/terminal必须 exact，
    consumer 不得分别解析两个可独立漂移的 current pointers。
19. B-019 shareable projection 只能包含 H-005 批准的 allowlist 字段。字段缺失与
    空值必须保持可区分；`data_status` 与 closed `status_reason` 必须显式输出，使
    complete-empty、partial 与 invalid 可区分，并与 `summary_digest` 绑定。未在 allowlist
    的字段即使为空也不得输出。
20. B-020 shareable projection 不得包含或派生输出 project/repository 名称或
    hash、absolute path、host login、session/request/event ID、rule ID、
    free-text reason/detail、command、file content、prompt、token、secret 或原始
    event/log digest。
21. B-021 自动生成摘要只能读本地证据并写 owned local paths；不得进行网络上传、
    analytics、剪贴板写入、浏览器打开、通知正文外发或自动发布。分享必须由用户
    后续显式调用获批 export 动作。
22. B-022 本地 generation、历史和 shareable artifacts 必须以 user-only 权限、
    temp-write + flush + safe atomic commit 写入；同一 generation 的 JSON/Markdown、manifest 与目录
    必须全部 fsync并验证后，ownership receipt与pointer分别经同 filesystem已 fsync staging inode + atomic
    no-replace hard-link发布。crash后两条 chain的 final pathname只能 absent或包含完整可验证 record；partial
    generation或只完成一种 renderer不能成为 current；既有、symlink或 non-owned output不能被 replace/覆盖。
23. B-023 简洁 value summary 与完整 maintainer health report 必须使用不同的
    surface identity；启用默认 value scheduler 不等于默认分享或默认调度完整
    health report，禁用其中一个也不能伪造另一个的状态。
24. B-024 历史摘要的保留期和上限必须固定且可见；ownership evidence 必须按 B-042
    独立于当前 summary schema/version。retention 只删除 receipt 与安全打开对象的
    non-reusable identity、digest 和 artifact identity 全部匹配且超期的历史 summary；
    标准 Linux/macOS 用户可写路径没有 atomic compare-by-identity unlink，默认不得 auto-delete。
    只有 H-007 明确批准且 runtime attestation 通过 B-042 完整 capability contract 的 backend 才能
    auto-retire；否则保留 candidate、fail visible，并在下一次写入将触及任一 hard cap 前停止新增
    history。receipt必须以 prepared durable record + atomic no-replace + dirfsync + commit marker + dirfsync
    逐条提交；reader忽略 torn/uncommitted，lost response exact replay不得重复。不删除 event logs、export或用户文件。
25. B-025 升级遇到 GH-556 已存在的 opt-in health scheduler 时，必须识别其
    surface、参数和 owner；不得静默把它替换成 value scheduler、创建重复 job，
    或把旧 opt-in 当成 H-001 的 consent evidence。
26. B-026 `disabled_by_user` 必须作为持久安装选择跨普通 upgrade 保留；缺字段的
    旧 install state 按 H-001 批准的 migration 处理并明确显示，不能把“未知”猜成
    已同意。
27. B-027 从 disabled/unsupported/broken 进入 active 必须经显式 enable 或一次
    新的获批安装确认，并通过 scheduler probe；仅存在 job 文件、历史报告或可执行
    文件不构成 active。
28. B-028 并发 install、upgrade、enable、disable、clean、summary generation/publish
    与 retention 必须遵循 B-041 的同一 bounded synchronization contract；等待超时必须
    fail visible，不能让 lifecycle 操作报告成功后仍有旧 generator 发布 artifact。
29. B-029 clean 只移除 VibeGuard-owned scheduler、state 和 current visibility（以 append-only
    no-current tombstone提交，不删除 pointer audit chain）；
    默认保留历史报告和显式 exports，只有获批 purge 动作才能删除 owned report
    data，第三方 scheduler 永远保留。为拒绝 clean 前已启动但尚未取得 lock 的 generator，
    clean 后必须保留最小、无报告内容的 lifecycle generation tombstone；它不是 active state。
30. B-030 doctor/verify 必须按 B-040 分别显示 scheduler lifecycle、artifact freshness、
    report data status 与 ownership/retention health 的合法组合，并验证 job target、
    taxonomy version、最近 attempt/success 和 current artifact；`active + no_data`、
    `active + stale` 或健康 scheduler + blocked retention 等组合不能互相覆盖，历史成功
    不能掩盖当前 target drift、ownership drift 或失败。
31. B-031 checkout 与 verified payload/package-manager 安装必须产生相同 schema、
    taxonomy、job ownership、opt-out、doctor/clean 和 summary 语义；payload 缺少
    任一运行依赖时 install 必须在注册 scheduler 前失败。
32. B-032 host coverage 只由 H-008 和 canonical event contract 决定。未知、
    incompatible 或无法归一化的 host evidence 必须排除并显示 coverage gap，不能归属到任一已支持 host。
    真实 legacy/v1 row 缺 canonical event identity 时以 `legacy_evidence` partial；声称 schema v2 却缺任一
    required identity 时 terminal nonzero/no-publish；present `event_id` 对应冲突 tuples 时以
    `event_identity_conflict` partial。三者不得互相回退。
33. B-033 每个 current/shareable artifact 必须绑定 window、scope、coverage status、
    data status、closed status reason、taxonomy version、producer version、source event-set digest 与自身
    `summary_digest`；该 digest 必须遵循 B-039 的稳定内容投影。tampered、stale、
    wrong-window 或 wrong-taxonomy artifact 不得被 doctor、export 或发布说明当作
    current evidence。
34. B-034 生成或安装在中断后重试必须从已提交 state/current artifact 或明确的
    pending 状态恢复；不得复用未验证 temp file、重复计数、留下 loaded-but-unowned
    job，或因取消而报告成功。
35. B-035 `complete` coverage 必须证明获批 window 内 live canonical log 与所有可能
    含该 window 事件的 retained archives 来自一个一致、封闭的 source snapshot；archive
    缺失、过期、损坏、无法读取、枚举竞态或 snapshot 无法证明时只能返回
    `partial_coverage`/error，不能发布 complete headline。证明必须来自独立、版本化、durable
    的 writer/GC coverage ledger、writer side-channel spool，以及与两者分离的单写者 local
    coverage authority：authority必须先提交空/现有 source root与 sequence-0 genesis，再以 H-002 获批的有界
    cadence/expiry持久化连续 heartbeat；seq0时间必须 exact等于 epoch start且 predecessor为 null，后续才用
    deadline公式。active journal须保留 4ad 的 terminal-prefix reserved capacity，并按获批 entry/byte/segment
    limits在 cadence内 early seal/new segment，且 retained总量有硬界，
    并在每次 canonical writer attempt 的任何 event 工作之前 durable 分配严格递增的
    `attempt_sequence`。只枚举当前仍存在的文件或只看“没有 event”不能证明没有 writer attempt。
    ledger 与 spool 同时失败时，authority 中尚未被 matching row/ledger commit 消解的 reservation
    必须形成明确 gap；durable `aborted_before_spawn` 证明 caller 从未存在，因此无需 event row且不制造 partial；
    durable `reservation_rejected` 表示 pre-slot admission 被拒且 caller 未启动，不计入 event set、也不制造 gap，
    但 reader 必须验证该 authority outcome 才能把对应 window 判为 complete；
    但任何可能已 spawn 或不确定的 slot 仍是 gap；authority heartbeat 过期、sequence 不连续或 authority 恢复为新 epoch 时，
    从最后可信 heartbeat 到 durable recovery checkpoint 的区间同样是 gap；但 H-002 获批 provider
    产生的可信 suspend/resume/boot fence 若同时证明该区间 host 上 canonical caller 不可能运行、边界
    quiescence 完整且时钟界限可信，则该 host-unavailable 区间从 coverage obligation 中排除，不得把正常
    sleep/reboot 自动记为 gap。fence 缺失、边界不确定或存在 open slot 时仍是 gap。只有 heartbeat 链完整
    覆盖整个 window、全部 attempt sequence 已闭合且 source snapshot 有效时，空 event set 才可成为
    `no_data`；任一 gap 相交都必须为 `partial_coverage`。仅 active value authority 注册的 resident host
    parent 才能启动需要记录的 canonical caller：installed Git pre-commit wrapper 必须先取得
    `git_pre_commit` parent reservation；Codex fan-out每个 inner caller必须由
    `{outer_request_id,canonical_hook_id,fanout_index}` exact派生独立 ID/slot，duplicate拒绝；child crash不得关闭 sibling。
    pre-slot failure 不得启动 canonical caller 或产生不可见 attempt；launcher 必须按 host hook failure
    contract fail visible，pre-hook 保持既有 fail-closed、post-hook 保持既有 visible non-success 语义，且缺少
    parent quiescence ack 会阻止旧 epoch 续租。opt-out 不启动 authority、不创建 slot，也不产生逐事件
    coverage failure；unsupported 默认同样如此，但用户可显式启动 B-005 的独立 manual authority epoch，
    `stop` durable seal后 `generate` 必须只读绑定 terminal root/stop/quiescence proof 的 exact sealed epoch；active
    epoch不得直接生成，且 sealed evidence不得冒充 scheduler active epoch。后续显式 enable 必须开启新 epoch，
    `enabled_at` 之前及首个完整覆盖 window 前均为 `partial_coverage`。query budget前必须完成所有 retained
    archive integrity preflight；失败 terminal no-publish，budget只约束随后 content scan。journal不得丢 gap proof。
    caller 已启动后的 reservation/spool/authority failure 不得改变其 guard decision、blocking 语义或
    退出码，但必须 visible。
36. B-036 进入 value taxonomy 的事件必须在 canonical event 创建边界持久化 closed、
    schema-versioned `event_id`、`rule_id`、`reason_code`、classification status 与
    classification contract version/digest；status 只证明 typed producer contract，不得提前
    声称当前 taxonomy 接受该 mapping。GH-703
    自己拥有这个最小 producer/schema 合同，不依赖 GH-704 获批或实现。缺失、未知、
    不一致或由 free text 反推的 identity 不得进入 value headline，并以 tech 明确映射的
    `unknown_host`、`incompatible_host`、`unclassified_event` 或 `event_identity_conflict` closed reason
    使 coverage 可见降级；声称 schema v2却缺 required `event_id`/typed identity的 row是 schema-invalid，
    必须 terminal nonzero且不发布，不能降级成 publishable partial。只有真实 v1 missing identity可用
    `legacy_evidence` partial reason。
    reader 只有在 producer registry 同时 exact-match `classification_contract_version` 与
    `classification_contract_digest` 后才可接受 typed identity；版本相同但 digest 未知/篡改以及
    typed rule/reason 对当前 taxonomy 零匹配都必须固定降级为 `unclassified_event`，不得归入
    `operational_blocks` 或任一 headline category。
    v2 protocol evidence 同样必须是 closed typed reason code；Rust、shell 与 Python
    `authorized-discard` canonical writers 必须使用各自真实的 closed classification source。
    GH-706 free-text classifier 只可读取 legacy rows，且任何 legacy row 都使 coverage 降级。
37. B-037 `event_id` 必须在事件首次持久化时生成并随记录在 live/archive/compaction 间
    byte-stable 保留；复制同一 event 仍是同一 identity，真实新 attempt 即使其余字段相同
    也必须得到新 identity。legacy row 无此 identity 时不得用 path/offset/content 猜测补齐。
38. B-038 `coverage_status != complete`、`data_status != ok` 或纳入的 event set 为空时，
    public/internal/shareable headline counts 必须为空，并携带 closed reason；只有完整
    snapshot 中至少一个 schema-valid canonical event 才能发布普通数值（包括真实的 0）。
39. B-039 `summary_digest` 只绑定稳定内容：source event-set、完整 window（含
    `coverage_status`）、`data_status`、closed status reason、scope、taxonomy、exact
    producer version、producer schema 与 counts；不得包含 `generated_at`、attempt time 或 renderer metadata。
    同时存在多个 failure facts 时，producer 必须先收集完整 closed candidate set，再按 tech 固定优先级
    选择唯一 `status_reason`；不得依赖扫描或错误发现顺序。同一稳定输入重试必须得到同一 digest，
    不同 evidence 必须得到不同 digest。同一 `event_id` 对应多个不同 canonical tuples 时，event-set
    hashing 必须以完整 canonical tuple bytes 作固定 secondary tie-break，不能依赖 archive 枚举顺序。
40. B-040 scheduler lifecycle、artifact freshness、report data status 与
    ownership/retention health 是四个正交的
    closed dimensions；任一维缺失、未知或非法组合均 fail visible，不能用 `no_data`/
    `stale` 覆盖健康 active scheduler，也不能用 active 掩盖 stale/invalid artifact。合法
    artifact/data/retention combination 必须由 tech 的 closed table 固定，不能留给
    schema/renderer 自选；从未提交 ownership receipt 但已存在 malformed/foreign current 时，
    `invalid + null + not_initialized` 是合法且必须可表示的组合。retention failure 不得伪装成
    scheduler `broken`。
41. B-041 summary generation、publish 和 retention 必须与 disable/clean/upgrade 使用
    同一有界 lock/lease 顺序；writer/GC 的 source-log critical lock 只允许捕获 immutable snapshot
    generation、handles 与 ledger identity，archive hashing/verification 必须在释放该 lock 后异步、有界执行，
    再重验 ledger generation。每次 enable/disable/clean 以及任何改变 wrapper/runtime/
    taxonomy/schema 或 generator inputs 的 upgrade 必须推进 durable monotonic lifecycle
    generation；generator 在等待 lock 前捕获 generation token，取得 lock 后及 publish 前都须
    复核 matching enabled generation。disable/clean 只有在阻止新 generation 且旧 generation
    已完成、取消并确认无后续 publish，或明确失败回滚后才能报告成功。
42. B-042 retention ownership 必须由独立、版本化、crash-atomic append-only receipt chain
    证明，而不能只靠 artifact 通过当前 schema 或历史路径 receipt。标准 Linux/macOS pathname
    rename/unlink、no-replace rename 加 reverify
    都不构成 compare-by-identity delete capability，用户可写路径默认 `no_auto_delete`。只有 attested backend
    同时提供 atomic expected-identity claim、同 identity delete/retire、crash recovery 与 replacement-race
    evidence 时才可 auto-retire；retention必须先 pin append-only pointer chain当前 target，永不选择它。
    只有 matching commit marker 的 receipt 才算已提交；record已写但 marker或 pointer未提交的 orphan
    不得凭 receipt/path删除：无 capability时保留并计入 entries/bytes
    hard caps，有 capability也须 atomic compare-by-identity claim/retire。capability缺失或失效即停止删除，并在
    下一历史写将触及 cap前 fail visible、保留 current/candidate/orphan。ledger损坏同样停止删除和新增 history。

## 验收标准

- [ ] H-001 至 H-008 均有维护者互斥选择，且 recommendation 未被当作默认批准。
- [ ] 在每个获批平台的 fresh checkout 和 verified payload 安装中，一次安装确认后
  无需额外 setup；下一个合格 window 自动生成 schema-valid value summary。
- [ ] dangerous/invented/other/protocol/operational 混合 fixture 满足互斥、去重和
  accounting；free-text 相似、unknown mapping 和 GH-706 non-protocol aggregate
  均不能抬高 headline。
- [ ] complete 空集为 no-data；同一空集只要 archive/ledger/writer/authority evidence 不完整就以
  partial coverage 为准。old runtime/taxonomy、malformed evidence、
  scheduler load failure、target drift 和 interrupted write 全部 fail visible，
  不产生虚假的 0-risk/current artifact。
- [ ] live log 与跨月/当月 overflow archives 在同一 snapshot 中产生相同稳定 event set；
  durable coverage ledger 能发现 scan 前已丢失/过期的 archive；archive 缺失/损坏/竞态、
  带 event-time interval 的 writer gap、legacy identity 与 incomplete evidence 均不能发布数值 headline。
  空 source bootstrap + 连续且未过期 heartbeat + 空 attempt set（或仅 verified no-spawn slots）可证明 complete-empty；caller 只在 parent ID 对应的
  authority-opened durable slot ack 后启动，dual ledger/spool loss 留下未闭合 sequence，两者都只能 partial；
  可信 suspend/boot fence 排除已证明的 host-unavailable 区间，缺 fence/open slot 才形成 recovery gap；
  opt-out/unsupported 默认没有 authority 或逐事件 diagnostic，unsupported 的显式 manual authority 在 stop seal
  后只读 generate，只能证明自身 sealed epoch 连续覆盖的 window，后续 enable 在首个完整 window 前保持 partial；
  clean 在删除 state 或提交 no-current 前必须对 scheduled/manual authority 复用 quiesce、terminal seal、stop 与
  resident-process proof，scheduler inactive 不能替代 manual authority barrier，任一 proof 缺失则 nonzero 且不报告成功；
  caller 已启动后的 coverage failure 不改变其 guard decision/exit semantics，且 reservation 通过官方 hook P95 gates。
- [ ] canonical writer 在 Rust、shell 与 Python authorized-discard 路径持久化 closed event/rule/reason identities；
  unknown/incompatible host 与 unclassified v2 映射确定的 partial reason；真实 v1 missing identity 映射
  `legacy_evidence` partial，present ID conflict 映射 `event_identity_conflict` partial，schema-v2 missing required
  identity 则 terminal nonzero/no-publish；free-text-only 行为降级可见，且不要求 GH-704 先批准或实现。
- [ ] 同一 window 的重试在 GC/compaction、archive enumeration、renderer 和生成时间变化后仍保持同一
  `summary_digest`；真实新 event 或 coverage/data/status-reason/producer-version 变化改变 digest。
- [ ] shareable Markdown/JSON 逐字段符合 allowlist，`generated_at` 是否出现严格服从 H-005；
  同一 generation 的两种 renderer 只通过一个 crash-atomic append-only pointer record 同时可见；adversarial project/path/
  prompt/command/token sentinel 不出现，自动路径无网络或剪贴板副作用。
- [ ] install/upgrade/disable/enable/clean 幂等且并发安全；旧 opt-in health job、
  用户 opt-out、第三方 jobs 和默认保留的历史 reports 均按合同处理。
- [ ] doctor/verify 对 scheduler lifecycle、artifact freshness、data status 与
  ownership/retention health 的组合以及 stale/tampered evidence 给出确定性、可操作结果。
- [ ] generation 与 disable/clean/upgrade 的 race 不产生 lifecycle 成功后的 late publish；
  clean 或 input-changing upgrade 前已启动但仍在等待 lock 的 generator 被旧 token 拒绝；
  retention 的 current-target pin与 capability-attested claim/delete barrier在 replacement时不删除 current或
  不匹配对象；默认 backend保留 receipt-only orphan并计入 hard caps，缺保证时不 auto-delete且 cap前停止新增。
- [ ] checkout 与 GH-699 payload/package-manager entry 的真实 smoke 输出同一
  taxonomy/version/count/digest，并证明 payload 运行不依赖 repository checkout。

## 边界情况清单

| 类别 | 判定（covered: B-xxx / N/A + 原因） |
| --- | --- |
| 空/缺失输入 | covered: B-001, B-010, B-011, B-019, B-026, B-031, B-032, B-035–B-040, B-042 |
| 错误与失败路径 | covered: B-005, B-007, B-010, B-011, B-013, B-027, B-030, B-031, B-033, B-035–B-042 |
| 授权/权限 | covered: B-002, B-004, B-019, B-020, B-021, B-022, B-026, B-027, B-029 |
| 并发/竞态 | covered: B-009, B-017, B-022, B-028, B-034, B-035, B-037, B-041 |
| 重试/幂等 | covered: B-006, B-009, B-017, B-028, B-034, B-035, B-037, B-039, B-041 |
| 非法状态转换 | covered: B-004, B-007, B-025, B-026, B-027, B-030, B-034, B-040, B-041 |
| 兼容/迁移 | covered: B-003, B-023, B-025, B-026, B-031, B-032, B-035–B-037, B-039, B-040, B-042 |
| 降级/回退 | covered: B-005, B-007, B-010, B-011, B-024, B-030, B-031, B-032, B-034–B-042 |
| 证据与审计完整性 | covered: B-001, B-008, B-012–B-020, B-030, B-033, B-035–B-040, B-042 |
| 取消/中断 | covered: B-007, B-022, B-028, B-034, B-035, B-041 |

## 发布说明

GH-703 只有在 H-001 至 H-008 获批、默认 scheduler 在真实安装入口通过验证、且
privacy/export negative evidence 完整后，才能宣称“default install produces a
weekly summary”。本 Draft 不改变当前 opt-in 行为。

若获批，发布说明必须明确：对 GH-556 的 supersession 仅限 value-summary scheduler
默认值；完整 health report 仍是独立维护者 surface；分享始终是显式、本地、
allowlisted export；Windows 或其他未获批平台不得宣称 active。GH-700/GH-701
不是默认实现硬依赖；GH-704 也不是 structured event identity 的隐性前置条件。未来
共享 taxonomy、新增 host 或接入 semantic evidence 时必须保持本合同。
