# Task Plan — GH700 公开可复现效果基准

## Linked Issue

GH-700

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## 实现任务

- [ ] `SP700-T1` 固化 official benchmark protocol 与产品决策门：把获批的 `interception_decisions`、两个未决 production mappings、`required_platforms`、`release_policy`、每类最少正/负样本数写入 versioned/digested protocol；任一选择未获明确批准、为空、越界、重复或未 canonical 排序时，official preflight 必须在零 case/零 timed sample 前 `unavailable`，不得由 CLI、renderer 或 release workflow 采用隐含默认值。Covers: B-002, B-003, B-006, B-011, B-012, B-018, B-026, B-031. Owner: maintainer decision owner + protocol implementation owner. Depends on: product/tech spec review；当前未决产品选择的可验证批准记录；GH-699 actual launcher 只作为 B-001 依赖，不阻止先实现 fail-closed protocol gate。Done when: protocol schema/fixture 只接受闭集决策与合法 required set，缺批准值的 official 命令输出同源 non-valid 状态并且 executor call count 为 0。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::protocol`; `bash tests/test_public_benchmark.sh`.

- [ ] `SP700-T2` 扩展 verified release identity receipt 与 handle-backed identity chain：installer 保存 versioned `release-identity.json`，绑定 repo/tag/source commit/target、runtime asset、release manifest、payload、wrapper 与 attestation；bench 从一次打开的 `current_exe` regular-file handle 计算 SHA-256、校验前后 metadata，并通过身份专用 no-follow reader 只读打开固定 receipt 及其闭集枚举的 installed files，逐项重算 bytes 后把 verified handles/bytes 交给 snapshot materializer；禁止目录枚举、任意 HOME 读取/写入、`argv[0]`、PATH、cwd 邻居、仅版本相同或 build-time 自报字段。Covers: B-002, B-013, B-016, B-021, B-024, B-028, B-030. Owner: release identity implementation owner. Depends on: SP700-T1 的 protocol identity shape；消费 GH-699 已合并 T1/T2 contract；actual launcher 路径只能在 GH-699 T3–T6 合并后由 no-clone fixture 探测。Done when: verified-provenance 的 exact bytes chain 可建立 official identity；checksum-only、缺 receipt、tamper、symlink/hard-link、wrong owner/mode/target/tag/commit、metadata race、额外 HOME path 与 wrapper/payload drift 均在 executor 前 fail closed，snapshot 完成后真实 HOME reader 已关闭。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::identity`; `bash tests/test_setup.sh`; `bash tests/test_public_benchmark.sh`.

- [ ] `SP700-T3` 先建立不依赖任何 production entrypoint 的 corpus/ground-truth/production-mapping/protocol schemas、reviewer evidence schema、RFC 8785 JCS canonicalizer/golden vectors，以及带 prior-release attestation/genesis trust-anchor 的 append-only ledger validator；空 mapping/未落地 entrypoint 必须合法表达为 official `unavailable`，但不能通过 completeness gate。Covers: B-004, B-019, B-022, B-025, B-026, B-027. Owner: evidence-schema and ledger owner. Depends on: SP700-T1 的 decision/protocol 闭集与明确 genesis approval（仅首个 release）。Done when: Rust/Python canonical bytes/digests 对 golden vectors 完全一致；duplicate key、float、未知 profile、reviewer overlap、checkout-only rewritten prefix、missing/wrong-lineage prior anchor、删除/重排/复用历史 tuple 全部 fail closed，且不需要先完成 SP700-T4。Verify: `python3 scripts/ci/validate_public_benchmark.py`; `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::digest`; `bash tests/test_public_benchmark.sh`.

- [ ] `SP700-T4` 在 SP700-T3 schema/validator 已冻结后补齐五类真实 production surface，并最终 populate reviewed corpus、matched ground truth、production mapping 与新 ledger tuple：尤其是 `invented_api` 与 `swallowed_exception` 必须按 SP700-T1 的明确产品选择实现可复用 released detector/guard；不得新增 benchmark-only regex、case-ID 分支、mock/stub 或把“不存在路径”改名为 API inventory；dangerous mapping 必须经过独立 security review。Covers: B-003, B-004, B-005, B-006, B-025, B-026, B-027. Owner: production detector owners + corpus/mapping single writer + independent security reviewer. Depends on: SP700-T1 的 mapping/样本决策；SP700-T3 的 schema/canonicalizer/trust-anchor validator；每个 detector 遵循其所属 runtime/guard 的独立 spec、test 与 human security-review gate。Done when: 五类 positive/matched negative 与独立 review evidence 全部存在，mapping 只指向 release payload/installed wrapper 的 canonical production entrypoint并只接受闭集 raw decisions/reasons，新 tuple append 到受信 prefix；任何未落地类别使整体 official headline `unavailable`，不能被 fixture 伪装。Verify: `python3 scripts/ci/validate_public_benchmark.py`; `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::mapping`; `bash tests/test_public_benchmark.sh`; 对新增 guard 运行其 focused production tests.

- [ ] `SP700-T5` 注册 `vibeguard bench` 并实现 embedded-input preflight、official/unofficial 边界与 launcher discovery：`main.rs` 仅分发到拆分后的 `bench/` 模块，official mode 固定 B-002 provenance 后才执行；开发 corpus、自定义 fixture、dirty/source build、checksum-only install 都逐层标 `unofficial` 且不能写 official 路径或被 README ingest；GH-699 actual launcher/no-clone smoke 未合并或未被 fixture 探测时只暴露 runtime 开发入口。Covers: B-001, B-002, B-015, B-019, B-020, B-021, B-028, B-031. Owner: benchmark CLI and preflight owner. Depends on: SP700-T1, SP700-T2, SP700-T3, SP700-T4；official one-command done-when 依赖 GH-699 T3–T6 merged evidence。Done when: verified release install 可通过实际探测到的 launcher 一条命令运行；所有不合格 provenance/official-input 路径在零 case 时非零退出且不生成 headline。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::preflight`; `bash tests/test_public_benchmark.sh`.

- [ ] `SP700-T6` 实现每次运行的隔离 sandbox、readonly production-layout snapshot、sealed executor registry、并发输出与可取消 cleanup：仅从 SP700-T2 verified handles/bytes 与 mapping 解析 installed wrappers/manifest-registered guards，以参数数组和最小 env 启动；dangerous fixture 只送 classifier；拒绝任意 command/path/shell、checkout/PATH fallback、symlink/hard-link/traversal、可写 snapshot 与 digest drift。每个 case 在独立 Unix session/process group 或 Windows kill-on-close Job Object 中运行；中断停止新 case，终止并等待完整 wrapper/shell/runtime 进程树后才写 partial report并清理记录的 temp root。Covers: B-005, B-010, B-013, B-014, B-024, B-025, B-030. Owner: sandbox and executor owner. Depends on: SP700-T2 identity channel；SP700-T4 populated sealed mapping；SP700-T5 preflight；与共享 `bench/` 文件的任务串行。Done when: 两个并发 process 使用不同 root/report；descendant-spawning fixture 证明 cancel 后整树退出且 N+1 不启动；无法确认退出时保留 temp 并失败可见；用户 repo/HOME/log/install bytes 与 canary 不变，snapshot materialization 全部在 timer 之前。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::sandbox`; `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::runner`; `bash tests/test_public_benchmark.sh`.

- [ ] `SP700-T7` 实现确定性 effectiveness 双运行、closed adapter、完整分母 metrics、axis 状态和 split digests：run A/B 使用全新 sandbox且按 case ID 排序；`execution_error`/timeout 进入 `positive_error|negative_error`、没有 production decision并强制 inconclusive；集中计算 TP/FN/FP/TN/error buckets、block/advisory/per-class counts，强制两条 denominator closure equations，再按 SP700-T3 的 `jcs-rfc8785-v1` bytes 生成跨平台 `decision_digest` 与 platform-bound `evidence_digest`。Covers: B-006, B-007, B-008, B-009, B-022, B-023, B-025, B-031. Owner: effectiveness and canonical-digest owner. Depends on: SP700-T3 canonicalizer；SP700-T4 populated mapping/corpus identities；SP700-T6 executor；与 benchmark model、runner、metrics、renderer 的其他写任务串行。Done when: 同 identity/parameters 的 A/B 语义完全一致且 error buckets 为零才可 valid；error cases 保留总分母但不进入 production-decision counts；零分母、方程/bytes/digest/decision/reason/order drift 均具名失败且无诊断 rate 冒充 headline；required targets 只比较 decision digest。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::metrics`; `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::digest`; `bash tests/test_public_benchmark.sh`.

- [ ] `SP700-T8` 实现独立 `bench_case_e2e_ms` latency axis：从 SP700-T6 的 readonly production-layout snapshot 启动 receipt 记录的真实 Claude/Codex installed wrapper 子进程，以单调时钟测量 spawn-to-full-output/exit，materialization、warmup 与 render 不计时；按 surface 报正整数 warmup/runs、P50/P95/P99/max、样本数、OS/arch 与 environment baseline，不跨平台平均。Covers: B-008, B-011, B-012, B-023, B-024, B-030. Owner: latency protocol owner. Depends on: SP700-T1 approved counts/thresholds；SP700-T2 wrapper identity；SP700-T6 snapshot/executor；与共享 `bench/` 文件的任务串行。Done when: spy 证明每个 timed sample 都 spawn exact installed wrapper 并等待完整 IO/exit；clock/baseline/sample/run/digest 异常只使 latency non-valid且 headline 留空，不重写独立 effectiveness verdict。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::latency`; `bash tests/test_hook_perf_contract.sh`; `bash tests/test_public_benchmark.sh`.

- [ ] `SP700-T9` 建立唯一 `BenchReport`、versioned strict schema、3×3 状态聚合与同源 human/JSON render/exit contract：renderer 只消费 aggregate，不重算 metrics/status；`valid+valid→valid`、`unavailable+unavailable→unavailable`、其余七种组合→`inconclusive`；非 valid axis 使用空值/破折号加闭集原因，unknown legacy schema 明确 unavailable，JSON stdout 与 diagnostic stderr 均脱敏。Covers: B-008, B-014, B-015, B-019, B-020, B-022, B-023, B-025. Owner: report schema and renderer owner. Depends on: SP700-T7, SP700-T8；与共享 benchmark model/renderer 的写任务串行。Done when: exhaustive 3×3 golden、schema/version/exit matrix 和 interruption partial report 证明 human/JSON 语义一致，只有 top-level valid 退出 0，非 valid 不显示 `0%`/`0ms`/`pass` 或历史值。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::render`; `bash tests/test_public_benchmark.sh`.

- [ ] `SP700-T10` 接入 staged native release benchmark、required-platform summary gate、可信 prior-ledger anchor 与不可覆盖 blocked-candidate evidence：native jobs 使用 exact binary + same-tag payload/receipt；可恢复 `block_release` 在退出前永久写完整 attempt manifest；独立 completion reconciler 对 hard-cancel/runner loss/timeout 的终态事件写 `pipeline_interrupted` null-evidence manifest并审核 publish sentinels，不依赖已终止 job post-step。两条路径共享 `jcs-rfc8785-v1`、run/attempt identity、no-overwrite/idempotency/conflict rules，且不创建 Release/page/assets/current row。Covers: B-016, B-018, B-021, B-022, B-027, B-029, B-031. Owner: release workflow + completion reconciler + permanent-evidence owner. Depends on: SP700-T2, SP700-T3, SP700-T5, SP700-T7, SP700-T8, SP700-T9；publish 动作继续受 release human gate。Done when: exact staged identity 与 required/display-only matrix全覆盖；normal failure、hard-cancel 和 duplicate terminal delivery fixtures均产生/验证唯一 attempt record，different bytes conflict fail；删除短期 bundle后仍可恢复完整 manifest；`publish_nonvalid` 只在 mandatory evidence valid 时发布同版本 non-valid evidence。Verify: `bash tests/test_public_benchmark.sh`; `bash tests/test_release_workflow.sh`.

- [ ] `SP700-T11` 实现从不可变 exact-release summary 生成 README benchmark marker 区与 configured locale 文档：每个平台独立显示 release、corpus identity、样本数、interception 口径/rate、FPR、latency P95、axis/top-level 状态及 immutable report link；只显示 axis-valid 数值，blocked candidate 不生成 row，publish_nonvalid 只生成同版本 non-valid row，且与既有 behavior eval/40-sample model benchmark 明确分区。Covers: B-008, B-015, B-017, B-018, B-020, B-023, B-031. Owner: documentation generator owner. Depends on: SP700-T9 report contract；SP700-T10 release summary contract；高上下文 README 更新由独立生成 PR 和 human review gate 持有。Done when: 3×3/current-marker golden 全通过，手工数字漂移被 freshness check 拒绝，旧 release 数据不可能换 tag 冒充 current。Verify: `python3 scripts/ci/render_public_benchmark.py --check`; `bash scripts/ci/validate-doc-paths.sh`; `bash scripts/ci/validate-doc-command-paths.sh`.

- [ ] `SP700-T12` 建立 corpus/schema/identity/privacy/concurrency/process-tree cancellation/canonical digest/latency/release 的完整 adversarial fixture harness，逐一覆盖每个 B-xxx 且断言产物：真实 HOME allowlist 外读取/全部写入被拒；descendant tree 在 cleanup 前终止；TP/FN/FP/TN/error closure 方程成立；Rust/Python JCS golden bytes一致；rewritten checkout ledger 被 prior attestation 拒绝；hard-cancel 由外部 reconciler 永久记录且重复事件幂等。Covers: B-001, B-002, B-003, B-004, B-005, B-006, B-007, B-008, B-009, B-010, B-011, B-012, B-013, B-014, B-015, B-016, B-017, B-018, B-019, B-020, B-021, B-022, B-023, B-024, B-025, B-026, B-027, B-028, B-029, B-030, B-031. Owner: public benchmark integration-test owner. Depends on: SP700-T2–SP700-T11；test fixtures 不得替代 production detector 或弱化现有 assertions。Done when: positive/negative/legacy/error/timeout/interruption/platform/policy mutation matrix全部具名通过，用户 repo/HOME/log/install canary byte-identical，secret/path 不出现在任何 surface，blocked attempt 在短期 bundle 删除后仍可恢复，并证明 unavailable/inconclusive 非零、零 executor/timed sample 与所有 publish sentinels。Verify: `bash tests/test_public_benchmark.sh`; `bash tests/test_behavior_eval.sh`; `bash tests/test_hook_perf_contract.sh`; `bash tests/test_release_workflow.sh`.

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
