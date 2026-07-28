# Task Plan — GH700 公开可复现效果基准

## Linked Issue

GH-700

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## 实现任务

- [ ] `SP700-T1` 固化 official benchmark protocol 与产品决策门：把获批的 `interception_decisions`、两个未决 production mappings、`required_platforms`、`release_policy`、每类最少正/负样本数，以及 protocol-owned canonical benchmark config、per-case initial-state identities、每个 latency surface 的 ordered case IDs/repetitions/interleaving schedule 写入 versioned/digested protocol；用户 config 与 runner 自选 workload 永不进入 official 输入。Covers: B-002, B-003, B-006, B-009, B-011, B-012, B-018, B-026, B-031. Owner: maintainer decision owner + protocol implementation owner. Depends on: product/tech spec review；当前未决产品选择的可验证批准记录。Done when: protocol schema/fixture 只接受闭集决策、合法 required set/config/state/schedules；缺批准值、未知/重复/乱序 case、非正 repetition 或用户 config 注入都在零 case/零 timed sample 前 unavailable。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::protocol`; `bash tests/test_public_benchmark.sh`.

- [ ] `SP700-T2` 扩展 offline-verifiable release identity 与 handle chain：verified installer 持久化签名 attestation bundle、signed release manifest、pinned trust-root version 和只作 local path mapping 的 `release-identity.json`；bench 离线验签 issuer/workflow/repo/source/subject，再从一次打开的 `current_exe` 与身份专用 no-follow handles 重算 manifest 绑定的 runtime/payload/wrapper/canonical benchmark config bytes。用户可变 config、receipt 自报 identity、目录枚举、任意 HOME 读写、`argv[0]`/PATH/cwd fallback 均禁止。Covers: B-002, B-013, B-016, B-021, B-024, B-028, B-030. Owner: release identity implementation owner. Depends on: SP700-T1 protocol identities；GH-699 payload contract。Done when: missing/modified bundle、wrong root/issuer/workflow/subject、receipt+payload 同时篡改、checksum-only、symlink/hard-link、wrong mode/metadata race、用户 config 变化与额外 HOME path 均在 executor 前 fail closed；合法 bundle 可在无网络环境复验。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::identity`; `bash tests/test_setup.sh`; `bash tests/test_public_benchmark.sh`.

- [ ] `SP700-T3` 先建立不依赖 production entrypoint 的 corpus/ground-truth/mapping/protocol/report/summary schemas、reviewer schema、RFC 8785 JCS canonicalizer/golden vectors，以及 prior-release attestation/genesis ledger validator；JSON number 限制在 ±9007199254740991，越界 identity 使用 canonical decimal string。Covers: B-004, B-016, B-019, B-022, B-025, B-026, B-027, B-031. Owner: evidence-schema and ledger owner. Depends on: SP700-T1 protocol shape与明确 genesis approval。Done when: Rust/Python 对 safe-integer 边界 byte-identical、±1 越界/float/duplicate key/未知 profile fail；strict summary schema 要求 exact input bindings/digest/attestation；prior-anchor mutation matrix fail closed，且不等待 SP700-T4。Verify: `python3 scripts/ci/validate_public_benchmark.py`; `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::digest`; `bash tests/test_public_benchmark.sh`.

- [ ] `SP700-T4` 在 SP700-T3 schema/validator 已冻结后补齐五类真实 production surface，并最终 populate reviewed corpus、matched ground truth、production mapping 与新 ledger tuple：尤其是 `invented_api` 与 `swallowed_exception` 必须按 SP700-T1 的明确产品选择实现可复用 released detector/guard；不得新增 benchmark-only regex、case-ID 分支、mock/stub 或把“不存在路径”改名为 API inventory；dangerous mapping 必须经过独立 security review。Covers: B-003, B-004, B-005, B-006, B-025, B-026, B-027. Owner: production detector owners + corpus/mapping single writer + independent security reviewer. Depends on: SP700-T1 的 mapping/样本决策；SP700-T3 的 schema/canonicalizer/trust-anchor validator；每个 detector 遵循其所属 runtime/guard 的独立 spec、test 与 human security-review gate。Done when: 五类 positive/matched negative 与独立 review evidence 全部存在，mapping 只指向 release payload/installed wrapper 的 canonical production entrypoint并只接受闭集 raw decisions/reasons，新 tuple append 到受信 prefix；任何未落地类别使整体 official headline `unavailable`，不能被 fixture 伪装。Verify: `python3 scripts/ci/validate_public_benchmark.py`; `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::mapping`; `bash tests/test_public_benchmark.sh`; 对新增 guard 运行其 focused production tests.

- [ ] `SP700-T5` 注册 runtime `bench`、实现 preflight/official boundary，并在 GH-699 actual launchers 合并后修改每个 manifest-declared Homebrew/npm installed launcher，使 `bench` 及剩余 argv/stdin/stdout/stderr/exit code 透明转发到同一 verified runtime，绝不进入 bootstrap/setup/init；no-clone fixture 按入口探测真实 path/argv，不猜 shim。Covers: B-001, B-002, B-015, B-019, B-020, B-021, B-028, B-031. Owner: benchmark CLI + distribution launcher owner. Depends on: SP700-T1–SP700-T4；GH-699 T3–T6 merged launcher anchors。Done when: fresh release install 的每个支持入口运行 `bench --json`，unknown arg/nonzero passthrough 与 IO capture 精确；setup/init sentinels不存在；任一入口缺 dispatch 则 official unavailable。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::preflight`; `bash tests/test_public_benchmark.sh`; no-clone brew/npm launcher smoke.

- [ ] `SP700-T6` 实现隔离 sandbox、canonical-config readonly snapshot、sealed executor、per-case fresh state、并发输出与 process-tree cancellation：只从 SP700-T2 signed-manifest handles 和 SP700-T4 mapping 解析 assets；每个 A/B case 从 SP700-T1 digested initial-state fixture 创建独立 HOME/state/session/project/log root；每个子进程使用独立 Unix session/group 或 Windows Job Object，整树退出后才 report/cleanup。Covers: B-005, B-009, B-010, B-013, B-014, B-024, B-025, B-030. Owner: sandbox/executor owner. Depends on: SP700-T1, SP700-T2, SP700-T4, SP700-T5。Done when: history/circuit-breaker-sensitive fixtures 不受前一 case 影响；用户 config 变化不改 official output；并发 roots 不交叉；descendant cancel、tree-unconfirmed、cleanup canary与timer boundaries具名通过。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::sandbox`; `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::runner`; `bash tests/test_public_benchmark.sh`.

- [ ] `SP700-T7` 实现确定性 effectiveness 双运行、closed adapter、完整分母 metrics、axis 状态和 split digests：run A/B 使用全新 sandbox且按 case ID 排序；`execution_error`/timeout 进入 `positive_error|negative_error`、没有 production decision并强制 inconclusive；集中计算 TP/FN/FP/TN/error buckets、block/advisory/per-class counts，强制两条 denominator closure equations，再按 SP700-T3 的 `jcs-rfc8785-v1` bytes 生成跨平台 `decision_digest` 与 platform-bound `evidence_digest`。Covers: B-006, B-007, B-008, B-009, B-022, B-023, B-025, B-031. Owner: effectiveness and canonical-digest owner. Depends on: SP700-T3 canonicalizer；SP700-T4 populated mapping/corpus identities；SP700-T6 executor；与 benchmark model、runner、metrics、renderer 的其他写任务串行。Done when: 同 identity/parameters 的 A/B 语义完全一致且 error buckets 为零才可 valid；error cases 保留总分母但不进入 production-decision counts；零分母、方程/bytes/digest/decision/reason/order drift 均具名失败且无诊断 rate 冒充 headline；required targets 只比较 decision digest。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::metrics`; `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::digest`; `bash tests/test_public_benchmark.sh`.

- [ ] `SP700-T8` 实现独立 `bench_case_e2e_ms` latency axis：严格执行 SP700-T1 每个 surface 的 ordered case IDs、per-ID warmup/measurement repetitions 与 interleaving schedule，从 readonly snapshot 启动真实 wrapper，以单调时钟测 spawn-to-full-output/exit；输出 schedule identity 与 per-surface P50/P95/P99/max，绝不重排、抽样、挑最快或跨 surface/platform reduction。Covers: B-002, B-008, B-011, B-012, B-023, B-024, B-030. Owner: latency protocol owner. Depends on: SP700-T1, SP700-T2, SP700-T6。Done when: schedule mutation matrix拒绝 missing/reordered/substituted case/repetition；spy 证明每个 scheduled sample 精确 spawn wrapper；environment/error 只使 latency non-valid并保留独立 surface status。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::latency`; `bash tests/test_hook_perf_contract.sh`; `bash tests/test_public_benchmark.sh`.

- [ ] `SP700-T9` 建立唯一 `BenchReport`、strict schema、closed raw case evidence 与 3×3×terminal 状态/exit contract：case 保存闭集 raw decision/raw reason/rule ID + normalized fields但无 free text/payload/stderr；先纯 3×3 算 axis candidate，再由 closed terminal errors 一律 override 为 inconclusive/nonzero/blank headline；report write/schema failure 由 CLI/release failure surface表达，不伪造 report。Covers: B-006, B-008, B-014, B-015, B-019, B-020, B-022, B-023, B-025. Owner: report schema/renderer owner. Depends on: SP700-T7, SP700-T8。Done when: exhaustive 3×3×`terminal_ok|terminal_error`、raw→normalized golden、failed-write/schema/cleanup/process-tree matrix证明 human/JSON/exit一致且 renderer不重算。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::render`; `bash tests/test_public_benchmark.sh`.

- [ ] `SP700-T10` 接入 staged native benchmark、strict input-bound summary 与 serialized release evidence：summary schema按 target绑定 required set、exact evidence digest/report checksum、aggregation/per-surface result，计算/attest `summary_digest`；all attempts/reconciler/publish 共用 candidate lease（no cancel-in-progress）与 reconciliation watermark，新 attempt/publish 必须先证明所有 prior terminal failures 已永久记录。normal failure 与 hard-cancel reconciler共享 JCS/run-attempt/no-overwrite规则。Covers: B-016, B-018, B-021, B-022, B-027, B-029, B-031. Owner: release workflow + summary/reconciler owner. Depends on: SP700-T2, SP700-T3, SP700-T5, SP700-T7–SP700-T9。Done when: omitted/replaced/duplicated input summary fail；pending prior cancel、run listing/store failure、watermark lag、different bytes conflict全阻断 rerun/publish；合法 normal/hard-cancel records推进 watermark；只有验签 summary 可发布。Verify: `bash tests/test_public_benchmark.sh`; `bash tests/test_release_workflow.sh`.

- [ ] `SP700-T11` 只从 SP700-T10 验签 summary 生成 README/locale marker：每个平台显示 provenance/effectiveness/status/link，每个 protocol-declared latency surface 使用固定独立 P95/status 列或子行，不做 reduction；blocked 无 row，publish_nonvalid 仅同版本空 metric row。Covers: B-008, B-015, B-016, B-017, B-018, B-020, B-023, B-031. Owner: docs generator owner. Depends on: SP700-T9, SP700-T10；README human review gate。Done when: 3×3×terminal、surface add/remove/order、summary input/digest/attestation 与 current-marker golden全通过，手工数字/列漂移被 freshness拒绝。Verify: `python3 scripts/ci/render_public_benchmark.py --check`; `bash scripts/ci/validate-doc-paths.sh`; `bash scripts/ci/validate-doc-command-paths.sh`.

- [ ] `SP700-T12` 建立完整 adversarial harness，覆盖 offline bundle/receipt 双篡改、canonical config vs user config、per-case history reset、all-launcher forwarding、fixed latency schedules/per-surface docs、raw case evidence、safe-integer边界、3×3×terminal、strict summary input binding，以及 lease/watermark reconciliation race；继续覆盖既有 corpus/privacy/process-tree/ledger/error equations。Covers: B-001, B-002, B-003, B-004, B-005, B-006, B-007, B-008, B-009, B-010, B-011, B-012, B-013, B-014, B-015, B-016, B-017, B-018, B-019, B-020, B-021, B-022, B-023, B-024, B-025, B-026, B-027, B-028, B-029, B-030, B-031. Owner: integration-test owner. Depends on: SP700-T2–SP700-T11。Done when:每个 mutation 断言具体 artifact/state/exit，不只 exit 0；用户 canaries不变，secret/path不泄漏，unavailable/inconclusive零 executor/timed sample，publish ordering sentinels完整。Verify: `bash tests/test_public_benchmark.sh`; `bash tests/test_behavior_eval.sh`; `bash tests/test_hook_perf_contract.sh`; `bash tests/test_release_workflow.sh`.

- [ ] `SP700-T13` 在同一 immutable implementation head 完成生产回归、安全审查与 SpecRail merge evidence：运行全部 Rust、benchmark、behavior、hook、release、docs 和 broad contract gates；由 independent reviewer 对照 product/tech/tasks 核对 official identity、production-only mapping、参数数组、privacy/cleanup、完整分母、digest split、required-platform 与 permanent failure evidence，SEC-11 reviewer 另行确认 command-execution surface。Covers: B-001, B-002, B-003, B-004, B-005, B-006, B-007, B-008, B-009, B-010, B-011, B-012, B-013, B-014, B-015, B-016, B-017, B-018, B-019, B-020, B-021, B-022, B-023, B-024, B-025, B-026, B-027, B-028, B-029, B-030, B-031. Owner: verification owner + independent read-only reviewer + human security reviewer. Depends on: SP700-T12；GH-699 T3–T6 merged/no-clone launcher evidence for B-001 official claim；current-head CI/review threads/PR gate。Done when: fresh deterministic checks 全绿，reviewer/security findings 为零，PR head SHA、CI、0 unresolved threads、review artifacts 与 SpecRail PR gate evidence完全一致；merge/release 仍只按当前授权和对应 human gate执行。Verify: 运行本文件“验证”中的全部命令并记录 current-head reviewer、security review 与 `checks/pr_gate.py` 结果.

## 并行拆分

- `SP700-T1` 是 protocol/产品选择先行门；未获得明确产品值时，其余 lane 只能实现并验证
  `unavailable`，不得生成 official headline。
- `SP700-T2`、`SP700-T3` 可在 T1 的接口冻结后并行，文件所有权分别限定为
  release identity/install surface 与 public-benchmark schema/canonicalizer/ledger
  validator；T3 不等待 production entrypoint，禁止共享可写文件。
- `SP700-T4` 明确依赖 T3 已冻结的 schema/validator。每个 production detector lane 按
  具体 detector 分配不重叠文件，最终 corpus/mapping/ledger artifact 由 T4 的单一 writer
  populate；dangerous mapping 的 security review 是只读 lane，因此依赖图不存在 T3↔T4
  回边。
- `SP700-T5`–`SP700-T9` 共享 `vibeguard-runtime/src/bench/`，默认由一个 Rust owner
  按依赖串行完成，不拆共享写 lane。
- `SP700-T10` release workflow、`SP700-T11` docs generator 可在 T9 contract 冻结后并行，
  文件所有权不重叠；T12 集成 fixture 在两者完成后统一收口，T13 仅做验证/只读审查。

## 验证

```bash
python3 checks/check_workflow.py --repo . --spec-dir=docs/specs/GH700
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
git diff --check
```

## Handoff Notes

- Product invariant set 与 task `Covers:` union 均为 `B-001`–`B-031`，无 orphan invariant
  或额外 B-ID。
- 当前任务只规划不实现；GH-700 live label 仍为 `ready_to_spec`，implementation route
  的 duplicate gate 看见现有 PR #713 以及其他 cross-reference PR。本计划继续使用原
  PR #713，不创建重复实现 PR；真正开始 implementation 前必须重新收集 fresh
  issue/duplicate evidence，并把目标绑定到唯一实现 lane。
- GH-699 是 partial dependency：已合并 T1/T2 payload contract；B-001 official claim
  必须等待 T3–T6 actual launcher/native no-clone smoke 合并并由 fixture 实际探测。
- 产品 spec 的五项选择不能从代码或 auto 授权推导。未明确批准时，SP700-T1 必须保持
  official result `unavailable`；实现者不得把 Recommended proposal 当成已批准值。
- Stop conditions：任何 benchmark-only detector、mock/checkout/PATH fallback、
  current-exe/receipt/digest 不一致、reviewer role 重叠、dangerous fixture 被执行、
  secret/raw payload/path 泄漏、case 从 ground-truth denominator 消失、非 valid axis
  显示数字、required platform 被 display-only report 替代、blocked candidate 未先持久化
  完整 per-attempt manifest、focused/broad gate 失败或 current actionable review finding。
- Human gates 继续保留：未决产品选择、SEC-11 command-execution security review、
  final PR review、merge 与 release。
