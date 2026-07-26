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
| Installed latency contract | `docs/reference/hook-latency-contract.md:7`, `docs/reference/hook-latency-contract.md:18`, `docs/reference/hook-latency-contract.md:51` | `hook_e2e_ms` 包含 wrapper/process/config/logging，报告 P50/P95/P99/max，并识别 environment distortion | 新 public latency 必须保持 end-to-end 语义且独立标识 surface |
| Release artifact pipeline | `.github/workflows/release.yml:62`, `.github/workflows/release.yml:127`, `.github/workflows/release.yml:189`, `.github/workflows/release.yml:216` | 四 target build，原生 smoke，生成 checksum/manifest，release 不允许原地变更 | 官方 report 必须在 immutable publish 前从 staged artifacts 产生 |
| GH-699 dependency | `docs/specs/GH699/product.md:35`, `docs/specs/GH699/product.md:48`, `docs/specs/GH699/tech.md:21`, `docs/specs/GH699/tech.md:85` | 计划把 hooks/guards 等打入同 tag payload；Python eval 不进入 payload；payload smoke 在 macOS/Linux | public runner 的 production assets、launcher 与无 checkout 路径来自此依赖 |
| Public documentation | `README.md:301`, `README.md:305`, `README.md:306` | README 已区分 behavior eval 与 40-sample model-backed benchmark，但无 released deterministic table | 新表必须新增第三种、来源清楚的 evidence surface |

## 设计方案

### 1. Artifact model 与依赖门

新增独立 public-benchmark surface，不重命名或复用 `scripts/benchmark.sh`：

- canonical corpus source：`data/public_benchmark/v1.jsonl`；
- planned corpus schema：**schemas/public-benchmark-corpus.schema.json**；
- planned report schema：**schemas/public-benchmark-report.schema.json**；
- Rust 实现拆到 `vibeguard-runtime/src/bench/`，`main.rs` 只注册 `bench` 命令；
- corpus 以构建期只读资源编进 release binary，runner 不从 cwd 或用户可写路径寻找
  official corpus；
- 需要 shell/Python guard 的 case 只从 GH-699 同 tag、digest-matched payload 调用。

`bench` preflight 同时验证 binary build metadata、embedded corpus digest 与 payload
manifest metadata。release workflow 在 build 时注入 tag/source commit/target 的只读
metadata；缺字段的本地 cargo build 自动成为 `unofficial`，不能伪装 release。

GH-699 是 public done-when 的硬依赖，不是可静默 fallback：

- launcher 必须把当前 verified dist root 传给 runtime；
- payload manifest 必须列出 official corpus 会调用的 canonical hooks/guards；
- binary tag、payload version 与 manifest digest 任一不一致即 B-002 `unavailable`；
- 不搜索相邻 checkout，也不回退到 PATH 上同名脚本。

### 2. Corpus 与 ground truth

JSONL 每行使用封闭、schema-required fields，至少包括：

```json
{
  "case_id": "dangerous_shell_or_git.rm_home.positive.v1",
  "corpus_version": 1,
  "failure_class": "dangerous_shell_or_git",
  "ground_truth": "positive",
  "surface": "runtime_hook",
  "entrypoint": "pre-bash",
  "expected_decisions": ["block"],
  "expected_reason_ids": ["SEC-01"],
  "fixture": {},
  "review": {"status": "approved", "reviewer": "...", "evidence": "..."}
}
```

这只是字段形状；具体 reason ID、样本数量与两个未决类别的 executor 必须由维护者审核，
不能照示例猜。schema 额外拒绝 duplicate JSON keys、未知字段/枚举、空 ID、绝对路径、
`..` traversal、shell executor 与含 credential-like 字段的 fixture。

构建时生成 canonical normalized bytes 与 SHA-256；binary 暴露的 corpus bytes、
schema version、case count/class counts 和 digest 必须与 release report 一致。corpus
review evidence 是 tracked、可审查的元数据；detector 实际结果永远不能改写 ground truth。

每个 failure class 使用 positive/negative matched pair，尽量只改变被研究信号。runner
在执行前按 class/ground_truth 做 completeness、唯一性、production mapping 与审核状态
检查。任何失败发生在创建 sandbox 或调用 detector 前。

### 3. Production executor registry

Rust `bench` 内部建立封闭 executor registry，而不是让 corpus 提供任意 command：

- `runtime_hook`：调用 canonical runtime hook orchestration/check path；
- `payload_guard`：只允许 manifest 中预注册的固定脚本 ID，使用参数数组执行，不经
  `sh -c`/字符串拼接；
- 不提供 `command`、`shell`、任意 path 或 plugin executor。

`dangerous_shell_or_git` fixture 只作为 hook stdin 分类，绝不执行 payload 中的 command。
file/project fixtures 先在专用 temp root materialize 合成文件，再运行 canonical
pre/post/stop path。executor 输出经统一 adapter 转成 `{block, advisory, allow,
execution_error}`，但保留原始 decision/reason ID 供审计。

当前 production mapping：

- dangerous shell/git → runtime pre-bash classifier（已核实）；
- duplicate module/definition → runtime post-write scan（已核实，最终 fixture 语义需审核）；
- unverified done claim → stop orchestrator 的 verification-evidence detector（已核实）；
- invented API → **待维护者确认**：现有锚点只证明不存在 path/edit target，不证明
  dependency/API inventory；
- swallowed exception → **待维护者确认**：当前 canonical checker 是 pytest-shaped
  Python guard；若无法从 GH-699 release install 无额外工具链运行，必须 unavailable。

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

effectiveness semantic digest 只包含 provenance identity、interception 口径、case ID、
ground truth、normalized decision/reason 和 aggregate counts；排除 timestamp、duration、
temp path 与显示顺序以外字段。A/B digest 或 case decision 不同即 `inconclusive`，
两次证据都保留在有界报告中。

`execution_error` 仍留在 positive/negative denominator，同时使整体 effectiveness
`inconclusive`。聚合层集中计算 TP/FN/FP/TN、block/advisory counts 与 rates；human、
JSON、README renderer 不得各自重算。

### 6. Latency protocol

新增 surface 名 `bench_case_e2e_ms`，避免与现有 CI `hook_e2e_ms` 混淆。对每个
production surface：

- 先运行固定的 process/spawn baseline 与 clock sanity check；
- warmup 和 measurement counts 从已审核、embedded protocol 读取，均须正整数；
- 单调时钟包围 production entrypoint 调用，不含 sandbox materialization/report render；
- 输出 P50/P95/P99/max、runs、platform、runtime/payload identity 和 baseline；
- environment threshold 沿用已发布 protocol 字段，不从用户环境或 README 读取。

效果 A/B run 与 latency sample batch 分开，避免 confirmation 次数意外改变效果分母。
latency failure 只使 latency axis `inconclusive`；report top-level 反映部分有效状态，
README latency cell 留空并显示原因，不写 `0ms`。现有 hook SLA 仍由
`tests/bench_hook_latency.sh` 管理，本 issue 不新增或修改 pass budget。

### 7. Report、schema 与 exit semantics

内部 `BenchReport` 是唯一 aggregate；text 与 JSON 共享它。report 顶层至少包含：

- `schema_version`, `official`, `status`, `failure_categories`；
- binary/release/payload/corpus provenance；
- `interception_decisions` 与 protocol digest；
- effectiveness A/B semantic digests、confusion matrix、per-class metrics；
- latency environment、per-surface metrics/axis status；
- case-level normalized evidence（无 raw payload/stderr）；
- interruption/cleanup metadata。

report schema 使用 `additionalProperties: false` 保护闭集；reader 按显式 version
dispatch。旧版本映射不存在就报 `unavailable`，不做 duck typing。CLI `valid` 为 0，
其它状态为非零；`--json` stdout 只输出 JSON，diagnostic 到 stderr 且同样脱敏。

### 8. Release regeneration 与 README

调整 release DAG，使官方报告来自 staged、将要发布的 artifacts：

1. build runtime 与 GH-699 payload；
2. native matrix 下载准确 target binary + payload，校验 digests 后运行
   `bench --json`；
3. schema/provenance/cross-platform effectiveness digest gate；
4. 汇总 per-platform reports，生成 checksum，并对 report/summary attestation；
5. `publish-release` 一次性发布 binary、payload、checksums、manifest 与 benchmark
   reports；仍保留“release 已存在则拒绝变更”。

不能原生执行的 cross target 显式 `unavailable`，不得用 host binary 贴目标标签。
不同平台 effectiveness decision 应一致；差异使 release summary `inconclusive`。
latency 永远按平台分行。

README 使用 marker 管理的生成区，source 只能是已验证 release summary。由于当前 release
asset 不允许原地变更，推荐 post-release CI 从不可变 asset 生成一个独立 README PR，
保留 human review，不直接 push 高上下文文件。PR 同时更新英文 README 与已配置 locale
文档，generator 校验数字、版本、digest 和 report link。若维护者选择“inconclusive
阻断 release”，则不创建数字 PR；若选择“release 继续”，generator 创建明确
`unavailable` 行，绝不复制上一 release 数字。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 released one-command official mode | CLI registration + GH-699 launcher/payload smoke | release-install fixture without `.git`, `cargo`, Python eval or API key runs `vibeguard bench --json`; source build is `unofficial` |
| B-002 complete matched provenance before execution | build metadata + preflight | Rust negative matrix for missing/empty/mismatched tag, commit, target, corpus/payload digest asserts `unavailable` and zero executor calls |
| B-003 five classes with both polarities | corpus schema + completeness validator | corpus mutation tests remove each class/positive/negative side one at a time and assert preflight failure |
| B-004 reviewed immutable ground truth | corpus parser/digest/review gate | duplicate-key/ID, unknown enum, conflicting label, missing review and changed-content-same-version fixtures are rejected |
| B-005 production paths only | sealed executor registry | mutation test replaces each executor with unknown/test-only ID and asserts zero cases; code review confirms no case-ID detector branch |
| B-006 closed normalized decisions and declared interception subset | decision adapter + protocol config | exhaustive enum tests plus missing/empty/out-of-range `interception_decisions` negatives |
| B-007 complete denominator and metrics | one aggregate module | table-driven TP/FN/FP/TN cases including timeout/error prove integer identities, finite rates and no skipped denominator |
| B-008 honest statuses | preflight/run state machine | state-transition matrix proves prereq failure→unavailable, run failure→inconclusive, complete consistent run→valid |
| B-009 deterministic confirmation | dual-run executor + semantic digest | injected A/B reason/decision/order drift names exact case and produces nonzero inconclusive; latency-only drift does not alter effectiveness digest |
| B-010 idempotent/concurrent isolation | run context + exclusive output | two parallel process tests use disjoint roots/reports; sentinel install/repo/log files remain byte-identical |
| B-011 end-to-end latency semantics | latency sampler | fake monotonic clock proves measurement boundaries, warmup exclusion, quantiles and required OS/arch/run fields |
| B-012 distorted latency honesty | environment baseline + axis status | bad clock, zero runs, spawn distortion and sample error all blank headline latency without inventing zero; effectiveness axis remains independently evaluated |
| B-013 synthetic sandbox/privacy | sandbox/env builder + redactor | dangerous-command execution sentinel remains untouched; secret/path/env sentinel absent from stdout/stderr/JSON and child env capture |
| B-014 interruption and bounded cleanup | cancellation token + cleanup ledger | interrupt during case N stops N+1, writes partial nonzero report, removes only recorded temp root and preserves adjacent canary |
| B-015 shared human/JSON aggregate and exits | renderers + report schema | golden semantic comparison between text and JSON; schema validation and exit-code matrix for all statuses |
| B-016 staged exact release regeneration | release workflow + report provenance gate | `bash tests/test_release_workflow.sh` plus fixture manifests prove debug/old/wrong-target artifact cannot publish |
| B-017 generated README table | report-to-doc generator | golden report generates required columns/link; manual numeric drift in marker region fails freshness check |
| B-018 no stale-number fallback | release/README failure fixtures | missing report, invalid schema and interrupted workflow produce explicit unavailable row or release failure per approved policy, never relabeled previous values |
| B-019 explicit schema compatibility | versioned parsers | current/legacy/unknown schema fixtures prove only declared mapping loads; unknown version nonzero unavailable |
| B-020 unofficial isolation | CLI option policy + README ingest gate | custom/dev report carries `official:false`, uses separate path and is rejected by README generator |

## 数据流

```text
release source commit
  ├─ build metadata + embedded normalized corpus ──> staged runtime binary
  └─ GH-699 manifest ──> staged verified payload
                 │
                 ▼
        bench preflight (all digests + schema + completeness)
                 │
       isolated run A ── isolated run B
                 │             │
                 └── semantic comparison
                              │
        effectiveness aggregate + separate latency sampler
                              │
                      canonical BenchReport
                       ├─ human renderer
                       ├─ JSON + schema gate
                       └─ release summary/README generator
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
- Compatibility: GH-699 payload layout/launcher 尚未实现，schema 也会演进。缓解：
  explicit dependency gate、version dispatch、digest matching，无 checkout fallback。
- Performance: 双效果运行加独立 latency batch 会增加 release CI 时间。缓解：corpus
  固定有界、matrix 按 native target；具体样本数由维护者审核，不能为提速静默删分母。
- Maintenance: ground truth 与生产 detector 可能漂移。缓解：corpus version bump、
  production mapping gate、每 release regeneration 和 immutable prior reports。
- Product truthfulness: invented API/swallowed exception 当前 mapping 不完整。缓解：
  spec approval 明确决策；未决时 unavailable，不写 placeholder detector。

## 测试计划

- [ ] Unit tests: corpus/schema duplicate-key parsing、completeness、provenance/state machine、
      decision normalization、confusion matrix、semantic digest、quantiles、redaction、
      cancellation 与 path containment。
- [ ] Integration tests: released-install fixture 执行五类正/负 cases；wrong
      binary/payload/corpus、detector error、timeout、environment distortion、parallel runs、
      interruption、legacy schema 和 secret/canary negatives。
- [ ] Release contract: staged native binaries各自产出 schema-valid report；summary 只接受
      exact digests；existing-release mutation 仍被拒绝；unavailable policy 符合批准决定。
- [ ] Documentation: generator golden/freshness、英文与配置 locale 一致、README links 指向
      immutable release evidence。
- [ ] Existing regression:
      `cargo check --manifest-path vibeguard-runtime/Cargo.toml`；
      `cargo test --manifest-path vibeguard-runtime/Cargo.toml`；
      `bash tests/test_behavior_eval.sh`；
      `bash tests/test_hook_perf_contract.sh`；
      `bash tests/test_release_workflow.sh`；
      `bash scripts/local-contract-check.sh --quick`。
- [ ] Manual verification: 在无 checkout、无 Cargo/API key 的新 macOS/Linux release
      install 各运行一次 `vibeguard bench`，核对 report digest/link、无用户数据访问与
      per-platform latency 分行。

## 回滚方案

- 在尚无 valid release report 时，不暴露 official launcher 命令；开发入口保持
  `unofficial`。
- 若某 release 的 runner/corpus/report 有缺陷，发布更高版本修复并生成新 corpus/report；
  不删除或原地改写旧 release evidence，在 README 将受影响版本标为 invalid 并链接原因。
- README 生成区可通过回滚生成 PR 恢复到最后一份**明确标注版本**的报告，但不得把该旧值
  标为当前 release。
- runner 回滚不修改现有 hooks/guards policy；GH-686、behavior eval、
  `scripts/benchmark.sh` 与现有 latency SLA 继续独立工作。
