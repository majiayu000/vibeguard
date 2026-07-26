# Tech Spec — released-production benchmark corpus、runner 与发布证据链

## Linked Issue

GH-700

## Product Spec

[`product.md`](product.md)

## Codebase Context

以下锚点均在写作时由当前 worktree 的 Read/grep 核实。

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Runtime CLI registry | `vibeguard-runtime/src/main.rs:68`, `vibeguard-runtime/src/main.rs:519` | 单一 `COMMANDS` 表分发 release runtime 子命令；当前没有 `bench` | `vibeguard bench` 的 release-binary 内核入口 |
| Deterministic behavior eval | `eval/run_behavior_eval.py:28`, `eval/run_behavior_eval.py:65`, `eval/run_behavior_eval.py:137`, `eval/run_behavior_eval.py:275` | repo-only Python harness 从 JSONL 读取样本、执行真实 hooks、聚合 pass/fail；latency 是每 case 粗粒度 wall time | 可复用语义，不可直接作为 released command 或 headline producer |
| GH-686 provenance foundation | `eval/paired_provenance.py:135`, `eval/paired_provenance.py:178`, `eval/paired_provenance.py:204` | 真实 paired eval 将输入钉到 commit，拒绝仓外、symlink、dirty/untracked 与 blob 不一致 | B-002/B-004/B-016 的 search-first 设计先例 |
| Existing score portal | `scripts/benchmark.sh:13`, `scripts/benchmark.sh:38`, `scripts/benchmark.sh:145`, `scripts/benchmark.sh:262` | repo-relative shell script聚合 precision CSV 与可选 model eval，输出内部 score archive | 名称相似但 provenance/口径不同；不得把它包装成 public released benchmark |
| Production hook paths | `vibeguard-runtime/src/hook_orchestrator.rs:69`, `vibeguard-runtime/src/hook_checks_bash.rs:144`, `vibeguard-runtime/src/hook_checks_write.rs:95`, `vibeguard-runtime/src/hook_orchestrator_stop.rs:65` | runtime 已有 hook orchestrator、危险命令分类、duplicate scan 与 unverified-stop 检测 | public cases 必须调用这些 canonical paths，而不是复制 detector |
| Unresolved class anchors | `vibeguard-runtime/src/hook_checks.rs:323`, `guards/python/test_code_quality_guards.py:94`, `guards/python/test_code_quality_guards.py:144` | runtime 能检出不存在文件/编辑目标；silent broad exception checker 当前是 pytest-shaped Python guard | “invented API”与“swallowed exception”的 production mapping 仍需产品决策 |
| Actual installed wrappers | `hooks/run-hook.sh:8`, `hooks/run-hook.sh:38`, `hooks/run-hook.sh:83`, `hooks/run-hook.sh:180`, `hooks/run-hook-codex.sh:66`, `hooks/run-hook-codex.sh:89`, `hooks/run-hook-codex.sh:139` | stable Claude/Codex paths 从真实 HOME 的 installed snapshot 解析 hook，并以子进程处理 stdin/output/policy | B-011/B-024 的 E2E latency 必须 spawn 这些实际安装副本 |
| Runtime release identity | `scripts/setup/runtime-install.sh:112`, `scripts/setup/runtime-install.sh:123`, `scripts/setup/runtime-install.sh:129`, `scripts/setup/runtime-install.sh:160`, `scripts/setup/runtime-install.sh:186`, `scripts/setup/runtime-install.sh:272` | installer 已核对 asset SHA/manifest size/provenance，并写 repo/tag/target/sha；runner 尚未重算 `current_exe` 或绑定 payload/wrapper digests | B-021 要补成 actual-executable identity chain，不能只信 self-reported version |
| Existing digest primitive | `vibeguard-runtime/src/setup_support.rs:49`, `vibeguard-runtime/src/setup_support.rs:58`, `vibeguard-runtime/src/setup_support.rs:178` | runtime 内已有 SHA-256 file/text 实现 | 可扩成从一次打开的 `current_exe` file handle 流式求摘要，无需 shell hashing |
| Installed latency contract | `docs/reference/hook-latency-contract.md:7`, `docs/reference/hook-latency-contract.md:18`, `docs/reference/hook-latency-contract.md:51` | `hook_e2e_ms` 包含 wrapper/process/config/logging，报告 P50/P95/P99/max，并识别 environment distortion | 新 public latency 必须保持 end-to-end 语义且独立标识 surface |
| Release artifact pipeline | `.github/workflows/release.yml:62`, `.github/workflows/release.yml:127`, `.github/workflows/release.yml:189`, `.github/workflows/release.yml:216` | 四 target build，原生 smoke，生成 checksum/manifest，release 不允许原地变更 | 官方 report 必须在 immutable publish 前从 staged artifacts 产生 |
| GH-699 partial dependency | PR #711；main `6bf4ddc3f43744581eac9666712ee80964611740` | fresh remote evidence 显示 T1/T2 payload artifact/setup 已于 2026-07-26T22:02:07Z 合并；T3 bootstrap、T4 no-clone native smoke、T5/T6 launchers 仍 pending | GH700 现在消费 merged payload contract，但仍须等待并探测真实 launcher/no-clone evidence |
| Public documentation | `README.md:301`, `README.md:305`, `README.md:306` | README 已区分 behavior eval 与 40-sample model-backed benchmark，但无 released deterministic table | 新表必须新增第三种、来源清楚的 evidence surface |

## 设计方案

### 1. Artifact model 与依赖门

新增独立 public-benchmark surface，不重命名或复用 `scripts/benchmark.sh`：

- fixture corpus：`data/public_benchmark/corpora/v1.jsonl`；
- 独立 ground truth：`data/public_benchmark/ground_truth/v1.jsonl`；
- versioned production mapping：**data/public_benchmark/production_mapping/v1.json**；
- append-only identity ledger：**data/public_benchmark/corpus_ledger.json**；
- planned schemas：**schemas/public_benchmark_corpus.schema.json**、
  **schemas/public_benchmark_ground_truth.schema.json**、
  **schemas/public_benchmark_production_mapping.schema.json**、
  **schemas/public_benchmark_report.schema.json**、
  **schemas/public_benchmark_failure_manifest.schema.json** 与
  **schemas/release_identity.schema.json**；
- Rust 实现拆到 `vibeguard-runtime/src/bench/`，`main.rs` 只注册 `bench` 命令；
- corpus/ground truth/mapping/ledger 以构建期只读资源编进 release binary，runner 不从
  cwd 或用户可写路径寻找 official inputs；
- 需要 shell/Python guard 的 case 只从 GH-699 同 tag、digest-matched payload 调用。

versioned benchmark protocol 还必须记录 approved `required_platforms`。该字段非空、
去重并 canonical 排序，和 protocol 其它字段一起 digest；每个平台 report 同时记录完整
set 与本 target 的 `required` boolean。protocol 未获批或 set 非法时 official preflight
unavailable，不允许 release workflow 临时从 matrix job 列表推导 required set。

installer 必须把已验证身份写成 versioned
`~/.vibeguard/installed/release-identity.json` receipt。它至少保存 release repo/tag/
source commit/target、runtime asset name/size/SHA-256、runtime release manifest digest、
payload asset/manifest/snapshot digests、实际 installed wrappers 及其 digests、attestation
issuer/workflow/subject/status。现有 `runtime-provenance` 可继续供兼容显示，但不能单独建立
official 身份。

`bench` 身份 preflight 的顺序是：

1. 用 `std::env::current_exe()` 定位 binary；不读取 `argv[0]`/PATH；
2. 打开一次 regular executable file handle，从该 handle 流式计算 SHA-256，并比较 hash
   前后 metadata；无法稳定读取则 unavailable；
3. digest/size/path 必须匹配 receipt 的 target asset，receipt 必须匹配保存的 release
   manifest 与 `verified-provenance` attestation identity；
4. payload、embedded inputs 与 actual installed wrapper bytes 各自重算 digest，全部匹配
   receipt/同 tag/source commit；
5. build-time version/tag/commit 只作额外一致性断言，不能替代 current bytes chain。

official mode 强制要求 `verified-provenance`；当前允许的 `checksum-only` install 仍可
跑诊断，但只能标 `unofficial`。这是 B-021 的安全 floor，不是待选产品 proposal。

GH-699 是 partially implemented public done-when dependency，不是可静默 fallback。
PR #711 的 merged T1/T2 payload contract 是当前 source of truth；只有后续 merged T3–T6
提供 bootstrap、no-clone native smoke 与 actual launcher 后，GH700 integration fixture
才冻结真实 launcher path/argv。tasks 文本、payload setup 本身或猜测的 `vibeguard` shim
都不是 launcher evidence；不得搜索相邻 checkout 或回退 PATH 同名脚本。

### 2. Corpus 与 ground truth

fixture JSONL 不携带 ground truth 或 executable path；每行只保存稳定 case ID、
failure class 和合成 fixture。独立 ground-truth JSONL 以 case ID 关联
`positive|negative`、matched pair、审核人/证据；production-mapping JSON 以 mapping ID
关联实际 installed entrypoint、required asset digests、closed raw decision schema、
normalization 与 mapping reviewer。示意形状：

```json
{
  "case_id": "dangerous_shell_or_git.rm_home.positive.v1",
  "corpus_version": 1,
  "failure_class": "dangerous_shell_or_git",
  "mapping_id": "claude.pre_bash.dangerous_shell.v1",
  "fixture": {}
}
```

这只是字段形状；具体 reason ID、样本数量与两个未决类别的 executor 必须由维护者审核，
不能照示例猜。schemas 额外拒绝 duplicate JSON keys、未知字段/枚举、空 ID、绝对路径、
`..` traversal、shell executor 与含 credential-like 字段的 fixture。审核身份按 B-026
强制分离：ground-truth reviewer 与 fixture/detector/mapping authors 独立；mapping
reviewer 与 detector/mapping/fixture authors 独立；dangerous mapping 另有独立 security
reviewer。schema + ledger gate 验证 reviewer IDs/roles 与 review evidence，任何重叠都在
执行前 unavailable；样本数可以由产品选择加强，但不得降低该 floor。

构建时分别 canonicalize 并计算 corpus、ground truth、production mapping、protocol 的
SHA-256。`corpus_ledger.json` append-only 记录它们的 version→digest tuple。validator
将已发布 ledger prefix 与当前文件逐条比较：已有 version 的 digest 变化、历史项删除/
重排、旧 version 复用或 ledger 未覆盖 embedded inputs 都失败。新 release 复用完全相同
tuple 合法；任何内容变化都必须 append 新 version tuple。

每个 failure class 使用 positive/negative matched pair，尽量只改变被研究信号。runner
在执行前 join 三份 artifacts，再按 class/ground-truth 做 completeness、唯一性、
production mapping、mapping asset existence 与审核独立性检查。orphan、duplicate 或
many-to-one ambiguity 都失败。任何失败发生在创建 sandbox 或调用 detector 前；detector
实际输出永远不能改写 ground truth/mapping/ledger。

### 3. Production executor registry

Rust `bench` 内部建立封闭 executor registry，而不是让 corpus 提供任意 command：

- `installed_wrapper`：仅解析 verified receipt + mapping 中登记的实际 installed
  `run-hook.sh` / `run-hook-codex.sh`，使用参数数组 spawn；
- `payload_guard`：只允许 manifest 中预注册的固定脚本 ID，使用参数数组执行，不经
  `sh -c`/字符串拼接；
- 不提供 `command`、`shell`、任意 path 或 plugin executor。

`dangerous_shell_or_git` fixture 只作为 hook stdin 分类，绝不执行 payload 中的 command。
file/project fixtures 先在专用 temp root materialize 合成文件，再通过 installed
wrapper/payload guard 运行 canonical pre/post/stop path。每个 versioned adapter 只接受
mapping 声明的 raw decision JSON/exit 与 raw reason-code 闭集，并把二者唯一映射为
`{block, advisory, allow}` + canonical reason code。unknown/malformed/ambiguous/multiple
decision 或 reason、缺失 reason，以及任何 free-text/substr/regex reason guessing 都产生
独立 `case_status: execution_error`，normalized decision/reason 留空；它不进入
decision/headline numerator，但仍留在 ground-truth denominator 并使 axis inconclusive。

当前 production mapping：

- dangerous shell/git → runtime pre-bash classifier（已核实）；
- duplicate module/definition → runtime post-write scan（已核实，最终 fixture 语义需审核）；
- unverified done claim → stop orchestrator 的 verification-evidence detector（已核实）；
- invented API → **待维护者确认**：现有锚点只证明不存在 path/edit target，不证明
  dependency/API inventory；Recommended proposal（未批准）要求先合并真正可复用的
  production inventory detector；
- swallowed exception → **待维护者确认**：当前 canonical checker 是 pytest-shaped
  Python guard；Recommended proposal（未批准）是抽成无 pytest runtime 依赖、production
  与测试共用的 released AST guard。

实现不得在 unresolved mapping 下先造两个 Rust benchmark-only regex。若产品选择新增
production detector，那是可复用 production capability，必须另行满足 runtime/spec/test
门，再由 corpus 引用。

### 4. Isolation、security 与 cancellation

runner 为每次运行创建权限收紧的专用 temp root：

- HOME、logs、project、git repo、outputs 全指向 temp 子目录；
- child env 从最小 allowlist 构造，不继承 token、proxy、credential 或用户
  `VIBEGUARD_*` overrides；
- fixture 路径全部在 canonicalized temp root 下，拒绝 symlink、hard-link escape、
  absolute path 与 traversal；
- payload executors 关闭 stdin 继承，设置 timeout，stdout/stderr 有大小上限；
- report 只保留 normalized decision、closed error category 与 synthetic case ID；
  原始 payload、用户路径、env 和任意 child stderr 不持久化。

在启动效果 case 或 latency warmup 前，materializer 只按 verified receipt/manifest 的
闭集文件清单，把 runtime、payload、wrappers、配置与 manifest 复制到 temp HOME 下与
生产安装完全相同的相对布局。复制后逐文件重新计算 digest/size，校验 receipt、拒绝
symlink/hard-link/extra executable，并把 install tree 设为只读；wrapper 的 HOME 与解析
路径只指向该 snapshot。materialization、permission tightening 与 digest verification
全部发生在计时区间外。缺文件、布局差异、可写文件或 digest drift 时零 timed sample
并 unavailable，绝不回退真实 HOME、checkout、mock 或 PATH。

一个 interruption token 阻止启动后续 case；当前 child 被终止并回收。partial report
写入 caller 显式路径或本次 temp 中的唯一文件，然后执行记录式 cleanup。cleanup 只允许
删除启动时创建并验证过的精确 temp root；失败时追加 closed cleanup error，绝不扩大路径。

并发运行使用随机 run ID + exclusive-create output；已存在 output 非覆盖报错。official
mode 不写 project/global event log，不读取前次报告。

### 5. Deterministic effectiveness protocol

执行协议由 embedded corpus metadata 固定：

1. preflight 全量验证；
2. 按 case ID 排序，在 run A 执行全部 cases；
3. 用全新 sandbox 按同序执行 confirmation run B；
4. 对每 case 比较 normalized decision/reason classification；
5. 一致后才聚合完整 confusion matrix 和每类分项。

`decision_digest` 的 canonical payload 只包含所有 native platforms 共同的 source
commit、corpus/ground-truth/mapping/protocol versions+digests、获批的
`required_platforms`、`interception_decisions`、按 case ID 排序的 ground truth +
normalized decision/canonical reason code
和 aggregate counts；排除 target-specific binary/payload/wrapper digest、OS/arch、
latency、timestamp、temp path。A/B `decision_digest` 或 case decision 不同即
effectiveness `inconclusive`，两次证据都保留在有界报告中。release matrix 只对
`required_platforms` reports 使用 `decision_digest` 做跨平台一致性 gate；非 required
reports 不进入该 gate。

`evidence_digest` 在每个平台报告完成后计算，canonical payload 是“完整 report 去掉
`evidence_digest` 字段本身”，因此绑定 `decision_digest`、current-exe/release-manifest/
payload/wrapper identities、target、完整 `required_platforms`、本 target 的 `required`
boolean、两个 axis 状态、latency/environment 与 schema。
不同 native targets 的 `evidence_digest` 正常应不同，不能做 equality gate。

`execution_error` 不属于 decision 闭集或 headline numerator，但对应 case 仍留在
positive/negative denominator，同时使 effectiveness `inconclusive`。聚合层集中计算
TP/FN/FP/TN、block/advisory counts 与 diagnostic rates；只有 axis `valid` 时 renderer
才能把 rate 显示为 headline。human、JSON、README 不得各自重算。

### 6. Latency protocol

新增 surface 名 `bench_case_e2e_ms`，避免与现有 CI `hook_e2e_ms` 混淆。每个 sample
必须从 B-030 已重验的 readonly production-layout snapshot 解析 actual installed
wrapper，以
`Command::new("bash").args([wrapper_path, fixed_hook_name])` 等参数数组方式 spawn 子进程，
传 fixture stdin 并等待 stdout/stderr/exit 完整返回。禁止 direct Rust function、
checkout hook、mock wrapper、PATH fallback 或只测 `bench` dispatcher。对每个 production
surface：

- 先运行固定的 process/spawn baseline 与 clock sanity check；
- warmup 和 measurement counts 从已审核、embedded protocol 读取，均须正整数；
- 单调时钟包围 installed wrapper subprocess 的 spawn-to-complete，不含 sandbox
  materialization/report render；
- 输出 P50/P95/P99/max、runs、platform、runtime/payload identity 和 baseline；
- environment threshold 沿用已发布 protocol 字段，不从用户环境或 README 读取。

效果 A/B run 与 latency sample batch 分开，避免 confirmation 次数意外改变效果分母。
wrapper path/digest drift 在 sampling 前使 latency `unavailable`；sample error/distortion
使 latency `inconclusive`。README latency cell 仅在 axis valid 时显示数值，否则破折号 +
状态/reason，不写 `0ms`。现有 hook SLA 仍由 `tests/bench_hook_latency.sh` 管理，本 issue
不新增或修改 pass budget。

### 7. Report、schema 与 exit semantics

内部 `BenchReport` 是唯一 aggregate；text、JSON 与 README summary 共享它。report 顶层
至少包含：

- `schema_version`, `official`, top-level `status`, `failure_categories`；
- actual current-exe/release-manifest/payload/wrapper/corpus provenance；
- `interception_decisions`、production-mapping identity、protocol digest、
  `required_platforms` 与本 target 的 `required` boolean；
- effectiveness axis status、A/B + cross-platform `decision_digest`、confusion matrix、
  per-class metrics；
- latency axis status、environment、per-surface metrics；
- platform-bound `evidence_digest`；
- case-level normalized evidence（无 raw payload/stderr）；
- interruption/cleanup metadata。

report schema 使用 `additionalProperties: false` 保护闭集；reader 按显式 version
dispatch。两个 axis 状态各为 `{valid, unavailable, inconclusive}`。top-level 是不读取
stage 的纯 3×3 function：`valid/valid→valid`、`unavailable/unavailable→unavailable`、
其它七种组合→inconclusive。旧版本映射不存在就报 unavailable，不做 duck typing。CLI
top-level valid 为 0，其它状态非零；`--json` stdout 只输出 JSON，diagnostic 到 stderr
且同样脱敏。README 每 cell 读取 axis status，不根据 top-level 猜数值。

### 8. Release regeneration 与 README

调整 release DAG，使官方报告来自 staged、将要发布的 artifacts：

1. build runtime 与 GH-699 payload/receipt fixture；
2. native matrix 下载准确 target binary + payload，先通过 `current_exe` identity chain，
   再从 actual merged launcher 运行 `bench --json`；
3. 每个平台 schema/provenance/axis gate；release summary 只选择 approved
   `required_platforms` 的 native reports 并比较其 `decision_digest`，`evidence_digest`
   只作各平台 artifact identity；
4. 仅聚合 required set 并生成 checksums；required reports 全 valid 且 decision digest
   一致时生成 valid summary，否则生成 non-valid candidate summary；非 required reports
   作为 display-only 附件，不改变 summary status；
5. 只有 valid 或获批 `publish_nonvalid` 分支可运行 `publish-release`，一次性发布
   binary、payload、checksums、manifest 与对应 benchmark reports；仍保留“release 已
   存在则拒绝变更”。

required target 不能原生执行时显式 `unavailable` 并使 summary non-valid；非 required
target unavailable 只展示、不阻断。不得用 host/cross binary 贴 native 目标标签；若
approved set 含四 target 就必须配置四个 native runners。required platforms 的
effectiveness decision 应一致，差异使 summary `inconclusive`。latency 永远按平台分行。

获批 `release_policy` 必须来自闭集 `{block_release, publish_nonvalid}`；缺失/越界值直接
阻断且不能猜。Recommended proposal（未批准）选择 `block_release`。两个分支共享
schema/provenance gate，但发布动作闭合如下。

effective action 为 `block_release` 时（包括 selected policy 是 `publish_nonvalid` 但
mandatory non-valid report/evidence 未通过 schema/provenance gate），matrix wrapper
捕获 bench 非零状态但暂不退出，先：

1. 写出 schema-valid candidate failure report，以及包含 candidate tag/source commit、
   target、`run_id`/`run_attempt`、selected policy/effective action、axis/top-level、closed
   failure/reason codes、report/evidence/checksums/provenance 的 schema-valid canonical
   failure manifest；
2. 对包含 `run_id`/`run_attempt` 的完整 canonical manifest 计算
   `failure_manifest_digest`，再打包 report、manifest 与 checksums；
3. 使用名称
   `benchmark-failure-<tag>-<target>-<run_id>-<run_attempt>-<failure_manifest_digest>.tar.gz`，
   以 no-overwrite artifact upload 保存；同时以
   `(run_id, run_attempt, failure_manifest_digest)` 为 predicate/ledger identity，把
   **完整 canonical failure manifest 内容**内嵌到不可覆盖、
   retention-independent 永久可检索的 attestation predicate（或等价 append-only
   immutable ledger），并以 bundle digest 为 subject；只写 pointer/digest/job summary
   不合格；
4. 把 artifact ID/digest、attestation subject 与 closed reason code 写入 job summary；
5. 最后返回原 benchmark failure，确保 publish-release 不运行。

workflow retry 必须带相同 `run_id` 下的新 `run_attempt`（新 workflow run 则使用新
`run_id`）；即使 report/evidence bytes 相同，manifest digest、artifact name 与长期
predicate/ledger identity 也必须因 attempt identity 不同而不同，不能覆盖旧 bundle 或
predicate。bundle 即使在 retention 后不再可下载，验证者仍能从长期 predicate/ledger
取回每个 attempt 的完整 manifest，复算 canonical digest 并复核具体内容/reason。失败
candidate 不创建 GitHub Release、release page/assets 或 README candidate current row；
旧 row 仅保留其原 release 身份。

`publish_nonvalid` 则必须先发布该 candidate 的 schema-valid non-valid report/evidence，
再创建同版本 README row：每个 non-valid axis cell 为空并显示 status、closed reason code
及 immutable report link，row top-level 非 valid 且不带 `current valid benchmark`。它不
创建 B-029 的 blocked-candidate record，也不得把旧 release 数字贴到新 row。任一
mandatory evidence 未通过 gate 时，此分支不得部分发布，必须记录 selected policy 后转入
B-029 的 effective block action。

README 使用 marker 管理的生成区。source 必须是该 exact release 的不可变已验证 summary：
valid branch 消费 valid summary，`publish_nonvalid` 消费同版本 non-valid summary，
`block_release` 不生成 candidate row。由于当前 release asset 不允许原地变更，推荐
post-release CI 从不可变 asset 生成一个独立 README PR，保留 human review，不直接 push
高上下文文件。PR 同时更新英文 README 与已配置 locale 文档。generator 对每个平台
独立显示：

- effectiveness valid → rate/FPR；否则 `— (effectiveness: <status>: <reason>)`；
- latency valid → P95；否则 `— (latency: <status>: <reason>)`；
- row status 始终为共享 top-level；
- only top-level valid row 可带 `current valid benchmark` 标识。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 released one-command official mode | CLI registration + actual merged GH-699 launcher/payload smoke | release-install fixture discovers the installed launcher rather than hard-coding a spec path; without `.git`, cargo, Python eval or API key it runs `vibeguard bench --json`; missing launcher is unavailable |
| B-002 complete matched provenance before execution | release identity receipt + preflight | negative matrix for missing/empty/mismatched current-exe, tag, commit, target, protocol/required-platforms, corpus/payload/wrapper digest asserts unavailable and zero executor calls |
| B-003 five classes with both polarities | corpus schema + completeness validator | corpus mutation tests remove each class/positive/negative side one at a time and assert preflight failure |
| B-004 reviewed immutable ground truth | separate fixture/ground-truth/mapping parsers | duplicate-key/ID, orphan joins, unknown enum, conflicting label, non-independent review and changed-content-same-version fixtures are rejected |
| B-005 production paths only | sealed executor registry | mutation test replaces each executor with unknown/test-only ID and asserts zero cases; code review confirms no case-ID detector branch |
| B-006 closed normalized decisions and declared interception subset | versioned decision adapter + protocol config | exhaustive raw→normalized enum tests prove execution_error has no decision; missing/empty/out-of-range headline subset is rejected |
| B-007 complete denominator and metrics | one aggregate module | table-driven TP/FN/FP/TN cases including timeout/error prove errors stay denominator but never enter numerator/counts |
| B-008 honest statuses | axis state machines + top aggregator | exhaustive axis status/error fixtures prove each axis emits only the closed status set and never renders non-valid as zero/pass |
| B-009 deterministic confirmation | dual-run executor + `decision_digest` | injected A/B reason/decision/order drift names exact case and produces nonzero inconclusive; latency/current-exe platform identity does not alter decision digest |
| B-010 idempotent/concurrent isolation | run context + exclusive output | two parallel process tests use disjoint roots/reports; sentinel install/repo/log files remain byte-identical |
| B-011 end-to-end latency semantics | actual installed-wrapper subprocess sampler | spy wrapper proves every timed sample spawns wrapper, drains full IO/exit, includes startup, excludes sandbox/warmup/report |
| B-012 distorted latency honesty | environment baseline + axis status | bad clock, zero runs, spawn distortion and sample error all blank headline latency without inventing zero; effectiveness axis remains independently evaluated |
| B-013 synthetic sandbox/privacy | sandbox/env builder + redactor | dangerous-command execution sentinel remains untouched; secret/path/env sentinel absent from stdout/stderr/JSON and child env capture |
| B-014 interruption and bounded cleanup | cancellation token + cleanup ledger | interrupt during case N stops N+1, writes partial nonzero report, removes only recorded temp root and preserves adjacent canary |
| B-015 shared human/JSON aggregate and exits | renderers + report schema | golden semantic comparison between text/JSON/README summary; schema and exit matrix cover every axis/top-level combination |
| B-016 staged exact release regeneration | release workflow + current-exe/report provenance gate | `bash tests/test_release_workflow.sh` plus fixture manifests prove workspace/debug/old/wrong-target binary cannot publish or satisfy a required native slot |
| B-017 generated README table | report-to-doc generator | axis-status golden matrix generates numeric or blank cells exactly once; manual numeric drift fails freshness |
| B-018 closed release-policy branches | release/README policy fixtures | exhaustive fixtures prove block creates no Release/page/assets/current row after permanent evidence, publish_nonvalid creates only same-version non-valid evidence/row, its evidence-gate failure enters effective block, and missing/unknown policy blocks |
| B-019 explicit schema compatibility | versioned parsers | current/legacy/unknown schema fixtures prove only declared mapping loads; unknown version nonzero unavailable |
| B-020 unofficial isolation | CLI option policy + README ingest gate | custom/dev report carries `official:false`, uses separate path and is rejected by README generator |
| B-021 verified current-exe identity chain | planned **vibeguard-runtime/src/bench/identity.rs** + release identity receipt | missing/checksum-only provenance is never official; replace/tamper/symlink/PATH/argv0/metadata-race matrix proves opened current-exe bytes match verified attestation+manifest+receipt before executor calls |
| B-022 split decision/evidence digests | canonical digest builders | required-set mutation changes both digests; same protocol/decisions on two required targets yields equal decision digests and unequal evidence digests; latency/binary mutation changes only evidence |
| B-023 axis/top-level/README total function | shared status aggregator + README renderer | exhaustive 3×3 axis golden asserts top-level and each metric cell/status/reason with no stale numeric value |
| B-024 real wrapper subprocess E2E | mapping resolver + latency executor | installed wrapper spy records argv/stdin and child completion; direct function, checkout wrapper, PATH fallback and digest drift are rejected |
| B-025 decision/reason closure and execution-error exclusion | mapping adapter + aggregate | exhaustive unknown/missing/multiple decision and reason fixtures plus free-text heuristic attempts create no normalized values/numerator, remain denominator and force inconclusive |
| B-026 independent ground truth and mapping | artifact schemas + reviewer gate | every forbidden author/reviewer overlap, missing security reviewer and unverifiable review evidence fails preflight; mapping content change requires new version/digest |
| B-027 immutable version→digest ledger | ledger validator + release contract | mutation suite changes/deletes/reorders/reuses every historical tuple and asserts build/release failure; exact tuple reuse passes |
| B-028 partial GH699 dependency | no-clone install/launcher discovery fixture | main fixture accepts merged T1/T2 payload contract but remains unavailable until T3–T6 actual launcher/native smoke exist; spec-only paths cannot satisfy it |
| B-029 immutable per-attempt blocked-release evidence | failure manifest/attestation + release DAG | two retries with identical report bytes produce distinct run/attempt-bound manifest digests, artifact names and predicates; deleting bundles still permits per-attempt recovery; Release/current-row sentinels stay absent |
| B-030 readonly production-layout snapshot | install materializer + wrapper executor | byte/layout/permission/digest mutation matrix fails before timed samples; spy proves materialization is outside timer and real wrapper runs from readonly temp HOME without touching source install |
| B-031 approved required-platform summary gate | protocol + release summary aggregator | set validation covers empty/duplicate/unsorted/unknown entries; exhaustive matrix proves only required native reports affect gate, display-only unavailable does not, and four-required configuration needs four native runners |

## Affected-file / test / command map

下表是 implementation 的预期 ownership map；GH-699 尚未合并的真实 launcher path 标为
“merge 后探测”，不猜文件名。若实现发现路径不同，先更新 tasks/tech anchor 再改代码。

| Concern | Planned affected files | Focused proof |
| --- | --- | --- |
| CLI + module split | `vibeguard-runtime/src/main.rs`, planned **vibeguard-runtime/src/bench/mod.rs**, **model.rs**, **corpus.rs**, **identity.rs**, **mapping.rs**, **runner.rs**, **metrics.rs**, **latency.rs**, **render.rs**, **sandbox.rs** | `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench` |
| Handle-backed SHA-256 | `vibeguard-runtime/src/setup_support.rs`, planned **vibeguard-runtime/src/bench/identity.rs** | known binary digest + replace-during-read test; no OS shell hash command |
| Corpus truth/mapping/ledger | planned **data/public_benchmark/**, the five **schemas/public_benchmark_*.schema.json** files, **scripts/ci/validate_public_benchmark.py** | schema positives/negatives + append-only ledger mutation suite |
| Installed release receipt | planned **schemas/release_identity.schema.json**, `scripts/setup/runtime-install.sh`, `scripts/setup/install.sh`, `scripts/ci/generate_runtime_release_manifest.py` | install fixture recomputes current binary/payload/wrapper digests and rejects tampered receipt/assets |
| Actual launcher | **待 GH-699 implementation merge 后由 no-clone fixture 探测并记录**；不得先写 guessed shim path | fresh HOME install invokes discovered user command and proves it reaches the same current-exe digest |
| Wrapper E2E | actual installed `~/.vibeguard/run-hook.sh`, `run-hook-codex.sh` contracts; production code materialize byte-identical readonly temp snapshot，不复制 detector | layout/digest/permission matrix + subprocess timer spy + existing `bash tests/test_hook_perf_contract.sh` |
| Report/readme | planned **schemas/public_benchmark_report.schema.json**, **scripts/ci/render_public_benchmark.py**, `README.md`, configured locale README | 3×3 axis golden; generated marker freshness; invalid axis has no numeric cell |
| Release/failure evidence | `.github/workflows/release.yml`, planned **scripts/ci/package_benchmark_evidence.py**, `tests/test_release_workflow.sh` | forced block uploads content-addressed attested bundle then fails; publish step absent |
| End-to-end regressions | planned **tests/test_public_benchmark.sh**, **tests/fixtures/public_benchmark/** | official/unofficial, identity, five classes, privacy, concurrency, interruption, digests, wrapper latency and release sentinels |

Implementation completion commands:

```bash
cargo fmt --manifest-path vibeguard-runtime/Cargo.toml -- --check
cargo check --manifest-path vibeguard-runtime/Cargo.toml
cargo test --manifest-path vibeguard-runtime/Cargo.toml
bash tests/test_public_benchmark.sh
bash tests/test_behavior_eval.sh
bash tests/test_hook_perf_contract.sh
bash tests/test_release_workflow.sh
bash scripts/ci/validate-doc-paths.sh
bash scripts/ci/validate-doc-command-paths.sh
bash scripts/local-contract-check.sh --quick
```

planned **tests/test_public_benchmark.sh** 的最终产物断言不能只看 exit 0，必须同时证明：

- canary user repo/HOME/global+project logs/install receipt/installed wrappers 在前后
  byte-identical；timed wrapper 来自 byte-identical readonly temp snapshot 且其
  materialization events 全在 timer start 前；
- dangerous fixture 的 execution sentinel 文件始终不存在；
- secret/path sentinels 不出现在 human stdout、stderr、JSON report、failure bundle、
  release summary 或 generated README marker；
- report 通过 schema，`current_exe_sha256` 匹配实际执行文件；required set 同时进入
  protocol/decision/evidence digests，summary 只受 required native reports 影响；
- block_release candidate 的长期 predicate/ledger 可在删除短期 bundle 后恢复完整
  per-attempt failure manifest/reason 并复算 digest；相同 report 的 retry 仍有不同
  run/attempt-bound identity。最终 workflow 非零且 Release/current-row sentinel 均不存在；
  publish_nonvalid fixture 则只产生同版本 non-valid report/row。

## 数据流

```text
release source commit
  ├─ embedded corpus + truth + mapping + ledger ──> staged runtime binary
  └─ GH-699 merged T1/T2 ──> payload contract
        future T3–T6 ──────> bootstrap + native smoke + actual launcher
                 │                              │
                 └──────── current_exe/payload/wrapper identity chain
                                                │
                                                ▼
                         preflight (digests + schemas + joins + review gates)
                 │
 readonly production-layout snapshot wrappers: isolated run A ── isolated run B
                 │             │
                 └── semantic comparison
                              │
        effectiveness axis + real-wrapper latency axis
                              │
                      canonical BenchReport
                       ├─ cross-platform decision_digest
                       ├─ platform evidence_digest
                       ├─ human renderer
                       ├─ JSON + schema gate
                       └─ required-platform summary gate
                            ├─ valid ──> valid summary/row ──> publish
                            ├─ non-valid + block_release
                            │      └─ permanent per-attempt failure manifest
                            │            └─ job failure (no Release/current row)
                            └─ non-valid + publish_nonvalid
                                   └─ non-valid summary/row ──> publish
```

没有网络调用或用户数据输入。持久化面只有 caller 选择的本次 report 与 release CI
artifact；temp fixtures/logs 在本次 run 内清理。README 只消费已发布、digest-matched
summary，不消费本地 stdout。

## 备选方案

- 直接包装 `eval/run_behavior_eval.py`：拒绝。它依赖 checkout/Python、读取 repo-relative
  scripts，不能满足 B-001/B-016。
- 扩展 `scripts/benchmark.sh`：拒绝。它的 score/model 模式与 public deterministic
  confusion-matrix contract 不同，混名会制造证据漂移。
- 把所有 detector 重写进 benchmark module：拒绝。benchmark-only detector 会验证自身，
  违反 B-005；只有独立批准的 production capability 才能成为 executor。
- release 时只上传数字、不上传 case/provenance report：拒绝。用户无法验证 denominator、
  corpus identity 或 unavailable 原因。
- 一个跨平台平均 latency：拒绝。平台差异会被平均值隐藏。

## 风险

- Security: dangerous fixture 被误执行、child env 泄密、temp cleanup 越界。缓解：
  sealed executor、参数数组、最小 env、classifier-only dangerous cases、canonical temp
  root 与 canary tests；该面触及 command execution，按 SEC-11 要求 human security review。
- Compatibility: GH-699 payload T1/T2 已合并，但 bootstrap/native smoke/launcher 尚未
  实现，schema 也会演进。缓解：明确 partial dependency、merge 后 launcher discovery、
  version dispatch、digest matching，无 spec-path/checkout/PATH fallback。
- Identity: binary 自报 metadata 或 receipt drift 会制造 official 假象。缓解：
  handle-backed `current_exe` digest → release manifest/attestation/receipt 链，以及
  payload/wrapper byte digests；自报字段只作一致性检查。
- Performance: 双效果运行加独立 latency batch 会增加 release CI 时间。缓解：corpus
  固定有界、matrix 按 native target；具体样本数由维护者审核，不能为提速静默删分母。
- Maintenance: ground truth 与生产 detector 可能漂移。缓解：independent ground truth、
  versioned production mapping、append-only version→digest ledger、每 release regeneration。
- Audit retention: blocked release 没有 GitHub Release asset。缓解：退出前把完整
  schema-valid failure manifest 内嵌进长期不可覆盖 attestation predicate/ledger；
  content-addressed bundle 只是短期副本，retention 到期仍可恢复内容/reason 并复核 digest。
- Product truthfulness: invented API/swallowed exception 当前 mapping 不完整。缓解：
  spec approval 明确决策；未决时 unavailable，不写 placeholder detector。

## 测试计划

- [ ] Unit tests: split corpus/truth/mapping schemas、duplicate-key/join/completeness、
      append-only ledger、handle-backed current-exe identity、raw decision/reason closure、
      3×3 axis aggregation、required-platform set/summary aggregation、confusion matrix、
      两个 report digest builders、per-attempt failure-manifest digest、quantiles、
      redaction、cancellation 与 path containment。
- [ ] Integration tests: released-install fixture 执行五类正/负 cases；wrong
      current binary/payload/wrapper/receipt/corpus/mapping、detector error、timeout、
      environment distortion、parallel runs、interruption、legacy schema 和
      secret/canary/execution sentinels；E2E sample 必须由 readonly production-layout
      snapshot 中的 installed wrapper spy 观察到，materialization 在 timer 外。
- [ ] Release contract: staged native binaries各自产出 schema-valid report；matrix 比较
      decision digest 而非 evidence digest；non-valid candidate 先上传唯一 attested failure
      manifest 长期 predicate/ledger 再失败；相同 report retry 仍产生独立 attempt
      identity，删除短期 bundle 后仍可复核；另一 policy 只发布同版本 non-valid
      evidence/row；required/display-only target matrix 与 existing-release mutation
      均受测试。
- [ ] Documentation: 3×3 axis generator golden/freshness、英文与配置 locale 一致、仅 valid
      metrics 显示数字，README links 指向 immutable release evidence。
- [ ] Existing regression:
      `cargo check --manifest-path vibeguard-runtime/Cargo.toml`；
      `cargo test --manifest-path vibeguard-runtime/Cargo.toml`；
      `bash tests/test_behavior_eval.sh`；
      `bash tests/test_hook_perf_contract.sh`；
      `bash tests/test_release_workflow.sh`；
      `bash scripts/local-contract-check.sh --quick`。
- [ ] Manual verification: 在无 checkout、无 Cargo/API key 的新 macOS/Linux release
      install 各运行一次**实际探测到的 launcher**，核对 current-exe identity chain、
      两类 digest、axis/top-level/cells、无用户数据访问与 per-platform latency 分行。

## 回滚方案

- 在 GH-699 actual launcher/receipt 尚未合并或尚无 valid report 时，不把 runtime
  开发入口标 official；它保持 `unofficial`/`unavailable`。
- 若某 release 的 runner/corpus/report 有缺陷，发布更高版本修复并生成新 corpus/report；
  不删除或原地改写旧 release evidence，在 README 将受影响版本标为 invalid 并链接原因。
- README 生成区可通过回滚生成 PR 恢复到最后一份**明确标注版本**的报告，但不得把该旧值
  标为当前 release。
- runner 回滚不修改现有 hooks/guards policy；GH-686、behavior eval、
  `scripts/benchmark.sh` 与现有 latency SLA 继续独立工作。
- 回滚 release workflow 时保留既有 failure bundles/attestations 与 ledger history；
  禁止通过删除历史 tuple 或覆盖 artifact“清理”失败证据。
