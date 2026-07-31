# Product Spec — 公开可复现的 VibeGuard 效果基准

## Linked Issue

GH-700

complexity: large

## 用户问题

VibeGuard 目前有三类内部证据，但外部用户无法从已发布安装独立复现一组完整、
诚实且版本绑定的效果数字：

- 确定性 behavior eval 会运行真实 hook，但要求仓库 checkout 和 Python harness；
- GH-686 的 with/without 配对评测能约束 prompt 规则副作用，但需要模型调用，
  也不是 released-binary 用户入口；
- 现有 benchmark/latency CI 面向维护者，不能证明 README 中某一组 headline
  数字来自哪一个 release、哪一份 corpus 和哪一条生产检测路径。

因此，“VibeGuard 能拦住什么、误拦多少、代价多大”仍然只能依赖项目方陈述。
GH-700 的目标命令是 `vibeguard bench`：用户从 GH-699 规划的已校验 release 安装
出发，不 clone 仓库、不安装 Rust、不依赖未发布源码，即可重放与该 release 绑定的
官方 corpus，并得到 interception rate、false-positive rate 与 hook latency。

当前事实（2026-07-27）是：GH-699 的 spec/tasks 已合并且 issue 仍 open；payload
`SP699-T1/T2` 的实现 PR #711 已于 2026-07-26T22:02:07Z 合并到 main
`6bf4ddc3f43744581eac9666712ee80964611740`。`SP699-T3` bootstrap、`SP699-T4`
no-clone native release smoke 与 `SP699-T5/T6` brew/npm launchers 仍 pending，
`vibeguard` 因此还不是当前 main 上可核实的真实 launcher。GH-700 可以消费已合并的
payload contract，但在实际 launcher 与 no-clone smoke 合并并被探测前，不能声称 B-001
的官方入口已经存在。

## 目标

- 提供一条 released-install 用户可直接执行的官方 benchmark 命令。
- 官方 corpus 至少覆盖 invented APIs、duplicate modules、swallowed exceptions、
  dangerous shell/git operations 与 unverified “done” claims，并为每类提供清洁
  对照。
- 每一组数字都绑定 release、corpus、production surface 与执行环境证据；缺证据时
  明确输出 `unavailable` 或 `inconclusive`。
- README 的公开表格由每个 release 的机器可读报告生成，并链接回不可变报告。
- 效果判定可确定性重放；延迟作为独立、带环境语境的测量轴报告。

## 非目标

- 不替代 GH-686 的 prompt-rule with/without 副作用门。
- 不把模型评测结果混入 deterministic hook/guard benchmark。
- 不为 benchmark 新造只在测试中存在的 detector，也不把 fixture 期望值当作实际
  detector 输出。
- 不在本 issue 改变现有 hook latency SLA 或规则的 block/warn policy。
- v1 不支持用户自定义 corpus 作为“官方”结果；实验性输入不得进入 README headline。
- 不把一次本地机器的延迟数字宣传为跨平台性能保证。

## 待维护者确认的产品决策与 Recommended proposals

以下决定不能从 issue、roadmap 或当前实现推导。每项都给出 **Recommended proposal
（未批准）**，只供维护者选择；写入 proposal 不等于批准。在 spec approval 时必须逐项
确认或改写，否则对应 headline 保持 `unavailable`，不得由实现者默认：

1. **H-001 — Interception 口径**：headline 只统计 `block/deny`，还是统计
   `block/deny + warn/review`。无论选择哪一种，报告都必须同时公开 block rate 与
   advisory rate，不能只展示合并后的最好数字。**Recommended proposal（未批准）：
   headline 只统计 normalized `block`；`advisory` 单列，绝不进入 interception/FP
   numerator。**
2. **H-002 — 两个类别的生产语义**：
   - “invented APIs”是指当前 hook 可证明的不存在路径/不存在编辑目标，还是依赖/API
     inventory 验证；后者目前没有已核实的 released deterministic production surface。
   - “swallowed exceptions”当前锚点是 Python guard 的 pytest-shaped checker；需确认
     v1 是把该 canonical guard 变成 release-install 可执行面，还是把该类标为
     `unavailable`。禁止复制一个 benchmark-only 检测器来满足表格。
   **Recommended proposal（未批准）：invented API 只接受真正的 dependency/API
   inventory production detector，不能用“不存在文件”改名顶替；swallowed exception
   将现有 AST 逻辑抽成无 pytest 依赖、production 与测试共用的 released guard。两条
   production mapping 未合并前，五类完整性门保持 unavailable。**
3. **H-003 — 公开平台集合**：获批 protocol 的 `required_platforms` 指定哪些 release targets
   参与 release summary gate；非 required targets 只展示，不影响 gate。不同 OS/架构的
   延迟不得静默平均。**Recommended proposal（未批准）：v1 的 required set 先取
   `aarch64-apple-darwin` 与 `x86_64-unknown-linux-musl`；另外两个 targets 可显示
   unavailable，但不阻断。若选择四 target required set，则四个平台都必须有 native
   runner，cross-compiled smoke 不能替代。**
4. **H-004 — Release policy**：闭集取值为 `{block_release, publish_nonvalid}`。前者不创建
   GitHub Release 或 README current row，并按 B-029 永久保存失败 manifest；后者发布
   带 non-valid report 的 release 与同版本 non-valid README row。两种方案都不得沿用
   上一版本数字冒充当前 release。**Recommended proposal（未批准）：选择
   `block_release`。**
5. **H-005 — Corpus 强度**：审核独立性与 dangerous mapping 的 security review 是 B-026
   规定的不可协商 integrity floor，不属于产品选择；这里只选择每类最少正/负样本数。
   **Recommended proposal（未批准）：每类至少 5 个 positive + 5 个 matched
   negative。**
6. **H-006 — Publication owner liveness**：唯一批准者是 repository release/security
   maintainer，并以 GH700 spec approval 固化；actor、store 与 workflow 不得批准或覆盖。
   **Recommended proposal（未批准）：`ttl_seconds=3600`、`heartbeat_period_seconds=900`、
   `min_renewal_interval_seconds=300`、`max_generation_age_seconds=604800`；store 只在前次
   expiry 前且距上次 accepted heartbeat 至少 300 秒时续租，且
   `lease_expires_at=min(accepted_at+3600, claim_accepted_at+604800)`，不严格延长 expiry
   的 heartbeat 拒绝；到 7 日上限后禁止续租，待 expiry 后才可 takeover。获批值、批准者
   roster 与 approval digest 全部进入 `liveness_policy_digest`；缺失或未批准则 publication
   preflight 为 `unavailable`。**

## Behavior Invariants

1. B-001: `vibeguard bench` 的官方模式必须能从 GH-699 计划并最终合并的、校验成功的
   released install 一条命令运行；不得要求 repository checkout、Rust toolchain、
   未发布脚本或用户 API key。在 GH-699 的 actual launcher 尚未合并并被 integration
   fixture 探测前，GH-700 只能暴露 runtime 开发入口且必须标为 `unofficial`。GH-700
   必须为 release manifest 声明的每个支持分发入口（包括 Homebrew 与 npm）实现并验证
   `bench` subcommand 的 argv/stdin/stdout/stderr/exit-code 透明转发；不得进入 bootstrap、
   setup 或 `init` 流程。源码构建、dirty checkout 或自定义二进制同样不得成为
   README/release headline 证据。
2. B-002: 每次官方运行必须在执行首个 case 前固定并输出至少以下 provenance：
   runtime version、release tag、target triple、build source commit、corpus schema
   version、corpus ID/version/digest、approved protocol version/digest 及其
   `required_platforms`、protocol-owned canonical benchmark config identity、per-surface
   latency workload schedule identity、environment-baseline workload/schedule/estimator/
   threshold identity、每个 executor 的 timeout/termination-grace/stdout-cap/stderr-cap、
   每个 interpreter 及 production path 传递闭包内其它 external executable 的
   protocol-bound identity、release payload manifest digest，以及本次实际使用的
   production surfaces 摘要。
   official 模式忽略用户可变 config/tuning/PATH 与 executor limit overrides；任一必填值
   缺失、为空、越界或互相不匹配时，结果为 `unavailable` 且零 case 执行；不得用
   `unknown` 或实现默认值生成 headline。
3. B-003: 官方 corpus 必须包含五个闭集 failure classes
   `{invented_api, duplicate_module, swallowed_exception,
   dangerous_shell_or_git, unverified_done_claim}`。每类必须同时有至少一条 positive
   case 与一条不应触发的 matched clean control；任一类、任一侧为空时，整体结果为
   `unavailable`，不能从分母中删除该类后继续发布。
4. B-004: 每条 corpus case 必须有稳定且唯一的 case ID；独立 ground-truth artifact
   记录 `{positive, negative}`、failure class 与审核证据，独立 production-mapping
   artifact 记录 production surface、允许的原始 decision 闭集和 normalization。fixture、
   ground truth、mapping 不得互相从 detector 输出反推；重复 ID、未知
   class/surface/decision、正负标签冲突或未审核条目使 corpus 无效。修改任一 artifact
   必须按 B-026/B-027 版本化，不得原地改写旧 release 的语义。
5. B-005: 每条 case 必须走 release 用户真实使用的 canonical hook/guard 生产入口。
   mock、stub、hard-coded case ID 分支、fixture 专用 detector 或仅测试时启用的实现都
   不算 interception 证据。某 failure class 尚无 released production surface 时，该类
   与整体 headline 必须 `unavailable`；不得以“测试通过”代替产品能力。
6. B-006: 成功完成 production adapter 解析的 case，其 normalized decision 必须来自
   闭集 `{block, advisory, allow}`，并保留 versioned mapping 允许的原始 production
   decision 与 rule/reason 标识。mapping 可以声明一个闭集
   `no_interception_success` raw variant：仅当 production 入口成功退出、明确没有 decision
   payload 且没有 raw reason 时，映射为 `allow` + canonical `no_interception`；这不是
   缺失字段 fallback。除该显式 variant 外，缺失 decision/reason 仍是
   `execution_error`。`execution_error`/timeout 是独立 case status，不是
   production decision，也永远不在 headline subset 中。报告必须声明
   `interception_decisions` 是 decision 闭集的哪个非空子集；该口径由 H-001
   批准。缺失或改变口径的报告之间不得直接比较。
7. B-007: 指标必须使用完整 ground truth 分母：
   `interception_rate = 被选定 interception_decisions 命中的 positive / positive_total`；
   `false_positive_rate = 被选定 interception_decisions 命中的 negative /
   negative_total`。同时公开 TP、FN、FP、TN、`positive_error`、`negative_error`、
   block count、advisory count 与每个 failure class 的分项；仅有 production decision 的
   case 才进入 TP/FN/FP/TN，且必须满足
   `positive_total = TP + FN + positive_error`、
   `negative_total = FP + TN + negative_error`。`execution_error`、timeout 或 skipped
   case 进入对应 error bucket，保留在总分母但不伪造成 production decision；任一 error
   bucket 非零时 effectiveness 为 `inconclusive`，diagnostic rate 不得成为 headline。
   零分母、整数关系不自洽、百分比非有限值或不在 0–100 时同样 `inconclusive`。
8. B-008: effectiveness 与 latency 两个 axis 各自使用同一个状态闭集并 fail closed：
   - `unavailable`：执行前缺 release/corpus/payload/权限/生产入口等前提；
   - `inconclusive`：执行已开始，但出现 case error、timeout、环境失真、结果不确定或
     证据不完整；
   - `valid`：全部 mandatory cases 完成、provenance 完整、分母有效且确定性复核一致。
   top-level 状态按 B-023 唯一聚合。人类输出、JSON、README 与 release evidence 必须
   使用同一状态；`unavailable`/`inconclusive` 不得显示为 `0%`、`pass` 或沿用历史数字。
9. B-009: 效果轴必须可确定性复核。同一 verified release、official corpus、
   interception 口径与显式运行参数的确认重跑，忽略 latency、timestamp、临时路径等
   非语义字段后，每个 case 的 decision/canonical reason code、case 顺序、计数和比例
   必须完全一致。每个 case 在 A、B 两次 run 中都必须从 protocol 声明的同一
   versioned/digested initial-state fixture 建立独立 state/session/project/log root；不得让
   同一 run 的前一 case history、circuit breaker、session 或 event log 影响后一 case。
   任一差异使效果轴 `inconclusive`，并列出不一致 case；不得择优选一次结果。
10. B-010: benchmark 必须幂等且并发隔离。重复或并发运行不得修改用户项目、已安装
    payload、global/project event logs、hook 配置或前一次报告；每次运行使用独立临时
    工作区和输出目标。输出路径冲突、残留状态被下一次复用或执行顺序改变 ground truth
    时，结果必须失败可见。
11. B-011: latency 是与效果轴分离的 `bench_case_e2e_ms` 面：从 spawn 实际 installed
    wrapper 子进程前到该子进程完整 decision/stdout/stderr/exit 返回后，使用单调时钟
    测量，并包含 release 用户真实承担的 shell wrapper、runtime process、stdin/stdout、
    config/policy/logging 与 detector 开销。直接调用 Rust function 或 checkout hook 的
    数值只能标 `core_us`/`unofficial`，不得成为 E2E headline。corpus sandbox 准备、
    warmup 与报告渲染不得混入。versioned/digested protocol 必须为每个 surface 固定有序
    case IDs、每个 ID 的 warmup/measurement repetition、完整执行顺序、
    `fresh_per_sample` state policy/initial-state identity 与 percentile estimator
    `nearest_rank_v1`；runner 不能自行选择 workload。environment baseline 也必须在同一
    protocol 中按 target 引用 `production_asset_registry` 的 no-op workload logical ID；
    executable identity 与 exec/argv contract 只来自该 registry entry，protocol 另行固定
    stdin/env、warmup/measurement counts、完整 interleaving、spawn-to-complete 单调时钟边界、
    闭集 estimator `nearest_rank_p95_v1` 与 inclusive threshold comparison；去除 warmup 后
    将 measurement integer-ns 升序排序，并唯一计算
    `baseline_stat_ns = samples[ceil(95*n/100)-1]`（zero-based、无插值）；不能采用 runner
    内建 estimator/workload 或 host PATH workload。每个 warmup/measurement sample 都从
    canonical initial state 创建新 HOME/log/history/session，warmup 不把 state 带入
    measurement。raw duration 使用整数纳秒排序，Pq 固定取
    `ceil(q*n/100)-1` 的 zero-based sample（q=50/95/99，无插值），display ms 仅由该整数
    确定性格式化。timed topology 必须等于 shipped production topology，模式固定
    `production_direct_v1`，`benchmark_only_interposition=[]`：benchmark-only
    broker/proxy/tracer/RPC 永不位于 timer 或 timed descendant 内，也不得从 baseline
    subtract。effectiveness 与独立的 untimed latency-conformance phase 使用 broker并签发同
    snapshot/case/full schedule/fresh-state的 `latency_exec_closure_receipt`。timed run另须使用
    `timed_exec_guard_v1`：它是 target-specific、registry/manifest绑定的 released production
    capability，闭包包含 guard component/loader/service logical IDs、immutable policy version/
    digest、production activation/invocation contract及 OS-attestation verifier/pinned issuer roots。
    installer必须为普通 non-benchmark wrapper安装并激活它，持久化绑定 target/component/policy/
    protection state的 authenticated receipt；official preflight重验 receipt并 challenge live
    kernel/OS state。benchmark只能验证/使用已激活 guard，不得安装、激活、重配或通过 bench-only
    flag启用；普通 wrapper每次 invocation所需 session setup属于用户真实路径并在 timer内，只有
    持久 installation activation在 timer外。kernel在 image执行前拒绝闭包外 identity，event loss/
    overflow/无法证明完整 tree均 fail closed，受信 OS attestation issuer在完成后签
    `timed_exec_guard_receipt` 绑定 registry/manifest/install receipt、live-state challenge、
    policy/session identity、完整 event/root digest与 sample set。self-report/TOFU、bench-only
    activation、policy/loader/service/issuer替换、preflight后停用或没有生产等价 guard的 target
    必须在采样前 unavailable；receipt 缺失/篡改或仅 timed run触发 undeclared
    child 时整批零 headline samples。protocol/report 绑定 execution mode、production topology、
    空 interposition list、closure与 timed-guard receipts；`brokered_timed` 一律拒绝。每个 surface 必须独立
    公开 schedule/state/estimator identity、正整数
    warmup、runs、P50/P95/P99/max、样本数和 OS/arch。
12. B-012: latency 运行必须先测量并公开环境基线。baseline 的 raw integer-ns measurement
    samples、`nearest_rank_p95_v1` identity、schedule/workload identities、
    `baseline_stat_ns` 与比较结果必须进入 report provenance；
    `baseline_stat_ns <= threshold_ns` 才通过，阈值本身通过。时钟不可用、样本执行错误、
    run 数非正、环境基线超过已发布协议阈值，或分位数/样本数不自洽时，latency 轴为
    `inconclusive` 且 headline latency 留空；效果轴只有在其自身满足 B-008/B-009 时才可
    单独为 `valid`。不同平台行不得平均，单次最快值不得代替分位数。
13. B-013: 所有 fixtures 必须是随 corpus 发布的合成内容，并在隔离临时目录运行。
    dangerous shell/git 字符串只允许送入 classifier，绝不执行；benchmark 不访问网络、
    用户 repository、凭据、剪贴板或既有日志，不继承无关环境变量。唯一允许的真实 HOME
    读取是 official preflight 的身份专用只读通道：先以 no-follow、owner/mode、regular-file
    和 verified-provenance 校验打开固定 receipt，再且仅再按一个 protocol-digested
    attestation bundle/signed manifest 并完成 trust bootstrap，再且仅再按 manifest 绑定的
    protocol-digested `production_asset_registry` 打开 installed payload/wrappers、
    canonical benchmark config、environment-baseline workload、interpreters 与 mapped
    production paths 传递闭包内全部 external executables。manifest 绑定 registry digest，
    production mapping 只引用 registry logical ID并拒绝 digest/size/version/path identity，
    receipt 只映射本地 path/handle；三者均不得另行声明 identity。runtime 不进入 registry，
    仅由 manifest 直接绑定、launcher 验证的 handle 派生 singleton
    `runtime_execution_grant`。用户可变 `config.json`/tuning 不在 allowlist，不得枚举目录、
    跟随链接、读取任意其它 HOME 数据或写入真实 HOME。校验后的 handles/bytes 只能
    materialize 到临时只读 snapshot，
    case/warmup/measurement 全程只使用该 snapshot。报告不得包含环境变量值、用户路径、
    fixture 原始 payload、密钥形态文本或未脱敏 stderr。无法建立这些边界时必须在首个
    case 前 `unavailable`。
14. B-014: 正常结束与异常结束都必须清理 benchmark 自己创建的临时状态；清理不得越过
    记录的专用临时根。每个 case 必须运行在独立 process group/session（Windows 为
    kill-on-close Job Object）中。收到取消/中断后停止启动新 case，终止并等待完整
    wrapper/shell/runtime 后代进程树退出后，才尽力写出带 `status: inconclusive`、已完成
    case IDs 与 interruption stage 的 partial report并清理，最终非零退出；无法确认进程树
    已退出时不得清理或声称完成。任何已接收的 interruption/cancellation（即使清理成功），
    以及 process-tree termination、report write/schema validation 或 cleanup 任一 terminal
    failure，都必须触发 B-023 的 closed terminal override，使最终 top-level
    `inconclusive`、headline 留空且非零退出，即使两个 axis candidate 都已 `valid`。
    partial report 不能更新 README 或 release headline。
15. B-015: human 与 `--json` 输出必须由同一份聚合结果渲染。JSON 使用版本化 schema，
    包含 B-002、B-006–B-012 所需证据和每 case 结果；human 摘要不得隐藏 JSON 中的错误
    类别。`valid` 退出 0；`unavailable`、`inconclusive`、schema/corpus error 与
    interruption 均非零退出。无数据用空值/空白加状态表达，不得伪造零值。
16. B-016: 每个 release 的官方报告必须由 release CI 使用“将要发布的准确 binary +
   同 tag payload”重新运行，而不是使用 workspace debug binary、Python eval 汇总、
   上一 release artifact 或手工输入。报告必须与 binary/payload/corpus digests
   相互校验，并作为不可变、可下载、带摘要的 release evidence 保存。cross-platform
   summary 必须通过独立 versioned closed schema，按 target canonical 排序绑定完整
   required set、每个 exact input report 的 evidence digest/report checksum、aggregation
   result、每个 surface 的选择结果、`summary_digest` 与 release-workflow attestation；
   publication/README 只能消费验签后的 summary。summary gate 只消费 B-031 的 required
   set，跨 target 报告不得冒充实际未运行的平台。
17. B-017: README benchmark 表必须从 B-016 的已验签 summary 生成，至少显示
    release、platform、corpus version/digest 短标识、positive/negative 样本数、
    interception 口径与 rate、false-positive rate、状态及报告链接；latency 不允许静默
    reduction，每个 production surface 必须有独立 P95/status 列（或独立子行），列集合与
    顺序来自 protocol schedule。数字不得手工编辑；表格必须明确它代表哪个 release。
    publication ownership、mutation-secret、append-only history、trust/fold 与 owner-liveness
    的完整规范性 contract 位于 [publication_history_contract.md](publication_history_contract.md)；
    该文档全部属于 B-017/B-018 acceptance surface；product/tech/tasks只引用其 machine-facing
    identifiers、secret boundary与 conformance vectors，不在调用方复制字段集合、枚举、canonical
    bytes、alias规则或局部覆盖 fail-closed 语义。
    generated PR、documentation surface plan、zero-marker plan、publication phase、invalidation
    receipt与 response-loss/takeover/recovery的 exact machine由同一 contract定义。产品层只要求：
    所有公开变更来自 exact human-reviewed plan；mutable base或 remote state变化时重新规划/复核；
    zero-marker必须有完整可验证历史；Release与全部 required documentation surfaces最终一致；
    proof不完整、结果歧义或不可逆状态不明时保留 owner并阻断下一 candidate，不以重发、手工改
    marker或本地 fallback恢复。corpus ledger只证明 artifact identities，不参与 publication判定。
18. B-018: release 报告无效、缺平台或 pipeline 中断时必须按获批的闭集
    `release_policy` 唯一分支，且不得保留前一 release 数字但换成新版本标签：
    - `block_release`：按 B-029 保存永久失败证据后阻断；不创建 GitHub Release、
      release page/asset 或该 candidate 的 README current row，已有历史 row 保持原版本
      且不得标为该 candidate；
    - `publish_nonvalid`：发布该版本的 schema-valid non-valid report/evidence，并创建
      同版本 README row；非 valid axis 的 metric cell 留空并显示 axis status、闭集
      reason code 与不可变 report 链接，row 永不得标 `current valid benchmark`，也不删除
      已有 latest-valid row 的该标识。
    缺失、为空或越界 policy 必须阻断，不能由 renderer/workflow 猜分支。
    `publish_nonvalid` 的 report/evidence 任一无法达到 schema/provenance gate 时不得
    发布残缺 release，而是以 `selected_policy: publish_nonvalid`、
    `effective_action: block_release` 和闭集 prerequisite failure code 进入 B-029。
    可恢复失败由当前 release workflow 在退出前写 B-029 证据；job/workflow
    hard-cancel、runner loss 或 timeout 由独立 completion reconciler 在 workflow 终态后
    按同一 candidate/run/attempt 身份补写与最终状态一致的
    `recovered_publication` 或 interruption record。它除只读 source 与
    attestation 写权限外，只能取得 environment-protected、attempt-bound 的 Release
    mutation 权限：仅可按 durable claim 枚举/bind/delete exact draft；revoke owner gate、
    disable auto-merge/dequeue、close exact pending de-current PR并 compare-delete exact head；
    按已验签 `publish_intent` 完成/验证同一 draft；或按 durable owner创建/supersede exact
    de-current/rollback/new-current/nonvalid-row/invalidate-current recovery PR并等待 human review/merge；
    不得直接写 default branch，也不得创建或改写其他 tag/release。任何新 mutation 前必须
    审计 publish sentinels；post-intent 严格按 B-029 三分支真值表恢复，不能依赖已终止 job。
    发布路径必须使用 attempt-scoped draft two-phase commit：先按 B-017 唯一锁顺序 CAS
    `owner_claimed`，再创建并 bind private draft；只有 `draft_bound` 可上传
    assets/checksums/summary，完整重验后 CAS `prepared`。valid 选择并证明 `genesis_zero`、
    `rollover_one` 或 `post_invalidation_zero` receipt 后再写不可变 `publish_intent`；`publish_nonvalid` 的 intent
    绑定 exact unmarked-row plan。最后以唯一 draft→published 作为 commit point。prepared
    且无可见动作的取消可删 exact draft并 terminal；pending de-current PR 必须先撤销 merge
    authority并取得 revocation receipt，已 merge de-current 则进入可接管的 reviewed rollback；
    intent 后严格按 B-029 matching Release/matching draft/neither 三分支；
    commit 后由同一 durable owner
    完成 valid marker 或 nonvalid row。不存在 public partial assets、无 owner 的 zero marker、
    无 owner 的 public Release 或 unrecovered README PR 合法状态。
19. B-019: 官方 report schema 与 corpus schema 的不兼容变更必须提升各自 schema
    version。旧 binary 不认识新 corpus、或新 renderer 无法验证旧 report 时必须明确
    `unavailable`，不能猜字段、静默丢字段或重新解释旧 headline。兼容读取只能是显式、
    有测试的版本映射。
20. B-020: 非官方参数、开发 corpus 或自定义 fixtures 必须在 human/JSON 每层标为
    `unofficial`，输出不得使用 official report 路径/命名，也不得被 README generator
    接受。移除参数后重跑 official corpus 是生成公开证据的唯一恢复路径。
21. B-021: official 身份必须持有 installer 已验证的 `verified-provenance`，这是安全
    强制项而非产品 proposal；`checksum-only` 或无 attestation 的安装最多运行
    `unofficial` 诊断。official runner 不得只信任 binary 自报的 version/tag/commit 或
    `current_exe` pathname。official mode 的 distribution entrypoint 必须是独立受信的
    最小 native launcher；仅由待执行 child、shell script 或 receipt 自证的 launcher 不算
    trust root。该 launcher 必须在任何 runtime bytes 执行前离线验证 persisted
    attestation bundle、pinned trust-root set/version 与 signed release manifest，再
    no-follow 打开 target runtime handle、校验前后 metadata，并把 handle 的 size/SHA-256
    与 manifest 中对应 target asset 比较。全部通过后，Unix 才能用
    `fexecve`/`execveat` 等执行同一 handle 并传入只读 identity fd；Windows 才能从
    deny-write/delete executable handle 启动并持有到 child 完成 identity handshake。
    平台或分发链不能独立认证 launcher、或不能证明 mapped image 来自已校验 handle 时
    official unavailable。child 必须从 inherited binding handle 再算 SHA-256并复验
    manifest chain，作为 defense in depth，不能成为首次信任判定。manifest 只直接绑定
    target runtime asset identity，并绑定 approved protocol digest 与
    `production_asset_registry` digest；payload、wrapper、canonical benchmark config、
    baseline workload、interpreter 与 transitive executable identity/exec/argv contract
    只由该 registry 声明。receipt 只提供 registry logical ID 到本地 path/handle 的 mapping，
    不能自证
    issuer/workflow/subject/digests。`argv[0]`、`PATH`、cwd 邻居 binary、启动后把 pathname
    替换回合法 binary、build-time 自报字段或仅“版本相同”都不能建立 official 身份。任何
    launcher trust、打开/读取/稳定性/digest/attestation mismatch 在零 case 时
    `unavailable`。
22. B-022: 报告必须同时给出两个不可混用的摘要：
    - `decision_digest` 是跨平台比较面，只绑定共同 release source commit、corpus/
      ground-truth/production-mapping/protocol identities、approved
      `required_platforms`、headline subset、按 case ID
      排序的 normalized decisions/canonical reason codes 与 aggregates；排除
      target-specific binary
      digest、OS/arch、latency、timestamp 和 temp path。
    - `evidence_digest` 是 platform-bound 面，绑定该平台完整 canonical report
      （计算时排除字段自身）、`decision_digest`、`current_exe`/payload/wrapper digests、
      target、该 target 是否 required、完整 `required_platforms`、axis 状态与
      latency/environment evidence。
    同一 release 的 required native platforms 必须比较 `decision_digest` 相等；非
    required reports 不进入该 equality gate。不同平台的 `evidence_digest` 本来应不同，
    禁止拿它做 cross-platform equality gate。所有 corpus/evidence/decision/failure
    digest 必须声明同一个 versioned canonical-byte profile：UTF-8 RFC 8785 JCS、拒绝
    duplicate keys、JSON number 只允许 IEEE-754 safe integer
    `[-9007199254740991, 9007199254740991]`（更大 identity 使用 canonical decimal string；
    比例以 numerator/denominator + display string 表示）、不包含尾随换行，然后对精确
    bytes 做 SHA-256；Rust/Python/shell 消费者必须共享含上下界 ±1 的 golden/reject
    vectors，未识别 profile 或任一 byte/digest 不一致均 fail closed。
23. B-023: `axis_candidate_status` 必须是两个 axis 状态的纯 3×3 total function，不读取
    stage 或其它隐藏状态：`valid + valid → valid`；
    `unavailable + unavailable → unavailable`；其余七种组合一律
    `inconclusive`。最终 top-level 再且仅再应用一个 closed `terminal_outcome` override：
    outcome 为 `completed` 时等于 candidate；存在
    `{interrupted, process_tree_unconfirmed, report_write_failed, report_schema_invalid,
    cleanup_failed}` 任一项时一律 `inconclusive`、headline 留空、非零退出。renderer
    不得重算；完整状态/exit matrix 是 3×3×
    `{completed, interrupted_or_terminal_failure}`，包含“两轴已完成后 clean cancel”。
    README 每个 metric cell 只显示其 axis 为 `valid` 的值；否则显示空白/破折号 +
    axis 状态与 reason，同时 row status 显示 top-level。top-level 非 `valid` 不得生成
    “current valid benchmark”标识。
24. B-024: E2E latency executor 必须从 verified install receipt/production mapping
    解析 actual installed Claude/Codex wrapper，并用参数数组启动子进程、传入 fixture
    stdin、等待完整输出与退出。每个 executor 的正整数 timeout、termination grace、
    stdout cap 与 stderr cap 必须是 approved protocol 的必填、canonical、digest-bound
    输入；Bash/Python 等 interpreter 的 target、来源、size、SHA-256、version identity
    与 exec/argv contract 必须只来自该 protocol 绑定的
    `production_asset_registry` entry。runner 不得采用实现默认值、环境变量或 PATH 解析。
    interpreter 可以是 authenticated release payload asset，或是 registry 明确允许且由
    preflight no-follow 打开、校验 bytes 后 materialize 的 authenticated host asset；
    两者都从 readonly snapshot 中的已验证精确路径/handle 启动，并在 report provenance
    中记录实际 identity。每个 mapped production path 的传递闭包内其它 external
    executable（例如 `git`）也必须由 production mapping 只引用 registry logical ID 与
    adapter semantics；source、size、SHA-256、version identity 与 exec/argv contract
    只在对应 registry entry 声明。runner 只能通过 readonly snapshot 的精确
    path/handle 或只含这些资产的 minimal PATH 启动。实现也可消除 subprocess dependency，
    但 ambient PATH、未声明 child exec 或“命令失败后按 PASS 继续”均不可成为 official
    行为。缺失、
    mismatch、cap overflow 或 timeout 必须得到闭集 error 状态，不能因实现差异产生另一
    production decision。executor 必须拒绝 checkout path、直接 runtime function、
    mock wrapper、PATH fallback 或仅测 `vibeguard-runtime bench` 自身调度开销。wrapper/
    executable 缺失、digest drift 或不是 protocol-bound registry/receipt 记录的文件时 latency
    axis `unavailable`。
25. B-025: production mapping 为每个 adapter 同时声明闭集 raw decisions、闭集 raw
    reason codes，以及它们到 `{block, advisory, allow}` 和 canonical reason code 的唯一
    映射。mapping-declared `no_interception_success` 是唯一允许 raw reason 缺席的正常
    variant：success exit + no decision payload + absent reason 必须精确映射为
    `allow/no_interception`。其它未知、多重、形状错误、缺失 decision/reason，或用
    free-text/substr/regex heuristic 猜 reason 的输出都产生独立 `execution_error` case
    status；不得把未知 reason 收进 `other` 或沿用 decision。`execution_error` 不得进入
    `interception_decisions`、TP/FP numerator 或任何 production decision count，但 case
    仍留在 ground-truth denominator，并使 effectiveness `inconclusive`，因此不能发布
    诊断 rate 为 headline。
26. B-026: ground truth 与 production mapping 必须是彼此独立、各自 versioned/digested
    的 artifacts。以下 reviewer separation 是不可协商的 integrity floor：ground-truth
    reviewer 不得是 fixture 作者、对应 detector 作者或 mapping 实现者；mapping reviewer
    不得是对应 detector 作者、mapping 实现者或 fixture 作者；dangerous shell/git
    mapping 另须一名不属于上述作者集合的 security reviewer。mapping 明确 real
    installed entrypoint、raw-decision/reason schema、normalization、required asset logical
    IDs 与 review evidence，并拒绝 registry-owned digest/size/version/path identity。
    reviewer 身份/role 必须来自 maintainer-controlled、signed/attested
    roster；每条 review record 必须由 roster 中对应 identity 签名并绑定 artifact digest、
    role、decision、source commit。自报字符串 ID 或同一 key/identity 的多个别名不算独立。
    任一 roster/record 签名缺失、身份重叠或无法验证均使 official corpus
    `unavailable`；不得由产品 proposal 降低。mapping 变更必须提升 mapping version、
    生成新 digest 并触发全量确认重跑，不能只改 corpus digest 掩盖。
27. B-027: tracked corpus ledger 必须 append-only 地绑定
    `(corpus_version, corpus_digest, ground_truth_version/digest,
    mapping_version/digest, protocol_version/digest)`。同一个已记录或已发布的
    corpus version 对应不同任一 digest 时，build/release 都必须失败；删除、重排历史
    identity 或复用旧 version 同样失败。validator 的 trusted frontier 必须从“上一已发布
    benchmark release”的 attested ledger root/length/full-prefix identity 开始，再按
    repository-global monotonic sequence 消费该 repo 其后所有 permanent blocked-attempt
    records 中 attested 的 ledger root/length/full-prefix identity；source/candidate 只作
    provenance，绝不得过滤 frontier。每次 blocked append 与 publish validation 必须持同一
    repository ledger lease，并让永久 store 以 lease monotonic fence 对
    `(expected_sequence, expected_root)` 执行 atomic compare-and-append；过期 fence、非当前
    prefix 或竞争 successor 必须在落盘前拒绝。每个新 identity 必须以前一个 frontier 为
    prefix，最终以最长已验证 frontier 约束当前 checkout。blocked candidate 已记录的 suffix
    因而不可在 retry 中重写；相同 tuple 可复用，内容变化必须 append 新 version。所有 trust
    anchors 必须经 verified-provenance 验证，不能来自当前 checkout。首个 official
    benchmark release 需要一次明确批准、带 attestation 的 genesis root。published 或
    blocked anchor 缺失、永久 store 获取失败、身份/顺序不匹配或 prefix 无法复算时
    build/release fail closed。
28. B-028: GH-699 是 **partially implemented dependency**：PR #711 已合并
    `SP699-T1/T2` 的 payload artifact 与 payload-mode setup，GH-700 必须消费 main 上该
    实际 contract，不能仍称其未合并；但 `SP699-T3` bootstrap、`T4` no-clone native
    release smoke 与 `T5/T6` launchers 仍 pending。official gate 必须由无 checkout
    integration fixture 探测未来合并的真实 launcher path/argv，不能从 spec 或 payload
    setup 猜 `vibeguard` shim。GH-700 仍负责让每个 manifest-declared installed launcher
    透明 dispatch `bench`；仅证明 launcher 存在不够，no-clone smoke 必须断言它不会进入
    bootstrap/setup/init 并透传 argv/stdin/stdout/stderr/exit。T3–T6 未完成、dispatch
    未落地或 smoke 未通过时，B-001 保持 unavailable。
29. B-029: 当 effective action 为 `block_release`（包括选中 `publish_nonvalid` 但其
    mandatory evidence gate 失败）时，可恢复失败路径必须在 release job 返回失败前生成
    schema-valid candidate failure report 与 schema-valid canonical failure manifest。
    manifest 必须是闭集 target-scoped 或 release-scoped 分支。target-scoped 分支完整包含
    candidate tag/source commit/target、workflow run/attempt、
    selected policy/effective action、axis/top-level 状态、闭集 failure/reason codes、
    report/evidence/checksum identities 与验证所需 provenance；其完整 canonical 内容
    必须内嵌在不可覆盖、retention-independent 永久可检索的
    attestation predicate（或语义等价的 append-only immutable ledger），不能只保存
    artifact pointer/digest/job summary。content-addressed bundle 可作为短期下载副本；
    即使 CI artifact retention 到期，独立验证者仍必须能从长期 predicate/ledger 恢复
    完整 manifest 并复核内容、reason 与 digest。`failure_manifest_digest` 的 canonical
    输入必须包含 `run_id` 与 `run_attempt`；bundle、attestation predicate/ledger identity
    必须同时包含 `(run_id, run_attempt, failure_manifest_digest)`。即使 report/evidence
    bytes 完全相同，每次 retry 也产生不同、不可覆盖且可独立检索的 attempt record；随后
    job 非零退出，GitHub Release、release page/assets 与 README candidate current row
    均不创建。

    required-platform 输入各自通过但 decision 不一致、缺输入或 aggregation 失败时，
    release-scoped 分支必须绑定 canonical failed-summary preimage/digest、完整
    required-platform set 与闭集 aggregation reason。每个 required target 都有一个闭集
    discriminated input：`present` 必须携带非空 report/evidence/checksum identity；
    `missing` 必须将这三项显式置 null 并携带 closed `missing_reason`，禁止伪造 identity。
    只有 strict summary 已成功构造时才携带非空 `summary_digest`；缺输入导致无法构造时
    `summary_digest` 显式为 null，canonical failed-summary digest 仍覆盖全部 target slots。
    此分支不能降格成单一 target record。

    对于 hard-cancel、runner loss 或 workflow timeout，独立 completion reconciler 必须先
    复验 durable owner、intent 与 public sentinels。post-intent 真值表唯一为：matching
    public Release 则验证并完成 README；否则 matching intent-bound private draft 则发布并
    完成 README；两者都 append `recovered_publication`。若二者皆无则 attest
    `release_recovery_blocked`、保留 owner，不能写 recovered/interruption。只有无 intent
    且恢复最终证明不发布时（claim 无 draft；无 transition 删除 bound draft；pending
    de-current 先取得 revocation receipt；已 merged de-current 则 exact rollback+draft delete），
    才创建 schema 的 `pipeline_interrupted` 分支：包含同一
    candidate/run/attempt、staged provenance、selected/effective policy、interruption
    conclusion/stage、publish-sentinel audit，以及闭集 `missing_evidence`；此分支明确将
    report/evidence/checksum identity 置空而不伪造。reconciler 用相同 canonical profile
    计算 attempt-bound digest 并永久 attestation/append，且重复 delivery 必须幂等、
    已有不同内容必须冲突失败。若 normal path record 已存在则只验证不覆盖。若终止发生在
    staged identity 首次 attestation 之前，reconciler 必须改用闭集
    `pipeline_interrupted_pre_attestation` 分支：只从受信的 `workflow_run` 终态事件与
    Actions API 复验得到 `(repo_node_id, workflow_id, run_id, run_attempt, head_sha,
    server_ref_type, server_ref_name, event, conclusion)`；ref 必须再与对应 branch/tag ref
    API 对齐，不能从 workflow input 猜。candidate tag、policy、staged provenance 和
    evidence identities 显式置 null，并列出 closed missing fields/stage。canonical JCS
    tuple 派生含 server ref 的 source-identity key 与包含 run/attempt 的无碰撞
    early-attempt key；终态事件在该 source lease 下路由/永久记录。后续只可绑定给
    tag/source 与 server ref 精确匹配的 staged candidate，并按 canonical key 顺序同时
    持有 early/candidate leases 后 union 进 watermark；无法证明精确匹配的 record 永久
    保持 unbound，不得由“同 commit 的下一个 candidate”接管。tuple/digest 冲突或归属歧义
    均 fail closed；不得读取 workflow 自由文本或跳过该 attempt。
    reconciler workflow 的 GitHub token显式固定为 `actions: read`、`contents: read`、
    `pull-requests: read`；mTLS client identity只可请求 authority执行已规划 operation，所有 GitHub
    write credential仅存在于 sole authority/broker，default branch仍只能经 human-reviewed PR/CAS修改。所有 release attempts、
    reconciler 与 publish gate 必须共享 candidate/source-identity
    路由的 serialized lease（禁止 cancel-in-progress）、repository ledger lease和合并后的 attested reconciliation
    watermark；新 attempt 与 publish 在持锁状态下必须枚举同 candidate/source identity 的
    全部既有 terminal attempts，并证明每个
    failed/cancelled/timed_out attempt（包括 pre-attestation interruption）都已有唯一且
    与终局一致的 permanent failure 或 `recovered_publication` record。存在未 reconciled attempt、
    terminal-run 列表/永久 store 不可用或 watermark 不一致时 fail closed，不能先发布后补写。
30. B-030: official run 在任何 latency warmup/measurement 前，必须通过 B-013
    身份专用只读通道，从 receipt 映射的已打开、已校验 handles/bytes，把已验签 manifest
    及 launcher 已验证的 runtime handle、单一 `production_asset_registry` 的 payload/
    wrappers/canonical config/baseline workload/interpreters/transitive external executables
    按生产安装布局
    materialize 到本次 temp HOME 的
    byte-identical、只读 install snapshot，并逐文件重算 digest 与 receipt/manifest/protocol
    identity 对齐。materialization、chmod 与 digest verification 不进入 latency 样本；
    计时区间必须从该 snapshot 启动真实 wrapper 子进程。缺文件、布局差异、可写状态或
    digest drift 使对应 axis 在零 timed sample 时 `unavailable`；身份通道关闭后
    case/warmup/measurement 不得再读真实 HOME，任何阶段都不得写真实 HOME 或使用
    checkout/mock/ambient-PATH fallback。preflight static inventory 与 child-exec audit
    只能发现明显漂移，不能充当运行时证明。effectiveness case 与 untimed latency-conformance
    phase 的完整 process tree 必须置于 protocol/manifest 绑定的、OS-authoritative
    deny-by-default exec broker 下；broker 在
    每次 descendant image 启动前只放行 resolved handle/digest 匹配的 registry logical ID，
    或 manifest 直接绑定且由 launcher-verified inherited handle 派生的 singleton
    `runtime_execution_grant`；grant 不写入 registry且禁止 pathname lookup。任何 backend
    不支持 pre-exec deny、broker 失联、分支
    延迟触发 undeclared executable 或 identity race 均在 image 执行前拒绝并使 official
    axis fail closed。timed latency 只可在同 snapshot/schedule的 untimed closure receipt通过后
    以 `production_direct_v1` 运行生产拓扑，broker/proxy不得进入 timer或 timed descendants；
    同时由生产本身携带的 kernel `timed_exec_guard_v1`在 image前拒绝闭包外 identity并于 tree
    完成后签发完整性 receipt；event loss或仅 timed分支触发 undeclared child使整批无 headline
    samples。无法同时证明闭包、production-equivalent guard与空 benchmark interposition 的 target 在零 timed sample 前
    `unavailable`。
31. B-031: approved、versioned/digested protocol 必须携带非空、去重、canonical 排序的
    `required_platforms`，且每项属于 release target 闭集。release summary 只聚合该 set：
    每个 required target 都必须由对应 native runner 产生 schema/provenance-valid report，
    且 required reports 的 `decision_digest` 一致；缺任一 required native report 或任一
    required target 非 `valid` 时 summary 非 valid 并进入获批 release policy。非 required
    target 可生成独立 display-only row；其 `unavailable`/缺 native runner 不得阻断
    summary，也不得替代 required target。summary schema 必须包含最终展示的全部 reports，
    为每项绑定 `required` boolean 与 exact
    `(target, evidence_digest, report_checksum)`；只有 required subset 参与 validity 与
    decision-equality aggregation，display-only 输入仍进入签名 summary preimage，README
    不得读取未绑定附件。`summary_digest` 的唯一
    preimage 是完整 summary object 删除 `summary_digest` 字段后的 JCS bytes；detached
    attestation 绑定该 digest，不进入 preimage。遗漏/重复/替换 input、自包含 placeholder 或
    aggregation result 不匹配都不可发布。若获批 set 含四个平台，则四个平台都必须有
    native runner；host/cross-compiled execution 不算覆盖。required set 缺失、空、重复、
    未排序、含未知 target 或与 report/digests 不一致时 preflight `unavailable`。

## 验收标准

- [ ] 从已校验 release 安装的每个 manifest-declared Homebrew/npm 入口运行
      `vibeguard bench` 等对应命令，无需 checkout/Rust/API key，透明转发 IO/exit 并产出
      同源 human + JSON 报告，绝不进入 setup/init。
- [ ] 官方 corpus 的五类 failure classes 均有 reviewed positive 与 matched clean
      control；缺类/缺侧/未知 production surface 时 fail closed。
- [ ] 报告公开 provenance、TP/FN/FP/TN + positive/negative error buckets、两条 denominator
      closure equation、block/advisory 分项、每类分项与 `interception_decisions`；
      execution_error 不进 production decision/numerator，但 case 不从 ground-truth
      denominator 消失。
- [ ] 同一 release 的确定性确认重跑与 required native platforms 产生一致
      `decision_digest`；每个平台有绑定 actual `current_exe` 的独立 `evidence_digest`。
- [ ] approved protocol 的 required set、canonical benchmark config、initial-state 与
      latency schedules 进入对应 digests；strict summary 逐项绑定 exact required report
      evidence/checksum并验签，非 required unavailable 仅展示。
- [ ] latency 按 protocol 固定的每个 surface case/repetition/order，从 offline-verified
      signed manifest materialize 的 readonly 生产布局启动真实 wrapper，逐 surface 报
      P50/P95/P99/max；README 保持独立列/子行，不做静默 reduction。
- [ ] dangerous fixtures 不会执行命令或读写用户项目/log；真实 HOME 只有 offline-verified
      bundle/signed manifest + 单一 digested production-asset registry 授权的 no-follow
      只读身份通道，baseline/interpreters/transitive executables 缺项、用户 config、
      registry 外读取和全部写入均被拒；sentinel secrets 不出现在任何输出。
- [ ] release CI 用准确 staged artifacts 重新生成不可变报告；可恢复阻断在退出前写证据，
      hard cancel/runner loss 由 environment-protected completion reconciler 按 publication
      phase 分流：无 intent 最终不发布时才把 target 或 release-scoped failure manifest
      永久内嵌到不可覆盖 attestation/ledger；post-intent matching Release/draft 完成 exact
      publication并只写 `recovered_publication`，neither 则 `release_recovery_blocked`。它的
      Release 写权限仅能按 durable claim bind/delete exact private draft、撤销 pending
      de-current PR、按验签 intent 完成同一 draft，或按 durable owner创建/supersede reviewed
      de-current、rollback、new-current、nonvalid-row、invalidate-current PR；不能直接写 default branch或改写其他 release；
      `repo_node_id` identity、candidate/source → ledger → publication 的唯一 lease 顺序、
      fenced CAS + merged watermark 阻止 prior attempt 或并发 candidate 后的 rerun/publish；
      pre-draft claim/binding、pending de-current revocation、genesis zero-marker、
      rollover rollback、post-intent Release、post-commit marker 与
      nonvalid row 都必须有
      pre-transition durable owner、intent 前 receipt、retained authenticated publication
      history并恢复到 terminal；draft/Release 不匹配则 `release_recovery_blocked`。
      reconciler GitHub token仅用显式
      `actions: read`/`contents: read`/`pull-requests: read`，write credential仅 authority/broker可持有。
- [ ] unavailable/inconclusive/interrupted/legacy-schema 及 process-tree/report/schema/
      cleanup terminal errors 均非零退出、blank headline，且不会把历史数字冒充当前 release。

## 边界情况清单

| 类别 | 判定（covered: B-xxx / N/A + 原因） |
| --- | --- |
| 空/缺失输入 | covered: B-002, B-003, B-007, B-015, B-021, B-024, B-030, B-031 |
| 错误与失败路径 | covered: B-005, B-008, B-012, B-015, B-018, B-019, B-023, B-025, B-029, B-031 |
| 授权/权限 | covered: B-002, B-004, B-013, B-021, B-026；identity/reviewer floor 不可由 proposal 降低 |
| 并发/竞态 | covered: B-009, B-010, B-016, B-021, B-022, B-030 |
| 重试/幂等 | covered: B-009, B-010, B-018, B-027, B-029 |
| 非法状态转换 | covered: B-008, B-014, B-015, B-020, B-023, B-025 |
| 兼容/迁移 | covered: B-001, B-016, B-017, B-019, B-027, B-028, B-031 |
| 降级/回退 | covered: B-005, B-008, B-012, B-018, B-023, B-028, B-031；不得把降级显示为 valid |
| 证据与审计完整性 | covered: B-002, B-004, B-006, B-007, B-009, B-016, B-017, B-021, B-022, B-025, B-026, B-027, B-029, B-030, B-031 |
| 取消/中断 | covered: B-014, B-018, B-029 |

## 发布说明

GH-700 的 public done-when 依赖 GH-699 的剩余实现：PR #711 已合并 `SP699-T1/T2`
payload contract，但 `T3` bootstrap、`T4` no-clone native smoke、`T5/T6` actual
launchers 仍 pending。release binary、payload、bootstrap 与 actual launcher 必须形成
同 tag、可校验的 released install；GH-700 还必须在探测到的每个支持 launcher 上实现并
验证 `bench` argv/IO/exit transparent dispatch。只有 offline attestation/manifest identity
与 no-clone dispatch smoke 同时通过，才能声称“一条命令从 release 复现”。
此前只能报告 `unofficial`/`unavailable`。

README 首次切换到生成表格时必须清楚区分既有的 40-sample model-backed
rule-detection benchmark 与本 spec 的 deterministic released-production benchmark；
二者不得合并成一个分数。
