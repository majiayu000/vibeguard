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
GH-700 要提供 `vibeguard bench`：用户从 GH-699 定义的已校验 release 安装出发，
不 clone 仓库、不安装 Rust、不依赖未发布源码，即可重放与该 release 绑定的官方
corpus，并得到 interception rate、false-positive rate 与 hook latency。

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

## 待维护者确认的产品决策

以下决定不能从 issue、roadmap 或当前实现推导；在 spec approval 时必须逐项选择，
否则对应 headline 保持 `unavailable`，不得由实现者默认：

1. **Interception 口径**：headline 只统计 `block/deny`，还是统计
   `block/deny + warn/review`。无论选择哪一种，报告都必须同时公开 block rate 与
   advisory rate，不能只展示合并后的最好数字。
2. **两个类别的生产语义**：
   - “invented APIs”是指当前 hook 可证明的不存在路径/不存在编辑目标，还是依赖/API
     inventory 验证；后者目前没有已核实的 released deterministic production surface。
   - “swallowed exceptions”当前锚点是 Python guard 的 pytest-shaped checker；需确认
     v1 是把该 canonical guard 变成 release-install 可执行面，还是把该类标为
     `unavailable`。禁止复制一个 benchmark-only 检测器来满足表格。
3. **公开平台集合**：哪些 release targets 必须有独立行；不同 OS/架构的延迟不得
   静默平均成一个 headline。
4. **Release policy**：官方 benchmark `inconclusive` 时，是阻断 release，还是发布
   release 但在 README/报告明确显示 `unavailable`。两种方案都不得沿用上一版本数字
   冒充当前 release。
5. **Corpus 审核门**：每类最少正/负样本数、ground-truth reviewer 身份要求，以及
   corpus 变更是否需要独立安全 reviewer。

## Behavior Invariants

1. B-001: `vibeguard bench` 的官方模式必须能从 GH-699 定义的、校验成功的 released
   install 一条命令运行；不得要求 repository checkout、Rust toolchain、未发布脚本或
   用户 API key。源码构建、dirty checkout 或自定义二进制可以运行开发诊断，但其结果
   必须标为 `unofficial`，不得成为 README/release headline 证据。
2. B-002: 每次官方运行必须在执行首个 case 前固定并输出至少以下 provenance：
   runtime version、release tag、target triple、build source commit、corpus schema
   version、corpus ID/version/digest、release payload manifest digest，以及本次实际
   使用的 production surfaces 摘要。任一必填值缺失、为空、越界或互相不匹配时，结果
   为 `unavailable` 且零 case 执行；不得用 `unknown` 生成 headline。
3. B-003: 官方 corpus 必须包含五个闭集 failure classes
   `{invented_api, duplicate_module, swallowed_exception,
   dangerous_shell_or_git, unverified_done_claim}`。每类必须同时有至少一条 positive
   case 与一条不应触发的 matched clean control；任一类、任一侧为空时，整体结果为
   `unavailable`，不能从分母中删除该类后继续发布。
4. B-004: 每条 corpus case 必须有稳定且唯一的 case ID、ground-truth
   `{positive, negative}`、failure class、预期 production surface、允许的闭集决策与
   ground-truth 审核记录。ground truth 不得从同一次 detector 输出反推；重复 ID、
   未知 class/surface/decision、正负标签冲突或未审核条目使 corpus 无效。修改 case、
   ground truth 或允许决策必须产生新的 corpus version/digest，并随新 release 发布，
   不得原地改写旧 release 的语义。
5. B-005: 每条 case 必须走 release 用户真实使用的 canonical hook/guard 生产入口。
   mock、stub、hard-coded case ID 分支、fixture 专用 detector 或仅测试时启用的实现都
   不算 interception 证据。某 failure class 尚无 released production surface 时，该类
   与整体 headline 必须 `unavailable`；不得以“测试通过”代替产品能力。
6. B-006: 每个 case 的归一化结果必须来自闭集
   `{block, advisory, allow, execution_error}`，并保留原始 production surface
   decision 与 rule/reason 标识。报告必须声明 `interception_decisions` 是该闭集的
   哪个非空子集；该口径由“待维护者确认的产品决策 1”确定。缺失或改变口径的报告之间
   不得直接比较。
7. B-007: 指标必须使用完整 ground truth 分母：
   `interception_rate = 被选定 interception_decisions 命中的 positive / positive_total`；
   `false_positive_rate = 被选定 interception_decisions 命中的 negative /
   negative_total`。同时公开 TP、FN、FP、TN、block count、advisory count 与每个 failure
   class 的分项。零分母、整数关系不自洽、百分比非有限值或不在 0–100 时结果为
   `inconclusive`；不得把 `execution_error`、timeout 或 skipped case 从分母移除。
8. B-008: 状态语义必须分开且 fail closed：
   - `unavailable`：执行前缺 release/corpus/payload/权限/生产入口等前提；
   - `inconclusive`：执行已开始，但出现 case error、timeout、环境失真、结果不确定或
     证据不完整；
   - `valid`：全部 mandatory cases 完成、provenance 完整、分母有效且确定性复核一致。
   人类输出、JSON、README 与 release asset 必须使用同一状态；`unavailable` /
   `inconclusive` 不得显示为 `0%`、`pass` 或沿用历史数字。
9. B-009: 效果轴必须可确定性复核。同一 verified release、official corpus、
   interception 口径与显式运行参数的确认重跑，忽略 latency、timestamp、临时路径等
   非语义字段后，每个 case 的 decision/reason 分类、case 顺序、计数和比例必须完全一致。
   任一差异使效果轴 `inconclusive`，并列出不一致 case；不得择优选一次结果。
10. B-010: benchmark 必须幂等且并发隔离。重复或并发运行不得修改用户项目、已安装
    payload、global/project event logs、hook 配置或前一次报告；每次运行使用独立临时
    工作区和输出目标。输出路径冲突、残留状态被下一次复用或执行顺序改变 ground truth
    时，结果必须失败可见。
11. B-011: latency 是与效果轴分离的 `bench_case_e2e_ms` 面：从调用 released
    production entrypoint 前到其完整 decision/输出返回后，使用单调时钟测量，并包含
    release 用户真实承担的 wrapper/process、stdin/stdout、配置查找与 detector 开销；
    corpus sandbox 准备、warmup 与报告渲染不得混入。每个 surface 必须公开正整数 warmup
    次数、measurement runs、P50/P95/P99/max、样本数和 OS/arch；不得把 in-process
    microseconds 标成 hook end-to-end latency。
12. B-012: latency 运行必须先测量并公开环境基线。时钟不可用、样本执行错误、run 数
    非正、环境基线超过已发布协议阈值，或分位数/样本数不自洽时，latency 轴为
    `inconclusive` 且 headline latency 留空；效果轴只有在其自身满足 B-008/B-009 时才可
    单独为 `valid`。不同平台行不得平均，单次最快值不得代替分位数。
13. B-013: 所有 fixtures 必须是随 corpus 发布的合成内容，并在隔离临时目录运行。
    dangerous shell/git 字符串只允许送入 classifier，绝不执行；benchmark 不访问网络、
    用户 repository、真实 HOME、凭据、剪贴板或既有日志，不继承无关环境变量。报告不得
    包含环境变量值、用户路径、fixture 原始 payload、密钥形态文本或未脱敏 stderr。
    无法建立这些边界时必须在首个 case 前 `unavailable`。
14. B-014: 正常结束与异常结束都必须清理 benchmark 自己创建的临时状态；清理不得越过
    记录的专用临时根。收到取消/中断后停止启动新 case，尽力写出带
    `status: inconclusive`、已完成 case IDs 与 interruption stage 的 partial report，
    非零退出；partial report 不能更新 README 或 release headline。
15. B-015: human 与 `--json` 输出必须由同一份聚合结果渲染。JSON 使用版本化 schema，
    包含 B-002、B-006–B-012 所需证据和每 case 结果；human 摘要不得隐藏 JSON 中的错误
    类别。`valid` 退出 0；`unavailable`、`inconclusive`、schema/corpus error 与
    interruption 均非零退出。无数据用空值/空白加状态表达，不得伪造零值。
16. B-016: 每个 release 的官方报告必须由 release CI 使用“将要发布的准确 binary +
    同 tag payload”重新运行，而不是使用 workspace debug binary、Python eval 汇总、
    上一 release artifact 或手工输入。报告必须与 binary/payload/corpus digests
    相互校验，并作为不可变、可下载、带摘要的 release evidence 保存；跨 target 报告
    不得冒充实际未运行的平台。
17. B-017: README benchmark 表必须从 B-016 的机器可读 release report 生成，至少显示
    release、platform、corpus version/digest 短标识、positive/negative 样本数、
    interception 口径与 rate、false-positive rate、latency P95、状态及报告链接。数字
    不得手工编辑；表格必须明确它代表哪个 release，不能把旧版本行呈现为“current”。
18. B-018: release 报告无效、缺平台或 pipeline 中断时，README/发布页面必须显式显示
    该 release 对应的 `unavailable`/`inconclusive` 与原因链接；不得保留前一 release
    数字但换成新版本标签。是否阻断 release 由“待维护者确认的产品决策 4”决定，但证据
    诚实性不因该选择改变。
19. B-019: 官方 report schema 与 corpus schema 的不兼容变更必须提升各自 schema
    version。旧 binary 不认识新 corpus、或新 renderer 无法验证旧 report 时必须明确
    `unavailable`，不能猜字段、静默丢字段或重新解释旧 headline。兼容读取只能是显式、
    有测试的版本映射。
20. B-020: 非官方参数、开发 corpus 或自定义 fixtures 必须在 human/JSON 每层标为
    `unofficial`，输出不得使用 official report 路径/命名，也不得被 README generator
    接受。移除参数后重跑 official corpus 是生成公开证据的唯一恢复路径。

## 验收标准

- [ ] 从已校验 release 安装运行一条 `vibeguard bench`，无需 checkout/Rust/API key，
      产出同源 human + JSON 报告。
- [ ] 官方 corpus 的五类 failure classes 均有 reviewed positive 与 matched clean
      control；缺类/缺侧/未知 production surface 时 fail closed。
- [ ] 报告公开 provenance、完整 confusion matrix、block/advisory 分项、每类分项与
      `interception_decisions`，分母不丢 skipped/error。
- [ ] 同一 release 的确定性确认重跑产生一致 decision digest；人为制造不一致时结果
      `inconclusive`。
- [ ] latency 按 released end-to-end surface 报 P50/P95/P99/max，并在失真环境下留空、
      不伪造 headline。
- [ ] dangerous fixtures 不会执行命令或读写用户项目/HOME/log；sentinel secrets 不出现
      在 human、JSON、stderr 或 release report。
- [ ] release CI 用准确 staged artifacts 重新生成不可变报告；README 表格由该报告生成
      并链接证据。
- [ ] unavailable/inconclusive/interrupted/legacy-schema 等负路径均非零退出，且不会把
      历史数字冒充当前 release。

## 边界情况清单

| 类别 | 判定（covered: B-xxx / N/A + 原因） |
| --- | --- |
| 空/缺失输入 | covered: B-002, B-003, B-007, B-015 |
| 错误与失败路径 | covered: B-005, B-008, B-012, B-015, B-018, B-019 |
| 授权/权限 | covered: B-002, B-004, B-013；corpus 审核权限仍需维护者决策 |
| 并发/竞态 | covered: B-009, B-010, B-016 |
| 重试/幂等 | covered: B-009, B-010, B-018 |
| 非法状态转换 | covered: B-008, B-014, B-015, B-020 |
| 兼容/迁移 | covered: B-001, B-016, B-017, B-019 |
| 降级/回退 | covered: B-005, B-008, B-012, B-018；不得把降级显示为 valid |
| 证据与审计完整性 | covered: B-002, B-004, B-006, B-007, B-009, B-016, B-017 |
| 取消/中断 | covered: B-014, B-018 |

## 发布说明

GH-700 的 public done-when 依赖 GH-699：release binary、payload 和 launcher 必须形成
同 tag、可校验的 released install，`vibeguard bench` 才能声称“一条命令从 release
复现”。实现可以先在开发树完成，但在 GH-699 前提未满足时只能报告 `unofficial` /
`unavailable`。

README 首次切换到生成表格时必须清楚区分既有的 40-sample model-backed
rule-detection benchmark 与本 spec 的 deterministic released-production benchmark；
二者不得合并成一个分数。
