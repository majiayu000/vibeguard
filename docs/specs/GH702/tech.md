# Tech Spec — Guard Pack v2、供应链验证、事务安装与精度 eligibility

## Linked Issue

GH-702

## Product Spec

[`product.md`](product.md)

## Spec 状态与实施门

本文件是 Draft design，不是 approved implementation plan。H-001–H-009 仍是未批准的
human decisions；以下 v2 结构用于证明这些选择可形成一致、可测试的方案。实现前必须有
一个 maintainer-approved decision artifact，绑定 product/tech spec digests 和九项选择。
若选择改变 planned paths、trust root、capability 边界、precision policy 或 host contract，
必须先更新本 spec，再生成 `tasks.md`。

## Codebase Context

以下锚点均在基线
`05ea122083e6bc4cc0b9fd3e2c168e576e8f431c` 的当前 worktree 中经 Read/grep 核实。

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Runtime CLI registry | `vibeguard-runtime/src/main.rs:62`; `vibeguard-runtime/src/main.rs:68`; `vibeguard-runtime/src/main.rs:519` | 单一静态 `COMMANDS` 表分发 runtime 子命令；没有 `add`/pack production client | B-001 需要 released binary 可达且不依赖 Python 的入口 |
| Checkout setup route | `setup.sh:176`; `setup.sh:184`; `setup.sh:193`; `scripts/setup/guard-packs.sh:4` | `setup.sh packs` 和 `install --pack` exec repo-relative Python helper | 当前是 dev/checkout surface，不能冒充 GH-699 actual launcher |
| Pack schema v1 | `schemas/guard-pack.schema.json:5`; `schemas/guard-pack.schema.json:21`; `schemas/guard-pack.schema.json:31`; `schemas/guard-pack.schema.json:38`; `schemas/guard-pack.schema.json:88` | schema 固定 version 1，source/targets/behavior 没有 publisher、bundle、provenance、precision、dependency 或 transaction contract；target/behavior 子对象允许扩展字段 | v2 不能靠在 v1 上塞可选字段形成不受控兼容 |
| Current pack | `packs/safe-bash/pack.yaml:2`; `packs/safe-bash/pack.yaml:8`; `packs/safe-bash/pack.yaml:10`; `packs/safe-bash/pack.yaml:154`; `packs/safe-bash/README.md:22` | `safe-bash` 是 `adoption_layer_only`，引用 repo 内 source，声明 default block；live install 只登记 receipt | B-036 需要 legacy reader 和 ownership-safe migration |
| Manifest loader/validator | `scripts/lib/guard_packs.py:41`; `scripts/lib/guard_packs.py:90`; `scripts/lib/guard_packs.py:133`; `scripts/lib/guard_packs.py:164`; `scripts/lib/guard_packs.py:243`; `scripts/lib/guard_packs.py:305` | 只扫描 `${ROOT}/packs/<id>/pack.yaml`，source/fixture 必须在当前 repo，target 闭集硬编码 | 不能解析 external locator 或 self-contained bundle |
| Registration lifecycle | `scripts/lib/guard_packs.py:615`; `scripts/lib/guard_packs.py:639`; `scripts/lib/guard_packs.py:654`; `scripts/lib/guard_packs.py:688` | install 先 audit 已有 Core，然后只写 receipt；uninstall 只删 receipt | 缺 staging、真实 ownership、update、rollback、recovery |
| Receipt model | `scripts/lib/guard_pack_receipts.py:17`; `scripts/lib/guard_pack_receipts.py:25`; `scripts/lib/guard_pack_receipts.py:41`; `scripts/lib/guard_pack_receipts.py:117` | receipt 记录 pack/target/profile/plan，但 `actual_writes` 只有自身，未绑定 bundle/provenance/precision/config before/after | v2 receipt 必须成为 transaction/audit source of truth |
| Atomic primitive | `scripts/lib/file_ops.py:25`; `scripts/lib/file_ops.py:47`; `scripts/lib/file_ops.py:51` | 已有 same-directory fsync + replace 和 SHA-256 helper | 可复用语义；production Rust client 需提供等价原子/摘要实现 |
| Local precision lifecycle | `scripts/precision-tracker.py:18`; `scripts/precision-tracker.py:42`; `scripts/precision-tracker.py:49`; `scripts/precision-tracker.py:52`; `scripts/precision-tracker.py:56`; `scripts/precision-tracker.py:273`; `scripts/precision-tracker.py:296` | repo-local triage/scorecard 用 70%/20、90%/50/30d、80% demotion thresholds 迁移 rule stage | 可作为 curated evidence 输入，不是 pack author 可自授的 official eligibility |
| Aggregate CI precision | `scripts/ci/validate-precision-thresholds.sh:5`; `scripts/ci/validate-precision-thresholds.sh:23`; `scripts/ci/validate-precision-thresholds.sh:64`; `scripts/ci/validate-precision-thresholds.sh:73` | 全 corpus aggregate precision/recall/F1 默认各 75% | 与 per-rule pack default gate 不同，必须分 type/schema/name |
| Host contract | `hooks/manifest.json:2`; `hooks/manifest.json:37`; `schemas/hooks-manifest.schema.json:6`; `schemas/hooks-manifest.schema.json:24`; `schemas/hooks-manifest.schema.json:61` | hooks manifest v1 每个 hook 固定 Claude/Codex 两列；没有通用 host registry | GH-701 draft 正在拥有该 generalization，GH-702 不得复制 |
| Release payload | `scripts/release/payload-manifest.txt:1`; `scripts/release/payload-manifest.txt:13`; `scripts/release/payload-manifest.txt:32`; `scripts/release/payload-manifest.txt:48` | GH-699 payload 已包含 `packs/`、schemas 和 legacy Python helpers | 新 Rust client/authoring assets 必须进入同一 verified payload contract |
| Existing regressions | `tests/test_guard_packs.sh:76`; `tests/test_guard_packs.sh:89`; `tests/test_guard_packs.sh:306`; `tests/test_guard_packs.sh:577`; `tests/test_precision_tracker.sh:196`; `tests/test_precision_tracker.sh:240` | 已覆盖 v1 validate/audit/receipt 和 precision lifecycle 主要路径 | 需要保留 legacy coverage，并拆出 supply-chain/transaction/policy suites |
| GH-699 delivery status | `docs/specs/GH699/tasks.md:5`; `docs/specs/GH699/tasks.md:7`; `docs/specs/GH699/tasks.md:8`; `docs/specs/GH699/tasks.md:9` | payload T1/T2 已完成；bootstrap、no-clone smoke、brew/npm launcher 尚未完成 | official `vibeguard add` 的 public evidence 受其后续 tasks 阻断 |

写作时 remote PR #712 head
`1408324dcb16be5327bb3f0c681433dcf3f7cd0f` 是 GH-701 Draft，提出 versioned host
registry；它尚未合并，不能当作当前 code contract。GH-700 Draft 则明确把 public
benchmark 与 existing precision score portal 分开，GH-702 不依赖其完成。

## 设计方案

### 1. Decision gate 与 artifact identity

在任何 v2 official publish/install 开始前，离线 gate 读取唯一 decision artifact：

```text
gh702_policy_version
product_spec_digest
tech_spec_digest
H-001 ... H-009 selections
approved_by
approved_at
expires_at
```

gate 拒绝 missing/duplicate/unknown selection、spec digest drift、过期批准或非 maintainer
identity。实现只消费选择，不从 Recommended proposal、环境变量或 CLI 猜值。H-003/H-006/
H-007/H-008/H-009 属于 security/default-policy decisions，批准证据还要满足仓库既有
`security_decision` human gate。

该 gate 产出 `guard_pack_policy_digest`，进入 index entry、bundle manifest、precision
eligibility、transaction plan、receipt 与 audit。这样 H 选择改变时，旧 pack 仍可解释，
但必须 re-audit，不能静默沿用新 policy。

### 2. v2 artifacts 与 closed schemas

Recommended v1 shape（未批准）包含六种互相独立、各自 versioned/digested 的 artifacts：

1. **Index snapshot/entry**：`publisher/name/version → bundle_digest`，并绑定 namespace
   ownership、publish attestation、yank/revoke state、runtime/schema ranges。
2. **Bundle manifest**：canonical identity、closed capabilities、targets/profiles、
   dependencies/conflicts、assets、rules、requested decisions 和 policy digest。
3. **Precision evidence**：逐 rule 绑定 rule/capability/fixture/reviewer/count/window，
   不允许只给 pack average。
4. **Policy**：H-001–H-009 的获批取值、thresholds、issuers、offline/revocation action。
5. **Transaction journal/receipt**：plan、before/staged/after digests、owned entries、
   audit、commit/rollback/recovery。
6. **Local override**：和 official receipt 分离，逐 rule 保存用户 action、confirmation、
   policy/eligibility identity，不得修改 official artifacts。

所有 JSON 使用 `additionalProperties: false`、closed enum、stable snake_case keys 和
显式 schema dispatch。canonicalization 必须拒绝 duplicate JSON/YAML keys、非 UTF-8、
非有限数字、非规范 path/semver；digest 对完整 canonical bytes 计算。manifest 中每个
asset/rule/capability/target/dependency ID 唯一，join 需全覆盖、无 orphan。

现有 `guard-pack.schema.json` 保留 v1 reader 输入，但 writer 只产 v2。不得把 v1
`additionalProperties` 宽松面当 v2 extension channel。v1 `safe-bash` 仍可 explain/audit/
remove；migration 是显式 command/plan，不在读取时自动写。

### 3. Production client 与 author tooling 分层

production `vibeguard add|pack explain|pack audit|pack update|pack remove` 进入 Rust
`guard_pack` module，保证 GH-699 released install 不依赖 Python。module 按职责拆分，避免
把现有已接近 800 行的 Python helper平移成单个超大 Rust/Python 文件：

- `model/schema`：closed structs、canonicalization、joins；
- `locator/index`：approved source resolver、bounded fetch/cache；
- `archive/trust`：streamed checksum/attestation、safe extraction；
- `capability`：sealed Core capability IDs 与 host compatibility；
- `precision`：纯 eligibility function；
- `transaction`：lock/journal/stage/apply/audit/commit/rollback/recovery；
- `render`：human/JSON plan/status/error 同源。

Python `scripts/lib/guard_packs.py` 退为 author/legacy adapter，并拆出 manifest/publish
helpers；它不能成为 official runtime fallback。author validator 和 Rust reader 共享
golden canonical fixtures，任何 parse/decision 差异使 CI 失败。

### 4. Locator、fetch 与供应链验证

resolver 先把 H-001 允许的 locator 解析为 source kind，再得到 canonical exact identity。
official online flow：

1. bounded 获取 signed index snapshot，验证 trust root、namespace ownership、snapshot
   freshness 和 rollback/freeze protection；
2. 选择 exact version，拒绝同 version 多 digest；
3. 获取 bundle 到 transaction staging，边流式下载边 enforce byte/time limits 和 SHA-256；
4. 验证 release attestation subject == canonical bundle digest；
5. 在解压前解析 outer metadata，再用安全 extractor逐 entry验证 path/type/size/link；
6. 解压后重算 manifest/assets digests，执行 schema/join/capability/precision gates。

任何 fetch/verify error 都保留 closed stage/reason，零 host/config write。redirect、
proxy、certificate 和 credential行为由 H-001/H-003 policy 闭集限定；URL/response text
不得进入 shell。index/bundle size、文件数、单文件、总展开大小、compression ratio、
redirect count 和 timeout 都有已发布上限。

offline cache 以 index snapshot digest + exact bundle digest 存储。只有 H-008 policy
认可且未超过 freshness/revocation window 的 cache 可用于 verified install；否则只可
explain cached metadata或 fail closed，不能自动转 unofficial。

### 5. Capability 与 host compatibility

v2 pack 不携带 host command。每条 rule 只引用 H-002 批准的 sealed capability ID；
capability registry 把 ID 映射到已随 verified VibeGuard release 安装的 Core detector/
adapter，并声明 protocol range、supported decision types 和所需 host features。

H-005 推荐 fixed Claude/Codex v1 时，resolver 读取现有安装 audit 的目标能力，但 pack
schema 仍只保存抽象 ID。若 GH-701 registry 合并，adapter 改为消费其 canonical
`host_id + capability` view；不复制 `claude`/`codex` config fields。unknown host、
unknown capability、known-incompatible protocol、unsupported event、missing Core asset
有不同 closed reason，均在 plan 前结束。

H-002 若批准 executable 扩展而不是推荐方案，本 tech spec 不足：必须回到 spec review，
补 executable signing、sandbox、syscall/filesystem/network/secret policy、resource
limits、crash isolation、update/revoke 和 SEC-11 human security review，不能直接在 tasks
中扩 scope。

### 6. Transaction、ownership 与 recovery

Recommended H-004 layout（未批准）：

```text
~/.vibeguard/guard-packs/
  store/sha256/<bundle_digest>/        readonly verified content
  active/<publisher>/<pack>/<target>   atomic pointer/identity file
  receipts/<publisher>/<pack>/<target>.json
  transactions/<transaction_id>/
    plan.json
    journal.json
    before/
    staged/
  locks/<target>.lock
  overrides/<publisher>/<pack>/<target>.json
```

每个 mutation 在 target lock 下运行：

```text
discover → plan → confirm → lock → recover-old → stage → verify
         → snapshot-owned-state → apply → audit → write receipt → switch active → commit
                                                       └ failure → rollback → audit restored
```

plan 使用 compare-and-swap 前提：每个将修改的 file/config entry 同时记录 owner 与
observed before digest。apply 前再检查，避免 plan 后 TOCTOU。config 修改使用结构化
reader/writer 和现有 target ownership语义，不做 string append；shared dependencies
需要引用集合，最后一个 owner remove 才可删除。

journal 每完成一步原子 append/replace closed state；receipt 只有 audit 成功后可写，
active pointer 最后切换。interrupt 后下次 mutation 先 recover unfinished journal。
rollback 只依据 journal，不扫描 HOME。rollback 失败保留 before/staged/journal 并返回
`needs_repair`，禁止删除诊断证据或继续装另一版本。

same identity retry 比较 receipt/active/store/policy digests，全等即 no-op；version 相同但
digest 不同视为 registry immutability violation。update 新旧 store并存直到 commit；
失败保持旧 active。remove 先验证 drift，只删独占 owned entries，用户/其他 pack canary
保持 byte-identical。

### 7. Precision eligibility 与 effective decision

新增纯函数，输入：

```text
requested_decision
rule_digest
capability_digest
trust_state
precision_evidence | null
approved_policy
local_override | null
```

输出：

```text
official_eligibility = block_eligible | warn_only
official_default = block | warn | off
effective_local_decision = block | warn | off
reason_codes[]
eligibility_digest
```

计算顺序固定：

1. 验证 trust、policy、rule/capability/fixture/reviewer bindings；
2. 验证 TP/FP/acceptable/unclassified counts、window/freshness；
3. 按 H-006 公式计算 eligibility；
4. evidence 缺失/invalid/不足/过期/低 floor → `warn_only`；
5. 达标只得到 `block_eligible`，再结合 requested decision/host capability；
6. 最后应用独立 local override，并保留 official result。

不能从 pack average、GH-700 benchmark、aggregate CI precision 或 author 自报值填充
per-rule evidence。现有 `precision-tracker.py` 可导出 curated candidate，但需经新 schema、
reviewer/fixture ledger 和 issuer签名后才成为 official evidence。`acceptable`/
`unclassified` 是否计入 minimum samples 由 H-006 policy 明确；不得沿用 tracker 的 total
samples语义同时又用另一分母。

status/audit 每条 rule 同时显示 requested、official eligibility/default、local effective、
precision value/null、counts、age、policy/issuer 和全部 reason。rule/policy/evidence/trust
变化产生新 eligibility digest并触发 audit；active block 失去 eligibility 时按 H-008 action
事务降级，失败进入 `needs_repair`。

### 8. Registry governance、publish 与 revocation

author flow 在独立仓库运行：

```text
vibeguard pack init
vibeguard pack validate <dir>
vibeguard pack build <dir>
vibeguard pack verify <bundle>
vibeguard pack publish <bundle>   # 单独 external action + confirmation
```

`build` 只读取 declared root、规范排序/mode/timestamp，产生 reproducible bundle；两次
相同 source + policy build digest一致。`validate` 使用与 production reader 相同 golden
contract，并运行 fixtures/capability/precision checks。`publish` 先验证 namespace
authorization 和 version absence，再上传 immutable bundle/attestation，最后以
compare-and-swap追加 index entry；任一步失败不产生可 resolve 的半 entry。

yank/revoke/namespace transfer 是独立 signed events，不改写旧 entry。client 保存所见
event identity。revoke online audit 按 H-008 policy生成降级 transaction；不能安全应用时
显示 `needs_repair` 并阻止新激活。runtime hot path 不联网，使用 committed local
eligibility；网络刷新只发生在 add/update/audit 等显式管理动作。

feedback export 由本地 explicit command 生成脱敏、schema-valid artifact，不自动发送。
publish/upload 是新的确认动作；diagnostic、bundle、receipt、report 都不得含用户代码、
HOME、token、proxy value、raw event payload 或未脱敏 stderr。

### 9. Legacy migration 与相邻 workstreams

- **safe-bash v1**：legacy reader继续 validate/explain/audit/remove。migration 先把旧
  receipt标为 registration-only，读取现有 Core audit建立 non-owned baseline，再安装 v2
  bundle；绝不声称旧 receipt拥有 Core files。
- **GH-699**：T3–T6 合并后，由 integration fixture探测 actual released launcher/path/
  argv。GH-702 不猜 shim 名或另造 bootstrap；payload manifest加入所有 production client
  资产。
- **GH-701**：只消费其最终 approved host registry；若其 schema/ID 与本 Draft冲突，
  implementation stop。fixed-host v1 不支持第三 host。
- **GH-700**：无实施依赖；其 report schema/digest不可用作 per-rule precision evidence。

### 10. Planned affected files

以下是 Recommended v1 的完整 implementation ownership map。H-001–H-009 若改变路径或
边界，先修订本 manifest；`tasks.md` 不能凭空增加未列 surface。

<!-- specrail-planned-changes -->
```json
{
  "issue": 702,
  "complete": true,
  "paths": [
    "vibeguard-runtime/Cargo.toml",
    "vibeguard-runtime/Cargo.lock",
    "vibeguard-runtime/src/main.rs",
    "vibeguard-runtime/src/guard_pack/mod.rs",
    "vibeguard-runtime/src/guard_pack/model.rs",
    "vibeguard-runtime/src/guard_pack/locator.rs",
    "vibeguard-runtime/src/guard_pack/archive.rs",
    "vibeguard-runtime/src/guard_pack/trust.rs",
    "vibeguard-runtime/src/guard_pack/capability.rs",
    "vibeguard-runtime/src/guard_pack/precision.rs",
    "vibeguard-runtime/src/guard_pack/transaction.rs",
    "vibeguard-runtime/src/guard_pack/render.rs",
    "schemas/guard-pack.schema.json",
    "schemas/guard-pack-index.schema.json",
    "schemas/guard-pack-registry-event.schema.json",
    "schemas/guard-pack-capability.schema.json",
    "schemas/guard-pack-precision.schema.json",
    "schemas/guard-pack-policy.schema.json",
    "schemas/guard-pack-receipt.schema.json",
    "schemas/guard-pack-transaction.schema.json",
    "schemas/guard-pack-override.schema.json",
    "schemas/guard-pack-feedback.schema.json",
    "packs/safe-bash/pack.yaml",
    "packs/safe-bash/README.md",
    "scripts/lib/guard_packs.py",
    "scripts/lib/guard_pack_manifest.py",
    "scripts/lib/guard_pack_publish.py",
    "scripts/lib/guard_pack_receipts.py",
    "scripts/precision-tracker.py",
    "scripts/ci/validate-guard-pack-publish.py",
    "scripts/setup/guard-packs.sh",
    "scripts/release/payload-manifest.txt",
    "setup.sh",
    "data/guard-pack-policy.json",
    "data/guard-pack-index.json",
    "data/guard-pack-registry-events.json",
    "data/guard-pack-capabilities.json",
    "tests/test_guard_packs.sh",
    "tests/test_guard_pack_supply_chain.sh",
    "tests/test_guard_pack_transactions.sh",
    "tests/test_guard_pack_precision_policy.sh",
    "tests/fixtures/guard_packs/",
    "tests/test_payload.sh",
    "tests/test_release_workflow.sh",
    "tests/test_manifest_contract.sh",
    "tests/test_setup.sh",
    ".github/workflows/ci.yml",
    ".github/workflows/release.yml",
    ".github/workflows/guard-pack-publish.yml",
    "CHANGELOG.md",
    "README.md",
    "docs/README_CN.md",
    "docs/how/guard-packs.md"
  ],
  "spec_refs": [
    "docs/specs/GH702/product.md",
    "docs/specs/GH702/tech.md",
    "docs/specs/GH702/tasks.md"
  ]
}
```

| Concern | Planned affected files | Focused proof |
| --- | --- | --- |
| Released CLI/client | `vibeguard-runtime/src/main.rs`, planned **vibeguard-runtime/src/guard_pack/** | `cargo test --manifest-path vibeguard-runtime/Cargo.toml guard_pack`；no-Python/no-checkout fixture |
| Closed v2 contracts | existing `schemas/guard-pack.schema.json`, planned **schemas/guard-pack-{index,registry-event,capability,precision,policy,receipt,transaction,override,feedback}.schema.json** | schema positive/negative corpus in `bash tests/test_guard_pack_supply_chain.sh` |
| Trust/safe archive | planned **guard_pack/locator.rs**, **archive.rs**, **trust.rs** | tamper/attestation/rollback/freeze/path/link/size/TOCTOU matrix |
| Capability/host | planned **guard_pack/capability.rs**; consume approved GH-701 registry when available | Claude/Codex/unknown/incompatible/unsupported fixture matrix |
| Transaction/receipt | planned **guard_pack/transaction.rs**, receipt/transaction schemas | crash-at-every-stage, concurrent lock, drift, rollback, recovery and canary tests |
| Precision policy | planned **guard_pack/precision.rs**, precision/policy schemas, `scripts/precision-tracker.py` | exhaustive eligibility truth table + evidence binding/freshness/override negatives |
| Author publish | planned **scripts/lib/guard_pack_manifest.py**, **guard_pack_publish.py**, **scripts/ci/validate-guard-pack-publish.py** | two-build digest equality; half-publish/index-CAS/revoke/yank fixtures |
| Legacy migration | `scripts/lib/guard_packs.py`, `scripts/lib/guard_pack_receipts.py`, `packs/safe-bash/` | existing 623-case shell surface remains green plus migration ownership sentinels |
| Release distribution | `scripts/release/payload-manifest.txt`, `scripts/setup/guard-packs.sh`, `setup.sh`, `tests/test_payload.sh`, `tests/test_release_workflow.sh` | GH-699 actual no-clone launcher invokes Rust client; payload tamper fails closed |
| Docs | `README.md`, `docs/README_CN.md`, planned **docs/how/guard-packs.md** | generated command/status examples; doc path and command validators |

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 released no-checkout command | Runtime registry + GH-699 actual launcher integration | fresh HOME fixture runs discovered released `vibeguard add` with `.git`, Python, Cargo and API key absent; checkout-only route reports unofficial |
| B-002 canonical exact identity | Locator + canonical model | table test rejects every missing/empty/mismatch/floating field before fetch/write and snapshots exact identity |
| B-003 external author independence | Author CLI + external-repo fixture | fixture root outside VibeGuard builds/publishes/installs while `git diff` of VibeGuard source stays empty |
| B-004 closed versioned schemas | Six schemas + readers | duplicate-key/unknown-field/enum/semver/range/rule-ID corpus fails in both Rust and Python readers |
| B-005 zero-side-effect invalid input | Resolver/preflight | missing/empty/unknown/tampered/zero-rule fixtures assert store/receipt/active/config canaries absent |
| B-006 approved decision gate | Policy schema + offline gate | missing/double/unknown/stale/spec-drift H-001–H-009 fixtures all block publish/install/eligibility |
| B-007 visible trust states | Model + renderers + receipt | golden human/JSON/receipt matrix distinguishes verified/unofficial/revoked with no warning-only substitution |
| B-008 complete pre-write plan | Planner + shared renderer | golden plan asserts identity, trust, capabilities, per-rule reasons, writes, conflicts, network, rollback and receipt before confirmation |
| B-009 closed capabilities | Manifest join + capability resolver | unknown/undeclared/multi-mapped/free-text/extra-payload fixtures fail before executor or host mutation |
| B-010 safe archive containment | Streaming archive extractor | absolute/traversal/device/link/case collision/duplicate/size/ratio corpus leaves staging boundary canary untouched |
| B-011 complete provenance chain | Index + trust verifier | checksum-only, self-report, wrong namespace/subject/digest and valid full-chain fixtures prove verified is all-or-nothing |
| B-012 online/offline failure semantics | Locator/cache/revocation policy | timeout/malformed/redirect/stale-cache/revocation-unknown matrix asserts fail-closed or exact approved cached status |
| B-013 target compatibility | Capability/host resolver | unknown host, incompatible protocol, unsupported capability, missing Core and valid Claude/Codex fixtures produce distinct closed statuses |
| B-014 runtime privacy/capability | Sealed capability registry + sandbox boundary | network/credential/path/log access sentinels and child-env capture prove undeclared access never runs or persists |
| B-015 transaction state machine | Transaction journal | positive transition trace is exact; illegal/partial-active transition fixtures fail schema/gate |
| B-016 scoped rollback/repair | Transaction rollback | injected failure at every stage restores before digests; rollback failure retains evidence and reports needs_repair |
| B-017 interruption recovery | Journal recovery | kill after every mutation boundary, rerun, and assert no premature active pointer plus deterministic recovery |
| B-018 complete committed receipt | Receipt schema/writer | field-removal/digest-mismatch corpus cannot commit; valid receipt binds every required identity/write/audit |
| B-019 ownership preservation | Planner + structured config adapters | user/other-pack canaries, before-digest drift and ambiguous shared entry all block or remain byte-identical |
| B-020 dependency graph | Dependency resolver | missing/cycle/conflict/range/multi-digest/undeclared recursion fixtures zero-apply; valid graph commits one transaction set |
| B-021 idempotent retry | Identity + receipt comparator | same identity retry is no-op with same receipt; same version/different digest is immutable violation |
| B-022 safe update | Update transaction | from/to diff golden; failure at each gate keeps old active/store bytes; success never mutates old store |
| B-023 ownership-safe remove | Remove/repair flow | shared refcount, exclusive file, missing/corrupt receipt and drift fixtures prove no HOME scanning or foreign delete |
| B-024 concurrency isolation | Per-target lock + transaction IDs | parallel same-target mutations yield one bounded winner; different-target run has disjoint journal/staging and deterministic state |
| B-025 per-rule evidence binding | Precision schema/join | pack-average-only, wrong rule/capability/fixture/reviewer/window and orphan evidence fixtures are rejected |
| B-026 honest precision calculation | Eligibility pure function | exhaustive count/denominator/future/expiry/reviewer matrix checks approved formula and invalid evidence |
| B-027 policy-owned thresholds | Policy loader + eligibility digest | env/CLI/README/author threshold attempts do not change result; policy change changes digest and recomputes |
| B-028 insufficient evidence degrades | Eligibility + renderer | missing/invalid/low-sample/stale/below-floor rows produce warn/off, null precision + reason, never block/0%/old value |
| B-029 block eligibility is not block | Eligibility truth table | cross-product of requested decision, trust, capability, host and evidence proves every prerequisite is necessary |
| B-030 isolated local override | Override schema/applicator | demotion, approved explicit promotion, missing confirmation and cross-user/registry mutation negatives |
| B-031 same gate for core/community | Shared eligibility function | identical evidence inputs under curated/community publishers yield identical eligibility; badge/high severity cannot bypass |
| B-032 evidence drift re-audit | Audit + eligibility identity | mutate rule/policy/evidence/capability/trust one at a time; digest changes and active ineligible block degrades or needs_repair |
| B-033 opt-in private feedback | Export renderer/redactor | default install/runtime packet capture is empty; export field golden is redacted; cancel-before-send makes zero network calls |
| B-034 immutable registry history | Index validator | duplicate namespace/version, overwrite/delete/reorder/transfer-without-event fixtures fail; historical receipt remains explainable |
| B-035 yank/revoke actions | Registry event + audit transaction | yank blocks new install; revoke blocks activation/degrades existing; injected write failure produces needs_repair, not warning-only block |
| B-036 legacy safe-bash migration | v1 reader + migration planner | current v1 regressions pass; migration never claims Core file ownership and failure leaves registration receipt usable |
| B-037 GH-699 dependency | Payload/release integration | `bash tests/test_payload.sh && bash tests/test_release_workflow.sh`; only discovered actual launcher/no-clone native smoke satisfies official |
| B-038 GH-701 interface boundary | Host adapter compatibility layer | contract test accepts approved registry IDs or fixed Claude/Codex policy and rejects second registry/third-host active claim |
| B-039 GH-700 metric separation | Schema/type/name guards | fixtures cannot load public benchmark or aggregate CI result as per-rule pack evidence; docs render distinct labels |
| B-040 reproducible atomic publish | Author build/publish client | two clean builds match digest; validation/upload/attestation/index-CAS failure never creates resolvable partial entry |
| B-041 truthful list/status/audit | Shared status aggregate/renderers | exhaustive installed/empty/invalid/incompatible/revoked/needs_repair golden checks fields and exit codes |
| B-042 offline runtime stability | Committed local eligibility + audit policy | block network, preserve runtime decision/store, show stale audit; expired/revocation-unknown follows exact degradation policy |

## 数据流

```text
author source root
  └─ validate/build ──> canonical bundle + per-rule evidence
                           │
                           ├─ verify namespace/provenance
                           └─ publish immutable object ──> signed index event

vibeguard add <locator>
  └─ approved policy + locator
       └─ index snapshot/revocation ──> exact identity
            └─ bounded bundle fetch ──> streamed digest/attestation
                 └─ safe staging extraction
                      └─ schema/join/capability/precision preflight
                           └─ immutable plan + explicit confirmation
                                └─ target lock + transaction journal
                                     ├─ apply/audit/receipt/active commit
                                     └─ rollback/recovery/needs_repair

runtime hook
  └─ committed local capability + effective decision
       └─ no registry/network/telemetry access
```

持久化面是 closed set：content-addressed verified store、index/revocation cache、
transaction journals/before snapshots、committed receipts/active identities、local overrides
和用户显式生成的 feedback export。临时下载与 staging 在 commit/rollback 后清理；
`needs_repair` evidence 在成功 recovery 前保留。任何 temp 路径、raw response、credential、
用户代码或 event payload 不进入 receipt/status。

外部调用只发生在显式 resolve/add/update/audit/publish/send-feedback 管理动作，并由 plan/
confirmation 声明。runtime enforcement、list local state 和 remove 已安装 pack 不依赖网络。

## 备选方案

- **直接让 `vibeguard add` git clone 任意 repository**：拒绝。branch 可变、submodule/
  hooks/LFS 扩大执行面，无法得到 immutable bundle identity 和 bounded archive contract。
- **把现有 `--packs-dir` 暴露为 third-party install**：拒绝。validator要求 repo-relative
  source存在，live install只写 receipt，无法满足 external author/ownership/rollback。
- **允许 pack 携带任意 install script**：不在 Recommended v1。若维护者选择，必须补充
  独立 executable sandbox/security spec，不能复用 declarative gate。
- **只用 pack-level precision**：拒绝。一条低精度规则可被高精度规则平均掩盖，违反
  issue 的 defaults gate。
- **让 GH-700 benchmark 直接授予 block**：拒绝。其 corpus、denominator、issuer 与
  per-rule external pack evidence不是同一合同。
- **等 GH-700/GH-701 全部完成再写 GH-702**：拒绝。pack identity/trust/transaction/
  precision合同可独立评审；仅 host generalization 与 public launcher分别受 GH-701/
  GH-699 gate。

## 风险

- Security: third-party bundle 是新的供应链输入；path escape、archive bomb、签名/
  namespace劫持、TOCTOU、config ownership和 capability越权可导致代码执行或高上下文
  文件破坏。缓解：H-002/H-003 human security decision、sealed capabilities、streamed
  limits、complete provenance、CAS + transaction rollback、SEC-11 mandatory review。
- Logic: precision denominator、sample gate或 override次序错误会把低精度规则升为 block。
  缓解：单一纯函数、exhaustive truth table、per-rule evidence binding、policy digest。
- Compatibility: v1 safe-bash、GH-699 launcher和 GH-701 host registry均会演进。缓解：
  explicit version readers、registration-only migration、merge后探测 actual interfaces，
  contract conflict stop。
- Data: receipt/journal损坏或 rollback失败可能留下 partial config。缓解：fsync+atomic
  journal、before digests、recovery-first、needs_repair不静默清理。
- Privacy: registry/feedback可能泄露用户环境。缓解：管理动作最小 metadata、runtime
  零网络、默认零上传、export/send分离、sentinel redaction tests。
- Availability: registry离线或 revoke endpoint失败。缓解：获批 bounded cache policy；
  不把 stale当 fresh，也不让 runtime hot path依赖网络。
- Maintenance: 当前 Python helper 793行；继续堆叠会越过 U-16 hard ceiling。缓解：
  production Rust module和 author helpers按职责拆分，legacy adapter只保留兼容层。

## 测试计划

- [ ] Schema/unit:
  - v1/v2/index/evidence/policy/receipt/transaction positive + negative corpus；
  - canonicalization、semver/range、dependency graph、archive path/limit；
  - provenance chain、policy gate、per-rule eligibility exhaustive truth table；
  - transaction state transitions、receipt ownership、override/revocation。
- [ ] Integration:
  - external repo author → reproducible build → local registry publish → fresh no-clone add；
  - tamper/rollback/freeze/yank/revoke/offline/unsafe archive；
  - failure/cancel/crash at every transaction stage + recovery；
  - parallel target lock、user/other-pack canaries、legacy safe-bash migration；
  - runtime network/secret/path sentinels和 feedback redaction。
- [ ] Release contract:
  - verified payload包含 client/schemas/policy；
  - GH-699 actual launcher discovery，不 hard-code spec path；
  - macOS/Linux fresh HOME no-checkout install/add/audit/update/remove；
  - release/index/bundle/attestation exact digest chain。
- [ ] Existing regression:

```bash
cargo fmt --manifest-path vibeguard-runtime/Cargo.toml -- --check
cargo check --manifest-path vibeguard-runtime/Cargo.toml
cargo test --manifest-path vibeguard-runtime/Cargo.toml
bash tests/test_guard_packs.sh
bash tests/test_precision_tracker.sh
bash tests/test_payload.sh
bash tests/test_release_workflow.sh
bash tests/test_manifest_contract.sh
bash scripts/local-contract-check.sh --quick
```

- [ ] Planned focused suites:

```bash
bash tests/test_guard_pack_supply_chain.sh
bash tests/test_guard_pack_transactions.sh
bash tests/test_guard_pack_precision_policy.sh
```

- [ ] Documentation:

```bash
bash scripts/ci/validate-doc-paths.sh
bash scripts/ci/validate-doc-command-paths.sh
```

## 回滚方案

- v2 client必须有 feature/command availability gate；未获批 H decisions、registry outage 或
  security incident 时，关闭新的 resolve/publish/add，不删除现有 receipts/journals。
- 回滚 runtime/client版本时保留 v2 store/receipt为 read-only explain/audit surface；旧
  client不认识 schema时明确 incompatible，不做 duck typing或删除。
- 若某 pack被 revoke，按获批 policy提交独立降级 transaction；无法安全降级时
  `needs_repair`，不以删除 evidence 作为回滚。
- safe-bash v1 reader/remove 保留到另一个获批 deprecation spec；v2 migration失败不改写
  legacy receipt。
- registry/index错误通过 append signed correction/revoke event和更高版本修复，禁止覆盖
  已发布 version/digest或改写历史 receipt。
- GH-701/GH-699接口发生不兼容时停止相关 tranche，回滚到最后一个 exact verified client
  和 host contract；不在 GH-702 内复制 launcher/host registry作为应急 fallback。
