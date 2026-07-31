# Task Plan — GH700 公开可复现效果基准

## Linked Issue

GH-700

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## 实现任务

- [ ] `SP700-T1` 固化 official benchmark protocol 与 H-001–H-005 产品决策门：除获批 decisions/mappings/required set/release policy/corpus counts 外，钉住 canonical benchmark config、effectiveness initial states、每个 latency surface 的 ordered cases/repetitions/interleaving、每个 executor 的 timeout/termination-grace/stdout/stderr caps、引用唯一 `production_asset_registry` logical IDs 的 target-specific interpreter 与 production path 全部 external-executable identities/exec-argv contracts、`fresh_per_sample` latency state/initial-state 和 `nearest_rank_v1` estimator（integer ns，Pq=`ceil(q*n/100)-1`，无插值），以及 environment baseline 的 registry-bound no-op workload logical ID/exec-argv contract、protocol-owned stdin/env、warmup/measurement/interleaving、timer boundary、闭集 `nearest_rank_p95_v1`（`baseline_stat_ns=samples[ceil(95*n/100)-1]`，无插值）、threshold 与 inclusive comparison。用户 config、ambient PATH、limit overrides、cumulative sample state 与 runner 自选 estimator/workload 永不进入 official 输入。Covers: B-002, B-003, B-006, B-009, B-011, B-012, B-018, B-024, B-026, B-031. Owner: maintainer decision + protocol owner. Depends on: product/tech review与未决选择批准。Done when: missing/invalid decisions/config/state/schedule/estimator/limits/registry entry、unknown/reordered case、state reuse、非正 repetition 或 cap 均在零执行前 unavailable；n=1/2/3/20/21 percentile 及 baseline threshold-1/equal/+1、count/order/timer-boundary goldens固定。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::protocol`; `bash tests/test_public_benchmark.sh`.

- [ ] `SP700-T2` 扩展 offline-verifiable release identity、trusted-launcher mapped-image binding 与 handle chain：installer 持久化 signed bundle/manifest/pinned roots/receipt；独立受信的最小 native launcher 在执行 runtime 前验签 manifest、打开并校验 manifest 直接绑定的 target runtime handle size/SHA-256/metadata，并验证 manifest 绑定的 protocol/`production_asset_registry` digest，随后才在 Unix 从同一 handle `fexecve/execveat` 并传 identity fd，或在 Windows 从 deny-write/delete handle 启动并持有到 child handshake；child 从 inherited binding handle 重算 runtime identity 只作 defense in depth，再严格按 registry entries 验证 payload/wrapper/canonical config/interpreter/baseline workload 及其它 declared external executables。`current_exe` pathname仅诊断。Covers: B-002, B-013, B-016, B-021, B-024, B-028, B-030. Owner: identity + launcher owner. Depends on: SP700-T1；GH-699 payload。Done when: untrusted/replaced launcher、pre-exec runtime digest mismatch、start-malicious-then-replace-path-with-signed-binary、bundle/receipt双篡改、wrong root/issuer/subject、checksum-only、symlink/metadata race/user config/undeclared executable 均 fail closed；不支持 trusted launcher 或 handle-bound exec 的平台 official unavailable。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::identity`; `bash tests/test_setup.sh`; `bash tests/test_public_benchmark.sh`.

- [ ] `SP700-T3` 在明确的 **schemas/public_benchmark_protocol.schema.json** 建立 protocol ownership，并建立 corpus/truth/mapping/report/summary/failure-manifest/review-record/publication-history schemas、JCS canonicalizer、reviewer verifier与 corpus-ledger validator。publication frontier 为 `(repo_node_id,length,root,full_prefix_digest)`；history transition分为 fence-independent immutable intent、mutable append authorization envelope与 store-signed committed envelope/receipt。op ID/intent绑定 repo/owner-generation/run/slot/predecessor/kind/payload且 schema拒绝 authorization fence；request另携 current fence/lease/actor。store先查事务 repo+op unique index：same digest返原 receipt，异 digest冲突；absent才验 current generation/fence/predecessor并 append/sign。fold/merge gate只消费 intent owner-generation + committed-envelope actual fence。ack-loss：committed op返原 receipt；uncommitted old fence失败，同 generation续租后用 same intent+new fence重授权；advanced禁止 rebase并按 suffix恢复或 new predecessor/generation/slot重规划；takeover前未提交旧 generation永久失效。versioned JCS union覆盖所有 record与六类 blocked，fold拒绝 ABA。Covers: B-004, B-016, B-019, B-022, B-025, B-026, B-027, B-029, B-031. Owner: schema/integrity owner. Depends on: T1。Done when:每种 record 的 commit前 timeout/commit后 ack-loss/restart+renewed-fence、immutable-intent fence-field injection、gate actual-fence source、old/new fence same-op/receipt、concurrent fences、same-ID digest冲突、takeover-before/after append、terminal/replan suffix、generation/fence reuse、index/receipt/envelope tamper、truncate/fork矩阵全绿。Verify: `python3 scripts/ci/validate_public_benchmark.py`; `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::digest`; `bash tests/test_public_benchmark.sh`.

- [ ] `SP700-T4` 在 SP700-T3 schema/roster validator 冻结后补齐五类 production surfaces并 populate corpus/truth/mapping/ledger：mapping 只引用 registry logical IDs；每条 ground-truth/mapping/security review record 必须由 roster identity 签名并绑定 artifact digest/role/decision/source commit；不得用多个自报 ID 伪造独立性。Covers: B-003, B-004, B-005, B-006, B-025, B-026, B-027. Owner: detector owners + corpus/mapping single writer + authenticated independent reviewers. Depends on: SP700-T1, SP700-T3与各 detector security gate。Done when:五类 matched pairs、signed review records与released mappings齐全；mapping digest/path injection、roster/record/overlap mutation fail；未落地类别 official unavailable。Verify: `python3 scripts/ci/validate_public_benchmark.py`; `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::mapping`; `bash tests/test_public_benchmark.sh`.

- [ ] `SP700-T5` 注册 runtime `bench`、实现 preflight/official boundary，并在 GH-699 actual launchers 合并后修改每个 manifest-declared Homebrew/npm installed launcher，使 `bench` 及剩余 argv/stdin/stdout/stderr/exit code 透明转发到同一 verified runtime，绝不进入 bootstrap/setup/init；no-clone fixture 按入口探测真实 path/argv，不猜 shim。Covers: B-001, B-002, B-015, B-019, B-020, B-021, B-028, B-031. Owner: benchmark CLI + distribution launcher owner. Depends on: SP700-T1–SP700-T4；GH-699 T3–T6 merged launcher anchors。Done when: fresh release install 的每个支持入口运行 `bench --json`，unknown arg/nonzero passthrough 与 IO capture 精确；setup/init sentinels不存在；任一入口缺 dispatch 则 official unavailable。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::preflight`; `bash tests/test_public_benchmark.sh`; no-clone brew/npm launcher smoke.

- [ ] `SP700-T6` 实现隔离 sandbox、canonical-config readonly snapshot、sealed executor、per-case fresh state、protocol-bound limits/executables、并发输出与 process-tree cancellation：只从 SP700-T2 signed-manifest handles 和 SP700-T4 mapping 解析 assets；每个 A/B case 从 SP700-T1 digested initial-state fixture 创建独立 HOME/state/session/project/log root；每个子进程从 readonly snapshot 的 verified executable 精确路径/handle 启动；static inventory/audit只作预检，OS-authoritative exec broker 在每次 descendant image 启动前只放行 registry logical ID 或 manifest/launcher handle 派生的 singleton runtime grant，禁止 pathname/self-registry fallback，unsupported/race/broker loss 均 fail closed；并应用 protocol limits、独立 process group/Job Object、整树 cleanup。Covers: B-005, B-009, B-010, B-013, B-014, B-024, B-025, B-030. Owner: sandbox/executor owner. Depends on: SP700-T1, SP700-T2, SP700-T4, SP700-T5。Done when: history/circuit-breaker-sensitive fixtures 不受前一 case 影响；用户 config/ambient PATH/limit override 不改 official output；real wrapper runtime 被 grant 放行，fake runtime、只在后续分支触发的 undeclared child exec、broker failure、cap/timeout fail closed；并发 roots 不交叉；descendant cancel、tree-unconfirmed、cleanup canary与timer boundaries具名通过。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::sandbox`; `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::runner`; `bash tests/test_public_benchmark.sh`.

- [ ] `SP700-T7` 实现确定性 effectiveness 双运行、closed adapter、完整分母 metrics、axis 状态和 split digests：run A/B 使用全新 sandbox且按 case ID 排序；mapping-declared success/no-payload/no-reason 精确映射 `allow/no_interception`，其它 missing/unknown/multiple raw fields 与 `execution_error`/timeout 进入 `positive_error|negative_error`、没有 production decision并强制 inconclusive；集中计算 TP/FN/FP/TN/error buckets、block/advisory/per-class counts，强制两条 denominator closure equations，再按 SP700-T3 的 `jcs-rfc8785-v1` bytes 生成跨平台 `decision_digest` 与 platform-bound `evidence_digest`。Covers: B-006, B-007, B-008, B-009, B-022, B-023, B-025, B-031. Owner: effectiveness and canonical-digest owner. Depends on: SP700-T3 canonicalizer；SP700-T4 populated mapping/corpus identities；SP700-T6 executor；与 benchmark model、runner、metrics、renderer 的其他写任务串行。Done when: 同 identity/parameters 的 A/B 语义完全一致且 error buckets 为零才可 valid；no-interception allow 与真正缺失字段 goldens 分离；error cases 保留总分母但不进入 production-decision counts；零分母、方程/bytes/digest/decision/reason/order drift 均具名失败且无诊断 rate 冒充 headline；required targets 只比较 decision digest。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::metrics`; `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::digest`; `bash tests/test_public_benchmark.sh`.

- [ ] `SP700-T8` 实现 `bench_case_e2e_ms`：严格执行 ordered cases/repetitions/interleaving，并为每个 warmup/measurement sample 从 latency initial-state 创建新 HOME/log/history/session；warmup state不进入measurements。每个 sample 从 readonly snapshot 的 protocol-bound executable set 启动 wrapper，并应用同一 protocol 的 timeout/grace/stdout/stderr caps；sampling 前按 protocol 执行 `production_asset_registry`-bound no-op baseline logical ID/exec-argv contract 与 protocol-owned stdin/env/warmup/measurement/interleaving/timer/estimator/threshold contract。raw integer ns 用 `nearest_rank_v1`（ceil rank，无插值）计算 per-surface P50/P95/P99/max，输出 schedule/state/estimator/limits/executable/baseline identities且不做 reduction。Covers: B-002, B-008, B-011, B-012, B-023, B-024, B-030. Owner: latency owner. Depends on: SP700-T1, SP700-T2, SP700-T6。Done when: history/log-growth fixture在不同实现产生相同样本语义；ambient PATH、默认 limit、cumulative reuse、floor estimator、order/repetition drift被拒；percentile boundary-count 与 baseline threshold-1/equal/+1、count/order/timer-boundary golden全绿。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::latency`; `bash tests/test_hook_perf_contract.sh`; `bash tests/test_public_benchmark.sh`.

- [ ] `SP700-T9` 建立唯一 BenchReport、closed raw evidence 与 3×3×terminal outcome contract：先算 axis candidate；`interrupted`（即使两轴已valid且cleanup成功）和 process-tree/report/schema/cleanup failures 都 override 为 inconclusive/nonzero/blank headline；cleanup 完成并把最终 closed result 纳入 terminal record 后才 exclusive-create 封口 report。Covers: B-006, B-008, B-014, B-015, B-019, B-020, B-022, B-023, B-025. Owner: report/renderer owner. Depends on: SP700-T7, SP700-T8。Done when: completed-axes-then-clean-cancel、cleanup-fails-before-seal golden 与所有 failure matrix不可能 exit0；immutable report 包含最终 cleanup error；privacy只剔除free text/payload/stderr而保留closed raw fields。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::render`; `bash tests/test_public_benchmark.sh`.

- [ ] `SP700-T10` 接入 strict summary 与统一 publication state machine：所有 actors 使用 `repo_node_id`，按 source/candidate→ledger→publication→branch CAS；每次 history append遵循 T3 fence-independent intent + current-fence authorization，restart续租只更换 request envelope，不改 op/intent bytes。首次 Release API/PR mutation前 CAS owner claim，draft response后/upload前 bind，重验后 prepared。四类 original/replacement PR在首次 ref/commit/PR mutation前 planned，response后 bound；lost response枚举 all states+ref，active/merged/closed分别 bind/恢复/revoke，ordinary zero保owner且不重发，仅线性化 exhaustive-negative证明 absence，其它按 kind blocked。rollover latest-frontier gate/revoke receipt与 fresh fence/head/nonce/review拒绝 late bind/merge/reopen/ABA。intent_written是两类 commit state唯一 predecessor；reconciler仅 actions/read+contents/pulls write，六 blocked保留 owner。Covers: B-016–B-018, B-021, B-022, B-027, B-029, B-031. Owner: publication owner. Depends on: T2/T3/T5/T7–T9。Done when:所有 record ack-loss old/new fence、takeover generation及 draft/PR API response-loss/all-state/stale-zero/cancel/merge/replacement/ABA矩阵均无 stale append/duplicate transition/orphan/late merge/双 current/漏 row。Verify: `bash tests/test_public_benchmark.sh`; `bash tests/test_release_workflow.sh`.

- [ ] `SP700-T11` 只从 SP700-T10 owner-bound summary 生成 exact README/locale patches：genesis 用 zero-marker receipt且不建 no-op de-current PR；de-current/rollback/new-current/nonvalid-row及其 replacements 全部使用统一 planned/bound envelope、受保护 nonce、all-state discovery与 latest-frontier merge gate，任何 response-loss不得创建第二个 PR或复用旧 review/check。de-current 取消须 revocation receipt；已 merge才 rollback。Covers: B-008, B-015, B-016, B-017, B-018, B-020, B-023, B-031. Owner: docs generator owner. Depends on: SP700-T9, SP700-T10；README human review gate。Done when: genesis、四 kind response-loss/all-state match、rollover cancel/merge、replacement/reopen/queue/ABA/late-merge、六类 blocked goldens全通过；最多一个 merge-authorized PR/current marker且无 orphan/ownerless Release。Verify: `python3 scripts/ci/render_public_benchmark.py --check`; `bash scripts/ci/validate-doc-paths.sh`; `bash scripts/ci/validate-doc-command-paths.sh`.

- [ ] `SP700-T12` 建立完整 adversarial harness，覆盖每种 history record 的 commit前 timeout、commit后 ack-loss、restart+renewed fence、immutable-intent fence-field injection、gate误读 intent fence、uncommitted old-fence fail/new-fence same-op once、committed old/new-fence same receipt、old/new并发、same-ID digest冲突、takeover-before/after append、0/1/N terminal/replan/incompatible suffix、owner-generation/fence reuse、index/receipt/envelope tamper、fork/truncate；draft覆盖 API loss/stale-zero/分页/权限/nonce/exhaustive-negative/upload；四 PR kind覆盖 ref/push/create/bind loss、all-state/multipage/spoof/wrong creator/fork、迟到 PR、cancel/late bind/merge、replacement/multilevel/reopen/ref ABA/stale gate；以及 post-intent/permissions/六 blocked。Covers: B-001–B-031. Owner: integration-test owner. Depends on: T2–T11。Done when:所有 mutation/append 断言 unique fold/actual-fence authorization/receipt/outcome，最多一个 merge-authorized PR/current marker，无 stale append/duplicate transition/orphan/late merge/ownerless Release/漏 row。Verify: `bash tests/test_public_benchmark.sh`; `bash tests/test_behavior_eval.sh`; `bash tests/test_hook_perf_contract.sh`; `bash tests/test_release_workflow.sh`.

- [ ] `SP700-T13` 在同一 immutable implementation head 完成生产回归、安全审查与 current-head evidence：运行 Rust/benchmark/behavior/hook/release/docs/broad checks；independent reviewer核对 identity/ledger、所有 history append ack-loss/idempotency、pre-draft claim/binding、四 PR planned/bound response-loss/all-state discovery、rollover revocation及六 blocked；SEC-11另审 command execution、trusted App/nonce、store receipt/index与 merge-gate/ruleset bypass。Covers: B-001–B-031. Owner: verification owner + independent reviewer + human security reviewer. Depends on: T12；GH-699 T3–T6；current-head remote gates。Done when: fresh checks全绿、findings为零，head/CI/0 threads/reviews/merge state一致；merge/release仍按授权。Verify: 记录普通仓库命令与current-head证据。

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

历史 packet 仍可在维护者明确选择 SpecRail 时运行以下可选离线完整性检查；它不是实现、
CI、review 或 merge-readiness 的前置门：

```bash
python3 checks/check_workflow.py --repo . --spec-dir=docs/specs/GH700
```

## Handoff Notes

```yaml
routing_decision:
  work_surface: code_execution
  readiness: plan_first
  reason: runtime, installer identity, distribution launcher, release workflow, schema, and policy changes
mode: plan_first
artifacts:
  product_spec: docs/specs/GH700/product.md
  tech_spec: docs/specs/GH700/tech.md
  task_plan: docs/specs/GH700/tasks.md
runtime_pinning_snapshot:
  accepted_baseline: 05ca05e0030897ea8e8585c0eacb62c7d12185d9
  gh699_merged_contract: SP699-T1/T2
  gh699_unaccepted_head: 6c5e1361993ca589cc20736ca3245d887dacfd75
  refresh_required_before_implementation: true
verification_owner:
  deterministic_gates: SP700-T13 verification owner
  independent_review: read-only reviewer on exact head
  security_review: human SEC-11 reviewer
stop_conditions:
  - any H-001–H-005 product choice is unapproved
  - GH699 actual launchers or no-clone forwarding evidence is absent
  - benchmark-only detector, mock, checkout, or PATH fallback appears
  - identity, roster, ledger, summary, reconciliation, or publication gate fails
  - focused/broad tests, exact-head required CI, independent review, review threads, or merge state fail
lane_map:
  SP700-T1: maintainer decision and protocol single writer
  SP700-T2: release identity and mapped-image launcher owner
  SP700-T3: schemas, canonicalization, roster, and ledger single writer
  SP700-T4: detector lanes plus one corpus/mapping writer and authenticated reviewers
  SP700-T5_to_T9: one serial Rust/launcher/report owner for shared files
  SP700-T10: release summary, reconciler, and publication owner
  SP700-T11: documentation generator owner
  SP700-T12_to_T13: integration verification followed by read-only reviews
```

- Product invariant set 与 task `Covers:` union 均为 `B-001`–`B-031`，无 orphan invariant
  或额外 B-ID。
- 当前任务只规划不实现；该 packet 创建时 GH-700 的 live label 为 `ready_to_spec`，该
  历史标签只作上下文、不授权 implementation。本计划继续使用原 PR #713，不创建重复
  实现 PR；真正开始 implementation 前必须重新检查 live issue、已有 PR/branch coverage
  与 current main，并把目标绑定到唯一实现 lane。
- GH-699 是 partial dependency：已合并 T1/T2 payload contract；B-001 official claim
  必须等待 T3–T6 actual launcher/native no-clone smoke 合并并由 fixture 实际探测。
- 产品 spec 的五项选择不能从代码或 auto 授权推导。未明确批准时，SP700-T1 必须保持
  official result `unavailable`；实现者不得把 Recommended proposal 当成已批准值。
- Stop conditions：任何 benchmark-only detector、mock/checkout/PATH fallback、
  current-exe/receipt/digest 不一致、reviewer role 重叠、dangerous fixture 被执行、
  secret/raw payload/path 泄漏、case 从 ground-truth denominator 消失、非 valid axis
  显示数字、required platform 被 display-only report 替代、blocked candidate 未先持久化
  完整 per-attempt manifest、focused/broad gate 失败或 current actionable review finding。
- 人工边界继续保留：未决产品选择、SEC-11 command-execution security review，以及
  merge/release 的明确授权；普通 current-head CI、independent review 与 review-thread
  evidence 不由可选 SpecRail 工具替代。
