# Tech Spec — Guard Pack v2、供应链验证、事务安装与精度 eligibility

## Linked Issue

GH-702

## Product Spec

[`product.md`](product.md)

External monotonic persistence 与 crash recovery 的 canonical contract 是
[`monotonic-anchor-contract.md`](monotonic-anchor-contract.md)；本文件只引用，不另建第二套状态机。

## Spec 状态与实施门

本文件是 Draft design，不是 approved implementation plan。H-001–H-010 仍是未批准的
human decisions；以下 v2 结构用于证明这些选择可形成一致、可测试的方案。实现前必须有
一个 maintainer-approved decision artifact，绑定 product/tech/supporting spec digests 和十项选择。
若选择改变 planned paths、trust root、capability 边界、precision policy 或 host contract，
必须先更新本 spec，再生成 `tasks.md`。

## Codebase Context

以下锚点在当前 PR base/origin/main `ce5bada07bda1ae72b5488fcf08be8982185a115` 经 Read/grep
核实；GH-699 delivery history 另以实现 commits 与 ancestry 校验，不把后续 T3 归给旧基线。

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Runtime CLI registry | `vibeguard-runtime/src/main.rs:62`; `vibeguard-runtime/src/main.rs:68`; `vibeguard-runtime/src/main.rs:519` | 单一静态 `COMMANDS` 表分发 runtime 子命令；没有 `add`/pack production client | B-001 需要 released binary 可达且不依赖 Python 的入口 |
| Checkout setup route | `setup.sh:176`; `setup.sh:184`; `setup.sh:193`; `scripts/setup/guard-packs.sh:5` | `setup.sh packs` 和 `install --pack` exec repo-relative Python helper | 当前是 dev/checkout surface，不能冒充 GH-699 actual launcher |
| Pack schema v1 | `schemas/guard-pack.schema.json:5`; `schemas/guard-pack.schema.json:21`; `schemas/guard-pack.schema.json:31`; `schemas/guard-pack.schema.json:38`; `schemas/guard-pack.schema.json:88` | schema 固定 version 1，source/targets/behavior 没有 publisher、bundle、provenance、precision、dependency 或 transaction contract；target/behavior 子对象允许扩展字段 | v2 不能靠在 v1 上塞可选字段形成不受控兼容 |
| Current pack | `packs/safe-bash/pack.yaml:2`; `packs/safe-bash/pack.yaml:8`; `packs/safe-bash/pack.yaml:10`; `packs/safe-bash/pack.yaml:154`; `packs/safe-bash/README.md:22` | `safe-bash` 是 `adoption_layer_only`，引用 repo 内 source，声明 default block；live install 只登记 receipt | B-036 需要 legacy reader 和 ownership-safe migration |
| Manifest loader/validator | `scripts/lib/guard_packs.py:41`; `scripts/lib/guard_packs.py:90`; `scripts/lib/guard_packs.py:133`; `scripts/lib/guard_packs.py:164`; `scripts/lib/guard_packs.py:243`; `scripts/lib/guard_packs.py:305` | 只扫描 `${ROOT}/packs/<id>/pack.yaml`，source/fixture 必须在当前 repo，target 闭集硬编码 | 不能解析 external locator 或 self-contained bundle |
| Registration lifecycle | `scripts/lib/guard_packs.py:615`; `scripts/lib/guard_packs.py:639`; `scripts/lib/guard_packs.py:654`; `scripts/lib/guard_packs.py:688` | install 先 audit 已有 Core，然后只写 receipt；uninstall 只删 receipt | 缺 staging、真实 ownership、update、rollback、recovery |
| Receipt model | `scripts/lib/guard_pack_receipts.py:17`; `scripts/lib/guard_pack_receipts.py:25`; `scripts/lib/guard_pack_receipts.py:41`; `scripts/lib/guard_pack_receipts.py:117` | receipt 记录 pack/target/profile/plan，但 `actual_writes` 只有自身，未绑定 bundle/provenance/precision/config before/after | v2 receipt 必须成为 transaction/audit source of truth |
| Atomic primitive | `scripts/lib/file_ops.py:25`; `scripts/lib/file_ops.py:47`; `scripts/lib/file_ops.py:51` | 已有 same-directory fsync + replace 和 SHA-256 helper | 可复用语义；production Rust client 需提供等价原子/摘要实现 |
| Local precision lifecycle | `scripts/precision-tracker.py:18`; `scripts/precision-tracker.py:42`; `scripts/precision-tracker.py:49`; `scripts/precision-tracker.py:52`; `scripts/precision-tracker.py:56`; `scripts/precision-tracker.py:273`; `scripts/precision-tracker.py:296` | repo-local triage/scorecard 用 70%/20、90%/50/30d、80% demotion thresholds 迁移 rule stage | 可作为 curated evidence 输入，不是 pack author 可自授的 official eligibility |
| Aggregate CI precision | `scripts/ci/validate-precision-thresholds.sh:5`; `scripts/ci/validate-precision-thresholds.sh:23`; `scripts/ci/validate-precision-thresholds.sh:64`; `scripts/ci/validate-precision-thresholds.sh:73` | 全 corpus aggregate precision/recall/F1 默认各 75% | 与 per-rule pack default gate 不同，必须分 type/schema/name |
| Host contract | `hooks/manifest.json:2`; `hooks/manifest.json:37`; `schemas/hooks-manifest.schema.json:6`; `schemas/hooks-manifest.schema.json:24`; `schemas/hooks-manifest.schema.json:61` | hooks manifest v1 每个 hook 固定 Claude/Codex 两列；没有通用 host registry | GH-701 Draft spec 已合入 main，但 decisions、registry implementation 与 native proof 尚未交付；GH-702 不得复制或提前消费 |
| Release payload | `scripts/release/payload-manifest.txt:1`; `scripts/release/payload-manifest.txt:13`; `scripts/release/payload-manifest.txt:32`; `scripts/release/payload-manifest.txt:48` | GH-699 payload 已包含 `packs/`、schemas 和 legacy Python helpers | 新 Rust client/authoring assets 必须进入同一 verified payload contract |
| Existing regressions | `tests/test_guard_packs.sh:76`; `tests/test_guard_packs.sh:89`; `tests/test_guard_packs.sh:306`; `tests/test_guard_packs.sh:577`; `tests/test_precision_tracker.sh:196`; `tests/test_precision_tracker.sh:240` | 已覆盖 v1 validate/audit/receipt 和 precision lifecycle 主要路径 | 需要保留 legacy coverage，并拆出 supply-chain/transaction/policy suites |
| GH-699 delivery status | current `docs/specs/GH699/tasks.md`; commits `6bf4ddc3f43744581eac9666712ee80964611740`, `05ea122083e6bc4cc0b9fd3e2c168e576e8f431c`, `da8780afe134b87a2b6f4369cb60083596861a7d` | T1/T2 landed at `6bf4ddc3` and portability gates at `05ea1220`; T3 bootstrap landed later at `da8780af`; all are ancestors of verified base `ce5bada0`；T4–T7 remain open | public evidence still needs no-clone release/package-manager work；never claim T3 existed at `05ea1220` |

main `6e4224c9af742a3a6959eb2dc189418d510d1663` 已合并 PR #712 的 GH-701 Draft
product/tech specs，提出 versioned host registry；GH-701 自身仍要求 H-001–H-004 decisions、
manifest v2/registry implementation 和 fixed third-host native-proof gate，故 merged Draft
不能当作可消费的 current runtime contract。GH-700 Draft 则明确把 public benchmark 与
existing precision score portal 分开，GH-702 不依赖其完成。

## 设计方案

### 1. Decision gate 与 artifact identity

policy reader 使用同一 closed schema，但按操作读取 role-specific artifacts：

```text
policy_role = publication | evaluation
gh702_policy_version
product_spec_digest
tech_spec_digest
H-001 ... H-010 selections
approved_by
approved_at
expires_at
```

build/publish gate 要求一个 current `publication` artifact，在操作时间未过期并匹配它绑定
的 spec bytes；signed publish attestation 记录 publication time 与 digest。install/audit
验证 embedded publication artifact 的签名/digest，以及它在该 signed publication time
曾有效，但不要求它在当前时间未过期或匹配 current spec。install/audit/eligibility 另要求
唯一 current `evaluation` artifact 未过期并匹配 current spec。任一操作拒绝其适用 role 的
missing/duplicate/unknown selection、spec digest drift、过期批准或非 maintainer identity；
publication artifact 后续 expiry/current-spec drift 本身不阻断 install，也不要求 republish。
实现只消费选择，不从 Recommended proposal、环境变量或 CLI 猜值。H-003/H-006/H-007/
H-008/H-009/H-010 属于 security/default-policy decisions，批准证据还要满足仓库既有
`security_decision` human gate。

同一 closed policy schema 按 role 产出两个不可混同的 identity：

- `publication_policy_digest`：在 build/publish 时固定，进入 immutable index entry 与
  bundle manifest，解释 artifact 当时依据的选择；
- evaluation policy identity：每次 resolve/install/audit 绑定 current approved policy 的 exact
  `(digest, authoritative_generation, validity_evidence_digest)`，进入 eligibility、plan、receipt
  与 audit，但不写回 bundle/index；generation/validity drift 即使 digest 相同也不是同一 identity。

发布当时二者可由同一 approved bytes 产生，字段和 role 仍必须分开。H 选择改变时，旧 pack
保留原 publication identity，同时在新 evaluation identity 下 re-audit；不得要求 republish、
改写 immutable artifact，或静默沿用旧 threshold/action。

### 2. v2 artifacts 与 closed schemas

Recommended v1 shape（未批准）包含七种互相独立、各自 versioned/digested 的 artifacts：

1. **Index snapshot/entry**：`publisher/name/version → bundle_digest`，并绑定 namespace
   ownership、publish attestation、runtime/schema ranges；resolver 对 canonical entry
   bytes 计算 index entry digest，并把结果放入 resolution/receipt envelope，entry 本身
   不嵌入该派生 digest，也不包含会随时间变化的 yank/revoke state。
2. **Bundle manifest**：只保存构建前可确定的 embedded identity
   （publisher/name/exact version/schema/publication-policy/content-root digest）、closed
   capabilities、targets/profiles、dependencies/conflicts、assets、rules 和 requested
   decisions。最终 bundle digest、index entry digest 与 registry-event evidence digest
   属于 resolution/receipt envelope，不嵌回 manifest；canonical official identity 是
   embedded identity 与这三个派生 digest 的 join，避免 digest 自引用。
3. **Registry-event evidence**：yank/revoke/namespace transfer 是 separately signed、
   append-only events；canonical event/evidence bytes 有独立 digest，绑定 immutable entry
   identity、event sequence/snapshot、issued/fresh-until times，不改写 entry bytes/digest。
4. **Precision evidence**：逐 rule 绑定 rule/capability/fixture/reviewer/count/window，
   不允许只给 pack average。
5. **Policy**：同一 closed schema 下 role-separated publication/evaluation artifacts；
   H-001–H-010 的获批取值、thresholds、issuers、offline/revocation/anchor action。
6. **Transaction journal/receipt**：plan、before/staged/after digests、owned entries、
   audit、commit/rollback/recovery。
7. **Local override**：和 official receipt 分离，逐 rule 保存用户 action、confirmation、
   evaluation-policy/eligibility identity，不得修改 official artifacts。

resolved identity 是 closed discriminated union：

```text
official_registry:
  publisher/name/exact_version/schema/bundle_digest/index_entry_digest
  registry_event_evidence_digest/publication_policy_digest
local_file:
  pack_id/exact_version/bundle_digest/canonical_locator_digest/schema/publication_policy_digest
```

`local_file` 的 publisher/index/event fields 必须 absent，不能为满足 official schema
伪造空字符串或 synthetic index digest。official/local 两类的 `source_kind` 与必填集合进入
receipt、plan 与 status；install resolution envelope 另加 current
`evaluation_policy_digest`。任何 floating locator 只可用于选择，不能成为 committed identity。

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
- `runtime_guard`：active policy identity、durable trusted-time high-water 与 expiry ceiling；
- `render`：human/JSON plan/status/error 同源。

Python `scripts/lib/guard_packs.py` 退为 author/legacy adapter，并拆出 manifest/publish
helpers；它不能成为 official runtime fallback。author validator 和 Rust reader 共享
golden canonical fixtures，任何 parse/decision 差异使 CI 失败。

### 4. Locator、fetch 与供应链验证

resolver 先把 H-001 允许的 locator 解析为 source kind，再得到 canonical exact identity。
official online flow：

1. bounded 获取 signed index snapshot 和 separately signed registry-event evidence，
   验证 trust root、namespace ownership、各自 identity/freshness 和 rollback/freeze
   protection；
2. 选择 exact version；仅当完整
   `(normalized publisher, normalized pack name, exact version)` 相同却出现多
   bundle/index-entry digest 时拒绝，不跨 pack name 比较；
3. 获取 bundle 到 transaction staging，边流式下载边 enforce byte/time limits 和 SHA-256；
4. 验证 release attestation subject == canonical bundle digest；
5. 在解压前解析 outer metadata，再用安全 extractor逐 entry验证 path/type/size/link；
6. 解压后重算 manifest/assets digests，执行 schema/join/capability/precision gates。

任何 fetch/verify error 都保留 closed stage/reason，零 host/config write。redirect、
proxy、certificate 和 credential行为由 H-001/H-003 policy 闭集限定；URL/response text
不得进入 shell。index/bundle size、文件数、单文件、总展开大小、compression ratio、
redirect count 和 timeout 都有已发布上限。

official offline cache 分别以 index snapshot digest、exact bundle digest 和 signed
registry-event evidence digest 存储。provenance trust `{verified, unofficial}` 与
revocation status `{current, revoked, unknown, not_applicable}` 分开保存和 render。
`official_registry` 必须使用前三种并携带 event evidence；`local_file` 必须使用
`not_applicable` 且 event field absent。identity-matched、
签名有效的 exact event cache 必须保留其结论：包含 applicable revoke event 时始终为
`revoked`；只有未超过获批 revocation freshness window、且证明截至 fresh-until 没有
applicable revoke 的 snapshot 才是 `current`。cache 缺失、malformed、identity mismatch
或过期的 non-revocation proof 才变为 `unknown` 并按 policy fail closed/degrade；已确认
revoke 不因 cache age 变为 unknown/current。所有 cache 显示 source/age/fresh-until，
不得自动转 unofficial、把过期 absence proof 谎报 current，或把仍有效 cache 错报 unknown。

### 5. Capability 与 host compatibility

v2 pack 不携带 host command。每条 rule 只引用 H-002 批准的 sealed capability ID；
capability registry 把 ID 映射到已随 verified VibeGuard release 安装的 Core detector/
adapter，并声明 protocol range、supported decision types 和所需 host features。

H-005 推荐 fixed Claude/Codex v1 时，resolver 读取现有安装 audit 的目标能力，但 pack
schema 仍只保存抽象 ID。只有 GH-701 decisions 获批、manifest v2/registry implementation
合入 main 且 compatibility/native-proof gates 通过，adapter 才改为消费其 canonical
`host_id + capability` view；merged Draft spec alone 不满足此 gate。不复制
`claude`/`codex` config fields。unknown host、
unknown capability、known-incompatible protocol、unsupported event、missing Core asset
有不同 closed reason，均在 plan 前结束。这些 compatibility failures 是不可由 local
override 提升的 terminal ceilings；只有 trust/revocation/compatibility/policy 全部允许、
且 ineligibility 仅来自 precision evidence 时，H-007 才可授权 local promotion。

H-002 若批准 executable 扩展而不是推荐方案，本 tech spec 不足：必须回到 spec review，
补 executable signing、sandbox、syscall/filesystem/network/secret policy、resource
limits、crash isolation、update/revoke 和 SEC-11 human security review，不能直接在 tasks
中扩 scope。

### 6. Transaction、ownership 与 recovery

Recommended H-004 layout（未批准）：

```text
~/.vibeguard/guard-packs/
  store/sha256/<bundle_digest>/        readonly verified content
  committed/<transaction_id>/         immutable dependency-set generation
  active/sets/<installation_scope_id>  one atomic dependency-set generation pointer
  active/floors/<installation_scope_id>.json  authenticated installation-floor mirror
  receipts/<source_storage_key>/<target>/<profile>.json  derived/read-only view
  transactions/<transaction_id>/
    plan.json
    journal.json                       closed applied manifest + recovery transitions
    before/
    staged/
  locks/ownership.lock
  locks/policy.lock
  locks/targets/<target>.lock
  locks/runtime-state/<installation_scope_id>.lock
  policy/active-evaluation.json          Core-owned authoritative local policy pointer
  policy/evaluation-generation-floor.json  authenticated policy-floor mirror
  policy/activation-journal.json         closed recoverable pending intent
  runtime-state/<installation_scope_id>/<active_generation_digest>.json  authenticated time mirror
  overrides/<source_storage_key>/<target>/<profile>.json
```

三个 mirror 的 authority 是 user-state tree 外、各自独立单调的 backend leaf；root 仅是稳定 trust container。
record identity、intent、two-generation mirror、journal/barrier/crash matrix 只由 supporting contract 定义。
runtime/management 要求 fresh per-leaf attestation 认证 selected mirror 的 exact leaf counter/digest；
unrelated leaf/aggregate-root progress 不得使 mirror 失效，unknown same-leaf transition 才 fail closed；
已证明 target leaf local lag 从 intent/journal roll forward。backend/platform 仍未批准。

`source_storage_key` 是 closed union：official 为
`official/<normalized_publisher>/<normalized_pack>`；local 为
`local/<sha256(canonical_local_identity)>`。local digest 输入覆盖 pack ID、exact version、
bundle、canonical locator、schema 与 publication policy identities；路径不得包含 raw
locator，也不得使用缺省 publisher、空字符串或可能与 official namespace 碰撞的 sentinel。
receipt/override schema 保存 source kind、canonical identity 与 storage key，读取时重算并
拒绝 mismatch。

上述 active policy entry 只保存已获批 policy digest、monotonic generation 与 validity evidence；activation 在 policy lock 下先原子写入并 fsync closed journal，绑定目标 pointer、
validity evidence、previous/target generation；再 CAS+fsync external floor，rename pointer 后重开
校验/fsync replacement 与 parent directory，才标 complete/清 journal。crash recovery 在任一 fsync
前中断都按 digest-valid intent 确定性重复同一 rename+fsync；缺失/损坏 intent 不得猜目标，
保持 fail closed。runtime 验证 pointer generation `>= floor`，旧 replay 即使 digest 匹配也
无效。pack/environment/CLI/publication artifact 均不能改写。每个 active generation 有独立
closed、Core-owned runtime-state entry，
绑定 installation generation、committed policy exact identity、`clock_epoch`、单调 sequence、
`last_trusted_runtime_time` 与不可逆 `audit_required` latch，并绑定上述 time leaf attestation。runtime 总先取得
`policy.lock`/等价 fence，证明 policy/install authorities 与 pointer/floors exact current，并持有到 decision。
current warn/off/no-data 跳过 runtime-state/time leaf；只有 block candidate 再取得 bounded runtime-state lock，
对可信 observation 先推进 high-water，fallback 同时锁存 reason。取锁前缓存不得执行；candidate 的
time-state lock/CAS 失败才 denial，latch 只有新 management generation 可清除。
新进程继承 durable high-water，不得以启动时间
重置。同 epoch 的 audit 不得降低它；显式 trusted-clock reconciliation 必须验证 Core-approved
time evidence，在 management locks 下重新 audit，递增 epoch，并将 evidence、新 generation
及其新 state 以 active pointer 原子提交。失败保持旧 pointer/state，普通 audit 不声称恢复。

dependency resolver 对 official graph node 使用
`(normalized_publisher, normalized_pack_name, exact_version)` 作为 immutability key，只有
该完整三元组相同而 bundle/index-entry digest 不同时才报冲突。相同 publisher/version 但
pack name 不同是两个合法 node；local node 使用完整 `source_storage_key`，不得退化为
publisher/version 或 pack/version 的部分 key。

每个 mutation 使用 canonical lock order：先取得 HOME-wide `ownership.lock`，再按 normalized
target ID 排序取得全部 target locks；lock-C 若提交 policy-bound generation，随后取得
`policy.lock`，最后取得 installation runtime-state lock；unlock 反序。HOME-wide lock 保护
shared store refs、dependency ownership、reservation 与 generation pointer，target locks
保护 host/config，policy lock 保护最终 policy pointer/floor 校验到 commit switch 的窗口。
不同 target 的 discovery/private staging/confirmation 可并行，但 shared mutation/commit
critical section 必须序列化。流程分为三个 lock epoch，exclusive lock 不跨越网络 fetch
或 interactive confirmation：

```text
lock-A → recover-old → validate-current-generation → snapshot base → unlock
       → discover → bounded-fetch/stage/verify
lock-B → recover/revalidate base → build immutable plan+digests → unlock
       → bounded-deadline confirm
lock-C → recover + CAS/fence revalidate generation/ownership/evidence/evaluation/plan
       → reserve/snapshot-owned-state → apply → audit
       → build+fsync generation/journal → final policy CAS/fence → floor fsync (= prepared)
       → rename set pointer → fsync pointer + parent directory (= durable commit)
          ├─ failure before floor → rollback
          └─ failure after floor → retain evidence + retry/recover switch; never rollback
```

`recover-old` 必须在 discovery/plan 前完成：旧 journal 造成的 partial state 不得参与新
plan。bounded fetch/staging 只写本 transaction 私有临时目录，不能进入 persistent store、
host/config、receipt、override 或 active surface；plan 展示 staging boundary/digests，
拒绝、取消、确认 timeout、验证失败或 rollback 后必须验证清理。confirmation deadline
来自 approved evaluation policy；lock-C 重新计算 policy-normalized evaluation time 与 eligibility
identity。floor 前 base generation、ownership、source-security binding、compatibility、policy、
evaluation/eligibility 或 plan digest 任一 drift，必须废弃旧确认并重新 plan/confirm。

plan 使用 compare-and-swap 前提：每个将修改的 file/config entry 同时记录 owner 与
observed before digest。fresh install 对 unowned path 建立 transaction-scoped provisional
reservation，绑定 transaction ID、expected-absent/current digest 和 planned after
 digest；它只在 ownership/target locks 内有效，不构成 receipt ownership，apply 前必须再次 CAS，
失败/取消随 rollback 清除。update/remove 仍只接受 committed receipt ownership，且当前
owned bytes/config state 必须匹配 receipt `after` digest；receipt `before` digest 是
rollback/remove restoration target，不是当前 ownership comparator。config 修改使用结构化
reader/writer 和现有 target ownership语义，不做 string append；shared
dependencies 需要引用集合，最后一个 owner remove 才可删除。

journal 每完成一步原子 append/replace closed state。audit 成功后先在
`committed/<transaction_id>/` 写入并 fsync 全部 resolved dependency receipts、active
identities、shared ownership refs、publication policy 与 committed evaluation policy exact
`(digest, authoritative_generation, validity_evidence_digest)`、provenance/
compatibility/precision evidence、source-applicable revocation binding、eligibility
digests、`decision_valid_until`、expiry fallback/reason 和 commit marker，并在 journal 记录
目标 monotonic installation generation、pointer/state digests；再推进并 fsync external
installation-generation anchor/floor，最后 rename installation-scope pointer，重开并校验 exact
replacement bytes/digest、fsync pointer handle，再 fsync containing directory；不得逐 pack switch。
两次 fsync 全部成功才是 durable commit boundary；此前 journal 必须保持 pending，不得 complete/
truncate/delete。runtime 必须先解析 set pointer，再验证 target/profile、commit marker 与 generation digest，绝不读取 orphan receipt、
staged state 或未提交 generation。durable pointer commit 后才允许 journal finalization/临时清理；
这些失败不撤销已提交语义，由下次 recovery 幂等完成。任一 pointer/directory fsync 前 crash 都从
保留的 target digest/bytes 确定性重复 rename+双 fsync。floor fsync 是 roll-forward-only
prepared boundary：之后旧 pointer 低于 floor 并 fail closed；必须保留 journal/generation/state
并重试或恢复目标 switch，禁止 rollback 或降低 floor，长期失败进入 `needs_repair`。
interrupt 后下次 mutation 先按 canonical order 取得 ownership/target/policy/runtime-state locks。
post-floor recovery 重读 exact host ID、adapter/compatibility/config-root digest，并将 closed applied
manifest 每个 normalized file/config key 的 owner/reservation/current digest 与 journal expected-after
逐项 CAS；missing/extra/mismatch 时 append+fsync `repair_required`、保留 foreign bytes/config 与全部
journal/before/applied evidence、返回 `needs_repair`，不得 switch、重写、出 committed receipt 或继续装。

commit 前，management 在 ownership/target locks 后取得 policy lock，再取 runtime-state lock；
两锁持有到 old-state snapshot、新 state fsync 与 active pointer durable switch。等价 CAS 实现须在
external installation anchor/floor 前取得 final compare-and-fence，journal 绑定 policy identity、
anchor counter 与 activation token，policy activation 在 token 释放前不得切换；pre-floor drift 才
rollback/re-plan/re-confirm。crash recovery 在 post-floor 发现 policy drift 时，append+fsync
`policy_drift_roll_forward` transition，CAS target state/time leaf 锁存 `policy_changed +
audit_required + protection_suspended`，再切换 exact target pointer；不得 rollback、执行旧 block 或
声称 healthy，fresh audit 以 successor generation 恢复。runtime lock revalidation 防止旧 generation
在 snapshot 后推进；新 state 继承同 epoch `max(existing_high_water, evaluation_time)`，pointer 同时
选择 generation/state 并验证 external installation floor，post-floor 只可 fail-closed roll forward。

same-content retry 先取得新的 normalized evaluation time，重算 freshness、revocation 与
eligibility identity，再比较 receipt/active/store/publication-policy/evaluation-policy/
index-entry/provenance/compatibility/precision-evidence/source-applicable-revocation/
evaluation/eligibility/horizon digests；只有全等才 no-op。official 比较 registry-event
digest；local 比较 `not_applicable` discriminant 且 event field 必须 absent。跨越任一
freshness/expiry/revocation
时间边界必须 re-audit，即使 bundle 和 policy bytes 未变。official 完整
`(publisher, pack, exact version)` 三元组相同但 bundle/index-entry digest 不同才是
registry immutability violation；local 使用完整 canonical identity/storage key，不做
partial version 比较。update 新旧 store并存直到 commit；
失败保持旧 active。remove 先验证 drift，只删独占 owned entries，用户/其他 pack canary
保持 byte-identical。

### 7. Precision eligibility 与 effective decision

新增纯函数，输入：

```text
requested_decision
rule_digest
capability_digest
source_security_binding =
  official_registry {
    provenance_trust,
    provenance_evidence_digest,
    revocation_status = current | revoked | unknown,
    registry_event_evidence_digest
  }
  | local_file {
    provenance_trust = unofficial,
    provenance_evidence_digest,
    revocation_status = not_applicable
    # registry_event_evidence_digest is absent
  }
compatibility_status
compatibility_contract_digest
precision_evidence_digest | null
precision_evidence | null
evaluation_policy_digest
authoritative_policy_generation
policy_validity_evidence_digest
approved_evaluation_policy
evaluation_time
local_override | null
# present promotion override additionally binds:
# override_confirmation_digest, confirmed_at, confirmation_expires_at
```

输出：

```text
official_eligibility = block_eligible | warn_only
official_default = block | warn | off
effective_local_decision = block | warn | off
reason_codes[]
eligibility_digest
decision_valid_until
block_basis = official_evidence | local_evidence_override | null
override_valid_until | null
expiry_fallback_decision = warn | off
expiry_reason_codes[]
override_status = applied | suspended | rejected | null
```

计算顺序固定：

1. 验证 source-kind union：official 的 provenance/revocation/event evidence 必须完整，
   local 必须 unofficial + `not_applicable` 且 event field absent；再验证 compatibility
   status/contract、evaluation policy 与 rule/capability/fixture/reviewer bindings；
2. 只相对显式、policy-normalized `evaluation_time` 验证
   TP/FP/acceptable/unclassified counts、window/freshness；函数内部不得读取 wall clock，
   evaluation time 进入 eligibility digest；
3. 按 H-006 公式计算 eligibility；
4. evidence 缺失/invalid/不足/过期/低 floor → `warn_only`；
5. 达标只得到 `block_eligible`，再结合 requested decision/host capability；
6. 应用独立 local override，并保留 official result；promotion 只可针对 evidence-only
   ineligibility；
7. 最后施加 terminal ceilings：`revoked`、unknown/incompatible host、unsupported
   capability、missing Core 必须 suspend/reject 任何促进到 block 的 override，effective
   decision 按 approved evaluation policy 只能降为 warn/off；`unknown` revocation 按明确 offline
   policy 处理，不能被 override 伪装成 current。
8. 按 block basis 计算有限 horizon。`official_evidence` 的 `decision_valid_until` 取
   evaluation policy expiry、precision evidence expiry/freshness、provenance/compatibility
   validity 与 official non-revocation `fresh_until` 等适用 horizon 的最早值。
   `local_evidence_override` 只允许 official、verified/current 且 evidence-only ineligibility；
   先要求 `confirmed_at <= evaluation_time < confirmation_expires_at`；future-dated、倒序或
   expired confirmation 为 invalid。再由 current policy 的 finite `max_override_ttl` 计算
   `override_valid_until = min(confirmed_at + max_override_ttl,
   confirmation_expires_at, evaluation policy expiry, provenance/compatibility validity,
   official non-revocation fresh_until)`，再以该值作为 decision horizon。missing/expired
   precision evidence 正是 override 的 ineligibility basis，不参与该 promotion horizon；
   local/unofficial source、synthetic event/time 或 unbounded TTL 仍禁止 promotion。任一
   basis-required horizon 缺失/invalid/unbounded 时只能 warn/off。同时把 block basis、
   confirmation digest、两个 horizon 与 fallback/reasons 全部纳入 eligibility digest。

不能从 pack average、GH-700 benchmark、aggregate CI precision 或 author 自报值填充
per-rule evidence。现有 `precision-tracker.py` 可导出 curated candidate，但需经新 schema、
reviewer/fixture ledger 和 issuer签名后才成为 official evidence。`acceptable`/
`unclassified` 是否计入 minimum samples 由 H-006 policy 明确；不得沿用 tracker 的 total
samples语义同时又用另一分母。

status/audit 每条 rule 同时显示 requested、official eligibility/default、local effective、
override status、precision value/null、counts、age、evaluation time、policy/issuer、provenance
trust、revocation/compatibility status、publication identity、committed/authoritative evaluation
policy 的 exact digest/generation/validity identities、policy floor、active installation
generation/floor、runtime sequence/latch、trusted-time high-water/`clock_epoch`、block basis、
`decision_valid_until`/source-applicable `override_valid_until`、expiry fallback/state 与
`audit_required`。eligibility digest 必须覆盖
上列每个 source-applicable binding digest；rule/evaluation-policy/evidence/provenance/
official-registry-event/compatibility/
normalized evaluation-time 变化产生新 digest 并触发 audit，即使 collapsed status 未变。
这包括只跨越 freshness/expiry/revocation window、其他 bytes 均未变化的情况。
active block 失去 eligibility 时按 H-008 action 事务降级，失败进入 `needs_repair`。

runtime hot path 先在 bounded policy lock/fence 下验证 external policy/install per-leaf authorities 与本地 pointer/floor exact current，并持有到 decision；
失败时 committed generation 未建立，必须 conservative deny/nonzero，不能信任 replayed warn/off。验证后
本就是 warn/off（包括 no-data/below-floor）的 record 保持原 decision、跳过 trusted-time leaf，time-anchor
unavailable 不能升级 denial。只有 current committed official/local block candidate 才取得 bounded
runtime-state lock，并在 decision 执行前持续重验 policy/active pointer、floor、state 与 per-leaf proof。policy identity drift 使用 semantic fallback；
即使随后因 expiry/rollback 选择 fallback，也先 CAS 推进 high-water 并在同一 state 锁存 closed reason +
`audit_required`，防止旧 block 复活。候选 block 的 pointer/floor/state/per-leaf proof 缺失、malformed、
replay 或任一 lock/CAS 失败才是 `runtime_guard_unavailable`，保守拒绝并非零返回；runtime 不得因后续
时钟或 policy bytes 返回旧值而清除 latch。
clock rollback 只有显式 reconciliation 可恢复；其他 official block 需 fresh audit，promotion
还需 fresh confirmation。
hot path 不联网，也不等待后台 scheduler 或用户先运行命令。

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
相同 source + publication policy build digest一致。`validate` 使用与 production reader 相同 golden
contract，并运行 fixtures/capability/precision checks。`publish` 先验证 namespace
authorization 和 version absence，再上传 immutable bundle/attestation，最后以
compare-and-swap追加 index entry；任一步失败不产生可 resolve 的半 entry。

yank/revoke/namespace transfer 是独立 signed events，不改写旧 entry。client 保存 canonical
event/evidence digest、签名链、sequence 与 freshness，resolved identity/receipt/audit 引用
该 digest而不是把 event state 折入 index entry digest。revoke online audit 按 H-008
policy生成降级 transaction；不能安全应用时
显示 `needs_repair` 并阻止新激活。runtime hot path 不联网；在 validity horizon 内使用
committed local eligibility，越界时执行上一节的 expiry ceiling。网络刷新只发生在
add/update/audit 等显式管理动作。

feedback export 由本地 explicit command 生成脱敏、schema-valid artifact，不自动发送。
publish/upload 是新的确认动作；diagnostic、bundle、receipt、report 都不得含用户代码、
HOME、token、proxy value、raw event payload 或未脱敏 stderr。

### 9. Legacy migration 与相邻 workstreams

- **safe-bash v1**：legacy reader继续 validate/explain/audit/remove。migration 先把旧
  receipt标为 registration-only，读取现有 Core audit建立 non-owned baseline，再安装 v2
  bundle；绝不声称旧 receipt拥有 Core files。
- **GH-699**：T1/T2=`6bf4ddc3`、portability=`05ea1220`、later T3=`da8780af`；待 T4–T7 后由 fixture 探测 released
  launcher/path/argv。GH-702 不重复 bootstrap、不猜 shim 名或另造 bootstrap；payload
  manifest加入所有 production client资产。
- **GH-701**：只在 decisions allowed、manifest v2/registry implementation 已合入且
  compatibility/native-proof gates allowed 后消费其 canonical registry；merged Draft
  spec 不算 availability。若其最终 schema/ID 与本 Draft冲突，implementation stop。
  fixed-host v1 不支持第三 host。
- **GH-700**：无实施依赖；其 report schema/digest不可用作 per-rule precision evidence。

### 10. Planned affected files

以下是 Recommended v1 的完整 implementation ownership map。H-001–H-010 若改变路径或
边界，先修订本 manifest；`tasks.md` 不能凭空增加未列 surface。

<!-- specrail-planned-changes -->
```json
{
  "issue": 702,
  "complete": true,
  "paths": [
    "vibeguard-runtime/Cargo.toml", "vibeguard-runtime/Cargo.lock",
    "vibeguard-runtime/src/main.rs", "vibeguard-runtime/src/guard_pack/mod.rs",
    "vibeguard-runtime/src/guard_pack/model.rs",
    "vibeguard-runtime/src/guard_pack/locator.rs",
    "vibeguard-runtime/src/guard_pack/archive.rs",
    "vibeguard-runtime/src/guard_pack/trust.rs",
    "vibeguard-runtime/src/guard_pack/capability.rs",
    "vibeguard-runtime/src/guard_pack/precision.rs",
    "vibeguard-runtime/src/guard_pack/transaction.rs",
    "vibeguard-runtime/src/guard_pack/runtime_guard.rs",
    "vibeguard-runtime/src/guard_pack/render.rs",
    "vibeguard-runtime/src/guard_pack/anchor/",
    "schemas/guard-pack.schema.json", "schemas/guard-pack-index.schema.json",
    "schemas/guard-pack-registry-event.schema.json", "schemas/guard-pack-capability.schema.json",
    "schemas/guard-pack-precision.schema.json", "schemas/guard-pack-policy.schema.json",
    "schemas/guard-pack-receipt.schema.json", "schemas/guard-pack-transaction.schema.json",
    "schemas/guard-pack-override.schema.json", "schemas/guard-pack-runtime-state.schema.json",
    "schemas/guard-pack-feedback.schema.json",
    "schemas/guard-pack-anchor-intent.schema.json", "schemas/guard-pack-anchor-commit.schema.json", "schemas/guard-pack-anchor-mirror.schema.json", "schemas/guard-pack-anchor-ipc.schema.json", "schemas/guard-pack-anchor-authorization.schema.json",
    "schemas/guard-pack-h010-decision.schema.json", "schemas/guard-pack-anchor-perf-budget.schema.json", "schemas/guard-pack-anchor-perf-batch.schema.json", "schemas/guard-pack-anchor-perf-result.schema.json",
    "packs/safe-bash/pack.yaml", "packs/safe-bash/README.md",
    "scripts/lib/guard_packs.py",
    "scripts/lib/guard_pack_manifest.py",
    "scripts/lib/guard_pack_publish.py",
    "scripts/lib/guard_pack_receipts.py",
    "scripts/precision-tracker.py",
    "scripts/ci/validate-guard-pack-publish.py",
    "scripts/setup/guard-packs.sh",
    "scripts/setup/guard-pack-anchor-service/",
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
    "tests/test_guard_pack_anchor.sh", "tests/perf_guard_pack_anchor.sh", "tests/bench_hook_latency.sh", "tests/test_hook_perf_contract.sh",
    "tests/fixtures/guard_packs/", "tests/fixtures/guard_pack_anchor/", "docs/reference/hook-latency-contract.md",
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
    "docs/specs/GH702/tech.md", "docs/specs/GH702/monotonic-anchor-contract.md",
    "docs/specs/GH702/tasks.md"
  ]
}
```

| Concern | Planned affected files | Focused proof |
| --- | --- | --- |
| Released CLI/client | `vibeguard-runtime/src/main.rs`, planned **vibeguard-runtime/src/guard_pack/** | `cargo test --manifest-path vibeguard-runtime/Cargo.toml guard_pack`；no-Python/no-checkout fixture |
| Closed v2 contracts | existing `schemas/guard-pack.schema.json`, planned **schemas/guard-pack-{index,registry-event,capability,precision,policy,receipt,transaction,override,runtime-state,feedback}.schema.json** | schema positive/negative corpus in `bash tests/test_guard_pack_supply_chain.sh` |
| Trust/safe archive | planned **guard_pack/locator.rs**, **archive.rs**, **trust.rs** | tamper/attestation/rollback/freeze/path/link/size/TOCTOU matrix |
| Capability/host | planned **guard_pack/capability.rs**; consume approved GH-701 registry when available | Claude/Codex/unknown/incompatible/unsupported fixture matrix |
| Transaction/receipt | planned **guard_pack/transaction.rs**, receipt/transaction schemas | crash-at-every-stage, concurrent lock, drift, rollback, recovery and canary tests |
| Precision/runtime policy | planned **guard_pack/precision.rs**, **runtime_guard**, precision/policy/override/runtime-state schemas, `scripts/precision-tracker.py` | exhaustive eligibility truth table + binding/freshness/override/policy-rotation/clock-rollback negatives |
| Monotonic anchor | planned **guard_pack/anchor/** + anchor authorization/H-010/perf schemas；exact owners in supporting contract | per-leaf concurrency、authorized target、JCS phase crash、identity mutation、installed Claude/Codex all-budget gate |
| Author publish | planned **scripts/lib/guard_pack_manifest.py**, **guard_pack_publish.py**, **scripts/ci/validate-guard-pack-publish.py** | two-build digest equality; half-publish/index-CAS/revoke/yank fixtures |
| Legacy migration | `scripts/lib/guard_packs.py`, `scripts/lib/guard_pack_receipts.py`, `packs/safe-bash/` | existing 623-case shell surface remains green plus migration ownership sentinels |
| Release distribution | `scripts/release/payload-manifest.txt`, `scripts/setup/guard-packs.sh`, `setup.sh`, `tests/test_payload.sh`, `tests/test_release_workflow.sh` | GH-699 actual no-clone launcher invokes Rust client; payload tamper fails closed |
| Docs | `README.md`, `docs/README_CN.md`, planned **docs/how/guard-packs.md** | generated command/status examples; doc path and command validators |

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 released no-checkout command | Runtime registry + GH-699 actual launcher integration | fresh HOME fixture runs discovered released `vibeguard add` with `.git`, Python, Cargo and API key absent; checkout-only route reports unofficial |
| B-002 canonical exact identity | Locator + discriminated embedded/resolved identity model | table rejects missing/empty/mismatch/floating fields；official requires immutable entry/event/publication-policy digests；local requires locator/bundle/publication-policy digests and rejects registry fields |
| B-003 external author independence | Author CLI + external-repo fixture | fixture root outside VibeGuard builds/publishes/installs while `git diff` of VibeGuard source stays empty |
| B-004 closed versioned schemas | Pack/artifact/policy + anchor authorization/H-010/budget/batch/result schemas；Rust production and Python authoring/legacy readers | duplicate/unknown/empty/every-identity mutation corpus fails consistently |
| B-005 zero-side-effect invalid input | Resolver/preflight | missing/empty/unknown/tampered/zero-rule fixtures assert store/receipt/active/config canaries absent |
| B-006 approved decision gate | Role-separated policy schema + offline gate | invalid-at-publication blocks publish；valid signed publication later expiry/spec drift does not block install；missing/stale/current-spec-drift evaluation blocks；rotation re-audits without republish |
| B-007 visible trust states | Source-kind model + renderers + receipt | official matrix covers current/revoked/unknown and requires event digest；local matrix requires unofficial + not_applicable and rejects present/synthetic event fields |
| B-008 complete pre-write plan | Planner + shared renderer | golden plan asserts identity, trust/revocation, capabilities, per-rule reasons, persistent writes, bounded staging/network, cleanup, rollback and receipt before bounded confirmation |
| B-009 closed capabilities | Manifest join + capability resolver | unknown/undeclared/multi-mapped/free-text/extra-payload fixtures fail before executor or host mutation |
| B-010 safe archive containment | Streaming archive extractor | absolute/traversal/device/link/case collision/duplicate/size/ratio corpus leaves staging boundary canary untouched |
| B-011 complete provenance chain | Index + trust verifier | checksum-only, self-report, wrong namespace/subject/digest and valid full-chain fixtures prove verified is all-or-nothing；event-only mutation never changes immutable entry digest |
| B-012 online/offline failure semantics | Locator/cache/revocation policy | timeout/malformed/redirect/fresh-absence/expired-absence/cached-revoked/expired-known-revoke/identity-mismatch matrix asserts exact current/revoked/unknown status |
| B-013 target compatibility | Capability/host resolver | unknown host, incompatible protocol, unsupported capability, missing Core and valid Claude/Codex fixtures produce distinct closed statuses and cannot be promoted by override |
| B-014 runtime privacy/capability | Sealed capability registry + sandbox boundary | network/credential/path/log access sentinels and child-env capture prove undeclared access never runs or persists |
| B-015 transaction state machine | Transaction + anchor supporting contract | authorized immutable target survives lost response；unrelated leaf/aggregate-root observation still rolls forward，only same-leaf divergence needs_repair |
| B-016 scoped rollback/repair | Transaction rollback/recovery | pre-floor restores before digests；post-floor every applied/host/config CAS match rolls forward；any drift preserves state/evidence and needs_repair |
| B-017 interruption recovery | Transaction + anchor recovery | crash every local/external/barrier stage and mutate applied/host/config；exact target resumes, mismatch needs_repair, never false receipt or permanent proven-target unavailable |
| B-018 complete committed receipt | Receipt schema/writer + source storage key | official receipt requires event digest；local requires not_applicable + absent event；all block receipts bind committed policy and finite decision/override horizons/fallback；local round-trip needs no publisher sentinel |
| B-019 ownership preservation | Planner + reservation + structured config adapters | update/remove succeeds only when current state matches receipt after digest；matching before but not after is drift；fresh conflict/cancel preserves canaries |
| B-020 dependency graph | Dependency resolver + set generation | missing/cycle/range/undeclared recursion zero-apply；same publisher+pack+version/different digest conflicts，while same publisher+version/different pack names coexist；valid graph uses one pointer |
| B-021 idempotent retry | Identity + receipt comparator | no-op compares source-applicable fields；local absent event is valid and synthetic event is rejected；same status with refreshed official evidence or a time boundary re-audits |
| B-022 safe update | Update transaction | from/to diff golden; failure at each gate keeps old active/store bytes; success never mutates old store |
| B-023 ownership-safe remove | Remove/repair flow | shared refcount, exclusive file, missing/corrupt receipt and drift fixtures prove no HOME scanning or foreign delete |
| B-024 concurrency isolation | HOME ownership lock + ordered target locks + transaction IDs | parallel shared-dependency/different-target mutations serialize ownership commit without deadlock；disjoint preflight/staging may parallel；lock timeout is bounded/visible |
| B-025 per-rule evidence binding | Precision schema/join | pack-average-only, wrong rule/capability/fixture/reviewer/window and orphan evidence fixtures are rejected |
| B-026 honest precision calculation | Eligibility pure function | discriminated source binding requires official event digest or local not_applicable/absent event；applicable digest changes produce new eligibility；time/count negatives remain invalid |
| B-027 policy-owned thresholds | Policy journal + per-leaf anchor CAS | Core-reconstructed signed target authorization + intent/fence/barrier bind exact authority；rotation/identity drift cannot reuse old decision；post-floor drift rolls forward suspended |
| B-028 insufficient evidence degrades | Anchored generation-scoped runtime guard | authenticate current generation before classification；current warn/off/no-data skip time anchor；block fallback latches time；lost-response resumes |
| B-029 block eligibility is not block | Eligibility truth table | cross-product of requested decision, trust, capability, host and evidence proves every prerequisite is necessary |
| B-030 isolated local override | Override schema/applicator | policy-bounded horizon works only when confirmed_at <= evaluation_time < expiry；future/expired/unbounded confirmation, policy drift and terminal ceilings reject；expiry requires fresh confirmation |
| B-031 same gate for core/community | Shared eligibility function | identical evidence inputs under curated/community publishers yield identical eligibility; badge/high severity cannot bypass |
| B-032 evidence drift re-audit | Audit + eligibility identity + runtime latch | digest/generation/validity or horizon drift latches degradation；only fresh audit/new generation restores ordinary drift，clock rollback also requires reconciliation |
| B-033 opt-in private feedback | Export renderer/redactor | default install/runtime packet capture is empty; export field golden is redacted; cancel-before-send makes zero network calls |
| B-034 immutable registry history | Index + registry-event validators | duplicate publisher+pack+version, entry overwrite/delete/reorder and transfer-without-event fixtures fail；valid yank/revoke changes only event evidence digest；historical receipt remains explainable |
| B-035 yank/revoke actions | Registry event + audit transaction | yank/revoke action references exact signed event evidence digest；yank blocks new install；revoke degrades existing；write failure produces needs_repair |
| B-036 legacy safe-bash migration | v1 reader + migration planner | current v1 regressions pass; migration never claims Core file ownership and failure leaves registration receipt usable |
| B-037 GH-699 dependency | Payload/release integration | `6bf4ddc3` T1/T2 + later `da8780af` T3 fixtures remain green；remaining T4–T7 release/package-manager/docs evidence satisfies official |
| B-038 GH-701 interface boundary | Host adapter compatibility layer | merged-Draft-only fixture stays fixed Claude/Codex；only decisions + merged implementation + compatibility/native proof accepts registry IDs；reject second registry/early third-host active claim |
| B-039 GH-700 metric separation | Schema/type/name guards | fixtures cannot load public benchmark or aggregate CI result as per-rule pack evidence; docs render distinct labels |
| B-040 reproducible atomic publish | Author build/publish client | two clean builds under the same publication policy match digest；evaluation-policy rotation does not rebuild；publish failures never create resolvable partial entry |
| B-041 truthful list/status/audit | Shared status + anchor renderer | golden output enumerates authority identities/floors/time plus backend/root/leaf/counter/barrier/availability/repair；degradation exits nonzero without key material |
| B-042 offline runtime stability | Committed eligibility + local anchor IPC | installed Claude/Codex runner；contract test breaches every H-010 budget and mutates approved-H010/policy/generation/validity/decision identities；all mismatch/rotation nonzero without stale fallback |

## 数据流

```text
author source root
  └─ validate/build ──> canonical bundle + per-rule evidence
                           │
                           ├─ verify namespace/provenance
                           └─ publish immutable object ──> immutable index entry
                                                        + signed registry events

vibeguard add <locator>
  ├─ lock-A: ordered ownership/target locks → recover + snapshot generation → unlock
  ├─ immutable publication identity + current evaluation policy + locator
  │    ├─ official: index + event evidence → bundle fetch
  │    └─ local: exact file identity + not_applicable revocation (no event field)
  │         └─ private staging/preflight
  ├─ lock-B: recover + revalidate base → immutable plan/digests → unlock
  ├─ bounded confirmation (no exclusive mutation lock held)
  └─ lock-C: reacquire ordered locks + CAS generation/ownership/evidence/time/plan
       ├─ reserve/apply/audit → one dependency-set pointer switch
       └─ rollback/recovery/needs_repair

runtime hook
  └─ authenticate current policy/install per-leaf authorities + local pointer/floors
       ├─ stale/unavailable → current generation unestablished → conservative deny + nonzero
       ├─ current committed warn/off/no-data → keep decision；skip trusted-time leaf
       └─ current committed block basis → generation-scoped time authority/state
            ├─ identity/time/horizon valid → committed block
            ├─ drift/expiry/rollback → persisted fallback + audit_required
            ├─ time-state/lock/CAS unavailable → conservative deny + nonzero
            └─ no registry/network/telemetry access
```

持久化面是 closed set：content-addressed verified store、index/registry-event caches、
transaction journals/before snapshots、committed receipts/active identities、durable installation-generation
floor mirrors、authoritative local evaluation-policy pointer/activation journal、evaluation-policy
floor/time mirrors and per-leaf attestation/authorization receipts、local overrides
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
  - transaction state transitions、receipt ownership、override finite horizon/revocation、
    active-policy identity、trusted-time high-water monotonic/CAS state。
- [ ] Integration:
  - external repo author → reproducible build → local registry publish → fresh no-clone add；
  - tamper/rollback/freeze/yank/revoke/offline/unsafe archive；
  - failure/cancel/crash at every transaction stage + recovery；
  - parallel target lock、user/other-pack canaries、legacy safe-bash migration；
  - runtime network/secret/path sentinels、policy rotation before expiry、clock rollback within the
    validity interval/across restart/high-water corruption和 feedback redaction。
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
bash tests/test_guard_pack_anchor.sh
bash tests/test_hook_perf_contract.sh
bash tests/bench_hook_latency.sh --runs=3 --confirmation-runs=3 --fail-on-regression
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
