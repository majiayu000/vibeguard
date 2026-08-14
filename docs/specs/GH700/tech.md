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
| Production hook paths | `vibeguard-runtime/src/hook_orchestrator/dispatch.rs:69`, `vibeguard-runtime/src/hook_checks/bash.rs:144`, `vibeguard-runtime/src/hook_checks/write.rs:95`, `vibeguard-runtime/src/hook_orchestrator/stop.rs:65` | runtime 已有 hook orchestrator、危险命令分类、duplicate scan 与 unverified-stop 检测 | public cases 必须调用这些 canonical paths，而不是复制 detector |
| Unresolved class anchors | `vibeguard-runtime/src/hook_checks/checks.rs:323`, `guards/python/test_code_quality_guards.py:94`, `guards/python/test_code_quality_guards.py:144` | runtime 能检出不存在文件/编辑目标；silent broad exception checker 当前是 pytest-shaped Python guard | “invented API”与“swallowed exception”的 production mapping 仍需产品决策 |
| Actual installed wrappers | `hooks/run-hook.sh:8`, `hooks/run-hook.sh:38`, `hooks/run-hook.sh:83`, `hooks/run-hook.sh:180`, `hooks/run-hook-codex.sh:66`, `hooks/run-hook-codex.sh:89`, `hooks/run-hook-codex.sh:139` | stable Claude/Codex paths 从真实 HOME 的 installed snapshot 解析 hook，并以子进程处理 stdin/output/policy | B-011/B-024 的 E2E latency 必须 spawn 这些实际安装副本 |
| Runtime release identity | `scripts/setup/runtime-install.sh:112`, `scripts/setup/runtime-install.sh:123`, `scripts/setup/runtime-install.sh:129`, `scripts/setup/runtime-install.sh:160`, `scripts/setup/runtime-install.sh:186`, `scripts/setup/runtime-install.sh:272` | installer 已核对 asset SHA/manifest size/provenance，并写 repo/tag/target/sha；runner 尚未重算 `current_exe` 或绑定 payload/wrapper digests | B-021 要补成 actual-executable identity chain，不能只信 self-reported version |
| Existing digest primitive | `vibeguard-runtime/src/setup/support.rs:49`, `vibeguard-runtime/src/setup/support.rs:58`, `vibeguard-runtime/src/setup/support.rs:178` | runtime 内已有 SHA-256 file/text 实现 | 可扩成从一次打开的 `current_exe` file handle 流式求摘要，无需 shell hashing |
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
  **schemas/public_benchmark_failure_manifest.schema.json**、
  **schemas/publication_history.schema.json** 与 **schemas/release_identity.schema.json**；
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
传递闭包内全部 external executables，以及 target-specific production timed-exec guard
component/loader/service、immutable policy和 OS-attestation verifier/issuer roots；并固定 kind、来源
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
installer为普通 non-benchmark wrapper安装/激活 guard并持久化 target/component/policy/protection
state receipt；preflight验签并 challenge live OS state，benchmark不得安装、启用或重配。
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
child-exec audit 仅作预检。effectiveness 与 untimed latency-conformance 的完整 descendant tree 由 manifest/protocol 钉住的 OS-authoritative deny-by-default exec broker 监管；
每次 image 只放行 registry handle/digest或 manifest/launcher inherited-handle
`runtime_execution_grant`，禁止 pathname lookup，闭包外 identity 在执行前拒绝。broker
decisions/identities进入 report；无 pre-exec deny、失联/race或 undeclared exec 均 fail closed。
timed latency 前须以同 snapshot/case/schedule/fresh-state取得 signed `latency_exec_closure_receipt`，
再验 registry/manifest/install receipt与 live-state challenge；普通 non-benchmark wrapper已激活且每次都使用的 production guard才可随 `production_direct_v1`计时，per-invocation session setup在 timer内，benchmark不得 load/reconfigure。guard image前拒绝、tree后由 pinned OS issuer签 policy/session/event/root receipt；event loss/overflow/timed-only child整批无 headline sample。

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
`[-9007199254740991, 9007199254740991]`，任何更大 integer 使用 canonical decimal
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
  materialization/report render或 benchmark-only broker/proxy/tracer/RPC；不得 baseline-subtract；
- protocol/report绑定 `production_direct_v1`、production-topology identity、空
  `benchmark_only_interposition`与同批 closure receipt；`brokered_timed`拒绝；
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

release DAG固定为 build exact artifact→native matrix以 actual launcher运行 bench→逐平台 schema/provenance/
axis gate→按 canonical target生成 strict signed summary→valid或获批 publish_nonvalid才 publish。summary绑定
完整 required/display-only set、report/checksum/evidence digest、decision equality、per-surface latency/status；
summary digest只覆盖删除自身后的 JCS object，detached workflow attestation不回填。published tag不可改写，
README只消费该验签 summary，不读 stdout或游离附件。

publication实现不在本文复制 wire/state machine。权威分层为：

- [history contract](publication_history_contract.md)：durability、fold、transition/effect closure、trust与 owner；
- [authority protocol](publication_authority_protocol_contract.md)：time-bound payload core、trusted time与 bootstrap；
- [API semantics](publication_ledger_contract.md)：Release effective request、blocked ledger与业务验证；
- [machine schema](publication_authority_api.schema.json)：exact 17 client + 5 control registry、nested types、CAS、
  authorization、nonce/replay、success/error与 digest DAG；
- [positive models](publication_authority_api.models.json) 和
  [conformance vectors](publication_conformance_vectors.md)：每 method正例及 adversarial oracle。

T10只调用 client surface；T3独占 backend/control/broker/time/KMS/anchor credentials。H-006未批准或只有
host/client time时所有 time-bound method unavailable。authority不可用、policy/identity/frontier drift、
proof不完整或 remote outcome不明时零新 mutation。pre-intent只能在 authenticated no-effect/cleanup/revocation
proof后 terminal；post-intent只能恢复 matching public Release或 exact intent-bound draft，否则
release_recovery_blocked并保留 owner。pending generated PR、delivery、capsule、backup或 anchor均从 durable
ID/read-confirm恢复，不使用 local/mock fallback。

blocked attempt先持久化永久 record/frontier，再允许 pipeline失败；completion reconciler以 server-auth
terminal listing与同一 machine API补录/绑定。watermark必须覆盖每个 terminal attempt的完整 reconciliation；
unresolved、subset、snapshot drift或 anchor uncertainty阻断下一 publication。README/release regeneration只在
history与 blocked ledger双 frontier、summary/plan/review、all mutation slots及 external anchor全部 closed后进行。
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
| B-018 closed release-policy branches | release/README policy fixtures + completion reconciler | pre-intent claim/draft cleanup; pending de-current requires revocation receipt; merged de-current requires rollback. post-intent matching Release/draft completes and records only recovered publication; neither match → `release_recovery_blocked`; ambiguous draft/PR recovery blocks |
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
| B-029 immutable per-attempt blocked-release evidence | lease/watermark + two-phase draft reconciler | missing target uses explicit null identities; server-authenticated pre-attestation interruption remains enumerable and mutation-free without claim; exact ledger identity persists; all cancel edges converge or retain a blocked owner |
| B-030 readonly production-layout snapshot | signed-manifest handle reader + canonical-config/all-executable materializer + wrapper executor | user config/PATH mutation cannot change official output; only signed config/baseline/executable closure is copied, materialization is outside timer, and undeclared child exec fails before sampling |
| B-031 approved required-platform summary gate | protocol + strict summary preimage/detached attestation | delete-self-field JCS golden is unique; placeholder/self/attestation-in-preimage and omitted/replaced required or displayed inputs fail; all displayed reports are signed while only exact required evidence affects validity |

## Affected-file / test / command map

implementation ownership只取 [tasks](tasks.md)；GH-699 launcher path在 merge后探测，不猜文件名。

| concern | owner surface | focused proof |
| --- | --- | --- |
| bench CLI/model/corpus/runner/metrics/render/sandbox | runtime bench modules + main dispatch | cargo bench unit/integration tests |
| installed identity/launcher/exec guard | setup/install/release manifest + actual installed wrappers | fresh HOME, handle-backed digest, forwarding/sentinel matrix |
| report/summary/README/release failure | planned public benchmark schemas, release workflow, renderer/reconciler | strict summary, marker, release/nonvalid/blocked fixtures |
| publication authority | T3 runtime authority + deploy/bootstrap surfaces | machine schema/models/vectors, durable volume, TSA, KMS, Object Lock, DynamoDB |
| consumer/completion | T10 client only | no control/backend/credential; terminal listing/reconciliation |
| adversarial harness | T12 tests/fixtures | full union, crash/ack-loss, CAS/replay/auth/digest mutations |

implementation completion commands remain:

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

E2E通过不只看 exit 0：user repo/HOME/log/install/wrapper须 byte-identical，execution/secret sentinels不存在；
report/current-exe/protocol/required-set/summary digests重算；threshold与 fake/missing/undeclared executable边界
唯一；blocked record在短期 bundle删除后仍可由永久 ledger恢复；valid/nonvalid publication按 signed history
闭合。publication harness直接消费 machine schema/models/named vectors，并覆盖 claim/binding、genesis、
rollover、PR/release recovery、break-glass、backup/anchor rollback与 all-method negatives。

## 数据流

    source + embedded corpus/truth/mapping + GH-699 payload
      -> staged exact runtime -> current-exe/launcher identity preflight
      -> isolated production-wrapper runs -> semantic + latency axes
      -> canonical report -> strict signed required-platform summary
      -> valid publication | publish_nonvalid | permanent blocked attempt

benchmark不接收用户数据；publication网络仅到 manifest-pinned authority/broker。持久化闭集为本次 local
report、published release evidence/短期 failure bundle，以及 authority永久 inventory：SQLite/WAL、history/
blocked records及 indexes、trusted-time preparations/proofs/high-water、capsules/outbox/audits、encrypted
Object-Lock backup versions/KMS attestations、signer receipts与 DynamoDB epochs/HEAD。短期 bundle/fixture清理
不得删除永久 ledger或 recovery evidence；缺任一 durable item即 non-ready。README只消费 published、
digest-matched summary。
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

- [ ] Unit：corpus/truth/mapping joins、integer边界、decision/reason closure、axis/terminal聚合、digest、
  latency、redaction/cancellation/path containment；publication直接参数化 22-method schema/models。
- [ ] Integration：released install的五类 cases、identity/config/launcher/timing/concurrency/interruption/
  sentinel negatives；authority覆盖 durable replay、CAS/auth、trusted time、capsule、backup/anchor及 recovery。
- [ ] Release：strict native summary、source→ledger→publication顺序、draft/PR/Release send-once与
  valid/nonvalid/invalidation/blocked state closure；README双 locale marker只从 immutable evidence生成。
- [ ] Regression：cargo check/test；tests/test_behavior_eval.sh；tests/test_hook_perf_contract.sh；
  tests/test_release_workflow.sh；planned tests/test_public_benchmark.sh；local-contract-check --quick。
- [ ] Manual：无 checkout、Cargo/API key的新 macOS/Linux release install各运行实际 launcher一次，核对
  current-exe chain、JSON/human一致、无用户数据访问及 per-platform latency。

## 回滚方案

- 在 GH-699 actual launcher/receipt 尚未合并或尚无 valid report 时，不把 runtime
  开发入口标 official；它保持 `unofficial`/`unavailable`。
- 若 current release 的 runner/corpus/report 有缺陷，只能按
  [publication history contract](publication_history_contract.md) 的 invalidation machine执行
  reviewed all-surface PR与 post-merge receipt；旧 evidence 不删除/改写。
- README 生成区可通过回滚生成 PR 恢复到最后一份**明确标注版本**的报告，但不得把该旧值
  标为当前 release。
- runner 回滚不修改现有 hooks/guards policy；GH-686、behavior eval、
  `scripts/benchmark.sh` 与现有 latency SLA 继续独立工作。
- 回滚 release workflow 时保留既有 failure bundles/attestations 与 ledger history；
  禁止通过删除历史 tuple 或覆盖 artifact“清理”失败证据。
