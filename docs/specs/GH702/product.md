# Product Spec — 可发布的第三方 Guard Pack 合同与精度门

## Linked Issue

GH-702

## Supporting Contract

[`monotonic-anchor-contract.md`](monotonic-anchor-contract.md) 定义 external CAS、本地两代 mirror、
commit journal 与 barrier recovery；其 backend/platform 选择仍须维护者批准。

## 当前事实

截至 2026-07-27，仓库只有一个内置 `safe-bash` Guard Pack。它是现有 Core
hook/rule 的 adoption layer：用户必须从仓库或已包含 `packs/` 的安装 payload 读取
manifest，现有非 dry-run `install` 也只在 Core audit 为 READY 后登记 receipt，并不下载
或安装第三方内容。当前没有 `vibeguard add <pack>`、发布索引、外部 bundle 身份、
供应链撤销机制，pack manifest 也没有与 default decision 绑定的 precision evidence。

GH-702 要把这条内部演示合同升级为外部贡献者可用的发布合同。它会改变用户安装内容、
默认阻断策略和供应链信任边界，因此本 Draft 只定义待批准行为；不代表任何产品或安全
选择已获批准。

## 用户问题

外部贡献者目前无法在不修改 VibeGuard 仓库的前提下发布 Guard Pack。用户也无法用一个
稳定的 released command 解析、验证、安装、升级或卸载第三方 pack，更无法知道某条
第三方规则为何默认 block、其 precision 数据来自哪里、是否仍然新鲜。

如果只把现有 `packs/<id>/pack.yaml` 暴露为下载格式，会同时留下三个危险空洞：

- manifest 引用的是本仓库相对路径，外部 bundle 无法自包含；
- pack 可以宣称 `default_decision: block`，但没有逐规则、可验证的 precision 前提；
- receipt 只登记一条记录，不拥有或回滚真实安装文件，无法安全处理冲突、更新和中断。

## 目标

- 发布一个版本化、可验证、可迁移的 Guard Pack 合同，使外部作者无需修改本仓库即可
  author、validate、publish。
- 提供 released-install 可执行的 `vibeguard add <pack>`、explain、audit、update 与
  remove 生命周期，并在任何用户配置写入前展示精确计划和信任状态。
- 将每条规则的 default decision 与完整、可复核的 precision evidence 绑定；证据不足、
  低于 floor 或过期时默认只能 warn，不能 block。
- 保持 local-first：安装时的必要网络访问和运行时数据边界明确，默认不上传用户事件、
  fixture、路径、代码或 triage 记录。
- 为现有 `safe-bash` pack 提供诚实迁移路径，不能把只登记 receipt 的 v1 行为冒充为已
  安装第三方 bundle。

## 非目标

- 不在本 issue 新增 detector、hook 语义或规则内容。
- 不把任意脚本、native binary、post-install command 或 package-manager lifecycle
  script 默认变成可信执行面。
- 不建立 SaaS、强制遥测、云端策略执行或私有 marketplace。
- 不替代 GH-699 的免 clone release launcher，也不替代 GH-701 的通用 host adapter
  registry。
- 不把 GH-700 的公开 deterministic benchmark、现有 aggregate CI precision gate 与
  per-rule pack default eligibility 混成一个指标。
- 不在本 Draft 选择 registry 运营者、签名根、precision floor 或可执行 capability；
  这些必须由维护者明确批准。

## 待维护者确认的产品与安全决策

以下选择均为 **Recommended proposal（未批准）**。任一决定缺失、双选、越界或没有绑定
获批 spec digest 时，对应 official publish/install/default-block 路径必须停止；实现者
不得把 recommendation 当作默认授权。

1. **H-001 — Pack locator 与发布介质**：`<pack>` 接受哪些来源、如何 pin 版本。
   **Recommended proposal（未批准）**：official locator 为
   `<publisher>/<pack>@<exact_semver>`，由 VibeGuard 配置的 HTTPS index 解析到不可变
   bundle digest；不接受 floating `latest` 作为 committed identity。显式
   `--file <bundle>` 只用于 local/unofficial 安装，v1 不默认接受任意 Git URL、branch
   或 curl-to-shell。
2. **H-002 — Bundle capability 边界**：第三方 pack 能否携带 executable。
   **Recommended proposal（未批准）**：v1 只允许 declarative rules、fixture、文档、
   profile metadata 和 sealed Core executor/capability IDs；禁止任意 shell/native
   executable、install script、dynamic plugin 与自定义 command。需要新 detector 时先以
   独立 Core issue/spec 合并，再由 pack 引用。
3. **H-003 — 供应链信任与 unofficial 路径**：official 所需 publisher/provenance
   强度，以及本地未验证 bundle 是否允许。
   **Recommended proposal（未批准）**：official index entry、namespace ownership、
   bundle checksum 与 release attestation 四者必须闭合；缺任一项拒绝 official 安装。
   `--file` 可在二次风险确认后安装为 `unofficial`，但所有规则强制 warn-only，且不能
   被 core/README/registry 计作 verified。
4. **H-004 — 安装、更新与回滚模型**：内容存储和 config ownership 如何提交。
   **Recommended proposal（未批准）**：每个 exact version 存入 content-addressed、
   readonly store；按 `lock/recover-old → discover/stage/verify → plan/confirm →
   reserve/snapshot → apply/audit → atomic committed-state switch/rollback` 执行，以
   receipt 记录每个 owned file/config entry 的 before/after digest。receipt 与 active
   identity 必须先组成 immutable committed-state generation，再以一次原子指针切换共同
   生效；不存在“active 已切换、transaction 尚未 commit”的中间状态。
5. **H-005 — v1 host scope**：是否等待 GH-701 host registry。
   **Recommended proposal（未批准）**：v1 产品支持仅限现有 Claude Code/Codex
   installed targets，pack 只声明抽象 capability IDs，不复制 host config 形状；若
   GH-701 的 decisions 获批、versioned host registry implementation 合入 main，且其
   compatibility/native-proof gates 通过后，才以其 host/capability IDs 为唯一 source；
   只合并 Draft spec 不构成 registry availability。此前保持获批的固定 Claude/Codex
   scope。第三 host 不能由 GH-702 自造第二套 registry。
6. **H-006 — Precision evidence 与 floor**：谁能出具证据、公式、样本量和新鲜度。
   **Recommended proposal（未批准）**：default-block eligibility 按 rule 计算
   `precision = TP / (TP + FP)`；只接受绑定 exact rule bytes、独立 review、公开 fixture
   ledger 的 curated evidence；要求 precision ≥ 90%、至少 50 个 classified samples、
   最近 30 天无 FP、evidence age ≤ 90 天。author 自报数据只展示，不授予 block。
7. **H-007 — Default decision 与用户 override**：低精度、无数据和安全规则如何处理。
   **Recommended proposal（未批准）**：证据缺失/不足/过期/低于 floor 一律默认 warn；
   不为“security-critical”建立无证据例外。用户可显式把 eligible block 降为 warn/off；
   把 ineligible rule 升为 local block 必须逐规则二次确认，并保持 `local_override`，
   不能改写 official eligibility。
8. **H-008 — Registry 治理与兼容**：namespace、yank、revoke、schema/runtime range 和
   curated/community 区分。
   **Recommended proposal（未批准）**：publisher namespace 唯一且可移交；已发布
   version/digest 不可覆盖；yank 阻止新安装但保留现有可审计状态，security revoke 阻止
   新激活并把已安装规则降为 warn/off + 明确告警；core-curated 与 community badge
   分列，不能由 author 自封。
9. **H-009 — Privacy 与 precision 反馈**：是否以及如何上传本地 triage。
   **Recommended proposal（未批准）**：默认零上传、运行时零网络；precision 反馈只能
   由用户显式导出脱敏 bundle 后另行提交，安装/运行失败不得静默启用 telemetry。
10. **H-010 — Monotonic anchor backend 与生命周期**：哪些平台可用、谁 provision/认证/恢复。
    **Decision frame（未批准，无默认选项）**：维护者必须为每个受支持 OS/architecture 选择
    closed backend kind 与 conformance profile，或明确该平台不允许 official block；不得从
    recommendation、探测到的 TPM/Keychain/service 或环境变量自动选择。批准 artifact 必须分别
    决定 backend/service owner、initial provision 权限与 user/Core/device identity、IPC endpoint 的
    server/client peer authentication/ACL/protocol/anti-replay、key/backend identity rotation、同设备
    reinstall 是 reattach 还是新 root、device replacement/backup restore 是否禁止或走显式迁移、
    backend/IPC unavailable 与 partial-CAS 的 repair authority/UX，以及 intentional reset 的确认、
    evidence retention 和旧 receipts 处置。每个 claimed platform 与每个 anchor-enabled Claude/Codex
    installed hook 还必须填写带单位的 `hook_e2e_p50_ms`、`hook_e2e_p95_ms`、
    `hook_e2e_p99_ms`、`hook_e2e_max_ms`，并填写 `cas_timeout_ms`、`ipc_timeout_ms`、
    `queue_wait_budget_ms`、`contention_total_budget_ms` 与 `contention_retry_limit_count`；不得留空、
    使用无单位“fast/bounded”或用专项 microbenchmark 替代 installed-path end-to-end budget。每次
    gate 必须按 supporting contract 输出 budget、initial、confirmation、逐字段 breaches 与 blocking
    decision；P50/P95/P99/max、CAS、IPC、queue、contention time/retry 任一项都不能被 P95-only
    verdict 隐藏。result 必须 exact 绑定获批 H-010/decision artifact digest 与 authoritative
    evaluation-policy digest/generation/validity evidence；任一 policy/budget rotation 或 mismatch 必须
    nonzero 并全量重跑，不能沿用旧 result。任何字段未选、平台无通过 conformance 的 backend、
    reinstall/device identity 不确定或 IPC peer 无法认证时，不得 provision/reset/迁移 root，也不得
    执行 official committed block；实现不能把 `tpm2_nv_v1` 或任何平台方案当作本 Draft 已批准。

## Behavior Invariants

1. B-001: official `vibeguard add <pack>` 必须从 GH-699 最终交付的 verified released
   install 直接运行，不要求 repository checkout、Python、Rust toolchain、用户 API key
   或未发布脚本。actual launcher 尚未合并并被 no-clone fixture 探测前，只能提供
   `unofficial` 开发入口，不得声称 issue done-when。
2. B-002: 每次 resolve 必须产生带 `source_kind` 判别器的唯一 canonical identity。
   `official_registry` identity 至少绑定 publisher namespace、pack ID、exact semantic
   version、manifest schema version、bundle digest、immutable index entry digest、
   separately signed registry-event evidence digest 与 immutable
   `publication_policy_digest`；
   `local_file` identity 必须绑定 embedded pack ID、exact semantic version、exact bundle
   digest、canonical locator digest、manifest schema version 与 immutable
   `publication_policy_digest`，
   并按 closed schema 将 registry/index/event 字段设为 absent，而不是伪造 entry。该
   source kind 的任一必填字段缺失、为空、越界或互相不一致时，在下载/写入前 nonzero
   退出；floating locator 不得成为 receipt identity。install resolution envelope 另行绑定
   current `evaluation_policy_digest`，不把它写回 immutable artifact identity。
3. B-003: 外部作者必须能在独立仓库中 author、validate、publish 一个自包含 pack，并让
   fresh verified install 添加它；流程不得要求向 VibeGuard 仓库提交 pack 文件、修改
   core manifest 或获得本仓库 write access。
4. B-004: official manifest、index entry、precision evidence、receipt 与 lock state 必须
   使用版本化 closed schemas；未知字段、重复 key/ID、未知 enum、空集合、非法 semver、
   duplicate rule ID 或 schema/runtime range 不兼容必须 fail visible，不做 duck typing。
5. B-005: `pack` 缺失、空 locator、未知 namespace/name/version、空 bundle、zero-rule
   bundle、digest mismatch 或 index 指向不存在对象时，不得创建 store、receipt、
   active pointer 或 host config 修改。
6. B-006: 所有 official product/security choices 必须来自获批、versioned/digested
   policy artifacts，并绑定 H-001–H-010 的选择。发布时的 immutable
   `publication_policy_digest` 与每次 install/audit 使用的 current
   `evaluation_policy_digest` 是不同 role/identity；它们可以在发布当时引用同一 policy
   bytes，但不得用一个字段混同。build/publish 时 publication policy 必须在该操作时间有效
   且匹配其绑定 spec；install/audit 时必须验证它在 signed publication time 曾有效，但其
   后续 expiry 或相对 current spec drift 只是历史 provenance，不能单独要求 republish。
   install/audit/default-block 只要求 current evaluation policy 未过期且匹配 current spec。
   对各自 role 的选择缺失、双选或无效时对应操作 blocked；recommendation 本身不是批准证据。
7. B-007: 输出必须在每一层分别展示 provenance trust
   `{verified, unofficial}` 与 revocation freshness
   `{current, revoked, unknown, not_applicable}`，不得把二者折叠成一个互相排斥的 enum。
   `official_registry` 只能使用前三种并必须绑定 registry-event evidence；`local_file` 必须
   使用 `not_applicable` 且 event evidence 字段 absent，不能伪造 synthetic current/event
   digest。local bundle、author-only precision 不得显示 provenance verified。一个
   identity-matched、签名有效且
   age 仍在获批 revocation freshness window 内的 exact cached registry-event snapshot
   必须保留其签名结论：包含 applicable revoke event 时始终为 `revoked`；只有签名 snapshot
   证明截至其 freshness horizon 没有 applicable revoke 时才是 `current`。缺失、malformed、
   identity mismatch，或证明“未 revoke”的 snapshot 超过该 window 时才是 `unknown`；
   已确认的 revoke 不因 cache age 过期而恢复为 unknown/current。不能因刷新失败就谎报
   新鲜，也不能把仍有效的 cache 错报 unknown，或用 warning 文本隐藏状态。
8. B-008: 在确认以及任何 persistent store、receipt、active、override、host/config 或
   其他用户拥有路径写入前，`explain`/install plan 必须展示 canonical identity、
   source/trust/revocation freshness、requested target/profile、capabilities、规则数、
   每条 effective default decision 及 precision reason、exact files/config entries、
   conflicts、network calls、rollback plan 和 receipt path。为得到该计划而进行的 bounded
   下载和安全解压只能写 transaction-private 临时目录：必须在计划中列出其边界和摘要，
   不得执行内容，不得被 runtime/host读取，拒绝/取消/失败时必须验证清理。旧 unfinished
   transaction 的 recovery 属于 B-017 的前置修复，不得混入或跳过新计划。无数据以空值
   + closed reason 显示，不伪造零值。
9. B-009: bundle 只能使用获批 H-002 capability 闭集；manifest 必须逐项声明 capability、
   asset digest 与对应 rule IDs。未声明、多重映射、未知 capability 或 payload 实际内容
   超出声明时，在执行/安装前拒绝；不能用 free-text command 猜 executor。
10. B-010: archive entry、manifest path 与 symlink/hard-link 必须被限制在本次 staging
    root；拒绝 absolute path、`..` traversal、device/FIFO/socket、case-fold collision、
    duplicate normalized path、超限文件/总大小/压缩比和指向 root 外的 link。验证失败零
    committed write，不能“尽力解压”。
11. B-011: verified trust 必须从 approved publisher namespace 到 immutable index entry、
    exact bundle checksum、attestation subject、manifest/assets digests 形成完整身份链；
    yank/revoke/transfer 属于另一个 separately signed、单独 digested 的 registry-event
    evidence identity，不得嵌入或改写 immutable entry bytes/digest。自报 version、TLS 下载
    成功或 checksum-only 不能单独建立 official 身份。
12. B-012: index/attestation/revocation 读取失败、超时、响应 malformed 或身份不匹配时，
    online official add 必须 fail closed。offline 行为只可按获批 H-001/H-003/H-008 policy
    使用 identity-matched、签名有效且仍在各自有效期内的 exact verified index、bundle 与
    registry-event caches，并必须显示各自 cache age/evidence digest。fresh cached
    non-revocation snapshot 可保持 `current`，cached applicable revoke 始终保持 `revoked`；
    只有缺失/invalid/mismatched 或过期的 non-revocation proof 才变为 `unknown`。不得静默
    跳过 revocation。
13. B-013: target/profile/capability compatibility 必须在 plan 前由一个 versioned contract
    确定。unknown host、known host + incompatible protocol、unsupported capability 与
    missing installed Core 分别给出 closed status，均不得冒充 active；不得用
    cross-host config 或 PATH 邻居 shim 满足 target。compatibility failure 是和
    revocation 同级的不可提升 ceiling，任何 local override 均不得把它变成 block/active。
14. B-014: installed pack 的 runtime 默认不得访问网络、用户凭据、剪贴板、非声明项目
    路径或 VibeGuard 外部日志；任何获批例外都必须是 H-002/H-009 中逐 capability 的显式
    opt-in，并进入 plan/receipt/audit。未声明访问按 policy failure 可见阻断，不能降级 pass。
15. B-015: non-dry-run 生命周期必须按获批 H-004 transaction 顺序执行，并在同一
    transaction ID 下保存 immutable plan、staged digest set、before snapshot、audit
    result 与 commit/rollback status。receipt 与 active identity 只能从 verified staged
    状态经成功 audit 组成一个 immutable committed-state generation；该 generation 必须
    命名 plan 解析出的全部 pack/dependency receipts、ownership 与 active identities，并由
    一个 installation-scope pointer 的一次 durable switch 共同生效，禁止逐 pack pointer
    依次切换。rename 后必须重开/校验并 fsync replacement pointer，再 fsync containing directory；
    两者完成才是 durable commit boundary，runtime 只消费完整、
    digest-valid 的 dependency-set generation，禁止 partial active。pointer 必须携带 monotonic
    installation generation；已 fsync 的 transaction journal 先记录目标 pointer/state，再推进
    独立 durable generation floor，最后执行上述 rename+双 fsync。policy/installation floor 与 trusted-time
    high-water/epoch/sequence 都必须绑定 B-027 定义的同一 authenticated root 下各自独立单调的
    leaf authority；同一
    user-state tree 内的 JSON 只可作 mirror，不能作为 anti-rollback authority。runtime 拒绝低于 floor 的旧 pointer replay；
    floor fsync 是 roll-forward-only prepared boundary：此前失败可 rollback；此后必须保留
    journal/generation/state 并重试或恢复 exact pointer switch，不能 rollback、降低 floor 或猜测
    目标 generation。recovery 必须在原 canonical locks 下重验 exact host/adapter/config-root identity
    与 applied manifest 的每个 file/config entry、reservation/owner、expected-after digest；只有 closed
    set 全等才可 switch。任一 missing/extra/mismatch 都保留现场进入 `needs_repair`，不得重写漂移、
    commit receipt/ownership 或声称 installed。
16. B-016: stage、verify、host apply、audit 或 floor fsync 前的 receipt preparation 失败时，
    系统必须只回滚本 transaction 已记录的 owned changes并恢复精确 before state；floor fsync
    后则禁止 rollback，只能按 B-015 重验后 roll forward。post-floor drift 必须 append+fsync
    repair transition、nonzero 并保留 journal/before/applied evidence；不得用 B-019 的 before/after
    数据覆盖当前用户/host state，也不得生成 committed receipts。rollback/recovery 失败均进入
    `needs_repair`，不得声称 installed。
17. B-017: 取消、中断、超时或进程崩溃后不得留下未提交的新 active pointer。下一次任何
    mutation 必须先按 canonical order 取得 HOME-wide ownership lock 与对应 target locks，
    识别 unfinished transaction，并按 immutable
    journal 完成 rollback/recovery；recovery 必须重算完整 applied-set digest 并逐项 CAS，而非抽样
    或只验证 generation。只有 recovery 完成并重新验证 committed generation
    后才可进行新 transaction 的 discovery、staging、planning 或 confirmation。interactive
    confirmation 必须有获批的 bounded deadline，等待期间不得持有 exclusive mutation
    locks；确认后必须按同一顺序重新取锁，并对 base generation、ownership、authoritative
    policy pointer/floor、plan/evidence/eligibility digests 做 CAS revalidation，drift 时废弃
    确认并重新 plan/confirm。不能用
    partial state 计算计划，也不能把旧 staging 或 partial receipt 当作成功安装。
18. B-018: committed receipt 必须绑定 canonical identity、trust/provenance chain、
    publication/evaluation policy digests、precision/provenance/compatibility evidence
    digests，以及 source-applicable revocation binding：official 必须有 registry-event
    evidence digest，local 必须为 `not_applicable` 且该字段 absent。receipt 还必须绑定
    `decision_valid_until`、source-applicable `override_valid_until`、expiry fallback/reason、
    committed evaluation policy 的 exact digest、authoritative generation、validity-evidence
    digest、source storage key、target/profile/capabilities、所有
    owned files 和 config entries 的 before/after digests、transaction ID、audit evidence
    与 effective decisions。source storage key 必须是 closed discriminated union：
    official 使用 normalized publisher + pack；local 使用完整 canonical local identity 的
    digest，不得要求/伪造 publisher sentinel，也不得把 raw local path 放进持久化路径。
    缺任一必填证据时不得 commit。
19. B-019: update/remove 只能修改 committed receipt 精确拥有且当前 bytes/config state
    仍匹配 receipt `after` digest 的 files/config entries；receipt `before` digest 只作为
    rollback/remove 的恢复目标，不能用来证明当前 ownership 未漂移。fresh install 对当前
    unowned path 必须在 ownership/target locks 下建立
    transaction-scoped provisional ownership reservation，记录 expected-absent/current
    digest、planned after digest 和 transaction ID，并在 apply 前 compare-and-swap；
    reservation 不等于 committed ownership，失败/取消必须随 rollback 清除，只有 B-015
    atomic commit 才转成 receipt ownership。用户或其他 pack 拥有的内容必须 preserved；
    ownership 冲突、drift 或 ambiguous shared entry 在 plan 阶段阻断，不能
    last-writer-wins。
20. B-020: dependencies/conflicts 必须是 exact、acyclic、version-range-valid 的 closed
    graph，并在 plan 中解析为同一 transaction set。missing、cycle、冲突或同一
    publisher namespace + pack name + exact version 对应不同 digest 时零 apply；不同 pack
    name 即使 publisher/version 相同也不得互相冲突；不得递归获取 undeclared dependency。
    全部 dependency receipts、shared ownership refs 与 active identities 必须进入同一
    B-015 generation 并通过一个 installation-scope pointer 原子提交，不得观察到只激活
    graph 子集的中间状态。
21. B-021: retry 必须先取得新的 policy-normalized evaluation time，重新计算所有
    time-dependent freshness/eligibility 与 normalized evaluation identity。只有 canonical
    identity、publication/evaluation policy、target/profile、committed digest set、
    provenance/registry-event/compatibility/precision evidence identities 和 normalized
    evaluation/eligibility digests 全等时，add 才是 idempotent no-op 并返回同一
    receipt identity；跨越 evidence/revocation/policy 时间边界必须 re-audit，不能被 digest
    comparator 跳过。official
    `(publisher namespace, pack name, exact version)` 三元组相同而 bundle/index-entry digest
    不同时必须视为 immutable identity violation，而不是 update；local 只按完整 canonical
    local identity/storage key 比较，不得用 partial version key。no-op comparator 只比较
    source-applicable evidence fields，local 不得为满足 official comparator 伪造 event digest。
22. B-022: update 必须显示 from/to exact identities 与 decision/ownership diff，重新执行
    provenance、capability、compatibility、precision 和 transaction gates；失败保持旧版本
    active。不得原地改写 version store 或复用旧 evidence 冒充新版本。
23. B-023: remove 必须先验证 receipt 与当前 owned digests，只删除该 pack 独占内容，并
    对 shared dependency 做引用计数/remaining-owner 判断。receipt 缺失、损坏或 drift 时
    进入显式 repair flow，不得扫描 HOME 猜哪些文件属于 pack。
24. B-024: 同一 HOME 的 add/update/remove 必须用一个 HOME-wide ownership/registry lock
    协调 shared store、dependency refs 与 ownership reservation，再按规范排序取得所需
    target locks；所有锁均 bounded，超时可见失败，每次 mutation 有唯一 transaction ID。
    不同 target 只有在 preflight/staging 资源不相交时可并行，涉及 shared dependency/
    ownership 的 mutation critical section 必须序列化；不得共享可写 journal/staging/
    output，提交顺序不能改变最终 ownership 或 effective decisions。
25. B-025: precision evidence 必须逐 rule 绑定 exact normalized rule bytes/digest、
    pack identity、detector/capability identity、ground-truth/fixture set、TP/FP/
    acceptable/unclassified counts、reviewer evidence、sample window 与 generated/expires
    timestamps；pack-level平均值不能替代低精度单条规则。
26. B-026: eligibility 计算只能使用获批 H-006 的公式和 classified sample 定义，并把
    policy-normalized `evaluation_time`/clock snapshot 作为显式输入和 eligibility digest
    的组成部分；还必须把 provenance evidence、compatibility contract、precision evidence
    与 current evaluation policy 的 exact binding digests 作为输入和 digest 组成部分，
    并使用 source-kind union：official 必须加入 registry-event evidence digest，local 必须
    加入 `revocation_status=not_applicable` 且 event digest absent。不能只传 collapsed
    status，也不能为 local 构造 synthetic event。不得在纯函数内部隐式读取
    wall clock。unclassified/acceptable 如何进入样本门必须由 policy 显式给出。除零、
    负数、计数不自洽、相对 evaluation time 的未来 timestamp、过期或 reviewer 不独立均
    使 evidence invalid，不能修正后继续。
27. B-027: precision floor、minimum samples、freshness、no-FP window 与 evidence issuer
    必须来自 current approved `evaluation_policy_digest`，而不是 pack author、环境变量、
    README、install command 或 artifact-embedded publication policy 临时覆盖。policy
    更新必须在不改写 bundle/index identity 的前提下重算 eligibility；Core-owned
    authoritative local evaluation-policy pointer 一旦切换，runtime 必须在下一次可能执行 committed/
    promoted block 前比较其 exact `(digest, generation, validity_evidence_digest)` 与 committed
    generation；任一
    identity drift 即使 digest 后来相同，也立即使用 warn/off fallback、durably latch
    `policy_changed + audit_required`；pointer/floor
    缺失、malformed 或 pointer generation 低于 floor 时则是 `runtime_guard_unavailable`；候选 block
    必须拒绝本次操作并非零返回，不能通过 fallback 放行，但 committed warn/off 不得升级为 denial。
    两者都不能等旧 horizon 到期。status
    同时显示 publication、committed evaluation 与 authoritative active evaluation policy
    identities。每次 policy activation 还必须在 Core-owned policy lock 下先写入并 fsync closed
    pending intent，绑定目标 policy digest、validity evidence 及前后 generation，再原子推进并
    fsync durable monotonic `policy_generation_floor`，最后 rename authoritative pointer、重开校验并
    fsync pointer 与 parent directory；只有两次 fsync 成功才可标 journal complete/清理。其间崩溃
    必须从 intent 确定性重放同一 pointer+fsync roll-forward，不能凭新 floor 猜目标 policy。
    runtime 同时验证 pointer generation 不低于该 floor。floor mirror 必须绑定 Core installation、
    user principal、anchor schema、policy leaf identity 及独立单调 `(leaf_counter, leaf_digest)`；fresh
    backend root proof 必须认证该 exact leaf state，但 sibling leaf 推进 shared root 只刷新 proof，
    不得使未变的 policy mirror 失效。旧 user-state snapshot 即使 coherent 也因 leaf authority
    不回退而失配。旧 pointer replay 即使 digest 再次
    匹配 committed generation 也必须按 unavailable 拒绝，floor 缺失/损坏同样 fail closed。
    management commit 必须在最终校验前取得同一 policy lock，并持有到 active-generation
    pointer switch 完成；若使用等价 CAS，必须在 installation floor/external anchor 推进前完成
    final compare-and-fence，并把 policy identity、anchor counter 与 activation fencing token 写入
    journal，activation 在 fence 释放前不得切换。floor 后 recovery 才发现 policy drift 时不能
    rollback：必须 journaled roll forward exact target pointer，同时先锁存
    `policy_changed + audit_required + protection_suspended`；不得执行旧 block 或声称 healthy，fresh
    audit 以新 generation 恢复。
28. B-028: 某 rule 的 evidence 缺失、invalid、样本不足、过期或 precision 低于获批 floor
    时，其 official effective default 必须是 warn，绝不能 block；无数据必须显示空
    precision + closed reason，不能写 `0%` 或沿用旧证据。用户显式关闭属于 B-030 的
    local override，不能改写该 official default。任何 committed block 必须带 finite、
    本地可检查的 `decision_valid_until` 与预先计算的 warn/off expiry fallback；runtime
    每次 enforcement 都检查该 horizon，并通过 Core-owned、per-installation durable trusted
    time high-water 检测回退。该 anchor path 只适用于 committed record 带 official/local block
    basis 且 pre-runtime decision 为 block 的候选；即使本次随后因 expiry/rollback 选择 fallback，
    仍须推进 high-water 并锁存 reason，防止旧 block 复活。committed decision 本就是
    warn/off（包括 no-data/below-floor）的规则不访问 anchor，anchor failure 也不得把它升级为 denial。
    候选 block 遇到任意
    `runtime_time < last_trusted_runtime_time`，即使仍位于
    evaluation/expiry interval 内，也必须立即忽略旧 block、使用 fallback 并显示
    `clock_rollback + audit_required`。high-water state 必须按 active generation 隔离并由同一
    installation-scope pointer 选择；runtime 必须按 canonical order 取得 policy lock 与
    installation runtime-state lock，在锁内读取并直到 decision 执行后持续重验 policy
    pointer/floor、active pointer/state，
    同时验证 pointer 的 monotonic installation generation 不低于独立 floor，禁止使用取锁前
    缓存或被 replay 的旧 generation。每个可信 `runtime_time >= high_water` 观测必须先 CAS
    推进 high-water 再选择 block/fallback；expiry、policy drift 或其他 semantic fallback 还须
    在同一 state 不可逆锁存 `audit_required` reason，runtime 不得自行清除。新 state 在 pointer
    switch 前不可影响旧 generation。
    management commit 必须在读取旧 high-water/sequence 前取得 installation runtime-state lock，
    并持锁直到新 state fsync 与 active pointer switch 完成，禁止 runtime 在交接窗口推进旧 state。
    high-water 缺失、损坏、身份不匹配或 bounded retry 后仍无法锁定/原子推进时必须拒绝本次
    操作并非零返回，不能降为 warn/off 后放行，也不能因进程重启静默降低 high-water。
    high-water/`clock_epoch`/sequence 每次推进都须以独立单调 time leaf CAS 为 authority，本地
    runtime-state 只是 authenticated mirror；shared root 上 sibling leaf 的合法推进只刷新 inclusion
    proof。候选 block 遇到 backend 缺失、proof 不可验证或 restore 后 leaf counter/digest 不等必须
    `runtime_guard_unavailable`，不得执行旧 block；既有 warn/off 仍保持其 precision semantics。
    rollback 后普通 fresh audit 不能降低同一 clock epoch 的 high-water；恢复必须走显式
    trusted-clock reconciliation，在 locks 下验证 Core-approved time evidence、重新 audit，
    递增 `clock_epoch` 并把 reconciliation evidence 与新 generation/runtime state 通过同一
    atomic pointer commit。失败时旧 active/state 保持不变且 protection 不恢复。
29. B-029: evidence 达标只授予 `block_eligible`，不会自动 block。只有 manifest 明确请求
    block、capability/host 支持、trust verified 且所有 policy gates 同时满足时才可成为
    official default block；任一前提失败时重新降为 warn/off，并列出全部 reason。
    unsupported capability、incompatible/unknown host 或 missing Core 是 terminal
    compatibility ceilings，不能作为仅 evidence 不足来处理。
30. B-030: 用户 override 必须逐 rule、可审计且和 official eligibility 分离。降级
    eligible block 可以直接生效；把 ineligible rule 升为 local block 只有在获批 H-007
    允许并经显式风险确认时生效，receipt/status 必须标 `local_override`，不能回写
    registry/precision evidence 或改变其他用户的 default。local promotion 只可针对
    evidence-only ineligibility，且 trust、revocation、compatibility 与 policy 均允许；
    `revocation_status = revoked`、unknown/incompatible host、unsupported capability 与
    missing Core 都是不可提升的终态 ceiling。evidence-only promotion 必须由 current
    evaluation policy 给出有限 `max_override_ttl`，并绑定独立的 confirmation issued/expires
    evidence；只有 `confirmed_at <= evaluation_time < confirmation_expires_at` 才可接受，
    future-dated、倒序或已过期 confirmation 必须拒绝。`override_valid_until` 取
    `confirmed_at + max_override_ttl`、confirmation expiry、policy expiry 及所有仍适用的
    provenance/revocation/compatibility horizons 的最早值，不得要求缺失/过期 precision
    evidence 提供未来 horizon，也不得用 synthetic/unbounded 值补齐。缺少任一 required
    override horizon、到期或 policy identity drift 时必须 suspended/rejected，并降为
    warn/off；恢复 block 需要新的显式确认和 fresh audit。
31. B-031: core-curated packs 与 community packs 使用同一 per-rule precision eligibility
    计算和 no-data降级语义；curated badge、仓库内置或 high severity 都不能绕过 floor。
    两者的 publisher/trust来源可以不同，但差异必须由 H-003/H-008 policy 明示。
32. B-032: precision evidence digest、current evaluation policy exact digest/generation/validity
    identity、rule bytes、
    capability mapping、provenance evidence digest、official registry-event evidence digest、
    compatibility contract digest、source-applicable revocation binding 或 normalized
    evaluation time 任一变化（包括 collapsed status 未变，或仅跨越 freshness/expiry/
    revocation window）都必须生成新 eligibility
    identity/digest 并触发 re-audit；publication policy 与 immutable artifact identity
    保持不变，旧 evidence 不得绑定新 bytes，same-content retry 也不得跳过。若 active block
    不再 eligible，下一次 audit 必须 fail visible 并按获批 evaluation policy 降级，而不是
    继续静默 block。即使没有 add/update/audit，runtime 发现 authoritative local policy
    digest/generation/validity identity mismatch、到达 `decision_valid_until`/
    `override_valid_until`，或发现 trusted-time
    high-water rollback/drift，也必须先施加本地 fallback ceiling 并标记 `audit_required`；
    只有 fresh management audit（clock rollback 另需 B-028 trusted-clock reconciliation；
    promotion 另需 fresh explicit confirmation）才可恢复 block。
33. B-033: 默认不得自动上传 event logs、源代码、用户路径、HOME、fixture payload、
    secrets 或 local triage。任何 feedback export 必须显式触发、先显示字段清单并脱敏，
    生成本地 artifact；发送/发布是另一个需确认动作，取消后零网络。
34. B-034: official registry 中 publisher namespace + pack name 唯一；已发布 exact
    version/index-entry bytes/digest append-only、不可覆盖或删除。yank/revoke/namespace
    transfer 必须产生 separately signed、append-only、单独 digested 的 registry events，
    event identity 进入 resolution/receipt/audit，但不得改变旧 entry identity；旧 receipt
    仍能解释当时信任状态，不能改写历史。
35. B-035: yank 阻止新 resolve/install，但不把已安装 pack 伪装为不存在；security revoke
    必须在 online audit/update 明确显示，并按获批 H-008 action 阻止新激活或降级现有
    decisions。每个 action 必须引用 exact registry-event evidence digest 与其签名链；
    无法写入降级时进入 `needs_repair`，不得只 warning 后保持 revoked block。
36. B-036: 现有 v1 `safe-bash` 只能通过显式 migration reader 规范化为 legacy
    adoption-layer view；其 registration-only receipt 不得被升级器解释为已拥有 Core
    files。迁移必须先生成 plan/ownership baseline，失败保持原状态且可继续 explain/remove。
37. B-037: GH-699 是 official command/distribution 依赖：payload/bootstrap/actual launcher
    必须真实包含并调用 pack client，no-clone native smoke 通过后才能满足 B-001。
    checkout-only `setup.sh packs` 或 spec 中猜的 shim 不能替代 released evidence。
38. B-038: 只有 GH-701 decisions 获批、versioned registry implementation 合入 main 且
    compatibility/native-proof gates 通过，GH-702 才必须消费其 host/capability identity；
    merged Draft spec 本身不开放该路径。此前或 v1 选择固定 Claude/Codex scope 时，第三
    host 必须显示 unsupported，不能在 pack schema 内复制另一套 host registry。两份合同
    冲突时停止实施并回到 spec review。
39. B-039: GH-700 不是 pack publish/install 的 hard dependency，且 public benchmark、
    aggregate CI precision 与本 spec per-rule eligibility 必须使用不同 type/schema/name；
    renderer 不得把其中一个数值冒充另一个 gate 的 evidence。
40. B-040: author publish 流程必须在上传前本地完成 schema、path/capability、
    compatibility、fixture、precision-evidence 和 reproducible-bundle validation；相同
    source + publication policy 重建必须得到相同 canonical bundle digest。validation 失败不得留下
    official index entry 或半发布 version。
41. B-041: `list`/`status`/`audit` 必须为每个 installed pack 展示 exact version/digest、
    trust、target、transaction/receipt health、revocation/cache age、每条 effective decision
    与 precision reason、`decision_valid_until`/expiry state/`audit_required`，以及
    publication policy identity、committed 与 authoritative evaluation policy 各自的 exact
    digest/generation/validity-evidence identity、policy generation floor、active installation
    generation/floor、runtime-state sequence/latch、monotonic anchor backend/root/leaf/counter、source-applicable `override_valid_until`、
    trusted-time high-water 与 `clock_epoch`，并以
    nonzero 区分 `{invalid, incompatible, revoked, needs_repair, protection_suspended,
    runtime_guard_unavailable}`；任何 `audit_required` 或 active protection 降级/暂停也必须
    nonzero，不能让 automation 把失去保护误判为 healthy；
    空 pack 列表是成功且显示为空，不是错误或伪造内置 pack。
42. B-042: registry/network 暂时不可用时，已安装、receipt-valid pack 的 runtime enforcement
    不得读取网络或删除用户状态；audit 必须诚实保留 provenance trust 并单独显示
    revocation status、cache source/age 与 offline evidence。local source 固定显示
    `not_applicable` 且没有 registry-event field。official identity-matched、签名有效且
    exact cached registry-event evidence 的签名结论：fresh non-revocation proof 保持
    `current`，applicable revoke event 无论 cache age 都保持 `revoked` 并执行 ceiling；
    cache 缺失、malformed、identity mismatch 或 non-revocation proof 超过 window 时才是
    `unknown` 并按 policy 降级。runtime 不联网但必须检查 committed validity horizon：
    horizon 到期、authoritative policy digest/generation/validity identity mismatch 或
    trusted-time high-water rollback
    即使用 warn/off fallback 并标记 `audit_required`。不能把 availability failure 当成新的
    current 证据，也不能把仍有效 cache 错报 unknown，或让已知 revoke 因过期恢复。

## 验收标准

- [ ] 外部作者在独立仓库生成可复现 bundle，通过本地 validator，并发布 immutable
      namespaced version；不修改 VibeGuard 仓库。
- [ ] fresh verified release install 用一条 `vibeguard add <pack>` 完成 resolve、plan、
      verify、transactional install 和 audit；无需 checkout/Python/Rust/API key。
- [ ] tampered/untrusted/revoked/unsafe archive、unknown capability/host/schema、ownership
      conflict、取消和并发负例均零 partial active state，且错误证据可复核。
- [ ] 每条 rule 的 default decision 由 exact precision/policy evidence 计算；低于 floor、
      无数据、样本不足或过期时只能 warn/off，不能 block。
- [ ] update/remove/rollback 只触碰 receipt-owned 内容，用户及其他 pack config canary
      前后 byte-identical。
- [ ] legacy `safe-bash` registration 可解释、可迁移或可卸载，不被冒充为第三方 full
      install。
- [ ] 默认无 telemetry；feedback export 与发送是分离、显式确认的动作。
- [ ] H-001–H-010 均有 maintainer 选择与 security review evidence，未选择时 official
      publish/install/default-block gate 明确阻断。

## 边界情况清单

| 类别 | 判定（covered: B-xxx / N/A + 原因） |
| --- | --- |
| 空/缺失输入 | covered: B-002, B-004, B-005, B-006, B-025, B-028, B-041 |
| 错误与失败路径 | covered: B-005, B-010, B-012, B-013, B-016, B-020, B-026, B-035, B-040, B-042 |
| 授权/权限 | covered: B-006, B-007, B-009, B-011, B-014, B-019, B-030, B-031, B-033, B-034 |
| 并发/竞态 | covered: B-015, B-017, B-019, B-021, B-022, B-024, B-032, B-040 |
| 重试/幂等 | covered: B-017, B-021, B-022, B-023, B-024, B-034 |
| 非法状态转换 | covered: B-006, B-007, B-015, B-016, B-018, B-029, B-035, B-041 |
| 兼容/迁移 | covered: B-004, B-006, B-013, B-036, B-037, B-038, B-039 |
| 降级/回退 | covered: B-007, B-012, B-016, B-017, B-028, B-029, B-030, B-032, B-035, B-042 |
| 证据与审计完整性 | covered: B-002, B-006–B-008, B-011, B-015, B-018, B-025–B-035, B-040–B-042 |
| 取消/中断 | covered: B-016, B-017, B-024, B-033, B-040 |

## 发布说明

首次交付必须标为 pack contract v2 或其它获批的新 major identity，不得原地扩大 v1
manifest 的语义。文档必须把 legacy Core adoption pack、verified third-party pack、
unofficial local pack 与 revoked pack 分开说明，并记录 H-001–H-010 的最终选择。

公开 `vibeguard add` 前必须同时具备：GH-699 actual released launcher/no-clone evidence、
获批 supplier/security policy、至少一个不在 VibeGuard 仓库内 author 的 end-to-end pack
   fixture，以及真实 update/remove/revocation演练。GH-701 仅有 merged Draft spec、尚未
   取得 decisions + registry implementation + compatibility/native-proof evidence 时，只能
   承诺获批的固定 host scope；GH-700 未完成不阻断 pack 功能，但不得发布混淆的
   precision/benchmark claim。
