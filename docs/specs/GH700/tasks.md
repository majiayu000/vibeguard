# Task Plan — GH700 公开可复现效果基准

## Linked Issue

GH-700

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## 实现任务

- [ ] `SP700-T1` 固化 official benchmark protocol 与 H-001–H-006 产品决策门、canonical config/state/schedule/limits/registry executable closure/fresh state/estimator/baseline。latency protocol只引用 registry logical IDs来固定 `production_direct_v1`、空 benchmark interposition、untimed closure及 target guard component/loader/service/policy/OS issuer/activation contract；实现/安装归 T2/T5。required documentation protocol只含 stable surface identity，mutable base属于 attempt plan。Covers: B-002, B-003, B-006, B-009, B-011, B-012, B-018, B-024, B-026, B-031. Owner: maintainer decision + protocol owner. Depends on: product/tech review与六项选择批准。Done when: missing decision/config/guard registry closure在零执行前 unavailable；percentile/baseline/brokered-timed/surface goldens固定。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::protocol`; `bash tests/test_public_benchmark.sh`.

- [ ] `SP700-T2` 扩展 offline-verifiable release identity、trusted-launcher handle chain及 production guard install identity：manifest绑定 runtime、protocol/registry及 target guard component/loader/service/policy/issuer closure；installer安装/激活普通 hook guard并持久化 target/identities/protection-state receipt，preflight验签并 challenge live OS state。Covers: B-002, B-013, B-016, B-021, B-024, B-028, B-030. Owner: identity + launcher/installer owner. Depends on: T1；GH-699 payload。Done when:除 launcher/assets篡改外，wrong-target/policy/loader/service/root/install receipt、inactive/replaced/downgraded guard、self-signed live receipt与 preflight→sample deactivation均零 sample unavailable。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::identity`; `bash tests/test_setup.sh`; `bash tests/test_public_benchmark.sh`.

- [ ] `SP700-T3` 建立全部 benchmark/publication schemas与 fold。`publication_history` frontier唯一为 `(repo_node_id,history_length,history_root,full_prefix_digest)`，top-level discriminator唯一为 `record_kind`；八个 blocked variants exact 为 `{release_mutation_recovery_blocked,draft_recovery_blocked,decurrent_pr_recovery_blocked,rollback_recovery_blocked,marker_recovery_blocked,nonvalid_row_recovery_blocked,invalidation_recovery_blocked,release_recovery_blocked}`。history authorization分 publication owner domain与 owner-free governance domain；leaf/root rotation/revocation使用 stable rotation ID、独立 governance lease/fence/threshold approval，pre-state验证并从 successor切换，phase-neutral且两域 fence隔离。六种 Release `mutation_kind={draft_create,draft_update,draft_delete,asset_upload,asset_delete,publish}` 定义 planned/bound/recovery/not-applied/compensation records、slot unique index、operation-independent plan core/stable slot ID、secret-free request commitment、typed per-slot nonce capsule/AAD、完整 kind tuple/discovery receipts；invalidation planned禁 merge SHA/timestamp并有独立 post-merge receipt。Covers: B-004, B-016, B-019, B-022, B-025–B-027, B-029, B-031. Owner: schema/integrity owner. Depends on: T1。Done when:共用 goldens固定 exact frontier JCS bytes/digest、八个 blocked records与六个 mutation kinds；`length`/`root`、discriminator/mutation alias、unknown blocked kind、construction cycle、raw nonce/request secret、missing/swapped/cross-slot/cross-operation capsule、digest/placeholder drift及 forged pre-merge SHA均 fail closed；governance rotation/fence/cutover与每 mutation fold通过。Verify: `python3 scripts/ci/validate_public_benchmark.py`; `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::digest`; `bash tests/test_public_benchmark.sh`.

- [ ] `SP700-T4` 在 SP700-T3 schema/roster validator 冻结后补齐五类 production surfaces并 populate corpus/truth/mapping/ledger：mapping 只引用 registry logical IDs；每条 ground-truth/mapping/security review record 必须由 roster identity 签名并绑定 artifact digest/role/decision/source commit；不得用多个自报 ID 伪造独立性。Covers: B-003, B-004, B-005, B-006, B-025, B-026, B-027. Owner: detector owners + corpus/mapping single writer + authenticated independent reviewers. Depends on: SP700-T1, SP700-T3与各 detector security gate。Done when:五类 matched pairs、signed review records与released mappings齐全；mapping digest/path injection、roster/record/overlap mutation fail；未落地类别 official unavailable。Verify: `python3 scripts/ci/validate_public_benchmark.py`; `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::mapping`; `bash tests/test_public_benchmark.sh`.

- [ ] `SP700-T5` 注册 runtime `bench`、实现 preflight，并在实际 launchers合并后接线；同时在非 `bench/` production module、hook orchestrator、actual run-hook wrappers、setup/install/release manifest中实现默认 production guard activation/invocation，禁止 bench-only flag。Covers: B-001, B-002, B-015, B-019–B-021, B-028, B-031. Owner: benchmark CLI + production hook/installer owner. Depends on: T1–T4；GH-699 launchers。Done when:fresh install的 ordinary non-benchmark wrapper与 bench使用同 guard identity/policy，bench安装/启用/重配 sentinel失败，per-invocation guard delay进入 existing hook SLA/E2E。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::preflight`; `bash tests/test_setup.sh`; `bash tests/test_hook_perf_contract.sh`; `bash tests/test_public_benchmark.sh`.

- [ ] `SP700-T6` 实现隔离/closure verifier；untimed broker pre-exec deny，timed lane只消费 T2/T5 已安装且 live-challenged的 production guard，禁止 benchmark install/load/reconfigure；普通 per-invocation session setup仍在 timer内。Covers: B-005, B-009, B-010, B-013, B-014, B-024, B-025, B-030. Owner: sandbox/executor owner. Depends on: T1/T2/T4/T5。Done when:bench-only activation、timed-only child、event loss/receipt tamper无 headline sample；broker delay排除而 production guard delay计入。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::sandbox`; `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::runner`; `bash tests/test_public_benchmark.sh`.

- [ ] `SP700-T7` 实现确定性 effectiveness 双运行、closed adapter、完整分母 metrics、axis 状态和 split digests：run A/B 使用全新 sandbox且按 case ID 排序；mapping-declared success/no-payload/no-reason 精确映射 `allow/no_interception`，其它 missing/unknown/multiple raw fields 与 `execution_error`/timeout 进入 `positive_error|negative_error`、没有 production decision并强制 inconclusive；集中计算 TP/FN/FP/TN/error buckets、block/advisory/per-class counts，强制两条 denominator closure equations，再按 SP700-T3 的 `jcs-rfc8785-v1` bytes 生成跨平台 `decision_digest` 与 platform-bound `evidence_digest`。Covers: B-006, B-007, B-008, B-009, B-022, B-023, B-025, B-031. Owner: effectiveness and canonical-digest owner. Depends on: SP700-T3 canonicalizer；SP700-T4 populated mapping/corpus identities；SP700-T6 executor；与 benchmark model、runner、metrics、renderer 的其他写任务串行。Done when: 同 identity/parameters 的 A/B 语义完全一致且 error buckets 为零才可 valid；no-interception allow 与真正缺失字段 goldens 分离；error cases 保留总分母但不进入 production-decision counts；零分母、方程/bytes/digest/decision/reason/order drift 均具名失败且无诊断 rate 冒充 headline；required targets 只比较 decision digest。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::metrics`; `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::digest`; `bash tests/test_public_benchmark.sh`.

- [ ] `SP700-T8` 实现 `bench_case_e2e_ms`：验证 registry/manifest/install/live guard receipts后，以普通 production invocation contract启动 wrapper；bench不得改变 guard，per-invocation setup在 timer内，report绑定 install/live/session/event receipts。Covers: B-002, B-008, B-011, B-012, B-023, B-024, B-030. Owner: latency owner. Depends on: T1/T2/T5/T6。Done when:bench-only activation或 sample前停用均零 headline；broker overhead排除、production guard overhead计入。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::latency`; `bash tests/test_hook_perf_contract.sh`; `bash tests/test_public_benchmark.sh`.

- [ ] `SP700-T9` 建立唯一 BenchReport、closed raw evidence 与 3×3×terminal outcome contract：先算 axis candidate；`interrupted`（即使两轴已valid且cleanup成功）和 process-tree/report/schema/cleanup failures 都 override 为 inconclusive/nonzero/blank headline；cleanup 完成并把最终 closed result 纳入 terminal record 后才 exclusive-create 封口 report。Covers: B-006, B-008, B-014, B-015, B-019, B-020, B-022, B-023, B-025. Owner: report/renderer owner. Depends on: SP700-T7, SP700-T8。Done when: completed-axes-then-clean-cancel、cleanup-fails-before-seal golden 与所有 failure matrix不可能 exit0；immutable report 包含最终 cleanup error；privacy只剔除free text/payload/stderr而保留closed raw fields。Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml bench::render`; `bash tests/test_public_benchmark.sh`.

- [ ] `SP700-T10` 接入 strict summary与统一 publication machine。每个 Release write在 call前持久化 planned slot+guard；uncertain禁止重发，按 exact discovery recover-bind/not-applied/compensate/block。phase gate只接受 `{bound,not_applied,compensated}`，not-applied含 pre-state+negative+quiescence，intended effect须唯一 later bound或已 compensated，且无 pending/blocked/in-flight/extras；takeover引用旧 plan fresh authorize。publication actor遇 governance suffix保留 phase并重规划。Covers: B-016–B-018, B-021, B-022, B-027, B-029, B-031. Owner: publication owner. Depends on: T2/T3/T5/T7–T9。Done when:六 kind全部 crash/discovery/partial/compensation/takeover不重复副作用。Verify: `bash tests/test_public_benchmark.sh`; `bash tests/test_release_workflow.sh`.

- [ ] `SP700-T11` 生成 exact all-surface patches并实现五 PR kind。invalidation planned/bound只绑定 base/head/reviewed commit/expected tree/blob/patch/method/ruleset，schema拒绝 future merge SHA/timestamp；server merge后 receipt才绑定 actual merge OID/PR/method/default refs/tree/blobs/owner/fence/frontier/evidence。Covers: B-008, B-015–B-018, B-020, B-023, B-031. Owner: docs generator owner. Depends on: T9/T10；human review gate。Done when:server生成非本地预测 SHA仍按 exact tree成功；precomputed/forged SHA、wrong tree/blob、merge response loss、duplicate receipt、base drift均 fail closed/recover。Verify: `python3 scripts/ci/render_public_benchmark.py --check`; `bash scripts/ci/validate-doc-paths.sh`; `bash scripts/ci/validate-doc-command-paths.sh`.

- [ ] `SP700-T12` 建立完整 adversarial harness：governance rotation覆盖 no/active owner、suffix重规划、stable ID/domain fence/cutover；六 Release kind覆盖每个 crash、0/1/N/in-flight zero/late response、partial/duplicate/delete/publish、compensation/takeover，并有 original not-applied→replacement bound→phase completion与 compensation not-applied→replacement compensation bound→original compensated正例；mutation capsule覆盖 construction-order/no-cycle、missing/swapped/cross-slot/cross-operation/digest mismatch、0/2 placeholder、raw-secret leak、ack-loss restart/takeover复用及 same slot/delivery拒绝二发；invalidation覆盖 future SHA拒绝/post-merge tuple；guard覆盖 install/live/bench-only activation。Covers: B-001–B-031. Owner: integration-test owner. Depends on: T2–T11。Done when:所有 slot处于 closed terminal set且 effect closure成立，最多一 draft/public Release/exact assets。Verify: `bash tests/test_public_benchmark.sh`; `bash tests/test_behavior_eval.sh`; `bash tests/test_hook_perf_contract.sh`; `bash tests/test_release_workflow.sh`.

- [ ] `SP700-T13` 在同一 immutable head完成回归/evidence；independent reviewer核对 owner-free governance authorization/idempotent cutover/domain-fence隔离、六 mutation slot recovery、phase-specific invalidation merge receipt、production guard install/ordinary use；SEC-11审 broker/outbox/compensation、trusted App/nonce/KMS/OS issuer与 command execution。Covers: B-001–B-031. Owner: verification owner + independent reviewer + human security reviewer. Depends on: T12；GH-699 T3–T6；current-head gates。Done when:fresh checks、CI、0 threads/reviews/merge state一致；merge/release仍按授权。Verify: current-head证据。

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
  - any H-001–H-006 product choice is unapproved
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
