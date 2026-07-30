# Product Spec — 可发布的第三方 Guard Pack 合同与精度门

## Linked Issue

GH-702

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
   GH-701 的 versioned host registry 先获批并合并，则以其 host/capability IDs 为唯一
   source。第三 host 不能由 GH-702 自造第二套 registry。
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

## Behavior Invariants

1. B-001: official `vibeguard add <pack>` 必须从 GH-699 最终交付的 verified released
   install 直接运行，不要求 repository checkout、Python、Rust toolchain、用户 API key
   或未发布脚本。actual launcher 尚未合并并被 no-clone fixture 探测前，只能提供
   `unofficial` 开发入口，不得声称 issue done-when。
2. B-002: 每次 resolve 必须产生带 `source_kind` 判别器的唯一 canonical identity。
   `official_registry` identity 至少绑定 publisher namespace、pack ID、exact semantic
   version、manifest schema version、bundle digest、immutable index entry digest、
   separately signed registry-event evidence digest 与 approved policy digest；
   `local_file` identity 必须绑定 embedded pack ID、exact semantic version、exact bundle
   digest、canonical locator digest、manifest schema version 与 approved policy digest，
   并按 closed schema 将 registry/index/event 字段设为 absent，而不是伪造 entry。该
   source kind 的任一必填字段缺失、为空、越界或互相不一致时，在下载/写入前 nonzero
   退出；floating locator 不得成为 receipt identity。
3. B-003: 外部作者必须能在独立仓库中 author、validate、publish 一个自包含 pack，并让
   fresh verified install 添加它；流程不得要求向 VibeGuard 仓库提交 pack 文件、修改
   core manifest 或获得本仓库 write access。
4. B-004: official manifest、index entry、precision evidence、receipt 与 lock state 必须
   使用版本化 closed schemas；未知字段、重复 key/ID、未知 enum、空集合、非法 semver、
   duplicate rule ID 或 schema/runtime range 不兼容必须 fail visible，不做 duck typing。
5. B-005: `pack` 缺失、空 locator、未知 namespace/name/version、空 bundle、zero-rule
   bundle、digest mismatch 或 index 指向不存在对象时，不得创建 store、receipt、
   active pointer 或 host config 修改。
6. B-006: 所有 official product/security choices 必须来自一个获批、versioned/digested
   policy artifact，并绑定 H-001–H-009 的选择。选择缺失、双选、过期或与当前 spec bytes
   不匹配时，publish、official install 与 default-block eligibility 均为 blocked；
   recommendation 本身不是批准证据。
7. B-007: 输出必须在每一层分别展示 provenance trust
   `{verified, unofficial}` 与 revocation freshness
   `{current, revoked, unknown}`，不得把二者折叠成一个互相排斥的 enum。local bundle、
   author-only precision 不得显示 provenance verified。一个 identity-matched、签名有效且
   age 仍在获批 revocation freshness window 内的 exact cached registry-event snapshot
   可以显示 `revocation_status = current`，同时必须显示 cache source/age；缺失、malformed、
   identity mismatch 或超过该 window 才必须显示 `unknown`。不能因刷新失败就谎报新鲜，
   也不能把仍有效的 cache 错报 unknown，或用 warning 文本隐藏状态。
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
    registry-event caches，并必须显示各自 cache age/evidence digest；仍在 revocation
    freshness window 内的 event cache 保持 `current`，超过该 window 才变为 `unknown`。
    不得静默跳过 revocation。
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
    一个 installation-scope pointer 的一次原子 switch 共同生效，禁止逐 pack pointer
    依次切换。该 switch 本身就是 durable commit boundary，runtime 只消费完整、
    digest-valid 的 dependency-set generation，禁止 partial active。
16. B-016: stage、verify、host apply、audit 或 receipt commit 任一步失败时，系统必须只
    回滚本 transaction 已记录的 owned changes并恢复精确 before state；rollback 自身失败
    必须 nonzero、保留 recovery evidence 并进入 `needs_repair`，不得声称 installed。
17. B-017: 取消、中断、超时或进程崩溃后不得留下未提交的新 active pointer。下一次任何
    mutation 必须先按 canonical order 取得 HOME-wide ownership lock 与对应 target locks，
    识别 unfinished transaction，并按 immutable
    journal 完成 rollback/recovery；只有 recovery 完成并重新验证 committed generation
    后才可进行新 transaction 的 discovery、staging、planning 或 confirmation。interactive
    confirmation 必须有获批的 bounded deadline，等待期间不得持有 exclusive mutation
    locks；确认后必须按同一顺序重新取锁，并对 base generation、ownership、plan/evidence/
    eligibility digests 做 CAS revalidation，drift 时废弃确认并重新 plan/confirm。不能用
    partial state 计算计划，也不能把旧 staging 或 partial receipt 当作成功安装。
18. B-018: committed receipt 必须绑定 canonical identity、trust/provenance chain、
    policy/precision evidence digests、target/profile/capabilities、所有 owned files 和
    config entries 的 before/after digests、transaction ID、audit evidence 与 effective
    decisions。缺任一必填证据时不得 commit。
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
    namespace/version 对应不同 digest 时零 apply；不得递归获取 undeclared dependency。
    全部 dependency receipts、shared ownership refs 与 active identities 必须进入同一
    B-015 generation 并通过一个 installation-scope pointer 原子提交，不得观察到只激活
    graph 子集的中间状态。
21. B-021: retry 必须先取得新的 policy-normalized evaluation time，重新计算所有
    time-dependent freshness/eligibility 与 normalized evaluation identity。只有 canonical
    identity、policy、target/profile、committed digest set、registry-event evidence 和
    normalized evaluation/eligibility digests 全等时，add 才是 idempotent no-op 并返回同一
    receipt identity；跨越 evidence/revocation/policy 时间边界必须 re-audit，不能被 digest
    comparator 跳过。相同 version 不同 bundle/index-entry digest 必须视为 immutable
    identity violation，而不是 update。
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
    的组成部分；不得在纯函数内部隐式读取 wall clock。unclassified/acceptable 如何进入
    样本门必须由 policy 显式给出。除零、负数、计数不自洽、相对 evaluation time 的未来
    timestamp、过期或 reviewer 不独立均使 evidence invalid，不能修正后继续。
27. B-027: precision floor、minimum samples、freshness、no-FP window 与 evidence issuer
    必须来自 approved policy digest，而不是 pack author、环境变量、README 或 install
    command 临时覆盖。不同 policy 下的 eligibility 必须可重算并显示 policy identity。
28. B-028: 某 rule 的 evidence 缺失、invalid、样本不足、过期或 precision 低于获批 floor
    时，其 official effective default 必须是 warn，绝不能 block；无数据必须显示空
    precision + closed reason，不能写 `0%` 或沿用旧证据。用户显式关闭属于 B-030 的
    local override，不能改写该 official default。
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
    missing Core 都是不可提升的终态 ceiling。任何越过 ceiling 的既有 block override
    必须 suspended/rejected，effective decision 只能按获批 policy 降为 warn/off。
31. B-031: core-curated packs 与 community packs 使用同一 per-rule precision eligibility
    计算和 no-data降级语义；curated badge、仓库内置或 high severity 都不能绕过 floor。
    两者的 publisher/trust来源可以不同，但差异必须由 H-003/H-008 policy 明示。
32. B-032: precision evidence、policy、rule bytes、capability mapping、publisher trust、
    registry-event evidence、compatibility 或 normalized evaluation time 任一变化（包括
    仅跨越 freshness/expiry/revocation window）都必须生成新 eligibility identity/digest
    并触发 re-audit；旧 evidence 不得绑定新 bytes，same-content retry 也不得跳过时间边界。
    若 active block 不再 eligible，下一次 audit 必须 fail visible 并按获批 policy 降级，
    而不是继续静默 block。
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
38. B-038: GH-701 若先批准 versioned host registry，GH-702 必须消费其 host/capability
    identity；若 v1 选择固定 Claude/Codex scope，则第三 host 必须显示 unsupported，不能
    在 pack schema 内复制另一套 host registry。两份合同冲突时停止实施并回到 spec review。
39. B-039: GH-700 不是 pack publish/install 的 hard dependency，且 public benchmark、
    aggregate CI precision 与本 spec per-rule eligibility 必须使用不同 type/schema/name；
    renderer 不得把其中一个数值冒充另一个 gate 的 evidence。
40. B-040: author publish 流程必须在上传前本地完成 schema、path/capability、
    compatibility、fixture、precision-evidence 和 reproducible-bundle validation；相同
    source + policy 重建必须得到相同 canonical bundle digest。validation 失败不得留下
    official index entry 或半发布 version。
41. B-041: `list`/`status`/`audit` 必须为每个 installed pack 展示 exact version/digest、
    trust、target、transaction/receipt health、revocation/cache age、每条 effective decision
    与 precision reason，并以 nonzero 区分 `{invalid, incompatible, revoked, needs_repair}`；
    空 pack 列表是成功且显示为空，不是错误或伪造内置 pack。
42. B-042: registry/network 暂时不可用时，已安装、receipt-valid pack 的 runtime enforcement
    不得读取网络或删除用户状态；audit 必须诚实保留 provenance trust 并单独显示
    revocation status、cache source/age 与 offline evidence。identity-matched、签名有效且
    仍在获批 revocation freshness window 内的 exact cached registry-event evidence 保持
    `revocation_status = current`，可按 policy 继续原 effective decision；cache 缺失、
    malformed、identity mismatch 或超过 window 时才是 `unknown` 并按 policy 降级。不能
    把 availability failure 当成新的 current 证据，也不能把仍有效 cache 错报 unknown。

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
- [ ] H-001–H-009 均有 maintainer 选择与 security review evidence，未选择时 official
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
unofficial local pack 与 revoked pack 分开说明，并记录 H-001–H-009 的最终选择。

公开 `vibeguard add` 前必须同时具备：GH-699 actual released launcher/no-clone evidence、
获批 supplier/security policy、至少一个不在 VibeGuard 仓库内 author 的 end-to-end pack
fixture，以及真实 update/remove/revocation演练。GH-701 未合并时只能承诺获批的固定 host
scope；GH-700 未完成不阻断 pack 功能，但不得发布混淆的 precision/benchmark claim。
