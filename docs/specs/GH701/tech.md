# Tech Spec — versioned host adapter registry 与第三 host proof

## Linked Issue

GH-701

## Product Spec

[`product.md`](product.md)

## Normative Security/Lifecycle Appendix

[`security-lifecycle-contract.md`](security-lifecycle-contract.md) is the normative
B-019/B-025/B-028 protocol and is part of the decision-bound spec set.

## Codebase Context

以下锚点在 round-3 修订开始时的 PR #712 HEAD
`568967c4f5d76e2f32e2a37734ed3f9d3b27c72b` 复核。

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Public first screen | `README.md:5`; `README.md:11`; `README.md:13`; `README.md:26` | PR #705 已提供 firewall 定位、demo GIF、当前 clone 安装与拦截清单；没有 required one-command block 或 benchmark 表 | PR #705 是四个 required blocks 中前两块完成的 partial baseline；额外块去留等待 H-004，GH-699/GH-700 证据到位前不能提前改写事实 |
| Hook registration source | `hooks/manifest.json:2`; `hooks/manifest.json:3`; `hooks/manifest.json:45`; `hooks/manifest.json:51` | schema v1 manifest 明确自称 Claude/Codex source of truth，每个 hook 固定有 `claude`、`codex` 两个对象 | 当前模型不能通过 registry 加 host，需 versioned generalization |
| Manifest schema/reader | `schemas/hooks-manifest.schema.json:24`; `schemas/hooks-manifest.schema.json:33`; `scripts/lib/hooks_manifest.py:95`; `scripts/lib/hooks_manifest.py:120`; `scripts/lib/hooks_manifest.py:253` | schema 强制两列；reader 分别提供 `claude_specs` / `codex_specs`，validator 只遍历两种 platform | host capability、协议版本和 closed support 状态需统一 contract，同时保留现有 consumer |
| Canonical hook core | `vibeguard-runtime/src/hook_orchestrator/mod.rs:22`; `vibeguard-runtime/src/hook_orchestrator/mod.rs:69`; `vibeguard-runtime/src/hook_orchestrator/mod.rs:75` | runtime 按 canonical `HookKind` 读取 stdin 并进入共享 hook checks/orchestrators | adapter seam 应在进入这里之前归一化、在 decision 输出之后编码，避免 core 分叉 |
| Claude wrapper/config | `hooks/run-hook.sh:8`; `hooks/run-hook.sh:15`; `hooks/run-hook.sh:16`; `hooks/run-hook.sh:115`; `scripts/setup/targets/claude-home.sh:396`; `scripts/setup/targets/claude-home.sh:424`; `scripts/setup/targets/claude-home.sh:590` | Claude wrapper 声明 source config/protocol 并调用共享 hooks；Claude target 负责 config、check 与 clean | generalization 必须保持 Claude profile 与配置 ownership |
| Codex input/output adapter | `hooks/run-hook-codex.sh:2`; `hooks/run-hook-codex.sh:66`; `hooks/run-hook-codex.sh:70`; `hooks/run-hook-codex.sh:116`; `hooks/run-hook-codex.sh:139`; `hooks/_lib/codex_runner.sh:27`; `hooks/_lib/codex_runner.sh:56`; `hooks/_lib/codex_runner.sh:71`; `vibeguard-runtime/src/codex_hooks/adapter.rs:85` | Codex wrapper 识别 namespaced hook，normalizer 可输出多行并逐行调用 canonical hook，再把 Claude-style outputs 转回 Codex；当前没有 host-neutral batch result/priority contract | 现有多项循环证明 seam 必须是 Vec/batch，而不是单 request；aggregation、correlation 与 multi-block 需要从 codex-specific runner 提炼 |
| Codex install/check | `scripts/setup/targets/codex-home.sh:39`; `scripts/setup/targets/codex-home.sh:60`; `scripts/setup/targets/codex-home.sh:90`; `scripts/setup/targets/codex-home.sh:179` | target 合并 VibeGuard entries、保留第三方 hooks、启用 feature flag并检查 capability | proof host target 必须采用同样的 atomic ownership/check/clean contract，不能复制 core |
| Caller evidence | `vibeguard-runtime/src/hook_orchestrator/context.rs:72`; `vibeguard-runtime/src/hook_orchestrator/context.rs:87`; `vibeguard-runtime/src/hook_orchestrator/context.rs:94`; `vibeguard-runtime/src/hook_orchestrator/context.rs:100` | caller identity fallback 只识别 Claude/Codex，其余归为 unknown | 新 host 必须由 adapter 提供 bounded identity/protocol evidence，不能靠环境猜测 |
| Existing contract tests | `tests/test_manifest_contract.sh:319`; `tests/setup/install_flow_tests.sh:755`; `tests/setup/install_flow_tests.sh:761`; `tests/hooks/test_log_timer.sh:85` | 已覆盖 Codex manifest/schema 负例、安装结果、第三方 preservation 与 caller identity | 新 registry/proof host 需要同密度 fixtures，并保留现有回归 |

## 设计方案

### 1. Recommended proposals 与 approval gate

实现开始前必须取得 machine-readable decision record，但它只能记录维护者在
H-001 / H-002 / H-003 / H-004 上的明确选择，不能把本 spec 的 recommendation
当成 approval。

- Recommended H-001 为 Gemini CLI proof host。依据是其官方 hook 文档已经定义
  synchronous `BeforeTool`、structured deny 与 extension 内 hooks/hooks.json
  packaging（[Writing hooks](https://github.com/google-gemini/gemini-cli/blob/main/docs/hooks/writing-hooks.md)；
  [Extension hooks](https://github.com/google-gemini/gemini-cli/blob/main/docs/extensions/reference.md)）；
  record 必须固定官方文档 URL、Gemini CLI exact release、hook protocol
  snapshot/digest、支持/不支持事件与 blocking response。若维护者选择 opencode
  或 Cursor CLI，必须用等价 native blocking evidence 替换这些字段。
- Recommended H-002 为 `--host gemini` opt-in；discover 不写入，plan 展示 exact
  diff 并确认。auto-detect 即使获批也只提出 target，同样逐项确认，且不可并用。
- Recommended H-003 为删除 stale branch。`readonly_retain` 必须记录 owner、expiry、
  expected head 与 active GitHub ruleset ID/digest；protected collector live 验证
  exact-branch update+delete deny/no bypass，expiry/head/rule 漂移失败；`ls-remote` 不足。
- Recommended H-004 为 `strict_four`：首屏只渲染 positioning、demo、GH-699
  one-command 与 GH-700 benchmark，PR #705 的 clone install/拦截清单移到首屏
  后。互斥备选 `preserve_pr705_extras` 只有在 GH-701 issue acceptance 已由维护者
  同步、明确列出额外块与证据要求后才有效；record 必须绑定该 issue update 的
  immutable node、source URL、updated_at 与 acceptance digest。未选、双选或未
  同步均 blocked。

decision record 还固定 adapter contract version、host protocol range、config
path/format、runtime pin、真实 CLI fixture 命令和 stop conditions。缺任一批准
字段时 route 仍是 `needs_human`。

#### 1.1 一次性 bootstrap，不让未来 gate 授权自身

当前受保护 main 尚无本节的 collector/attestation/offline gate，因而 H-001–H-004
可信 record 不可能先于 bootstrap 存在。解锁顺序固定如下：

1. 当前三份 normative specs 先走 ordinary repository routing 的 `plan_first`：
   handoff 固定 `mode`、artifacts、runtime pinning snapshot、verification owner、
   stop conditions 与 lane map；维护者必须在 GitHub review 中明确批准完整 spec set。
   Recommended proposals 不因 spec approval 自动成为 H-001–H-004 selections。
2. coordinator 从 live GitHub issue/PR/branch/review-thread state 做 duplicate-work
   search，并把当前 base SHA、搜索时间、冲突 PR/branch 与结论写入
   docs/specs/GH701/tasks.md 的 bootstrap tranche。tasks 必须覆盖 B-001–B-035，把
   bootstrap 标为首个 `bootstrap_once` task/tranche；host/README 产品 tranche 可
   预排，但每项必须标为 `execution_state: blocked`，并依赖
   `gh701_decision_gate: allowed`。H-004 缺失时只有 bootstrap 可执行，不禁止生成完整 blocked plan。可选 SpecRail
   packet/evaluator 可以在用户明确请求时提供本地辅助，但不得成为任务生成、
   bootstrap 授权或后续实现的前置条件，也不得替代 live GitHub/CI/review evidence。
3. bootstrap implementation PR 可包含 tasks.md 计划 artifact；其 production/test
   diff 除下列 allowlist 外一律拒绝：
   `resolved_trust_paths` 的全部 exact paths、checks/gh701_attestation.py、
   tests/test_{gh701_decision_gate,gh701_maintainer_evidence_collector,
   host_adapter_proof_gate,readme_claim_gate}.sh 与 tests/fixtures/GH701/bootstrap/。
   proof/README consumers 在 decisions 缺失时必须 fail closed；禁止放宽其他 issue、
   ordinary routing、CI、review 或 human merge gate。
4. bootstrap PR 不得修改 README.md、hooks/manifest.json、hooks/、
   vibeguard-runtime/、scripts/setup/ 或任何 host adapter/config，也不得产生
   proof/active/complete evidence。CI 必须把第 1–2 步的批准 review node、base SHA
   与 duplicate-work snapshot 作为只读输入，验证固定 allowlist/negative tests；
   candidate 新 gate 不能为自己的 merge 提供 spec approval。
5. bootstrap PR 仍按 ordinary `impl_pr_open → human_review → ci_green →
   merge_ready → merged` 流程，保留 independent final review 与 human merge
   authorization。只有 listed surfaces merge 到受保护 main 后，
   `bootstrap_once` 才永久关闭；main 上受保护 workflow 随后收集 H-001–H-004。
   缺 decision allowed 时，tasks.md 中其余 tranche 继续 blocked。

`bootstrap_once` 的关闭哨兵不是 feature-branch marker：offline scope gate 只读
检查 GitHub evidence 给出的 protected default-branch HEAD，要求该 tree 同时含
全部 `resolved_trust_paths`、attestation verifier，以及后续 GH701 CI consumer
对 decision/head/digest 的显式调用契约；每个下游 gate 缺 decision 时 fail
closed。protected-main workflow 在 merge 后生成
artifacts/evidence/GH701/bootstrap-completion.json 与 detached
artifacts/evidence/GH701/bootstrap-completion.intoto.jsonl；completion contract
使用 decision schema 的 `$defs.bootstrap_completion`，固定
`bootstrap_contract_version: 1`、default-branch head、完整 sorted trust path set、
每个 main-tree blob SHA-256、protected workflow 的 decision-gate 调用契约与
task/implementation CI consumer 的 decision/head/digest binding 契约。

offline scope gate 先验证 completion attestation 的 protected workflow identity，
再逐项重算当前 main tree blob digests 和 wiring contract。只有 path set 完整、
contract version/behavior 匹配且所有 digests 相等时状态才是 `closed`，随后任何
第二个 bootstrap diff 都 blocked。schema-valid negative fixtures 必须覆盖缺失
protected workflow decision-gate invocation、缺失 task/implementation CI
consumer binding、任一 contract/version/blob digest 漂移与 path 部分存在；
这些结果一律为
`partial/needs_human`，绝不能 closed，也不得重开宽泛 bootstrap。当前 spec PR
必须先 merge，tasks/bootstrap PR 才能开始，所以 bootstrap 不会把 normative spec set
与 control-plane implementation 混入同一次人类批准。

decision contract 的 planned fixed surfaces 为：

- schema：schemas/gh701-maintainer-decisions.schema.json
- collected record：artifacts/evidence/GH701/maintainer-decisions.json
- detached attestation bundle：
  artifacts/evidence/GH701/maintainer-decisions.intoto.jsonl
- read-only collector：checks/collect_gh701_maintainer_evidence.py
- offline gate：checks/gh701_decision_gate.py
- negative harness：tests/test_gh701_decision_gate.sh

record 对 H-001–H-004 各保存 closed `decision_id`/`selected_option`，以及 GitHub
`actor_login`、`author_association`（只接受 OWNER/MEMBER）、immutable
`source_node_id`、canonical `source_url`、`source_created_at`、
`source_updated_at`、`source_body_sha256`、单调 `collection_generation`、
`revocation_state`、`approved_spec_head_sha` 和 selection-specific fields。
collector 只接受 PR/issue 编号，从 GitHub API 只读查询 structured maintainer
decisions；actor、association、node/URL/head/time/option 均不得由 argv、环境变量
或现有 artifact 注入。每次授权前，受保护 workflow 必须重新查询 source node，
要求 node 仍存在、updated_at/body digest 未变、没有更晚的同 decision selection
或结构化 `revoke` marker，并把本次 live query 的 check-suite/run ID 与 generation
写入 record。collector 必须运行在受保护 default-branch workflow，以 GitHub
artifact attestation 对 record digest、collector workflow/ref/SHA、run identity
与 live-query generation 签名；实现分支不能自称 trusted collector。

trusted workflow identity 固定为
`.github/workflows/gh701-maintainer-evidence.yml@refs/heads/main`，权限仅
以下五个显式键，不使用合并或隐式权限：

```yaml
permissions:
  contents: read
  issues: read
  pull-requests: read
  id-token: write
  attestations: write
```

gate pin GitHub OIDC issuer、repository、workflow path、`refs/heads/main` 与
collector commit SHA，拒绝 pull-request ref 或同名 feature-branch workflow。
H-004 的 `preserve_pr705_extras` record 还包含 collector 从 issue acceptance
structured marker 解析出的 canonical JSON snapshot（闭集 block ID + evidence
gate）、issue node/URL/updated_at 与 JCS SHA-256；H-004 decision source 必须晚于
该 update 并引用同一 digest。离线 gate 与 renderer 都从 attested snapshot 重算
digest，不需要信任实现者提供的 issue body 副本。

offline gate 先验证 attestation bundle 的签名、certificate identity、workflow
ref/SHA、record SHA-256 与 generation，再验证四项互斥选择、GitHub
node/URL/time/body digest、association、revocation state、approved spec head 与
当前 candidate 的 ancestry/binding。offline gate 单独运行只可返回
`valid_preview`，不能授权实现或发布；`allowed` 还要求调用它的当前 protected CI
run 已完成上述 live-source query、run/check-suite identity 与 attestation
一致，且该 source 没有更新、删除、更晚 selection 或显式 revoke。
`preserve_pr705_extras` 额外验证 issue acceptance digest/node。bootstrap merge
之后，task/implementation CI consumers 都必须在本次 protected CI 调用中执行
live-source check 与该 gate，绑定
`decision_record_sha256`、`attestation_sha256`、`collection_generation`、
protected run identity 与 candidate HEAD；禁止只读缓存的 allowed JSON、较旧
generation、口头批准或另一 spec 的 task plan。任一项未获批准、source 被编辑/
删除/撤销或存在更晚 decision 时保持 `needs_human`，本 spec 不代替维护者选择。

record 的 head contract 固定五个字段：`approved_spec_head_sha`、
`product_blob_sha256`、`tech_blob_sha256`、`security_lifecycle_blob_sha256` 与
`decision_input_sha256`。`approved_spec_head_sha` 是 spec PR 经维护者批准并 merge
后、位于 default branch 的 commit；collector 必须验证完整 spec set bytes 与
被批准 PR head 完全相同，不能直接使用可能因 squash 而不在 main ancestry 上的
PR head。三个 blob digest 对
`git cat-file blob <approved_spec_head>:docs/specs/GH701/{product,tech,security-lifecycle-contract}.md` 的原始
bytes 计算，不做换行、Unicode 或空白规范化。

`decision_input_sha256` 对 tech.md 内唯一 `gh701-decision-inputs` JSON object 做
RFC 8785 JCS 后计算 SHA-256；该 object 固定 H-001–H-004 closed options、proof
host/release/protocol requirements、H-003 expected branch/head、H-004 issue
acceptance snapshot rules 与 collector trust identity：

<!-- gh701-decision-inputs:start -->
```json
{
  "schema_version": 2,
  "issue_number": 701,
  "decisions": {
    "H-001": {
      "options": [
        "gemini_cli",
        "opencode",
        "cursor_cli_with_equivalent_native_proof"
      ],
      "host_id_by_option": {
        "gemini_cli": "gemini_cli",
        "opencode": "opencode",
        "cursor_cli_with_equivalent_native_proof": "cursor_cli"
      },
      "required_selection_fields": [
        "host_release", "host_distribution_provenance",
        "protocol_snapshot_sha256", "native_blocking_event",
        "security_provider_kind", "security_provider_version",
        "containment_policy_sha256", "executable_memory_policy_sha256",
        "high_side_supervisor_identity", "high_side_supervisor_version", "declassification_policy_sha256", "low_side_output_schema_sha256",
        "trusted_clock_source_identity", "trusted_clock_mapping_policy_sha256", "mutation_exclusion_provider_kind", "mutation_exclusion_provider_version",
        "mutation_exclusion_policy_sha256", "lifecycle_provider_kind", "lifecycle_provider_version", "lifecycle_transition_policy_sha256",
        "lifecycle_caller_auth_policy_sha256", "lifecycle_journal_trust_root_sha256",
        "host_acquisition_ack_schema_sha256", "use_release_receipt_schema_sha256",
        "relocation_manifest_sha256", "relocation_signing_identity"
      ]
    },
    "H-002": {
      "options": [
        "explicit_host_opt_in",
        "auto_detect_install"
      ],
      "required_confirmation": "per_target_exact_diff"
    },
    "H-003": {
      "options": [
        "delete",
        "readonly_retain"
      ],
      "branch": "docs/gh701-readme-first-screen",
      "expected_head_sha": "c77253b4bcdc7c18f8861bfc8693e6db89150436",
      "readonly_retain_required_fields": [
        "owner", "expires_at", "protection_ruleset_id", "protection_ruleset_sha256",
        "deny_update", "deny_delete", "bypass_actor_count"
      ]
    },
    "H-004": {
      "options": [
        "strict_four",
        "preserve_pr705_extras"
      ],
      "preserve_required_fields": [
        "issue_node_id",
        "issue_source_url",
        "issue_updated_at",
        "acceptance_snapshot",
        "acceptance_jcs_sha256"
      ],
      "acceptance_markers": [
        "<!-- gh701-acceptance:start -->",
        "<!-- gh701-acceptance:end -->"
      ]
    }
  },
  "collector_trust": {
    "oidc_issuer": "https://token.actions.githubusercontent.com",
    "repository": "majiayu000/vibeguard",
    "workflow_path": ".github/workflows/gh701-maintainer-evidence.yml",
    "workflow_ref": "refs/heads/main",
    "require_live_source_recheck": true,
    "revoke_marker": "revoke",
    "offline_preview_authorizes": false
  },
  "resolved_trust_paths": [
    ".github/workflows/gh701-maintainer-evidence.yml", ".github/workflows/gh701-proof-supervisor.yml", ".github/workflows/host-adapter-proof.yml",
    ".github/workflows/readme-claim-evidence.yml", "checks/collect_gh701_maintainer_evidence.py",
    "checks/gh701_attestation.py", "checks/gh701_decision_gate.py",
    "checks/host_adapter_proof_gate.py", "checks/readme_claim_gate.py",
    "scripts/render_readme_claims.py", "schemas/host-adapter-proof.schema.json", "schemas/gh701-host-acquisition-ack.schema.json", "schemas/gh701-use-release-receipt.schema.json",
    "schemas/gh701-maintainer-decisions.schema.json", "schemas/gh701-maintainer-witness.schema.json", "schemas/gh701-proof-supervisor-attestation.schema.json",
    "schemas/readme-claim-evidence.schema.json", "schemas/public_benchmark_summary.schema.json"
  ]
}
```
<!-- gh701-decision-inputs:end -->

collector 生成最终 canonical decision input 时，以该 object 为 base，按固定 key
加入 H-001–H-004 selected values/selection-specific fields、H-004 acceptance
snapshot、H-003 observed branch state，以及每个 `resolved_trust_paths` 文件在
protected-main collection HEAD 的 raw-byte SHA-256；record 同时保存
`collector_trust_head_sha`。不得接受调用者提供的 digest map。task/implementation
candidate 只有同时满足以下四项才继承 decisions：

1. `git merge-base --is-ancestor <approved_spec_head_sha> <candidate_head>`；
2. `git merge-base --is-ancestor <collector_trust_head_sha> <candidate_head>`；
3. candidate 三份 normative spec 原始 bytes digest 与 record 完全相同；
4. 从 candidate specs、attested selections/snapshot/facts 与当前 trust-path bytes
   重建的 JCS decision-input digest 与 record 完全相同。

因此 tasks.md、实现代码与 tests 的 descendant commits 可继续，而 normative spec
任一 byte、decision object、selected issue acceptance snapshot、host
release/protocol、stale branch expectation、workflow path/ref 或 collector trust
identity 改变都立即 `needs_human`，必须从 protected-main collector 重新收集四项
decision/attestation。ancestry 成立不能掩盖 digest 漂移。

bootstrap 关闭后，`resolved_trust_paths` 只能经 `trust_rotation` 修改，不能重开
`bootstrap_once`；rotation request 必须来自结构化 GitHub maintainer approval，
固定旧 `collector_trust_head_sha`、candidate PR/head、sorted changed path set、
每个 old/new raw-byte SHA-256、candidate diff SHA-256、reason、UTC expiry 与随机
nonce；approval actor 只能是与 candidate author 不同的 OWNER/MEMBER。当前
protected-main collector 通过 GitHub API 直接读取 candidate blobs 和 diff，重算
全部 digest，确认变更仅落在获批 trust path、当前 completion sentinel 仍匹配旧
trust set、approval 未编辑/删除/revoke/过期，随后用 protected-main workflow
identity 签发 detached rotation attestation。candidate workflow、candidate 内的
schema/gate、实现者提供的 digest map 或通配 path 都没有授权能力。
rotation attestation 只允许该 exact candidate head 单次通过旧 trust-byte equality；
ordinary CI/review/merge gate 仍全部必需。merge 后 protected workflow
从新 main 重建 completion sentinel/trust digests，旧 rotation nonce 永久 consumed，
并撤销旧 H-001–H-004 allowed record，要求重新收集 decisions。candidate head、
path set/digest、approval source、expiry、old sentinel 或 protected workflow
identity 任一不匹配均 `needs_human`，不得回退为第二次 bootstrap。
该集合覆盖 authorization-conferring consumer/schema/renderer/workflow invocation；普通 implementation PR 不得修改 verifier 后再由它授权同一 candidate。

### 2. Manifest v2：top-level hosts + per-hook mappings

`hooks/manifest.json` 升级为 `schema_version: 2`，结构责任明确分两层：

- top-level `hosts` 以 `snake_case host_id` 为 key；每项声明 adapter contract、
  `protocol_version_range`/`runtime_version_range`/`runtime_abi_range`/`host_response_deadline_ms`、
  wrapper/config/capabilities/lifecycle。三 host 各一次；resolver 在 plan/core 前
  验证全部 range，未知/越界为 `incompatible`、零写入、零 core execution。
- 仅 `kind: hook` 的 executable hook 带 `host_mappings`。mapping key 必须与
  top-level hosts **完全相等**，每个值声明 B-004 support、profiles 与有序
  event mappings；`native/partial` 必须至少有一个 event 和 encoder，
  `unsupported/not_applicable` 禁止携带可执行 command。
- `library`、`manual`、`git-hook` 不经 host dispatch，必须没有
  `host_mappings`。现有 `run-hook-codex` wrapper metadata 移到
  `hosts.codex.wrapper`；wrapper 不是可被 core 执行的 hook。manifest docs 对
  non-host entry 单独渲染，不伪造每-host `not_applicable` 行。
- validator 拒绝 undeclared/extra/missing mapping、重复 event+matcher、
  unknown profile、invalid protocol range、mapping 指向 non-hook、
  `native` 无 blocking encoder、unsupported 带 command，以及 host wrapper /
  canonical script identity 不一致。

`scripts/lib/hooks_manifest.py` 提供单一
`host_specs(manifest, host_id, profile)` / capability view。v1 reader 保留为
deprecated compatibility input：只把现有 Claude/Codex 两列规范化成 v2 in-memory
view，打印一次 bounded deprecation warning；所有 writer/generator 只输出 v2，
v1 不得声明第三 host/active proof。GH-701 不删除 v1 reader，未来删除必须新 spec。
Claude/Codex registry entry 固定 `lifecycle: legacy_json_compat_v1`，继续调用现有 target-specific atomic owned-entry merge/preservation/check/clean；proof host/新增 host 必须按 capability 选择
`versioned_host_storage_v1` 或 `verified_file_setup_v1` 并走第 4 节。validator 拒绝 legacy/新-host lifecycle 互换、capability 与 lifecycle 不符，以及 verified-file 自动 mutation。

Unknown matrix 固定为：

| Surface | Condition | Result | Config/core side effect |
| --- | --- | --- | --- |
| manifest validation | mapping host 未在 top-level hosts 声明 | contract error / nonzero | none |
| discovery | 检测到未注册 executable/config | `unsupported` | zero write, core not run |
| known adapter | host 已注册但 protocol/version 越界 | `incompatible` | zero write, core not run |
| blocking runtime | 已注册 blocking event 但 event/payload 无法 decode | fail-closed host response | sanitized failure log only |

### 3. Batch canonical adapter seam

adapter 接口不是一对一：

```text
decode_host_event(native_event) -> Result<Vec<CanonicalHookRequest>, AdapterError>
evaluate_batch(Vec<CanonicalHookRequest>) -> Vec<CanonicalHookDecision>
encode_host_response(batch, decisions) -> Result<HostResponse, AdapterError>
```

- `CanonicalHookRequest` 固定 `batch_id`、`request_id`、`request_index`、host /
  protocol identity、canonical event/tool、core 消费的 tool input、session/cwd
  与 enforcement metadata。一个 multi-file/apply-patch native event 按 host
  payload 顺序产生 N 个 requests；空 Vec 只允许 mapping 显式
  unsupported/not-applicable，其他空 batch 为 adapter error。
- decoder 固定 `MAX_BATCH_REQUESTS = 64`。在构造 canonical requests、调用 core
  或写逐项日志之前，先以 bounded parser 验证 native collection 的完整 item count；
  count 超限、无法确定或流式输入在第 65 项出现时，整个 batch fail-closed，零项
  进入 evaluation，且只记录 closed `batch_too_large` + capped count metadata。
  禁止 truncation、partial evaluation 或把未评估项当作 pass。
- 同步 host deadline 必须大于 `RESPONSE_RESERVE_MS = 250` 加
  `CORE_TERMINATION_RESERVE_MS = 100`。每个 invocation 必须遵守 normative appendix
  §1 的 non-escapable provider；process group 不构成 containment。Linux timeout 在 bounded
  inner cleanup 后仍有 D-state task时销毁 outer VM；仅凭 closed host pipes/ledger 和 provider
  destroy/zero-side-channel receipt 才编码 sanitized `hook_error: batch_deadline_exceeded`。
- core 严格按 request_index 依次运行现有 `HookKind`、checks、orchestrators、
  rules 与 guards，每项产生恰好一个 decision；proof adapter 不得复制
  rm/U-16/L1 classifier。每项日志带 batch/request/index，fix instruction 也绑定
  request_id。
- 每个 core invocation 的 `HookResult.failed`、`hook_error` 或等价执行失败必须
  规范化为该 request 的闭集 `hook_error` decision；它保留 sanitized closed reason
  class 与 request correlation，不携带 parser/core free text。不得丢弃失败、压成
  pass/warn、少返回 decision，或让 aggregator 接收未定义的 error side channel。
- batch aggregator 固定闭集优先级
  `hook_error > block > escalate > gate > correction > warn > complete > pass`。
  `hook_error`、`block`、`escalate`、`gate` 都是 fail-closed
  enforcement/confirmation outcomes；任一存在时禁止 auto-apply correction。
  `hook_error` primary 使用固定 host fail-closed encoder response，并逐项写 sanitized
  error log。`complete` 是 non-enforcement terminal success，
  显式聚合但不得覆盖 warn 或 enforcement。primary decision 是最高优先级中
  request_index 最小者。
  所有 block 都必须写 log，不能只写 primary；fixes 按 request_index 去重并以固定
  `MAX_FIX_ITEMS = 8`、`MAX_FIX_BYTES = 4096` 合并，primary fix 优先，其余保持输入
  顺序；不拆分一个 fix，超限项整体省略并记录 `omitted_fix_count` 与
  `fixes_truncated: true`，不得泄漏被省略 raw text。
- primary fix 缺失/编码失败/oversize 时保持 block，返回小于 256-byte、仅含 closed
  reason/request_id 的 `PRIMARY_FIX_FALLBACK` 与 fallback/truncation/count flags。
  有原 fix 时保留随机 `fix_id`；缺失时生成 128-bit CSPRNG `fallback_fix_id`。
  原文/content digest 不进 response/log/proof；其余 oversize fix 整体省略。
- host 只允许一个 response 时，response 引用 primary request，同时携带有界 fixes
  与 `decision_count`；每条日志和 proof artifact 都能由 batch_id/request_id 回查。
  duplicate/missing/cross-batch ID、decision 数与 request 数不同或 response 无 primary
  log 都 fail loud。
- `batch_id` 在 adapter boundary 由 128-bit CSPRNG 生成且不含 payload；request_id
  固定为 batch_id 加 request_index，不能从 host-provided ID 直接复用。重试是新
  batch，并通过独立 `retry_of_batch_id` 关联，避免重复 ID 混淆旧日志。
- decoder/encoder 只持久化 closed diagnostics；raw payload、prompt、command、content、
  parser free text 与 high-side/secret-derived data 在 project/global logs、proof 与 response 中不得出现。

### 4. Transactional and verified host lifecycle

两种新 lifecycle 都实现 appendix §3 的 `recoverable_host_transaction_v1` 闭集；
Claude/Codex 仍 dispatch 到 `legacy_json_compat_v1`，不得生成第三 host proof。

1. `discover/plan`：只读解析 host/version/config/capability。operation 闭集为
   install/update/clean/disable/reverse/supersede；缺 version-CAS+exclusive-lease 时零 mutation。
2. `lock/lease`：canonical path 顺序取得 bounded local locks，再向 host API 取得 lease；
   durable journal fsync transaction、operation、managed identity、sealed token digest、owner/expiry。
3. `base_bound`：lease 内 fresh-read current version+digest。install/update 只替换 exact
   VibeGuard entry；clean/disable 从此 fresh current 删除 exact owned entry，保留全部当前第三方
   entry/order，绝不复用 install snapshot。owned entry 被改写/碰撞则 needs-human。
4. `apply`：先 durable mutation intent，再由 host API 在一个 linearization point 校验
   lease+current version/digest 并 CAS candidate；返回 version 后重读 exact candidate 并 fsync result。
   rename/advisory lock/mtime/exclusive claim 不能冒充该 capability；多 target 逐项 durable。
5. `probe/commit`：bounded native probe 分别验证 registration 或 unregistration；成功才 durable
   写 operation-specific evidence/commit。`active` 在 terminal lease-release receipt 前不可见。
6. `abort/rollback`：仅当 token 仍属于 transaction 且 current exact-equal apply 返回的
   candidate version+digest，才 version-CAS 回该 operation 的 fresh base；clean 不得回 install base。
   token/version/digest drift（含 byte-identical newer version）保留当前内容并 needs-human。
7. `release`：success/abort/needs-human 都先 durable 写 release operation ID，再幂等
   release/revoke API lease并 fsync signed result；之后才释放 local locks。owner-death/expiry必须返回
   同 transaction/token-digest 的 durable revoke receipt，unknown/not-found 不能自行视为 released。
8. `recover/gc`：按 transaction/release ID 查询 API，精确区分 CAS 前、CAS 后、commit 后和
   release 后 crash，恢复下一个缺失 transition。只有 `lease_released` 可删 local journal；
   needs-human 保留 journal/sealed recovery，release-before-fsync 重放 receipt而不重复 mutation。

`verified_file_setup_v1` 的 target mutation 仍由用户执行；protected provider 在 same-user
trust domain 外拥有 journal/CAS/lease。publication abort 的 verified reverse 必须在同一
multi-record CAS 把 current tombstone 恢复成 exact predecessor completed pointer，或原子发布
等价新 generation；exact absence 保持不可 use。任何 pointer/identity drift 都完成零效果。

### 5. Deterministic README claim evidence

实现不创建第二套 GH-700 benchmark authority。README claim gate 对 GH-699 使用本节
的 install envelope；对 GH-700 直接消费其 committed Release 与验签
`public_benchmark_summary`：

- planned schema：schemas/readme-claim-evidence.schema.json
- GH-699 fixed evidence path：docs/evidence/GH699/readme-install.json
- GH-699 detached attestation path：
  artifacts/evidence/GH699/readme-install.intoto.jsonl
- GH-700 authority：计划中的 **schemas/public_benchmark_summary.schema.json** 验证的 committed
  GitHub Release summary、summary 所绑定的 exact report checksums、release
  `publish_intent` attestation 与公开 Release asset inventory
- trusted producer workflow：
  `.github/workflows/readme-claim-evidence.yml@refs/heads/main`
- planned validator：checks/readme_claim_gate.py
- planned negative harness：tests/test_readme_claim_gate.sh

GH-699 evidence 使用 required envelope：
`schema_version`、closed `claim_id`、`issue_number`、`source_head_sha`、
`release_tag`、`release_manifest_sha256`、`verified_at`、`inputs_digest`、
`producer_sha256`、exact `producer_argv`、`workflow_run_id`、
`attestation_subject_sha256`、`rendered_claim` 与 claim-specific payload。source
head 必须等于 validator 对该 claim 固定 input allowlist 执行“latest relevant
change commit”得到的 commit，且是 current HEAD ancestor；`inputs_digest` 覆盖同一
producer/config/fixture allowlist，不包含 evidence 自身，任何受影响输入变化都会
同时造成 head/digest stale。

GH-699 发布用 evidence 只能由上述 protected-main workflow 在 clean checkout 中按 envelope
的 exact argv 执行 pinned producer 生成；workflow 权限闭集为 `contents: read`、
`id-token: write`、`attestations: write`，并对 evidence digest、producer
SHA/argv、source HEAD、release manifest 与 run identity 生成 GitHub artifact
attestation。validator 离线读取 fixed path、schema、git ancestry/current inputs、
detached attestation 与 README marker，验证 certificate workflow/ref、subject/run
binding 后，重新计算 latest relevant head、input digest 和 rendered value；
未认证 payload 即使内部 digest 自洽也拒绝。local mode 可以重跑 exact producer
做 diagnostics，但只能返回 `valid_preview`，不得发布 README claim。README 不能
手写第二份数字/命令。

- GH-699 payload 固定 argv、clean-home marker、platform、release payload/runtime
  digest、`repo_clone_present: false`、install/verify exit codes 与 bounded output
  digest；任一非零、clone、未覆盖 supported platform 或 release mismatch 拒绝。
- GH-700 validator 不运行独立 `vibeguard bench`，也不接受平行的 GH-700 README
  benchmark payload。它从 published
  Release inventory 取得 GH-700 `public_benchmark_summary`，验证 schema、
  `summary_digest`、release-workflow attestation、`publish_intent`、tag/source
  commit、每个 bound report checksum 与 publication committed state，再直接消费
  summary 内 sample counts、interception/false-positive/latency numerator /
  denominator 和 rendered rows。summary 未发布、Release 未 commit、asset/checksum
  漂移或存在 standalone rerun 时拒绝。
- negative fixtures 必须 schema-valid 后再触发 semantic gate，覆盖 missing path、
  wrong issue/claim、non-ancestor/stale head、changed inputs、wrong release、
  tampered/unsigned output、wrong workflow/ref/run、wrong producer SHA/argv、
  rendered README、GH-699 clone/nonzero，以及 GH-700 unpublished/draft Release、
  wrong publish intent、standalone rerun、historical latency/zero-sample/summary
  或 report checksum mismatch。

README renderer 在读取 GH-699/GH-700 evidence 前必须执行 H-004 decision gate，
并把 `decision_record_sha256`、`attestation_sha256`、`approved_spec_head_sha` 与
`selected_option` 写入 generated marker。`strict_four` 输出恰好四块：PR #705
定位、PR #705 demo、GH-699 one-command、GH-700 benchmark；当前 clone 安装与
拦截清单移到首屏之后。`preserve_pr705_extras` 则只允许额外输出 H-004 所绑定
GH-701 issue acceptance 中逐项命名且有 deterministic source 的 PR #705 块；
renderer 重算 acceptance digest，不能把任意现有 README 文本当作已批准额外块。
H-004 缺失/双选、head 或 digest 漂移时 renderer nonzero 且不写 README。

### 6. Fixed third-host proof gate

第三 host 使用以下固定 contract，不由实现者临时选路径：

- runtime schema/path：schemas/host-adapter-proof.schema.json；artifacts/evidence/GH701/third-host-proof.json
- maintainer witness schema/path：schemas/gh701-maintainer-witness.schema.json；artifacts/evidence/GH701/maintainer-witness.json
- witness attestation bundle：artifacts/evidence/GH701/maintainer-witness.intoto.jsonl
- supervisor schema/bundle：schemas/gh701-proof-supervisor-attestation.schema.json；artifacts/evidence/GH701/proof-supervisor.intoto.jsonl
- protected supervisor workflow：.github/workflows/gh701-proof-supervisor.yml@refs/heads/main
- collector/gate/harness：checks/collect_gh701_maintainer_evidence.py；checks/host_adapter_proof_gate.py；tests/test_host_adapter_proof_gate.sh

runtime proof 固定 schema/issue/host/release/protocol/adapter/event/HEAD/time、VibeGuard `event_correlation_id`、host/runtime/config digests、batch/request/fix/log correlation 与 decision summaries；schema 禁止 maintainer identity/source/time。candidate time 不是 freshness authority。native event ID 只在进程内解析，不进
artifact/log/response/witness；correlation ID 是不从 native/payload/digest 派生的
独立 128-bit CSPRNG 值。

proof 由真实 released host session 产生，direct wrapper/runtime/demo 不能生成
`proof_kind: native_session`。artifact 不提交进 source commit，所以 gate 可要求
`candidate_head_sha == git rev-parse HEAD`；age 只由 protected run/supervisor event/
attestation issuer 的 trusted time 计算，三者 max skew 300s；H-001 exact-pin trusted clock source identity 与 monotonic-to-wall mapping policy digest；`0 <= age <= 7 * 24h`，future/replay 拒绝。
protected workflow 固定拆成两个 job/VM。credential-free execution job 使用
`permissions: {}`；candidate 环境缺少 `GITHUB_TOKEN`、OIDC request、Actions
runtime/artifact/attestation token，且 VM 不能读取 supervisor state/output/handoff。
trusted supervisor 在 VM 外实现 candidate-independent high-side boundary：unknown/free-form
默认 secret，仅 closed digest-bound policy 的 low typed fields 经单向 channel 进入 candidate；
secret/derived digest/encoding/substrings/length/key/opaque handle 均不可读。closed output schema
由 supervisor canonicalize。H-001 exact-pin high-side supervisor identity/version、declassification policy
与 low-side output schema digests；attestation 绑定这些选择、高侧 keyed commitment、candidate view、
typed transcript、output schema 与 sink manifest。byte sentinel 仅 diagnostic；split/encoded/
hashed/cross-sink reconstruction 由 access/noninterference proof 阻断。
native proof 完整实现 appendix §1–2：Linux 内层 cgroup 清理有界；D-state descendant 未退出时
protected control plane 在 deadline 内销毁无 host-writable backend 的 outer VM，并签发 destroy/
zero-side-channel receipt。H-001 provider/policy 还绑定 continuous loader ledger、relocation page
roots 与 inbound/outbound memory denial；escape、COW、patch、gap 或 unsupported provider 阻断。
boundary 销毁后按 protected CAS + authenticated closed manifest 交付 subjects；OIDC signer
先验签 manifest、逐 byte 重哈希并 exact-match inventory/version 后才签 subjects。

maintainer witness 是单独 artifact，由第 1 节同一个受保护 default-branch
collector 从 fresh GitHub review/comment 只读生成。collector 只接受 PR/issue
编号，从结构化 `observed_native_block` maintainer statement 取得
`source_node_id`、canonical `source_url`、actor、OWNER/MEMBER association、
`witnessed_at`、`candidate_head_sha`、`event_correlation_id` 与 runtime proof SHA-256；这些
字段不得由 CLI 参数、环境变量或 runtime proof填入。受保护 workflow 对 witness
digest、collector workflow/ref/SHA 与 run identity 生成 detached GitHub artifact
attestation；implementer 在 feature branch 运行同名脚本或手写 witness JSON 都
没有受信 certificate identity，必须被拒绝。

witness record 还固定 `source_created_at`、`source_updated_at`、
`source_body_sha256`、单调 `collection_generation` 与闭集 `revocation_state`。
每次 proof allowed 前，当前 protected CI run 必须重新通过 GitHub API 查询同一
`observed_native_block` node，重算 canonical body digest，确认 node 仍存在、
updated_at/body 未变、没有更晚的同 event/head witness、结构化 `revoke` marker
或删除状态；live-query run/check-suite identity 与新 generation 必须进入 witness
attestation 和 gate result。只验证较早 witness 的离线签名不能授权。
gate 还必须消费当前 protected CI run 的
`gh701_decision_gate: allowed` result、decision record 与 attestation，先把 proof
的 `host_id` 按 `host_id_by_option` 闭集 exact-match H-001 selected option，再逐项
exact-match H-001 的
`host_release`、`host_distribution_provenance`、`protocol_snapshot_sha256`、
`native_blocking_event`、high-side supervisor/declassification/output-schema、trusted-clock source/mapping、
lifecycle provider kind/version/transition+caller-auth policies/journal trust root、两个 host-use subject schema digests 与 candidate head。distribution provenance 是 closed
union：签名 package identity + registry integrity，或 signed release manifest +
platform asset digest；两者都绑定 issuer/subject/release/platform 与 expected
binary SHA-256。gate 从受信 metadata/H-001 attestation 取得 identity，并验证 supervisor bundle 的固定 schema/path/issuer/workflow/ref/SHA/run/subjects/predicate、
event/nonce/process/redaction、provider journal root/sequence/snapshot、host-acquisition-ack/use-release receipt digests 绑定；native 绑定 executable，
两 subject 按两个 fixed trust-path schema exact bytes/digest 验证，且 `$ref` 只许同文件 fragment、零 external resolver；
interpreted CLI 同时绑定 interpreter/argv/entrypoint/package snapshot。gate-time
重读只检测 drift；拒绝 self-report/pathname/unsigned checksum、运行后替换或
snapshot 外代码。其他第三 host proof 不能替代获批 host。之后 gate 分别
schema-validate runtime proof 与 witness，再离线验证 witness
attestation 的签名/certificate identity/workflow SHA/record digest，最后绑定
immutable node、canonical URL、同一 event correlation、exact candidate head、runtime proof
SHA 与时间顺序；candidate `observed_at` 仅 exact-match trusted event time（skew≤300s），
trusted event/issuance 均在 protected gate time 的 7×24h window。之后再验证 host/runtime file SHA、当前 config digest、
event/log/fix correlation 与 dual-log redaction。negative fixtures覆盖 missing
witness、embedded/self-filled witness、untrusted workflow/certificate、tampered
attestation、missing/stale decision result、wrong H-001 host/release/distribution/
protocol/event、wrong node/association、stale/future、wrong head/event/proof SHA、
host distribution/issuer/package/integrity/binary digest drift、runtime/config
digest drift、duplicate IDs、missing secondary block、secret sentinel、
missing/wrong process-time measurement、gate-time swap、native event ID leakage、
wrong interpreter/argv/entrypoint/package root、external module load、
direct-wrapper proof，以及 witness source edit/delete/revoke/supersede。只有 gate
allowed 才能把 proof host 标为 active 或
声明 GH-701 third-host slice complete。allowed 后只上传 sanitized runtime proof、
witness 与 attestation bundle 作为 exact-head CI/PR artifacts，并在 gate result
记录各自 SHA-256；source tree 不提交 runtime artifact，也不上传 raw
config/payload/log content。

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 | README wording + generated capability matrix | `bash scripts/ci/validate-hook-behavior-docs.sh`；人工确认 README supported-host 列表与当前 registry evidence 一致 |
| B-002 | H-004-aware README required-block renderer + GH-699 gate | `bash scripts/ci/validate-doc-paths.sh`；README claim negative fixture 断言 PR #705 只满足 positioning/demo required blocks，缺 GH-699 evidence 时仍显示当前真实 install path |
| B-003 | GH-700 evidence renderer/gate | `bash scripts/ci/validate-doc-command-paths.sh`；README claim negative fixture 断言缺 evidence、历史 latency、zero-sample 均不生成 benchmark 表 |
| B-004 | host registry schema + validator | `bash tests/test_manifest_contract.sh`；`bash scripts/ci/validate-hooks-manifest.sh` |
| B-005 | batch canonical request/decision golden fixtures | `cargo test --manifest-path vibeguard-runtime/Cargo.toml`；同一 fixture 的 Claude/Codex/proof-host common decision parity |
| B-006 | separate runtime proof + trusted maintainer-evidence gate | 运行 host-adapter proof gate；受保护 collector witness 绑定真实 native event、exact HEAD、deny/fix 与 matching sanitized dual logs |
| B-007 | capability registry + unsupported-event fixtures | `bash tests/test_manifest_contract.sh`；`bash tests/test_setup.sh` 的 proof-host unsupported-event fixture |
| B-008 | unknown matrix + decode failure paths | `cargo test --manifest-path vibeguard-runtime/Cargo.toml`；`bash tests/test_setup.sh` 覆盖 unknown executable/protocol/event 四类结果 |
| B-009 | closed diagnostics + candidate-independent confidentiality | runtime/setup fixtures 拒绝 high-side access 与 split/encoded/hashed/cross-sink reconstruction；sentinel 仅 diagnostic |
| B-010 | transactional lifecycle upsert/clean ownership | `bash tests/test_setup.sh`；重复 transaction/clean fixture 检查 managed identity、第三方 bytes/order 与 config digest |
| B-011 | snapshot/apply/probe/rollback | `bash tests/test_setup.sh` 的 malformed、readonly、phase-failure、probe-failure 与 external-drift fixtures |
| B-012 | ordered locks + host-scoped state/caller identity | `bash tests/test_setup.sh`；`bash tests/hooks/test_log_timer.sh`；同 config contention、多 config reverse-order 与 multi-host fixtures |
| B-013 | adapter I/O/privacy review | `bash tests/test_behavior_eval.sh`；`git diff --check`；人工审查新增 adapter 无 network/telemetry/secret reader |
| B-014 | v2 Claude/Codex compatibility consumers | `bash tests/test_setup.sh`；`bash tests/test_codex_runtime.sh`；v1/v2 golden configs semantic equivalent，现有 JSON auto-install/owned-entry preservation 不变，lifecycle 互换被 validator 拒绝 |
| B-015 | registry protocol/runtime compatibility resolver | `bash tests/test_manifest_contract.sh`；version below/above/unknown negative fixtures |
| B-016 | journal crash recovery/retry | `bash tests/test_setup.sh`；每个 transaction phase kill fixture 后重试，断言 safe rollback 或 needs_human 且无 duplicate registration |
| B-017 | check/doctor bounded probe evidence | `bash tests/test_setup.sh`；对六个 evidence state 的 fixtures 运行 check/doctor |
| B-018 | H-004-aware README renderer + dependency gates + journey | decision gate 与 README-claim gate；`strict_four`/`preserve_pr705_extras` positive fixtures 精确渲染，未选/双选/acceptance digest mismatch nonzero；维护者在 fresh home 计时 install → verify → real-host interception |
| B-019 | decoder cap/deadline + destructible containment | runtime tests 覆盖 64/65/unknown count、escape/broker、D-state/inner-cgroup nonempty、bounded outer VM destroy 与零 late output；appendix §1 |
| B-020 | deterministic complete decision aggregator | `cargo test --manifest-path vibeguard-runtime/Cargo.toml` 的 all pairwise mixed decisions（含 hook_error/complete）、`HookResult.failed`/hook_error normalization、hook_error/block/escalate/gate suppress correction、multi-block、fix dedupe/cap fixtures |
| B-021 | batch/request/log/fix correlation | `cargo test --manifest-path vibeguard-runtime/Cargo.toml`；duplicate/missing/cross-batch ID 与 missing-primary-log negative fixtures |
| B-022 | v2 top-level hosts/per-hook mappings/non-host entries | `bash tests/test_manifest_contract.sh`；`bash scripts/ci/validate-hooks-manifest.sh` 的 key-set、non-host、contradiction negative fixtures |
| B-023 | v1 compatibility/deprecation | `bash tests/test_manifest_contract.sh`：v1 read+warning、v1 third-host reject、v2-only writer 与 v1/v2 Claude/Codex golden parity |
| B-024 | complete unknown matrix | `bash tests/test_manifest_contract.sh`；`bash tests/test_setup.sh`；`cargo test --manifest-path vibeguard-runtime/Cargo.toml` 分别固定 contract/discovery/protocol/runtime outcomes |
| B-025 | recoverable host transaction + protected-journal verified-file lifecycle | setup tests 覆盖 closed phases、same-user forgery、publication-aborted tombstone→predecessor pointer restore、consume/N+1 CAS、lease-release-before-GC；appendix §3 |
| B-026 | versioned install/clean CAS + crash/drift recovery | `bash tests/test_setup.sh`：fresh-current owned-entry removal/third-party preservation、clean rollback base、token/version/digest drift、commit/release/fsync crash 与 durable revoke receipt |
| B-027 | authenticated GH-699/GH-700 evidence schema/gate | 运行 README-claim negative harness；GH-699 protected producer attestation + exact SHA/argv 与 GH-700 committed Release `public_benchmark_summary`/reports/`publish_intent` positive fixtures 精确渲染 README；standalone rerun、draft/unpublished Release、unsigned/self-reported/wrong workflow/ref/run/producer 与 semantic negative matrix 全部 nonzero |
| B-028 | H-001-bound proof/witness and trusted time | harness 验证 H-001 high-side supervisor/policy/output schema、trusted clock source/mapping + run/event/issuer time+300s skew、journal provider/root/use subjects、relocation/page equality；replay/substitution/write/trace gap 均 nonzero；appendix §§2–3 |
| B-029 | stale branch closure gate | protected GitHub ruleset API fixture：deleted allowed；readonly retain 仅 exact head/owner/unexpired/exact-target update+delete deny/zero bypass allowed；retain→delete without fresh H-003、`ls-remote` only、rule/head drift/new push blocked |
| B-030 | H-004 mutually exclusive decision + issue acceptance binding | decision-gate fixtures：strict-four allowed；preserve only with matching immutable issue node/digest allowed；missing/double/unsynced/re-witness-missing blocked |
| B-031 | live-source decision record/attestation + task binding | `bash tests/test_gh701_decision_gate.sh`；current protected run + latest generation 对 eligible descendant HEAD/digests allowed，source edit/delete/revoke/newer selection、offline preview、self-filled/stale/cached/wrong-spec records blocked |
| B-032 | protected read-only maintainer evidence collector | host-proof harness 验证 separate runtime/witness artifacts、trusted workflow attestation、node/event/head/time/proof-SHA binding；current-run source edit/delete/revoke/supersede recheck 与 generation binding；embedded、cached 或 implementer-filled witness blocked |
| B-033 | closed primary fix fallback | `cargo test --manifest-path vibeguard-runtime/Cargo.toml`：missing fix 生成 fresh fallback ID；4097-byte/encode failure 保留 existing fix_id；均保持 bounded block 且无 raw/digest leakage |
| B-034 | ordinary-routing one-time bootstrap tranche | harness 要求完整 B-ID plan、产品 tranche 均 blocked；fixed allowlist/completion fixtures 必须含 supervisor schema/workflow 与 **schemas/public_benchmark_summary.schema.json**，下游 gate 缺 decisions fail closed；host/runtime/setup/README/unlisted/second bootstrap blocked |
| B-035 | approved spec/trust heads + immutable byte/JCS digest inheritance | decision-gate tests：unchanged 3-spec/trust descendant allowed；任一 non-ancestor、product/tech/security-lifecycle byte、JCS/acceptance/protocol/branch/trust drift 全部 needs-human；protected-main exact trust rotation 单次 allowed，self-issued/wildcard/stale/replay blocked |

## 数据流

1. 维护者先在 GitHub review 明确批准三份 normative specs；coordinator 完成 ordinary
   `plan_first` handoff 与 live duplicate-work search，生成完整 tasks 后只执行
   `bootstrap_once` allowlist PR。该 PR 经 CI、independent human review/merge 到
   main 后，受保护 collector 才能取得 H-001–H-004 decisions；可选 SpecRail
   packet/evaluator 不参与授权。
2. 当前 protected CI run 重查 live decision source；offline gate 验证 attestation、
   generation/revocation、spec/trust ancestry、三份 spec bytes 与 JCS input digest；
   CI allowed 后 lifecycle 才读取 selection/manifest v2，只读 discover 并生成绑定 base digest 的 exact plan。
3. plan 按 registry 选择 versioned CAS+lease transaction 或零 mutation 的 verified-file
   exact diff；后者仅在用户应用、probe 前后 bytes/metadata、held target+parent identities
   与 completed tuple/exclusion receipt 均匹配才产出 proof evidence，drift 均 partial。
4. host 发送 native event；decoder 校验 host/protocol/version，产生带 batch/request
   correlation 的 ordered canonical request Vec。
5. core 按 index 独立判定每个 request 并逐项写 sanitized log；执行失败先变成
   fail-closed `hook_error`，aggregator 再按固定 priority 选 primary、保留所有
   blocks、合并有界 fixes。
6. credential-free candidate 只见 declassified low-side view；protected supervisor 绑定 trusted
   time、confidentiality transcript、outer-VM closure、loader ledger 与 signed journal snapshot，
   封存 exact subjects。signer 重哈希后签名；collector fresh witness，gate 重查 source/revocation
   并与 H-001 closure 对比，绑定 node/event/head/time/proof/supervisor/manifest digests。
7. README-claim gate 读取 GH-699 tracked install evidence，并直接读取 GH-700 已
   committed Release 的验签 `public_benchmark_summary`、reports 与 publish intent；
   renderer 同时消费 approved H-004：strict 模式形成恰好四块，preserve 模式只加入
   issue acceptance 明确批准的额外块。

## 备选方案

- 为 proof host 复制 `run-hook-codex.sh` 与 core classification：拒绝。这样只能
  证明第三份 fork，不证明 adapter seam，并会造成 policy/privacy 漂移。
- 直接在现有 manifest 每个 hook 增加第三个固定字段：拒绝。下一 host 仍需 schema、
  reader、validator 与 docs 的横向改造，无法形成 registry contract。
- 让 decoder 只返回一个 canonical request：拒绝。Codex apply-patch 与第三 host
  multi-file event 会丢请求，无法定义 mixed decision 或多个 block 的证据。
- “最后一个 decision 胜出”或只记录 primary block：拒绝。输入排序会改变安全结果，
  secondary blocks/fixes 无法审计。
- 用 generic shell command adapter 接任何未知 host：拒绝。无法证明 protocol、
  blocking semantics、config ownership 与 caller identity，会把 unsupported
  伪装成 native。
- 用 temp+rename 但没有 lock/journal/probe：拒绝。单文件原子替换不能处理
  plan/apply TOCTOU、多文件 partial commit 或 crash recovery。
- 由 README 手工复制 GH-699/GH-700 命令/数字：拒绝。source evidence 与 rendered
  claim 会漂移，必须由单一 validator 重算。
- 要求 H-001–H-004 decision gate 先批准自身 bootstrap：拒绝。collector/workflow
  尚未在 main 时无法产生可信 attestation；bootstrap 只能由 ordinary
  `plan_first` handoff、维护者 GitHub 完整 spec-set review、live duplicate-work
  search、CI、PR review 与 merge gates 授权，并受固定 allowlist 限制。可选
  SpecRail 输出既不需要也不授权该 tranche。
- 只把 decision 绑定 PR head 或要求所有后续 HEAD exact-equal：拒绝。squash merge
  可能让 PR head 不在 main ancestry，而 exact-equal 又会阻止 tasks/code commits；
  default-branch approved spec head + exact spec byte/JCS digests 同时保留可继承性与
  decision-sensitive fail-closed。

## 风险

- Security：host payload 可能含 prompt、源码、命令与 token；candidate-independent high-side
  declassification boundary 是保密权威，sentinel 仅 diagnostic。高上下文 config 写入需要
  人工确认、ordered lock、digest-safe rollback；proof 记录 only digests/closed
  summaries，不记录 raw payload。
- Compatibility：manifest v2/registry 可能破坏 Claude/Codex config generation；
  v1 normalized compatibility view、deprecation warning 与 v1/v2 golden outputs
  必须先落地，GH-701 不删除 v1 reader。
- Performance：adapter 不得新增网络 I/O 或第二次 core evaluation；protocol
  decode/encode、N request evaluation 与 bounded probe 必须有 batch-size/timeout/
  latency limits 和 evidence。
- Maintenance：若 lifecycle、capability 或 decoder 继续按 host 散落，seam 会
  退化；registry/common traits 是单一 ownership，host 文件只含协议差异。
- Release coordination：README 最终形态跨 GH-699/GH-700；缺任一 released
  evidence、H-004 approval 或 validator mismatch 时保持窄而真实的 partial
  baseline；不得从 README 现状猜测 strict/preserve mode。
- Recovery：external writer 在 apply 后改 config 时禁止 automatic/stale manual
  rollback；保留外部内容与 receipt/digests 并 needs_human，不覆盖新更改。
- Branch ownership：stale branch 只能 approved delete，或 owner+expiry 且 active
  exact-target/no-bypass update+delete restrictions；protected API live check 失败即停止。
- Evidence authority：candidate 只在无 GitHub/OIDC/artifact token 的隔离 VM 执行；独立
  job 不执行 candidate，只在重哈希 authenticated subject blobs 后签名；drift fail closed。
- Bootstrap authority：bootstrap 是一次性最小 control-plane tranche，不是
  H-001–H-004 的隐式批准。base gate evidence、allowlist、main-existence sentinel
  或 human review 任一缺失均停止；bootstrap 不得顺带实现产品面。
- Decision inheritance：普通 descendant code commit 应可复用批准，但 spec/JCS
  byte drift 必须重批。只检查 ancestry 会放过语义漂移，只检查 exact HEAD 会造成
  永久阻塞，二者必须与三个 digest 联合。
- Trust rotation：永久禁止第二次 bootstrap 仍需允许修补 collector/gate；只有
  protected-main collector 对 exact candidate/path/digests/expiry 签发的一次性
  rotation 可以打破旧 byte equality，candidate 自授权或 replay 必须 fail closed。

## 测试计划

- [ ] Unit tests：v2 registry constraints、v1 compatibility、complete unknown
  matrix、batch empty/single/multi、64/65/unknown-count pre-evaluation boundary、
  hook-error/complete-inclusive pairwise decision priority、failed/hook_error
  normalization、enforcement suppress correction、multi-block、correlation/fix cap、
  oversize primary closed fallback、
  malformed/privacy 与 encode failure。
- [ ] Lifecycle tests：全 phase、lock/deadlock、versioned CAS/lease 与 crash rollback；verified-file
  覆盖 same-user mirror/IPC forgery、failed/publication abort verified reverse+retire、
  `rollback_required: false` retirement rejection、consume crash、N/N+1 CAS、present/absent、
  H-001 provider/transition/caller-auth/journal/publish/abort/use 与 owner-death negatives。
- [ ] Evidence tests：README-claim schema/gate 的 protected producer attestation、
  GH-699 exact producer SHA/argv，以及 GH-700 committed Release summary/report/
  publish-intent binding 与 standalone rerun/draft/unsigned/wrong-workflow matrices；
  H-004 strict/preserve/unsynced issue matrix；decision source edit/delete/revoke/
  newer-generation matrix；separate host-proof/witness 的 H-001 provenance/head/
  source/config matrix；H-001-pinned high-side identity/policy/output schema 与 split/encoded/hashed/cross-sink leakage；
  execution VM credential absence、job separation、signing job no-candidate-code、
  authenticated subject blobs/manifest/re-hash，以及 missing/extra/substituted blob、
  trusted clock source/mapping drift、trusted-time skew/replay、lifecycle provider/policy/journal-root drift、D-state outer-VM teardown、broker escape/late output、
  inbound/outbound write、private-COW exec/self-signed relocation/page mismatch、trace gap/load-unload、
  preload/DYLD/plugin/unknown image/JIT negatives；所有
  negative fixtures 先通过 schema 再被 semantic gate 拒绝。
- [ ] Bootstrap tests：ordinary `plan_first` handoff、维护者 GitHub spec approval +
  live duplicate evidence、完整 tasks coverage、固定 diff allowlist、candidate
  gate 自授权拒绝、pinned public-benchmark schema 与 completion fixture、可选工具无
  授权能力、main merge 前 collector untrusted、sentinel 后 second bootstrap 拒绝，
  以及普通 tasks 全部等待 decisions。
- [ ] Head-binding tests：approved default-branch spec head 的 unchanged descendant
  allowed；squashed/non-ancestor PR head、三份 normative spec 单 byte、JCS key/value、
  issue snapshot、release/protocol、branch head 与 workflow trust drift 全部要求
  fresh maintainer collection；exact protected-main rotation 单次 allowed，
  self-issued/wildcard/stale/replayed rotation 全部 blocked。
- [ ] Real host acceptance：获批 released CLI/session 的 native multi-request
  blocking event 与 fresh-home journey；模拟、direct wrapper/runtime/demo 不能
  生成 proof kind 或替代 maintainer witness。
- [ ] Full focused verification：`cargo fmt --manifest-path vibeguard-runtime/Cargo.toml -- --check`；`cargo check --manifest-path vibeguard-runtime/Cargo.toml`；`cargo test --manifest-path vibeguard-runtime/Cargo.toml`；
  `bash scripts/ci/validate-hooks.sh`；`bash scripts/ci/validate-hooks-manifest.sh`；`bash tests/test_manifest_contract.sh`；`bash tests/test_setup.sh`；
  `bash tests/test_codex_runtime.sh`；`bash tests/test_behavior_eval.sh`；`bash scripts/ci/validate-doc-paths.sh`；`bash scripts/ci/validate-doc-command-paths.sh`；
  `bash scripts/local-contract-check.sh --quick`；`git diff --check`。

## 回滚方案

bootstrap 尚未 merge 时直接关闭该 PR，不产生 H decision 或产品状态；已 merge
但尚未收集 decisions 时，若必须回滚 collector/gate/workflow，后续所有普通
tasks 保持 blocked，不回退为旧的无 gate implement route。已有 decision 后移除或
更改 bootstrap trust surfaces 会使 collector identity/JCS digest 失效，必须先
撤销 decision allowed 状态，再经新的完整 spec-set human approval 设计替代
bootstrap；不能用旧 attestation 授权新 gate。

回滚前必须对 rollback target HEAD 重新运行 decision gate，并读取获批 H-004；
不得默认使用本 spec 推荐的 `strict_four`。`strict_four` 回滚保持 PR #705 的
positioning/demo 两个首屏块并把其余 partial-baseline 内容留在首屏之后；
`preserve_pr705_extras` 回滚还必须保留其绑定 issue acceptance 明确列出的额外块。
H-004 缺失、过期或与 target HEAD/acceptance digest 不匹配时停止为
`needs_human`，不得猜测布局或重写 README。两种模式都保留 v1 Claude/Codex read
compatibility。proof host 出现问题时，versioned lifecycle 自动移除 owned config；
verified-file lifecycle 只在 candidate/receipt 匹配时输出 user-applied reverse，base 重验后 check/doctor 才显示 `unsupported/not_installed`；不得自动写或删除第三方配置。若 v2 reader 影响 Claude/Codex，
恢复 v1 input normalization + golden config，但 writer 继续停止生成损坏的 v2，
并保留 privacy、journal/digest-safe rollback 与 truthful unknown matrix。

GH-699/GH-700 任一 evidence/gate 失败时只移除对应 README generated block，不
删除仍有效的另一块或 approved H-004 要求保留的 PR #705 块；禁止恢复手写 claim。
third-host proof 或独立 maintainer witness/attestation 失效时撤销 active/完成声明，
不伪造刷新 timestamp。回滚 stale branch decision 也只能在 approved `deleted` 与
带 active no-bypass update+delete ruleset 的 `readonly_retain(owner, expiry)` 间重批，不能恢复可写 branch。
