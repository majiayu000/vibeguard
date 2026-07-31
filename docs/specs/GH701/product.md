# Product Spec — agent firewall 定位与可扩展 host adapter 契约

## Linked Issue

GH-701

complexity: large

## 用户问题

VibeGuard 的规则、hook、guard 与本地 observability 已经能保护 Claude Code 和
Codex CLI，但公开叙事与安装面仍把产品呈现成“两种工具的规则包”。当前 host
接入也不是一个可复用的公开契约：`hooks/manifest.json` 只表达 `claude` 与
`codex` 两列，安装、配置、输入归一化、输出适配、health 与清理逻辑按 host
分散。新增 Cursor CLI、Gemini CLI 或 opencode 时，很容易复制 rule/guard core、
漏掉 capability 差异，或在未知 host 上显示虚假的“已保护”。

PR #705 只是首屏目标的 **partial baseline**：README 已有 agent-firewall 一句话
定位、真实 demo GIF、当前支持的 clone 安装命令与拦截清单，但四个 required blocks
中只有“定位”和“demo”完成；“免 clone 一命令安装”和“可复现 benchmark 表”仍分别
依赖 GH-699 与 GH-700。额外内容是否继续留在首屏由 H-004 决定。PR #705 也没有
实现 host adapter seam 或证明第三个 host，不能把 partial baseline 写成整个
GH-701 已完成。

## 目标

- 建立一个有版本、可验证、可扩展的 host adapter 契约，使 host-specific
  配置、事件与响应留在 adapter 边界，现有 rule/guard core 不因新增 host 分叉。
- 在 Claude Code 与 Codex CLI 之外交付至少一个经维护者选定的新 host adapter，
  用真实安装、真实 host event 与真实 interception 证明 seam。
- 对未知、缺能力、版本不兼容或配置失败的 host 显式降级，绝不把“不支持”显示成
  “已保护”。
- 保持 PR #705 已交付的 partial baseline，并按维护者批准的 H-004 呈现首屏：
  推荐的 strict-four 模式只保留一句话定位、30 秒真实 interception demo、经
  GH-699 证明的一命令安装、经 GH-700 证明的 benchmark 表；若维护者改选保留
  PR #705 额外内容，必须先同步 GH-701 issue acceptance，再由同一证据 renderer
  呈现。H-004 未选择时不得实施 README 最终布局。

## 非目标

- 不重写规则、guard、hook decision 语义、profile 或 runtime policy。
- 不承诺 Cursor CLI、Gemini CLI、opencode 三者全部在本 issue 中支持；本 issue
  只要求一个经批准的 proof host，其余 host 必须有 truthful capability 状态。
- 不用模拟器、手工拼 JSON 或 VibeGuard 自己的 demo 命令冒充新 host 的真实接入
  证明。
- 不在 GH-699 完成前发明一命令安装入口，也不在 GH-700 完成前发明 benchmark
  数字或发布表格。
- 不引入 SaaS、远端 telemetry、云端规则执行或凭据收集。
- 不把 PR #705 已完成的 README 重排作为本 issue 的主要实现工作。

## 已完成 slice 与剩余范围

| 范围 | 当前状态 | 本 spec 的处理 |
| --- | --- | --- |
| 一句话 agent-firewall 定位 | PR #705 已合并（required block 1/4） | 保持，不回退到 two-tool rule-pack 叙事 |
| 30 秒真实 interception demo | PR #705 已合并（required block 2/4） | 保持真实 demo 与可重录来源 |
| 当前 clone 安装与拦截清单 | PR #705 partial baseline | 不是最终 one-command/benchmark block，不据此宣称 GH-701 完成 |
| 免 clone 一命令安装 | GH-699 `ready_to_implement` | 依赖交付；本 issue 不声明完成 |
| 可复现 benchmark 表 | GH-700 `ready_to_spec` | 依赖交付；本 issue 不声明数字 |
| host adapter seam 与第三 host proof | 未实现 | 本 issue 的主要剩余范围 |

## Recommended proposals（待维护者批准）

以下互斥选择是推荐方案，不构成本 spec 自行批准；维护者没有留下明确选择记录时，
实现 gate 必须保持 blocked。

1. **H-001 proof host — Recommended proposal: Gemini CLI**。其官方文档已有
   synchronous `BeforeTool` hook、structured deny 与 extension hook packaging，
   比需要 in-process TypeScript plugin 的候选更接近现有 stdin/stdout adapter。
   维护者仍须批准该选择并固定被验证的 Gemini CLI release/protocol；备选为
   opencode，Cursor CLI 只有取得等价 native blocking evidence 后才可选择。
2. **H-002 安装触发 — Recommended proposal: 专用 `--host gemini` opt-in**。
   discovery 始终只读，只有用户明确给出 host 参数并确认 diff 才写配置；“检测到
   executable”互斥备选也只能生成 proposal，必须经过相同的 exact-diff 确认后
   才能写入，不得与 opt-in 同时生效。
3. **H-003 stale branch — Recommended proposal: delete after approval**。远端
   `docs/gh701-readme-first-screen` 当前指向 `c77253b4`，其有效内容已通过 squash
   merge PR #705（`48076210`）进入 main，且该 commit 不是 main ancestor。唯一
   备选是 `readonly_retain`，并必须同时记录唯一 owner 与 UTC expiry；不允许
   rebase、复用、继续 push、无 owner/expiry 永久保留或“稍后再决定”。
4. **H-004 README 首屏组成 — Recommended proposal: `strict_four`**。该选择把
   定位、demo、GH-699 one-command 与 GH-700 benchmark 作为首屏恰好四块，并把
   PR #705 的当前 clone 安装与拦截清单移到首屏之后。互斥备选
   `preserve_pr705_extras` 允许额外内容继续留在首屏，但维护者必须先通过同一
   GitHub 决策来源明确更新 GH-701 issue acceptance，列出保留块及其证据要求；
   不能只改 spec/README 后声称 acceptance 已同步。两者均未获批或同时出现时，
   route、README renderer 与 closure gate 必须 blocked；task planning 仅可生成
   B-034 的一次性 fail-closed bootstrap allowlist tranche。

## Behavior Invariants

1. B-001 README 与用户可见状态页必须把 VibeGuard 描述为位于 AI coding agent
   与 codebase 之间的本地 firewall，同时把“已支持 host”限制为有当前安装、
   capability 与真实 interception 证据的 host；不得用产品定位暗示所有 agent
   已受保护。
2. B-002 PR #705 只算最终首屏四块中的定位与 demo 两块以及当前安装的 partial
   baseline；GH-699 尚未通过其验收前，首屏安装命令必须继续显示当前真实受支持
   路径，不得把 clone install 称为 final one-command block 或宣称 GH-701 完成。
3. B-003 首屏 benchmark 表或 headline number 只有在 GH-700 提供 released
   command、fixture/version 与可复现结果后才可发布；缺少或过期证据时必须显示
   尚未提供，不得填 0、示例值或历史 CI latency 冒充 effectiveness benchmark。
4. B-004 每个 host 必须有闭集 capability 状态
   `native`、`partial`、`unsupported`、`not_applicable`，并逐项声明 event、
   blocking ability、profile 与协议版本；字段缺失、未知枚举或自相矛盾时契约
   校验必须失败，不能推断为 `native`。
5. B-005 host adapter 只能把 host event 转成 VibeGuard 的 canonical hook
   request，并把 canonical decision 转回 host response；新增 proof host 时，
   相同 canonical fixture 的 rule/guard decision、reason class 与 enforcement
   mode 必须与现有 host 一致，不能复制或改写 rule/guard core。
6. B-006 proof host 必须在真实 CLI/session 中完成至少一个支持的 blocking
   interception：安装/启用成功、host 发出真实 event、VibeGuard 返回该 host
   可执行的 deny/block 与 fix instruction、event log 记录正确 host identity；
   手工调用 wrapper、直接调用 runtime 或 demo transcript 不算 proof。
7. B-007 proof host 的 unsupported event 必须逐项标为 `unsupported` 或
   `partial` 并给出可操作说明；adapter 不得注册 host 不会发送的 event，也不得
   用 pass、空输出或“healthy”掩盖能力缺口。
8. B-008 未知 host、未知协议版本或无法辨认的 event 必须 graceful fail：
   不修改 host 配置、不报告已安装/healthy、不执行 rule/guard core，并返回
   bounded、无敏感内容的 unsupported/incompatible 诊断与下一步；若请求已进入
   一个声明可 blocking 的 adapter 且 payload 无法安全归一化，则保持 fail
   closed。
9. B-009 adapter 对 malformed payload、未知 tool/event 名称、缺字段和错误类型
   不得持久化 raw payload、command、file content、prompt、token、secret 或任意
   host free text；诊断只允许闭集分类与必要的非敏感结构元数据。
10. B-010 proof host adapter 安装必须是幂等的：重复执行产生同一语义配置，不
    重复注册 VibeGuard hook，不改变第三方 hook 的内容或相对顺序；clean/disable
    只移除可证明由 VibeGuard 管理的条目。
11. B-011 host 配置缺失、只读、语法损坏、写入中断或 verification 失败时不得
    留下“安装完成”的部分状态；旧可用配置必须保留或恢复，失败必须可见并给出
    修复动作。
12. B-012 同一机器同时安装多个受支持 host 时，各 host 的配置、wrapper identity
    与 health evidence 必须隔离；并发或任意顺序的重复安装不得让一个 host 的
    event 被归属为另一个 host，也不得覆盖第三方配置。
13. B-013 新 adapter 的默认数据流保持 local-first：不新增网络上报、远端执行、
    analytics 或 secret 读取；host 配置写入只发生在用户确认的目标与 VibeGuard
    owned entry 内，并遵守 host 自身权限边界。auto-detect 只能提出候选 target，
    不能把 executable 存在视为确认；每个 target 都必须展示并确认 exact diff。
14. B-014 已支持的 Claude Code 与 Codex CLI 安装、profile、capability、
    fail-closed、第三方 hook preservation、doctor/verify-install 与 clean 语义
    必须保持；generalize manifest 或 adapter registry 不得改变它们的有效配置。
    两者现有 JSON target 继续使用已验证的 atomic owned-entry merge/clean 兼容
    lifecycle，不追溯要求 host storage API；B-025 的新 shared lifecycle 只用于
    proof host/新增 v2 host，registry 必须显式选择二者而不能把旧 host 降级为 manual。
15. B-015 adapter 与 core 的 compatibility 必须由 host adapter contract
    version、host protocol/version range 与 VibeGuard runtime version 显式判定；
    每个 host registry entry 必须声明可接受的 runtime version/ABI range，并在
    配置写入或 core 执行前验证；不兼容组合必须 fail visible，不能尝试
    best-effort 转换后报告成功。
16. B-016 用户中断安装或 adapter update 后重试时，系统必须从已验证的旧状态或
    明确的 incomplete 状态继续；不得复用未验证的 temporary config、伪造成功
    evidence 或产生重复 event registration。
17. B-017 每次 install/check/doctor 必须从当前配置与一次 bounded probe 生成
    host evidence，至少区分 `active`、`partial`、`unsupported`、
    `incompatible`、`broken`、`not_installed`；历史日志或仅检测到可执行文件
    不能单独证明当前 protection active。
18. B-018 在 GH-699 与 GH-700 各自完成且 H-004 有且只有一个获批选择后，首屏
    才可组合展示其已验证的一命令安装与 released benchmark；renderer 必须消费
    H-004 gate result：`strict_four` 输出恰好四块，
    `preserve_pr705_extras` 只输出已同步到 GH-701 issue acceptance 且有证据的
    命名额外块。从空环境到安装、verify 与 proof host 真实 interception 的
    维护者复核流程应在五分钟目标内完成；任一依赖或 H-004 缺失时必须明确显示
    当前较窄路径而非宣称达标。
19. B-019 一个 native host event 必须归一化为有序的零到多个 canonical
    requests，而不是假设永远一对一；零项只允许来自显式 `unsupported` /
    `not_applicable` mapping，多 tool/file event 的每个可执行项都必须保留原输入
    顺序并被 core 独立判定。每个 batch 最多 64 个 requests；decoder 必须在任何
    core evaluation 或逐项日志之前验证完整 count，超限或无法确定 count 时整个
    batch fail-closed，禁止截断或部分执行。host entry 还必须声明同步 response
    deadline；adapter 为 encode 和 termination 各保留固定时间，以剩余总预算约束
    每项 core 调用。每项在可取消的独立 process group/job boundary 运行；到期时必须
    终止整个 boundary 并确认全部 child 已 reap，之后才可为当前项及所有未执行项
    生成闭集 `hook_error` 并返回 fail-closed，禁止遗留进程或 late output/log。
20. B-020 同一 batch 的 mixed decisions 必须按固定优先级
    `hook_error > block > escalate > gate > correction > warn > complete > pass`
    产生唯一 host response；每个 core invocation 的 `failed` 或 `hook_error`
    必须先规范化为 fail-closed `hook_error` decision，不能丢弃、降级或留给
    aggregator 猜测。`hook_error`、`block`、`escalate`、`gate` 任一存在时都不得
    执行 correction。
    `complete` 是已完成的非 enforcement 结果，必须显式聚合但不得覆盖 warning、
    confirmation 或 blocking 结果。多个 block 全部进入日志，primary block
    取输入顺序最早者，去重后的 fix instructions 按输入顺序有界合并，不能只记录
    最后一个或让 pass/complete 覆盖 enforcement。
21. B-021 每个 canonical request、decision、fix instruction、host response 与
    event-log row 必须共享不可复用的 `batch_id`、`request_id` 与有序 index；
    缺失、重复、跨 batch 引用或 primary response 无对应 log evidence 时 proof
    与 health gate 均失败。
22. B-022 manifest v2 必须在 top-level 声明 host registry，并由每个 executable
    hook 引用 per-host mapping；mapping 只能引用已声明 host。library、manual 与
    git-hook 等非 host-dispatched entry 不得伪造 host mapping；host/mapping
    缺失、重复或矛盾必须 fail loud。
23. B-023 v1 manifest 只能在明确 deprecation compatibility path 中读取并
    规范化为 Claude/Codex view，不能表达第三 host、不能生成 proof-host active
    evidence，且 writer/generator 只输出 v2；移除 v1 reader 需要后续 spec，不得
    在本 issue 静默删除兼容。
24. B-024 unknown matrix 必须稳定区分：未知 manifest host/mapping 为 contract
    error；discovery 遇到未知 executable 为 `unsupported` 且零写入；known host
    + unknown protocol 为 `incompatible`；blocking adapter runtime 收到未知
    event/payload 为 fail-closed。四类不得互相降级成 pass/active。
25. B-025 proof host/新增 v2 host 的 config 更新必须遵守
    `discover → plan → lock → snapshot → apply → probe → commit/rollback`；
    任一步失败、中断或超时都不得写 committed/active evidence，plan 之后的配置
    digest 漂移必须停止而不是覆盖并发更改。自动写入仅支持 host storage API
    提供的 versioned CAS/lease：同一服务端 linearization point 验证 version，
    lease 排斥旧/新 writer，再 commit candidate；journal 记录 transaction/version/
    lease token 并通过 API 查询恢复。普通 macOS/Linux JSON 文件、rename、
    advisory lock、mtime 或 exclusive claim 都不能排除延迟 old-FD write，不得
    冒充该 capability；只能输出 exact-diff 的 manual proposal、零磁盘 mutation，
    状态保持 `partial/needs_human`，不能产出 active/proof。获批 proof host 若无
    该 API 必须重新选择，不得实现不可达的自动 install 契约。Claude/Codex 现有
    JSON target 依 B-014 走显式 compatibility lifecycle，不得被本条静默改成 manual。
26. B-026 同一 config 的并发 writer 必须由 bounded lock 串行化；多个 config
    按 canonical path 排序取锁避免死锁。进程崩溃后下一次运行必须识别 pending
    transaction；普通失败与崩溃恢复都只有在 lease token 仍归属本 transaction、
    API current version 精确等于 apply 返回的 version 且 digest 等于 candidate 时
    才可 version-CAS rollback。任一 token/version/digest drift（包括 bytes 相同但
    version 更新）都保留当前内容并进入 `broken/needs_human`。
27. B-027 GH-699 install claim 与 GH-700 benchmark claim 必须分别有固定 schema、
    固定 evidence path 与同一个离线 README-claim validator；validator 绑定 claim
    类型、issue、release、source HEAD、exact producer SHA/argv、输入/输出 digest、
    protected-CI run identity、detached artifact attestation 与 README rendered
    value；claim payload 的 exit code、clone marker、sample count 或 numerator /
    denominator 不得作为未经认证的自报事实。missing、schema-valid semantic
    mismatch、tampered/unsigned payload、错误 workflow/ref/producer invocation、
    stale HEAD/release、非零 install、repo clone、占位/历史 latency benchmark
    均必须由 negative fixtures 拒绝。GH-700 的唯一 benchmark authority 是其
    committed GitHub Release 所绑定并验签的 `public_benchmark_summary`、对应
    report checksums 与 `publish_intent`；GH-701 不得另跑一次 `vibeguard bench`
    或建立平行的 README benchmark payload。
28. B-028 第三 host proof 必须由固定 schema/path 的 fresh runtime artifact 与
    独立 maintainer witness 共同满足：runtime artifact 精确绑定当前 candidate
    HEAD、VibeGuard 生成的 event correlation ID、redaction result、host binary
    SHA-256、VibeGuard
    runtime SHA-256、config digest 与 correlation IDs；超过 7×24 小时、future
    timestamp、head/event/digest 不匹配、缺 witness 或 witness 早于 event 时 gate
    必须阻断。proof gate 还必须消费当前 H-001 decision result，并 exact-match
    获批的 host_id/option、host release、protocol snapshot、native blocking
    event 与受信发行来源。host binary 必须通过 H-001 绑定的签名 package identity、
    registry integrity 或 signed release manifest 得到独立 approved digest，并由
    受信 proof supervisor 在事件发生时对 proof-producing process 做平台进程测量。
    supervisor 必须输出固定 schema/path 的 detached attestation；验证器 exact-match
    protected workflow issuer/identity/ref/SHA，并把 runtime proof SHA、candidate
    head、event/nonce/process/distribution digests 与 redaction inventory digest
    绑定为 attested subjects，缺任一绑定都阻断。
    native binary 绑定 session nonce、进程身份与 executable digest/signature；
    interpreted CLI 还必须绑定 interpreter、canonical argv/entrypoint 与受信发行
    manifest 的只读 package snapshot/Merkle root，禁止 snapshot 外 module load。
    gate-time 路径重读、binary 自报 release/SHA 或 pathname 不能建立 provenance。native
    event ID/free text 不得持久化。另一个第三 host 的有效 proof 不能替代获批选择。
29. B-029 stale branch 最终状态只能是 `deleted`，或
    `readonly_retain + owner + UTC expiry + active no-bypass update restriction`；
    protected collector 必须从 GitHub ruleset/protection API live 验证规则覆盖
    exact branch、禁止 update 且 bypass actor 为空，并绑定 rule ID/digest。仅
    `ls-remote`、任何第三状态、缺字段、expiry 已过或发生新 push 都阻断 closure。
30. B-030 H-004 必须是维护者明确选择的互斥值 `strict_four` 或
    `preserve_pr705_extras`，推荐值 `strict_four` 本身不构成批准；后者还必须绑定
    已更新 GH-701 issue acceptance 的 immutable node/source URL、更新时间与
    acceptance digest。H-004 缺失时 task plan 仍须覆盖全部 B-ID，并可预排明确标为
    blocked、依赖 `gh701_decision_gate: allowed` 的 README/host tranches；唯一可执行
    的内容是 `bootstrap_once` allowlist。两值并存、issue 未
    同步或同步发生在选择之后但未重新见证时，README/implementation/closure
    gate 均 blocked。
31. B-031 H-001 至 H-004 必须来自固定路径、固定 schema 的 machine-readable
    decision record。受保护 collector 每次授权前必须重新读取 live GitHub source，
    确认原 node 仍存在、内容/updated_at 未变、没有更新的同 decision 或显式
    revocation，并生成 fresh collection generation；随后离线 gate 验证每项选择、
    维护者 actor、`author_association`、immutable source URL/node、approved spec
    head 与时间。只有当前受保护 CI run 的 live-source check 与对应 attestation
    同时有效才可 `allowed`。推荐文本、实现者自填 JSON、已编辑/删除/撤销 source、
    较旧 generation、缺失/过期/错误 head 的记录均不算批准。普通 routing、
    task plan、renderer 与 closure 必须重新消费当前 gate result 及 record digest，
    不能依赖人工口头说明、本地离线 preview 或复用另一 HEAD/较早 run 的结果。
32. B-032 runtime proof 与 maintainer witness 必须是两个独立 artifact。
    maintainer witness 只能由受保护的只读 GitHub collector 获取并带可离线验证的
    attestation，绑定 immutable node、native event、candidate head 与见证时间；
    implementer 不能通过 runtime proof 字段、命令参数或手写文件提供 actor、
    association、source URL 或 witnessed time。witness record 必须绑定 source
    body digest、`updated_at`、单调 collection generation 与 revocation state；
    每次允许 proof 前，当前 protected run 必须重新读取该
    `observed_native_block` source，确认 node 仍存在、body/digest/time 未变且没有
    后续 revoke/superseding witness。任一 artifact 缺失、source 已编辑/删除/撤销、
    绑定不一致、attestation 无效或 evidence 不新鲜时 third-host gate blocked。
33. B-033 primary block 的 fix instruction 即使单项超过 response byte cap，也
    不得被省略成无修复信息的响应；encoder 必须保持 `block`，返回固定、无 payload
    的有界 closed fallback 并标记 truncation/fallback；原 fix 存在但 oversize
    或编码失败时保留其随机 `fix_id`，原 fix 缺失时生成新的 CSPRNG
    `fallback_fix_id`。oversize 原文及其 content-derived digest 不得进入
    response/log/proof；schema-valid oversize-primary
    fixture 必须证明 pass/correction/空 fix 均不会替代该 closed fallback。
34. B-034 decision collector/gate 尚未存在于受保护 main 时，只允许一次
    `bootstrap_once` tranche。该 tranche 只由 ordinary repository routing 的
    `plan_first` handoff、维护者对 product/tech 的明确 GitHub review、live
    duplicate-work search、当前 PR CI 与 human merge review 授权；任何可选
    SpecRail packet/evaluator 都不是前置条件或授权来源。task plan 必须覆盖全部
    B-ID；只有 bootstrap tasks 可执行，其余 tasks 全部依赖尚未满足的
    H-001–H-004 decision gate。bootstrap PR 的实现 diff 只能包含 decision/witness
    schemas、只读 collector、全部 decision/proof/README authorization gates 及
    schemas、README renderer、受保护 main workflows 和这些表面的 tests/fixtures；
    所有下游 gate 在 decisions 缺失时必须 fail closed。不得改 host adapter、
    runtime/manifest、setup、README 或生成 active/完成 claim。该 PR 仍须正常 CI、human final review
    与 merge gate；只有 merge 到 main、attested completion sentinel 验证完整
    protected workflow、collector/schema/gate path set 与全部 contract/blob
    digests 后才能收集可信 decisions，任一缺失或漂移只能是
    `partial/needs_human`，绝不能标为 closed。
35. B-035 decision record 必须同时绑定 `approved_spec_head_sha`、product.md 原始
    bytes SHA-256、tech.md 原始 bytes SHA-256 与 canonical decision-input
    SHA-256。后续 task/implementation HEAD 只有在 approved spec head 是其 ancestor、
    两份 spec bytes digest 完全相同且重新计算的 decision-input digest 完全相同
    时才能继承批准；task/code/test 的非 decision-sensitive descendant commit 可以
    继续。任一 spec byte、H-001–H-004 option/约束、issue acceptance snapshot、
    proof protocol/release、branch expectation 或 collector trust identity 改变，
    旧 decision 立即失效并必须由维护者重新收集/批准。已关闭的 bootstrap 不能因
    trust-path 修复而重开；修改 collector/schema/gate/workflow 必须走受保护 main
    发起的 `trust_rotation`：独立维护者批准精确 candidate HEAD、旧/新 path digests、
    diff digest、scope 与 expiry，protected-main collector 直接读取 candidate bytes
    并签发 attestation。candidate 自身 workflow、实现者 JSON 或宽泛 path approval
    均不能授权轮换；merge 后必须重建 completion sentinel 并重新收集 decisions。

## 验收标准

- [ ] 有一份版本化 host adapter/capability 契约，Claude、Codex 与 proof host
  都通过 schema 与 deterministic fixture 验证，未知 host/字段 fail visible。
- [ ] 新 proof host 在真实 session 中完成一次 blocking interception，输出 fix
  instruction，health evidence 显示正确 host/protocol/capability。
- [ ] 同一 canonical fixture 在 Claude、Codex、proof host 的共同能力交集上得到
  等价 decision；新增 host 的 diff 没有复制或修改 rule/guard core。
- [ ] 重复安装、第三方 hook preservation、malformed config/payload、partial
  write、clean 与多 host 顺序/并发 fixture 全部通过。
- [ ] README 只陈述当前可证实事实；GH-699/GH-700 未完成时不提前发布一命令安装
  或 benchmark，完成后五分钟 journey 有新鲜人工证据。
- [ ] multi-request fixture 覆盖 mixed decision 与多个 block，response、fix 与所有
  event logs 可由 batch/request IDs 双向关联。
- [ ] manifest v2、v1 compatibility/deprecation、non-host entries 与完整 unknown
  matrix 有 schema-valid positive/negative fixtures。
- [ ] config transaction 的 versioned CAS/lease、lock contention、TOCTOU drift、
  每个 phase failure、API-based crash recovery/safe rollback 均有确定性证据；
  普通文件/rename/exclusive-claim 与 delayed old-FD fixtures 必须零写入并保持
  partial，不能产出 active/proof。
- [ ] GH-699/GH-700 README claims 与第三 host proof 各由固定 gate 消费；缺失、
  tampered、stale、wrong-head/event/digest/witness fixtures 全部 nonzero。
- [ ] H-001–H-004 decision record 与 maintainer witness 分别通过固定 schema、
  protected collector attestation 和离线 gate；witness source 的 edit/delete/revoke
  在当前 protected run 被重新查询并拒绝；route/task/renderer/closure 都绑定当前
  HEAD 的 gate result，implementer 自填 evidence 被拒绝。
- [ ] oversize primary fix fixture 保持 block 并返回有界 closed fallback，原文
  不出现在 response、双日志或 proof。
- [ ] bootstrap tasks 只能在 ordinary `plan_first` handoff、维护者 GitHub spec
  approval 与 live duplicate-work search 后生成并执行一次；bootstrap PR diff
  allowlist、CI、human review 与 merge gate 均通过，且可选 SpecRail 输出不参与
  授权；merge 前所有普通 implementation tasks 保持 blocked。
- [ ] decision gate 对 approved spec head 的 descendant 仅在 product/tech byte
  digests 与 canonical decision-input digest 均不变时 allowed；任一敏感输入变化的
  schema-valid fixture 要求重新收集维护者批准；精确、限时、protected-main
  `trust_rotation` 是修改 trust paths 的唯一通路。

## 边界情况清单

| 类别 | 判定（covered: B-xxx / N/A + 原因） |
| --- | --- |
| 空/缺失输入 | covered: B-004, B-008, B-009, B-019, B-022, B-027, B-028, B-030, B-031, B-032, B-034, B-035 |
| 错误与失败路径 | covered: B-007, B-008, B-011, B-015, B-017, B-020, B-024, B-025, B-028, B-030, B-031, B-032, B-033, B-034, B-035 |
| 授权/权限 | covered: B-010, B-011, B-013, B-025, B-028, B-029, B-030, B-031, B-032, B-034, B-035 |
| 并发/竞态 | covered: B-012, B-021, B-025, B-026 |
| 重试/幂等 | covered: B-010, B-016, B-021, B-026, B-034, B-035 |
| 非法状态转换 | covered: B-011, B-015, B-016, B-017, B-024, B-025, B-026, B-029, B-030, B-031, B-032, B-034, B-035 |
| 兼容/迁移 | covered: B-004, B-014, B-015, B-022, B-023 |
| 降级/回退 | covered: B-003, B-007, B-008, B-011, B-018, B-024, B-026, B-030, B-033, B-034, B-035 |
| 证据与审计完整性 | covered: B-001, B-002, B-003, B-006, B-017, B-018, B-020, B-021, B-027, B-028, B-029, B-030, B-031, B-032, B-033, B-034, B-035 |
| 取消/中断 | covered: B-016, B-025, B-026, B-034 |

## 发布说明

PR #705 是定位+demo 已完成、install+benchmark 未完成的 partial baseline，不需要
回滚已完成两块，也不能据此关闭 GH-701。host adapter seam 与 proof host 只有在
spec 获批且 H-001/H-002/H-003/H-004 得到可验证的明确维护者选择后才能实施；
Recommended proposal 本身不算批准。README 的 one-command install 与 benchmark
更新分别等待 GH-699、GH-700 的 deterministic gate，布局严格消费 H-004 gate
result。adapter 发布说明必须列出 capability matrix、batch aggregation、
协议/version range、unsupported event、事务/clean、proof freshness 与隐私边界。
