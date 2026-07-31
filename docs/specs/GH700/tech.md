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
- planned schemas：**schemas/public_benchmark_protocol.schema.json**、
  **schemas/public_benchmark_corpus.schema.json**、
  **schemas/public_benchmark_ground_truth.schema.json**、
  **schemas/public_benchmark_production_mapping.schema.json**、
  **schemas/public_benchmark_report.schema.json**、
  **schemas/public_benchmark_summary.schema.json**、
  **schemas/public_benchmark_review_record.schema.json**、
  **schemas/public_benchmark_failure_manifest.schema.json** 与
  **schemas/release_identity.schema.json**；
- Rust 实现拆到 `vibeguard-runtime/src/bench/`，`main.rs` 只注册 `bench` 命令；
- corpus/ground truth/mapping/ledger 以构建期只读资源编进 release binary，runner 不从
  cwd 或用户可写路径寻找 official inputs；
- 需要 shell/Python guard 的 case 只从 GH-699 同 tag、digest-matched payload 调用。

versioned benchmark protocol 还必须记录 approved `required_platforms`、
protocol-owned canonical benchmark config identity、每个 effectiveness case 的
initial-state identity，以及每个 latency surface 的 ordered case IDs + warmup/measurement
repetition schedule。canonical config 是随 release 只读发布、由 protocol digest 绑定的
固定 benchmark config；用户 `~/.vibeguard/config.json` 与 tuning 永不进入 official
snapshot。required set 非空、去重并 canonical 排序；每个平台 report 同时记录完整 set 与
本 target 的 `required` boolean。protocol 未获批或任一 config/state/schedule/set 非法时
official preflight unavailable，不允许 runner/workflow 临时选择 workload 或用户设置。

同一 protocol 还拥有不可由 runner 默认的 `executor_limits` 与唯一身份真源
`production_asset_registry`。前者按 executor ID 固定正整数 timeout/grace/stdout/stderr
caps；后者按 target + logical ID 闭集登记 payload、wrappers、canonical
config、environment-baseline workload、interpreters 与每条 mapped production path
传递闭包内全部 external executables，并固定 kind、来源
`{release_payload, authenticated_host}`、asset/path ID、size、SHA-256、version、exec/argv
contract。signed manifest 只直接声明并绑定 target runtime asset identity，同时绑定
approved protocol digest 与 registry digest；其它资产 identity/exec/argv contract
只由 registry 声明。production mapping 只保存 adapter semantics 并引用 logical ID，
receipt 只映射 logical ID 到本地 path/handle，不得复制或覆盖 identity。registry/limits 都
进入 protocol canonical bytes/digest 与 report provenance；缺项、重复 ID、非正 limit、
未知 kind/source、digest/version/exec-closure mismatch、ambient PATH 或环境 override 均在
零 case 时令 official unavailable。

installer 必须写 versioned `~/.vibeguard/installed/release-identity.json` receipt。它保存
release repo/tag/source/target、signed manifest 与 `production_asset_registry` digest、
registry logical-ID→本地 path/handle mapping、attestation bundle path/digest、pinned
trust-root set/version，不复制 asset identities。verified installer 还必须
持久化完整 attestation bundle（certificate/signature/transparency inclusion proof）与
签名 release manifest；offline verifier 用 binary 内置/版本钉住的 trust roots 重验 bundle
签名、issuer/workflow/repo/source/subject，再由 signed manifest 绑定 exact protocol/
registry digests。receipt 只映射 registry logical IDs 到本地 handles，不能靠可改写字段自证。
现有 `runtime-provenance` 可继续供兼容显示，但不能单独建立 official 身份。

真实 HOME 只通过一个身份专用的 preflight reader 访问。reader 以 no-follow 打开固定
receipt，要求 regular file、当前用户 ownership、非 group/world writable、canonical
parent 与 expected schema；离线验证 persisted attestation bundle + signed manifest 后，
只按 `production_asset_registry` 逐个 no-follow 打开 payload/wrappers、canonical
config、baseline workload、interpreters 与全部 transitive external executables，
不读取用户可变 config，不枚举目录、不接受未声明绝对路径/`..`/hard-link/symlink，也不
开放任意读取 API。每个 handle 在 hash 前后重验 metadata，materializer
只消费这些已验证 handles/bytes。snapshot 完成即关闭身份通道；executor、
warmup 和 timed sample 不再访问真实 HOME，所有真实 HOME 路径必须从 report/redacted
diagnostic 中移除。receipt/registry 任一身份/权限/类型/路径检查失败时零 case
`unavailable`。

`bench` 身份 preflight 的顺序是：

1. 分发链先提供独立受信的最小 native launcher；它必须由待执行 runtime 之外的
   platform/package provenance 认证。shell script、receipt 或 child 自报不能充当 trust root；
2. trusted launcher 在执行 runtime 前离线验证 persisted attestation bundle 到 pinned
   trust root，并验证 signed release manifest 的 repo/issuer/workflow/tag/source/subject；
3. launcher 按 signed manifest no-follow 打开 target runtime，流式计算 size/SHA-256并
   比较 hash 前后 metadata；只有与 manifest target asset 完全匹配后，Unix 才能从同一
   handle `fexecve`/`execveat(AT_EMPTY_PATH)` 并传入只读 duplicate identity fd，Windows
   才能从 deny-write/delete executable handle 启动并持有至 child handshake。不支持
   trusted-launcher 或 mapped-image/handle binding 的平台 official unavailable；
4. child 从 inherited binding handle 再算 SHA-256并比较前后 metadata，只作 defense in
   depth；`current_exe` pathname 只作 diagnostic，不建立首次信任。start-then-replace
   pathname race 必须 fail closed；
5. `production_asset_registry` 内 payload、embedded inputs/config、baseline workload、
   actual wrappers、interpreters 与全部 external executables 各自重算 digest/size，全部
   匹配 manifest/protocol/同 tag/source commit；receipt 仅提供本地 path mapping；
6. build-time version/tag/commit 只作额外一致性断言，不能替代 launcher 在 exec 前建立的
   current-bytes chain。

official mode 强制要求 `verified-provenance`；当前允许的 `checksum-only` install 仍可
跑诊断，但只能标 `unofficial`。这是 B-021 的安全 floor，不是待选产品 proposal。

GH-699 是 partially implemented public done-when dependency，不是可静默 fallback。
PR #711 的 merged T1/T2 payload contract 是当前 source of truth；只有后续 merged T3–T6
提供 bootstrap、no-clone native smoke 与 actual launcher 后，GH700 integration fixture
才冻结真实 launcher path/argv。GH700 在探测出的每个 manifest-declared distribution
launcher 上增加 `bench` dispatch contract：Homebrew/npm 等入口必须把剩余 argv、stdin、
stdout、stderr、exit code 透明转发到同一 verified runtime，不得落入 bootstrap/setup/init。
tasks 文本、payload setup、仅 launcher 存在或猜测的 `vibeguard` shim 都不是 evidence；
不得搜索相邻 checkout或回退 PATH 同名脚本。no-clone fixture 要逐入口验证
`bench --json`、unknown bench arg 与 nonzero exit passthrough。

### 2. Corpus 与 ground truth

fixture JSONL 不携带 ground truth 或 executable path；每行只保存稳定 case ID、
failure class 和合成 fixture。独立 ground-truth JSONL 以 case ID 关联
`positive|negative`、matched pair、审核人/证据；production-mapping JSON 以 mapping ID
关联实际 installed entrypoint、required asset logical IDs、closed raw decision schema、
normalization 与 mapping reviewer，并拒绝 registry 外的 digest/size/version/path identity。示意形状：

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
reviewer。protocol/release manifest 钉住 maintainer-controlled reviewer roster 的
attested digest；roster 把不可变 identity key/OIDC subject 映射到允许 roles。每条 review
record 使用 roster identity 签名并绑定 artifact canonical digest、role、decision、
source commit 与 timestamp。schema + verifier 验证 roster/record bundle、key/subject、
role 与 overlap；不同自报 ID 但同一 key/subject 仍视为同一人，distinct-fake-ID mutation
必须失败。任一认证或独立性失败都在执行前 unavailable；样本数可加强但不能降低该 floor。

构建时按第 5 节的 versioned canonical-byte profile 分别计算 corpus、ground truth、
production mapping、protocol 的 SHA-256。`corpus_ledger.json` append-only 记录它们的
version→digest tuple。release validator 从上一已发布 benchmark release 的
verified-provenance attestation 获取 `(ledger_length, ledger_root, full_prefix_digest)`，
再按 repository-global monotonic sequence 消费该 repo 其后全部 blocked-attempt
predicates 携带的 ledger identities；source/candidate 只作 provenance，不能过滤 frontier。
每次 blocked append/publish validation 都在同一 `repository_ledger_lease` 取 monotonic
fence；store 仅对匹配当前 `(expected_sequence, expected_root, fence)` 的请求 atomic
compare-and-append，过期 fence、非当前 prefix/竞争 successor 在落盘前拒绝。
验证 repo、issuer/workflow 与 attestation subject 后逐条比较：已有 version digest 变化、
历史项删除/重排、旧 version 复用、fork/gap 或 ledger 未覆盖 embedded inputs 都失败。
trust anchor 不得来自当前 checkout；
published/blocked anchor 找不到、永久 store 取不到、顺序冲突或验不过时 official build
fail closed。首个 official release 必须消费维护者明确批准并 attest 的 genesis root。新
release 复用完全相同 tuple 合法；任何内容变化都必须 append 新 version tuple，并把新
root/length/full-prefix identity 写入本 release attestation；block_release 的 permanent
record 也必须写入该 identity，使失败 candidate 已记录的 suffix 不能在 retry 中被重写。

每个 failure class 使用 positive/negative matched pair，尽量只改变被研究信号。runner
在执行前 join 三份 artifacts，再按 class/ground-truth 做 completeness、唯一性、
production mapping、mapping asset existence 与审核独立性检查。orphan、duplicate 或
many-to-one ambiguity 都失败。任何失败发生在创建 sandbox 或调用 detector 前；detector
实际输出永远不能改写 ground truth/mapping/ledger。

protocol 还为每个 case 绑定 versioned/digested initial-state fixture，默认是显式空
session/history/log/circuit-breaker state；需要非空前置状态的 case 必须在 corpus 中引用
reviewed initial-state ID，不能读取前一 case 的产物。每次 A/B 执行每个 case 前都从该
fixture 创建全新 HOME/state/session/project/log root 并使用固定 synthetic session IDs，
case 完成后销毁；run 内顺序只用于报告稳定排序，不得成为共享可变状态。

### 3. Production executor registry

Rust `bench` 内部建立封闭 executor registry，而不是让 corpus 提供任意 command：

- `installed_wrapper`：仅解析 verified receipt + mapping 中登记的实际 installed
  `run-hook.sh` / `run-hook-codex.sh`，使用参数数组 spawn；
- `payload_guard`：只允许 `production_asset_registry` 中预注册的固定脚本 logical ID，
  使用 registry-owned exec/argv contract 以参数数组执行，不经
  `sh -c`/字符串拼接；
- 不提供 `command`、`shell`、任意 path 或 plugin executor。

executor registry 的每个 ID 必须精确关联 protocol-owned `executor_limits`，并只引用
`production_asset_registry` 中该 production path 的 transitive executable logical IDs；
mapping 不复制 identity。需要 Bash/Python 或 `git` 等其它 external
executable 的 executor，只能从 readonly snapshot 中启动 preflight 已验证的精确
path/handle；脚本需要 PATH 解析时只提供由这些已验证 assets 构成的 minimal PATH。禁止
`Command::new("bash")`、`Command::new("python")`、`Command::new("git")`、`/usr/bin/env`
或 ambient PATH lookup。实现可以把 subprocess 改为进程内 library；static inventory 与
child-exec audit 仅作预检，不能证明分支后续不会 exec。每个 case/sample 的完整 descendant tree 必须由 manifest/protocol 钉住的 OS-authoritative deny-by-default exec broker 监管。
每次 image 启动前只允许 resolved handle/digest 匹配 registry logical ID，或匹配 manifest
直接绑定、launcher 已验证并以 inherited handle 派生的唯一 `runtime_execution_grant`；
grant 不写回 registry且禁止 pathname lookup，闭包外 identity 在执行前拒绝。所有 broker
decisions、实际 executable identities 与四个 limits 进入 report；backend 无 pre-exec deny、
失联/race 或 undeclared exec 均 fail closed，无合规 backend 则零 sample `unavailable`。

`dangerous_shell_or_git` fixture 只作为 hook stdin 分类，绝不执行 payload 中的 command。
file/project fixtures 先在专用 temp root materialize 合成文件，再通过 installed
wrapper/payload guard 运行 canonical pre/post/stop path。每个 versioned adapter 只接受
mapping 声明的 raw decision JSON/exit 与 raw reason-code 闭集，并把二者唯一映射为
`{block, advisory, allow}` + canonical reason code。mapping 可声明唯一
`no_interception_success` raw variant：production entrypoint success exit、无 decision
payload、raw reason absent 的组合精确映射为 `allow` + `no_interception`；不得把其它
缺失字段解释成该 variant。unknown/malformed/ambiguous/multiple decision 或 reason、
其它缺失 decision/reason，以及任何 free-text/substr/regex reason guessing 都产生独立
`case_status: execution_error`，normalized decision/reason 留空；它不进入
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
- payload executors 关闭 stdin 继承，严格应用 protocol 对该 executor ID 绑定的
  `timeout_ms`、`termination_grace_ms`、`stdout_max_bytes` 与 `stderr_max_bytes`；
  runner 不得提供隐式默认值或环境 override，cap overflow/timeout 产生闭集
  `execution_error` 并触发完整进程树终止；
- report 保留 mapping schema 允许的 closed raw production decision、raw reason code、
  rule/reason identifier、normalized decision/canonical reason、closed error category 与
  synthetic case ID；free text、原始 payload、用户路径、env 和任意 child stderr 不持久化。

在启动效果 case 或 latency warmup 前，materializer 只按 verified signed manifest 的
`production_asset_registry`，把 launcher 已验证的 runtime handle、已独立验签的 manifest
及 registry 中 payload/wrappers/config/baseline/interpreters/transitive executables 复制到
temp HOME 的生产布局。runtime identity 仍只来自 B-021 manifest/handle chain，registry
不得登记 runtime/protocol/自身以免 digest 自引用。复制后逐文件重算 digest/size，校验
registry/manifest/protocol identity、拒绝 symlink/hard-link/extra executable，并设为只读；
wrapper 的 HOME 与解析
路径只指向该 snapshot。materialization、permission tightening 与 digest verification
全部发生在计时区间外。缺文件、布局差异、可写文件或 digest drift 时零 timed sample
并 unavailable，绝不回退真实 HOME、checkout、mock 或 PATH。

一个 interruption token 阻止启动后续 case。每个 case 在 Unix 建立独立 session/process
group，在 Windows 放入启用 kill-on-close 的 Job Object；timeout/cancel 先向整个树发送
graceful termination，超时后强制终止，并等待 group/job 中所有 wrapper、shell、runtime
descendant 确认退出。只有完整进程树已退出后才执行记录式 cleanup；cleanup 只允许删除
启动时创建并验证过的精确 temp root，所有 cleanup 结果先进入内存中的 closed terminal
record。cleanup 成功或失败均在其结束后，才把包含最终 terminal record 的 partial report
一次性封口到 caller 显式路径；未提供 caller 路径时使用与待清理 temp root 分离的
attempt-bound durable report root。无法确认全树退出时保留 temp root、记录 closed
cleanup/process-tree error 后再封口并非零退出，不能在后代仍可能写入时删除。cleanup
失败同样必须在封口前追加 closed cleanup error，绝不扩大路径或覆盖已存在输出。

并发运行使用随机 run ID + exclusive-create output；已存在 output 非覆盖报错。official
mode 不写 project/global event log，不读取前次报告。

### 5. Deterministic effectiveness protocol

执行协议由 embedded corpus metadata 固定：

1. preflight 全量验证；
2. 按 case ID 排序，在 run A 中为每个 case 从其 digested initial-state fixture 创建全新
   state/session/project/log root，执行后销毁，不在 cases 间复用 hook history；
3. run B 对每个 case 重新从同一 initial-state fixture 创建独立 root，并按同序执行；
4. 对每 case 比较 normalized decision/reason classification；
5. 一致后才聚合完整 confusion matrix 和每类分项。

所有 digest 输入共享 `canonicalization_version: jcs-rfc8785-v1`：先拒绝 duplicate JSON
keys/unknown schema；JSON number 仅允许 safe integer
`[-9007199254740991, 9007199254740991]`，更大 run/asset/identity 使用 canonical decimal
string，rate 使用 reduced numerator/denominator 且 display decimal 也是 string；再生成
UTF-8 RFC 8785 JCS bytes，不附加 BOM 或尾随换行，最后 SHA-256。Rust producer、Python
validator 与 release packaging 必须通过同一组包含 key order、escaping、Unicode、
safe-integer 两端及各自越界 ±1、空值和 forbidden float 的 golden/reject vectors；
profile 未识别或跨实现 bytes/digest 不一致时 fail closed。

JSONL 仅是 corpus/ground-truth 的传输格式，不直接作为 digest bytes。validator 必须逐行
解析并按 schema 拒绝空记录/duplicate ID/unknown field，再按 UTF-8 case ID 升序排列
records；canonical digest preimage 是这个有序 records 列表构成的单一 JCS array。禁止
哈希原始换行文本、逐行 JCS 直接拼接或保留输入行序；Rust/Python golden 必须覆盖 CRLF、
尾随换行、输入乱序、escaping 与 duplicate-case framing，并得到同一 array bytes/digest
或同一具名拒绝。

`decision_digest` 的 canonical payload 只包含所有 native platforms 共同的 source
commit、corpus/ground-truth/mapping/protocol versions+digests、获批的
`required_platforms`、canonical benchmark config identity、initial-state identities、
`interception_decisions`、按 case ID 排序的 ground truth + normalized decision/
canonical reason code
和 aggregate counts；排除 target-specific binary/payload/wrapper digest、OS/arch、
latency、timestamp、temp path。A/B `decision_digest` 或 case decision 不同即
effectiveness `inconclusive`，两次证据都保留在有界报告中。release matrix 只对
`required_platforms` reports 使用 `decision_digest` 做跨平台一致性 gate；非 required
reports 不进入该 gate。

`evidence_digest` 在每个平台报告完成后计算，canonical payload 是“完整 report 去掉
`evidence_digest` 字段本身”，因此绑定 `decision_digest`、current-exe/release-manifest/
payload/wrapper identities、target、完整 `required_platforms`、本 target 的 `required`
boolean、两个 axis 状态、per-surface workload schedule identities、latency/environment
与 schema。
不同 native targets 的 `evidence_digest` 正常应不同，不能做 equality gate。

`execution_error` 不属于 decision 闭集或 headline numerator，但对应 case 进入
`positive_error|negative_error` 并仍留在对应 denominator，同时使 effectiveness
`inconclusive`。聚合层集中计算 TP/FN/FP/TN、两个 error buckets、block/advisory counts
与 diagnostic rates，并强制
`positive_total = TP + FN + positive_error`、
`negative_total = FP + TN + negative_error`；decision counts 之和只等于无 error 的
case 数。只有 axis `valid` 且两个 error bucket 为零时 renderer 才能把 rate 显示为
headline。human、JSON、README 不得各自重算。

### 6. Latency protocol

新增 surface 名 `bench_case_e2e_ms`，避免与现有 CI `hook_e2e_ms` 混淆。每个 sample
必须从 B-030 已重验的 readonly production-layout snapshot 解析 actual installed
wrapper，以
protocol-declared、preflight verified、readonly-snapshot interpreter 的精确路径/handle，
以参数数组 `[wrapper_path, fixed_hook_name]` spawn 子进程，传 fixture stdin，并在绑定的
timeout/output caps 内等待 stdout/stderr/exit 完整返回。禁止 host PATH interpreter、
direct Rust function、checkout hook、mock wrapper、PATH fallback 或只测 `bench`
dispatcher。对每个 production surface：

- 先运行 protocol-owned environment baseline 与 clock sanity check。protocol 按 target
  引用 `production_asset_registry` 中 no-op workload logical ID；executable identity 与
  exec/argv contract 只来自该 registry entry，protocol 另行绑定 stdin/env、
  warmup/measurement counts、完整 interleaving、spawn-to-complete 单调时钟边界、
  integer-ns raw samples、闭集 estimator `{id: nearest_rank_p95_v1, percentile: 95}`、
  `threshold_ns` 与 inclusive comparison。去除 warmup 后将 n 个 measurement samples
  升序排列，唯一计算 zero-based
  `baseline_stat_ns = samples[ceil(95*n/100)-1]`（无插值），再判断
  `baseline_stat_ns <= threshold_ns`；runner 默认 estimator/workload/host PATH 不得参与；
- ordered case IDs、每个 ID 的 warmup/measurement repetition 与完整 interleaving 顺序从
  已审核、embedded protocol 读取；每个 ID 存在且 counts 均须正整数，runner 不得采样、
  重排或选择最快 fixture；
- schedule 绑定 `latency_state_policy: fresh_per_sample` 与 latency initial-state digest：
  每个 warmup/measurement sample 都创建新的 HOME/log/history/session root并在结束后销毁；
  warmup state 不能带入 measurement，任何 cumulative reuse policy 都拒绝；
- estimator 固定 `nearest_rank_v1`：对 integer nanoseconds 升序排序，Pq 取
  zero-based `ceil(q*n/100)-1`（q=50/95/99，无插值），max 取末项；report 保存 exact
  sample ns/percentile ns，display ms 只作确定性字符串格式化；
- 单调时钟包围 installed wrapper subprocess 的 spawn-to-complete，不含 sandbox
  materialization/report render；
- 输出 schedule/state/estimator identity、P50/P95/P99/max、runs、platform、
  runtime/payload identity 和 baseline；
- environment baseline workload/schedule/`nearest_rank_p95_v1`/threshold、executor timeout/
  termination grace/stdout cap/stderr cap 与全部 external executable identity 沿用已发布
  protocol 字段，不从用户环境、PATH 或 README 读取。goldens 至少覆盖 threshold-1、
  threshold、threshold+1，证明阈值本身通过、上界 +1 失败，并覆盖 baseline sample/count/
  timer-boundary/interleaving/estimator 任一 drift。

效果 A/B run 与 latency sample batch 分开，避免 confirmation 次数意外改变效果分母。
wrapper path/digest drift 在 sampling 前使 latency `unavailable`；sample error/distortion
使 latency `inconclusive`。README 为每个 protocol-declared surface 使用独立 P95/status
列或子行，不做跨 surface reduction；axis invalid 时每个 cell 为破折号 + 状态/reason，
不写 `0ms`。现有 hook SLA 仍由 `tests/bench_hook_latency.sh` 管理，本 issue不新增或修改
pass budget。

### 7. Report、schema 与 exit semantics

内部 `BenchReport` 是唯一 aggregate；text、JSON 与 README summary 共享它。report 顶层
至少包含：

- `schema_version`, `canonicalization_version`, `official`, top-level `status`,
  `failure_categories`；
- actual current-exe/release-manifest/payload/wrapper/corpus provenance，以及
  protocol-bound executor limits/interpreter identity；
- `interception_decisions`、production-mapping identity、protocol digest、
  `required_platforms` 与本 target 的 `required` boolean；
- effectiveness axis status、A/B + cross-platform `decision_digest`、
  TP/FN/FP/TN + positive/negative error buckets、denominator closure values 与
  per-class metrics；
- latency axis status、environment、per-surface metrics；
- platform-bound `evidence_digest`；
- case-level closed raw production decision、raw reason code、rule/reason identifier、
  normalized decision/canonical reason 与 case status；不保存 free text、raw payload/stderr；
- closed `terminal_outcome`、interruption/process-tree termination/cleanup metadata。

report schema 使用 `additionalProperties: false` 保护闭集；reader 按显式 version
dispatch。两个 axis 状态各为 `{valid, unavailable, inconclusive}`；
`axis_candidate_status` 是纯 3×3 function：
`valid/valid→valid`、`unavailable/unavailable→unavailable`、其它七种组合→inconclusive。
final top-level 只再应用 closed `terminal_outcome` override：`completed` 沿用 candidate，
任一 `interrupted|process_tree_unconfirmed|report_write_failed|report_schema_invalid|
cleanup_failed` 都强制 inconclusive、blank headline、非零退出；clean interruption 即使发生
在两轴 valid 后也不能退出 0。若 report write/schema 本身失败，CLI/
release wrapper 通过闭集 diagnostic/failure manifest 表达而不伪造 valid report。测试覆盖
3×3×`{completed, interrupted_or_terminal_failure}`。旧版本映射不存在就报 unavailable，不做 duck
typing。`--json` stdout 只输出 JSON，diagnostic 到 stderr 且同样脱敏。README 每 cell
读取 axis status，不根据 top-level 猜数值。
### 8. Release regeneration 与 README

调整 release DAG，使官方报告来自 staged、将要发布的 artifacts：

1. build runtime 与 GH-699 payload/receipt fixture；
2. native matrix 下载准确 target binary + payload，先通过 `current_exe` identity chain，
   再从 actual merged launcher 运行 `bench --json`；
3. 每个平台 schema/provenance/axis gate；release summary 只选择 approved
   `required_platforms` 的 native reports 并比较其 `decision_digest`，`evidence_digest`
   只作各平台 artifact identity；
4. 对全部最终展示的 reports 生成 checksums；按 target canonical 排序构建 strict
   `public_benchmark_summary`，逐项绑定 `required` boolean 与 exact
   `(target, evidence_digest, report_sha256, checksum)`、完整 required set、decision
   equality、per-surface latency/status 与 aggregation result。只有 required subset
   参与 validity/decision equality；display-only reports 同样进入 summary object 和签名
   preimage，但不改变 summary status。`summary_digest` preimage
   唯一为删除 `summary_digest` 字段后的完整 summary object 的 JCS bytes；detached
   release-workflow attestation 绑定结果，不进入 preimage。required reports 全 valid 且
   decision
   digest 一致时生成 valid summary，否则生成 non-valid candidate summary；README 只能
   展示该验签 summary 内绑定的 required 或 display-only report，不能读取游离附件；
5. 只有 valid 或获批 `publish_nonvalid` 分支可运行 `publish-release`，一次性发布
   binary、payload、checksums、manifest 与对应 benchmark reports。已 published 的同 tag
   release 一律拒绝变更；已存在 private draft 只有在 draft ID、attempt、tag/source、
   asset digests 与已验签 `publish_intent` 完全匹配时，才允许继续同一 draft 的幂等
   publish/recovery，任何无关或不匹配 draft 仍 fail closed。

publication 使用 attempt-scoped draft 与一个统一 durable state machine：
1. actors 只按 source/candidate → `repository_ledger_lease` → `repository_publication_lease` →
   branch CAS 短暂取锁；禁止反向。等待 review 时释放 lease，active durable owner仍阻断新 candidate。
2. phase A 重验 draft/summary/policy/exact reviewed README patches；可见动作前在受认证、
   retention-independent、append-only `publication_history` fenced-CAS append prepared
   owner，绑定 repo/candidate/run/attempt/fence/draft/summary/policy/base/reviews/deadline；
   transition/terminal 永久保留。
3. `rollover_one` 证明单 current、merge reviewed de-current 并在 intent 前 durable append
   merge SHA/前后 blob receipt；`genesis_zero` 证明零 marker、history 无历史 eligible valid
   publication、除本 exact owner 外无 active owner、corpus ledger 仅含 non-valid/no
   publication，再 append history-frontier-bound zero receipt；其它状态 fail closed。
4. receipt durable 后 valid intent 才绑定 receipt/pre-approved new-current patch；nonvalid
   intent 绑定 unmarked-row。
   commit 后 owner 从 `valid_zero_marker`/`intent_written` CAS 到 `release_committed_valid_marker_pending`
   或 `release_committed_nonvalid_row_pending`；crash 由 prepared owner/intent/sentinels补齐。
5. de-current 后 intent 前取消进入 `valid_rollback_pending`；rollback/new-current/nonvalid-row
   PR reject/close/timeout/owner loss 由 reconciler 提升 fence并建同 candidate/exact replacement。
   无获批 replacement attests `rollback_recovery_blocked`、`marker_recovery_blocked` 或
   `nonvalid_row_recovery_blocked` 并继续阻断；exact rollback+delete/README merge 后才 terminal。
required target 不能原生执行时显式 `unavailable` 并使 summary non-valid；非 required
target unavailable 只展示、不阻断。不得用 host/cross binary 贴 native 目标标签；若
approved set 含四 target 就必须配置四个 native runners。required platforms 的
effectiveness decision 应一致，差异使 summary `inconclusive`。latency 永远按
platform × surface 独立展示，不聚合为单一 P95。publication、README 与 checksum gate 只
消费 schema/digest/attestation 三重验证后的 summary；遗漏/重复/替换 input 均失败。

获批 `release_policy` 必须来自闭集 `{block_release, publish_nonvalid}`；缺失/越界值直接
阻断且不能猜。Recommended proposal（未批准）选择 `block_release`。两个分支共享
schema/provenance gate，但发布动作闭合如下。
effective action 为 `block_release` 时（包括 selected policy 是 `publish_nonvalid` 但
mandatory non-valid report/evidence 未通过 schema/provenance gate），failure-manifest
schema 是闭集 union：单 target 失败使用 `target_failure`；required reports 各自有效但
decision 不一致、缺输入或 aggregation 失败使用 `release_aggregation_failure`，后者绑定
canonical failed-summary preimage/digest、完整 required-platform set 与闭集 aggregation
reason。每个 required target 都必须有 `input_state` discriminated union：`present` 携带
非空 report/evidence/checksum identities；`missing` 把三项显式置 null 并携带闭集
`missing_reason`。strict summary 成功构造时才写非空 `summary_digest`；缺输入使其无法构造
时该字段显式为 null，failed-summary digest 仍覆盖全部 target slots。matrix wrapper
对可恢复的 bench/job failure 捕获非零状态但暂不退出，先：

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
   **完整 canonical failure manifest 内容**与本 candidate 的 ledger
   `(length, root, full_prefix_digest)` 内嵌到不可覆盖、
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
hard-cancel、runner loss、job/workflow timeout 不能依赖上述 wrapper 继续运行。另设
completion reconciler，由 release workflow 终态事件触发；source 只读、attestation store
可追加，protected environment 显式授予 `actions: read`、`contents: write`、
`pull-requests: write`；
   该权限只允许删除无可见 transition 的 prepared draft、按 intent 完成同一 draft，或按
   durable owner supersede并创建同 candidate exact rollback/new-current/nonvalid-row replacement；
   README PR 均须 review/CAS。reconciler 用 `(repo_node_id, workflow_id, candidate tag/source
   commit, run_id, run_attempt)` 查询预发布阶段已
attested staged identity。cancelled/timed_out/failure 且无 normal record 时，先复验
owner/intent/public sentinels：已有 intent/Release 必须完成唯一 publication/exact README，
在 history append `recovered_publication`，不得写 B-029 interruption/block record；仅无
intent 且恢复证明不发布（含 exact rollback+draft delete）时，才生成 `pipeline_interrupted`
failure manifest：report/evidence/checksum identity 为显式 null，
   `missing_evidence` 为闭集，保留 provenance、policy、interruption 与 publication phase。
   它先物化 prepared owner：无可见动作可删 draft；`valid_rollback_pending` 恢复旧 marker再删；
   有 intent则完成/验证唯一 Release；valid-marker/nonvalid-row pending 在 deadline/heartbeat/
   rejection 后以更高 fence接管并重建 exact reviewed replacement，不伪报 sentinels absent。它按
`jcs-rfc8785-v1` 计算 attempt-bound digest并把完整 manifest
attest/append 到相同永久 store。重复终态 delivery 对相同 bytes 幂等；相同 identity
已有不同 bytes 时冲突失败且报警，绝不覆盖。normal-path record 已存在时只重验并退出。
reconciler 自身失败必须由 scheduled audit 重试并保持 candidate 未发布；测试不得用
已终止 job 的 post-step 冒充此路径。
若 staged identity 尚未 attested，reconciler 进入独立闭集
`pipeline_interrupted_pre_attestation` 分支。它只消费受信的 `workflow_run` 终态事件并
使用 Actions API 按 server-side run ID 复验
`(repo_node_id, workflow_id, run_id, run_attempt, head_sha, server_ref_type,
server_ref_name, event, conclusion)`；server ref 还须与对应 branch/tag ref API 对齐，不能
从 workflow input 猜。candidate tag、policy、staged provenance 与 evidence identities
全部显式 null。canonical JCS 派生
`source_identity_key = sha256(repo_node_id, workflow_id, head_sha, server_ref_type,
server_ref_name)` 与
`early_attempt_key = sha256(source_identity_key, run_id, run_attempt, event)`；tuple 不同却
digest 相同即冲突。终态事件持 source-identity lease 后 append；API/ref 不可验证则永久
unbound 并 fail closed，不能从 watermark 删除或信任 workflow artifact/free text。
release attempt、completion reconciler、scheduled audit 与 publish gate 共享 serialized
lease，`cancel-in-progress: false`：staged identity 存在时用 candidate key，否则用上述
source-identity key。identity 后续出现时只在 staged candidate 的 tag/source 与 server ref
精确匹配后，按 key digest canonical 顺序同时取得 source/candidate leases，append
early→candidate binding，并把 digest union 进 candidate watermark；无法证明匹配的 record
永久 unbound，不得由同 commit 的下一个 candidate 接管。每个新 attempt 启动前及 publish
前在持锁状态枚举同 candidate/source identity 的 terminal attempts，
要求每个先前 failed/cancelled/timed_out attempt（含 pre-attestation interruption）都有
唯一、内容一致且与终局匹配的 permanent failure 或 `recovered_publication` record，并生成
attested reconciliation watermark（覆盖最大 terminal run/attempt 与 record digest set）。
存在 unreconciled attempt、run listing/permanent store 不可用、不同内容冲突或 watermark
落后时 fail closed。所有路径都执行唯一全局顺序 source/candidate → repository ledger →
repository publication → branch CAS；需要较早层的新操作必须全部释放后从头重取，禁止
deadlock-prone nested reacquisition。append 后才推进 watermark；token/CAS 失效即停写；active
ownership 只允许同 candidate takeover，任一 `*_recovery_blocked` 阻断下一 publication。
`publish_nonvalid` 以 prepared owner + intent 发布 schema-valid non-valid report/evidence，
再通过 owner-bound reviewed PR 创建同版本 row：non-valid axis 留空并显示 status/reason/link，
永不带 current marker且不删已有 latest-valid marker。row merge 前保持
`release_committed_nonvalid_row_pending`；crash/reject/close/timeout 按统一 reconciler
replacement或 `nonvalid_row_recovery_blocked`，不能放行下一 candidate。它不创建 B-029
blocked record，也不得把旧 release 数字贴到新 row。任一
mandatory evidence 未通过 gate 时，此分支不得部分发布，必须记录 selected policy 后转入
B-029 的 effective block action。

README 使用 marker 管理的生成区。source 必须是该 exact release 的不可变已验证 summary：
valid branch 消费 valid summary，`publish_nonvalid` 消费同版本 non-valid summary，
`block_release` 不生成 candidate row。仅 valid branch 在 publication 前 human-reviewed
地删除旧 current marker并重验 zero-marker，post-release 再添加新 current；non-valid
branch 跳过这两个 marker 动作，只添加无 marker row并保留 latest-valid current。所有 PR
都同时更新英文 README 与已配置 locale 文档，保留 human review，不直接 push 高上下文
文件。generator 对每个平台
独立显示：

- effectiveness valid → rate/FPR；否则 `— (effectiveness: <status>: <reason>)`；
- 每个 protocol-declared latency surface 都有固定独立 P95/status 列或子行；禁止从多个
  surface 选择最快/最慢或静默 reduction；
- row status 始终为共享 top-level；
- only top-level valid row 可带 `current valid benchmark` 标识。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 released one-command official mode | runtime CLI + manifest-declared Homebrew/npm launcher dispatch | no-clone fixtures prove every supported installed launcher transparently forwards `bench` argv/stdin/stdout/stderr/exit without entering bootstrap/setup/init; missing/non-forwarding launcher is unavailable |
| B-002 complete matched provenance before execution | signed manifest/bundle + protocol config/schedule/limits/all-executable preflight | negative matrix for current-exe, tag, commit, target, canonical benchmark config, initial-state/schedules, baseline contract, executor limits, all executable identities, protocol/required-platforms, corpus/payload/wrapper digest asserts unavailable and zero executor calls |
| B-003 five classes with both polarities | corpus schema + completeness validator | corpus mutation tests remove each class/positive/negative side one at a time and assert preflight failure |
| B-004 reviewed immutable ground truth | separate fixture/ground-truth/mapping parsers | duplicate-key/ID, orphan joins, unknown enum, conflicting label, non-independent review and changed-content-same-version fixtures are rejected |
| B-005 production paths only | sealed executor registry | mutation test replaces each executor with unknown/test-only ID and asserts zero cases; code review confirms no case-ID detector branch |
| B-006 closed normalized decisions and declared interception subset | versioned decision adapter + strict case-evidence schema | exhaustive raw decision/reason/rule-id→normalized enum tests include successful no-payload/no-reason→allow/no_interception, prove other missing fields fail, retain closed raw fields, drop free text, and reject invalid headline subsets |
| B-007 complete denominator and metrics | one aggregate module | table-driven TP/FN/FP/TN/positive_error/negative_error cases prove both closure equations, errors stay denominator without entering production-decision counts, and nonzero errors suppress headline |
| B-008 honest statuses | axis state machines + top aggregator | exhaustive axis status/error fixtures prove each axis emits only the closed status set and never renders non-valid as zero/pass |
| B-009 deterministic confirmation | per-case initial-state materializer + dual-run executor + `decision_digest` | history-sensitive hook fixture proves every A/B case gets the same fresh digested state and previous cases cannot influence it; injected drift remains inconclusive |
| B-010 idempotent/concurrent isolation | run context + exclusive output | two parallel process tests use disjoint roots/reports; sentinel install/repo/log files remain byte-identical |
| B-011 end-to-end latency semantics | fresh-per-sample state + nearest-rank-v1 per-surface sampler | history/log-growth fixture proves warmup and measurements never share state; n=1/2/3/20/21 goldens distinguish ceil-rank from floor; every scheduled wrapper sample uses protocol-bound limits/executables and drains full IO |
| B-012 distorted latency honesty | protocol-bound environment baseline + axis status | no-op identity/argv/env/count/order/timer/estimator drift fails; threshold-1/equal/+1 goldens prove inclusive boundary; bad clock, zero runs, spawn distortion and sample error blank headline latency |
| B-013 synthetic sandbox/privacy | identity-only HOME reader + sandbox/env builder + redactor | allowlist fixture permits only verified receipt-enumerated files; directory enumeration/symlink/other HOME reads and all writes fail; dangerous-command sentinel remains untouched and secret/path/env sentinel is absent |
| B-014 interruption and bounded cleanup | process group/session/Job Object + terminal-outcome override + cleanup ledger | descendant fixture proves full tree exits; cleanup-before-seal fixture proves the immutable partial report contains the final cleanup result; clean cancellation after both axes valid and all tree/report/schema/cleanup failures still force final inconclusive/nonzero |
| B-015 shared human/JSON aggregate and exits | renderers + strict report schema | semantic golden and 3×3×terminal-ok/error matrix cover persisted/failed-report paths, exits and blank headlines without renderer recomputation |
| B-016 staged exact release regeneration | strict summary + attempt draft/publish-intent commit | input/self-digest mutations cannot publish; all assets verify in private draft before intent; cancellation before/after intent/commit converges without public partial assets |
| B-017 generated README table | branch-aware verified-summary-to-doc generator | valid publication de-currents before commit then adds new current; publish_nonvalid preserves latest-valid current and adds only an unmarked row; drift fails freshness |
| B-018 closed release-policy branches | release/README policy fixtures + completion reconciler | exhaustive fixtures prove recoverable block and hard-cancel both create permanent attempt evidence without Release/page/assets/current row; publish_nonvalid creates only same-version non-valid evidence/row; evidence-gate and unknown-policy failures block |
| B-019 explicit schema compatibility | versioned parsers | current/legacy/unknown schema fixtures prove only declared mapping loads; unknown version nonzero unavailable |
| B-020 unofficial isolation | CLI option policy + README ingest gate | custom/dev report carries `official:false`, uses separate path and is rejected by README generator |
| B-021 verified current-exe identity chain | independently trusted native launcher + offline bundle + handle-bound exec/mapped-image handshake | launcher verifies manifest and runtime handle digest before exec; start modified image then replace pathname with signed binary still fails; Unix inherited exec fd/Windows deny-write handle binds executing image to signed manifest |
| B-022 split decision/evidence digests | safe-integer RFC 8785 JCS canonical builders | Rust/Python golden/reject vectors cover ±9007199254740991 and out-of-range ±1, big decimal strings, case-ID-sorted JSONL→JCS-array framing, config/state/schedule identities and split digest behavior |
| B-023 axis candidate + terminal override | shared status aggregator + renderer | exhaustive 3×3×`terminal_ok|terminal_error` golden proves terminal failure always yields inconclusive/nonzero/blank headline while error-free candidate remains pure |
| B-024 real wrapper subprocess E2E | mapping resolver + protocol-bound executable closure/limits + latency executor | installed wrapper spy records verified interpreter/`git` identities, limits, argv/stdin and child completion; fake/missing executable, undeclared child exec, direct function, checkout wrapper, ambient PATH and digest drift are rejected |
| B-025 decision/reason closure and execution-error exclusion | mapping adapter + aggregate | explicit no_interception success maps to allow without a raw reason; every other unknown/missing/multiple decision/reason fixture and free-text heuristic attempt creates no normalized value/numerator, remains denominator and forces inconclusive |
| B-026 independent ground truth and mapping | attested maintainer roster + signed review-record schema | fake distinct IDs sharing key/subject, unrostered role, bad signature/digest/commit and forbidden overlaps all fail before execution |
| B-027 immutable version→digest ledger | published + permanent blocked-attempt trust frontier + ledger validator | mutation suite rewrites a blocked suffix and asserts mismatch against the longest verified frontier; missing/out-of-order/wrong-lineage anchors fail; approved genesis and exact tuple reuse pass |
| B-028 partial GH699 dependency | no-clone discovery + distribution launcher dispatch smoke | main fixture accepts merged payload but remains unavailable until actual launcher exists and each manifest-declared launcher forwards bench argv/IO/exit without setup/init |
| B-029 immutable per-attempt blocked-release evidence | lease/watermark + two-phase draft reconciler | missing target uses explicit null identities; server-authenticated pre-attestation interruption remains enumerable; exact ledger identity and failed inputs persist; before/after-intent cancellation converges without partial public state |
| B-030 readonly production-layout snapshot | signed-manifest handle reader + canonical-config/all-executable materializer + wrapper executor | user config/PATH mutation cannot change official output; only signed config/baseline/executable closure is copied, materialization is outside timer, and undeclared child exec fails before sampling |
| B-031 approved required-platform summary gate | protocol + strict summary preimage/detached attestation | delete-self-field JCS golden is unique; placeholder/self/attestation-in-preimage and omitted/replaced required or displayed inputs fail; all displayed reports are signed while only exact required evidence affects validity |

## Affected-file / test / command map

下表是 implementation 的预期 ownership map；GH-699 尚未合并的真实 launcher path 标为
“merge 后探测”，不猜文件名。若实现发现路径不同，先更新 tasks/tech anchor 再改代码。

| Concern | Planned affected files | Focused proof |
| --- | --- | --- |
| CLI + module split | `vibeguard-runtime/src/main.rs`, planned **vibeguard-runtime/src/bench/mod.rs**, **model.rs**, **corpus.rs**, **identity.rs**, **mapping.rs**, **runner.rs**, **metrics.rs**, **latency.rs**, **render.rs**, **sandbox.rs** | `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench` |
| Handle-backed SHA-256 | `vibeguard-runtime/src/setup_support.rs`, planned **vibeguard-runtime/src/bench/identity.rs** | known binary digest + replace-during-read test; no OS shell hash command |
| Protocol/corpus truth/mapping/ledger/reviews | planned **data/public_benchmark/**, the eight **schemas/public_benchmark_*.schema.json** files including **schemas/public_benchmark_protocol.schema.json**, **scripts/ci/validate_public_benchmark.py** | protocol schema ownership; baseline boundary + JSONL framing goldens; signed reviewer records; published/genesis/blocked-frontier ledger mutation suite |
| Installed release identity | planned **schemas/release_identity.schema.json**, persisted attestation bundle + signed manifest, `scripts/setup/runtime-install.sh`, `scripts/setup/install.sh`, `scripts/ci/generate_runtime_release_manifest.py` | offline trust-root/issuer/workflow/subject verification plus recomputed binary/payload/wrapper/canonical-config/baseline/all-executable digests rejects tampered receipt/assets |
| Actual launcher | GH-699 merge 后探测真实 manifest-declared paths；GH-700 owns Homebrew/npm `bench` dispatch changes at those anchors | fresh HOME per-launcher smoke proves argv/stdin/stdout/stderr/exit forwarding to same current-exe and proves bootstrap/setup/init sentinels absent |
| Wrapper E2E | actual installed `~/.vibeguard/run-hook.sh`, `run-hook-codex.sh` contracts; production code materialize byte-identical readonly temp snapshot，不复制 detector | layout/digest/permission + fake/missing `git`/undeclared-exec matrix, baseline and wrapper timer spies, existing `bash tests/test_hook_perf_contract.sh` |
| Report/readme | planned **schemas/public_benchmark_report.schema.json**, **schemas/public_benchmark_summary.schema.json**, **scripts/ci/render_public_benchmark.py**, `README.md`, configured locale README | exact summary inputs; valid de-current/zero-gap/new-current and nonvalid preserve-current/unmarked-row goldens; per-surface rows; invalid axis has no numeric cell |
| Release/failure evidence | `.github/workflows/release.yml`, planned **.github/workflows/benchmark-failure-reconcile.yml**, **scripts/ci/package_benchmark_evidence.py**, **scripts/ci/publish_benchmark_failure_record.py**, **schemas/public_benchmark_failure_manifest.schema.json**, `tests/test_release_workflow.sh`, planned **tests/fixtures/public_benchmark/failure_records/** | missing-target null union、pre-attestation event/API branch、blocked ledger frontier、watermark/idempotency/conflict、deleted-bundle recovery与two-stage marker publish ordering |
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
- protocol-bound baseline workload/schedule/estimator/timer/threshold 与全部 mapped
  external executables 已进入 provenance；threshold-1/equal/+1 及 fake/missing/undeclared
  executable fixtures 得到唯一状态；
- block_release candidate 的长期 predicate/ledger 可在删除短期 bundle 后恢复完整
  per-attempt failure manifest/reason/ledger frontier 并复算 digest；missing target 为显式
  null union，pre-attestation interruption 仍可由 server-authenticated tuple 检索，相同
  report 的 retry 仍有不同 run/attempt-bound identity。最终 workflow 非零且
  Release/candidate-row sentinel 均不存在；
  publish_nonvalid fixture 则最终产生同版本 non-valid report/row。
- valid fixture 覆盖 genesis self-owner admitted/other-owner rejected 与 rollover receipt；
  公开前有 prepared owner，commit/owner-update crash可恢复，旧 row不再标 current。
- rollback/new-current/nonvalid-row PR 的 reject/close/stall/crash 都产生 same-candidate
  reviewed replacement或 durable recovery-blocked；未 terminal 前下一 candidate 被拒。

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
                            ├─ valid ──> prepared owner ──> genesis receipt / de-current PR
                            │                              └─ publish ──> owned new-current PR
                            ├─ non-valid + block_release
                            │      └─ permanent per-attempt failure manifest
                            │            └─ job failure (no Release/current row)
                            └─ non-valid + publish_nonvalid
                                   └─ prepared owner ──> publish ──> owned unmarked row
```
没有网络调用或用户数据输入。持久化面是以下闭集：

1. caller 显式选择的本次 local report；
2. valid/`publish_nonvalid` release artifacts，以及 `block_release` 的短期
   content-addressed failure bundle；
3. `block_release` 的 retention-independent predicate/ledger，内嵌完整 per-attempt
   manifest，以 `(run_id, run_attempt, failure_manifest_digest)` 检索；
4. 受认证、retention-independent、append-only `publication_history`，保存 owner、receipt、
   fenced transition、`recovered_publication` 与 terminal records。
temp fixtures/logs 在本次 run 内清理；删除或 retention 到期的短期 bundle 不得删除第三、
四项，
验证者仍能从 permanent predicate/ledger 恢复完整 manifest、通过 schema、复算 digest
并核对 closed reason/provenance。README 只消费已发布、digest-matched summary，不消费
本地 stdout 或 blocked-candidate permanent record。

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
  实现，schema 也会演进。缓解：明确 partial dependency、merge 后 launcher discovery +
  每个 manifest-declared Homebrew/npm 入口的 bench dispatch/no-clone forwarding smoke、
  version dispatch、digest matching，无 spec-path/checkout/PATH fallback。
- Identity: binary 自报 metadata 或 receipt drift 会制造 official 假象。缓解：
  offline-verified persisted attestation bundle + pinned roots → signed release manifest →
  handle-backed current-exe/payload/wrapper/canonical-config bytes；receipt 只映射本地 path，
  自报 identity 只作一致性检查。
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
      append-only ledger、offline attestation + handle-backed identity、safe-integer JCS boundary、
      raw decision/reason closure、per-case initial-state reset、3×3 axis candidate + terminal
      override、strict input-bound summary aggregation、confusion matrix、report/failure/summary
      digest builders、fixed latency schedule/quantiles、redaction、cancellation 与 path containment。
- [ ] Integration tests: released-install fixture 执行五类正/负 cases；wrong
      current binary/payload/wrapper/bundle/receipt/corpus/mapping、user-config mutation、
      history-sensitive per-case isolation、all-launcher forwarding、detector error、timeout、
      environment distortion、parallel runs、interruption、legacy schema 和 sentinels；
      E2E sample 必须按 fixed schedule 由 readonly snapshot wrapper spy 观察到。
- [ ] Release contract: native reports/strict summary；`repo_node_id` exact-ref identity、唯一
      source/candidate→ledger→publication→CAS 顺序和 pre-transition durable owner 阻止并发/
      deadlock/ownerless publish；failure retention、genesis/rollover/rollback/new-current 与
      nonvalid-row takeover/recovery-blocked 均受测试。
- [ ] Documentation: 3×3×terminal、per-surface latency、双 locale 与 branch-aware marker
      freshness；仅 valid metrics 显示数字，links 指向 immutable release evidence。
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
