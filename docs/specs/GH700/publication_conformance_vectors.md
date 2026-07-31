# GH700 Publication Conformance Vectors

本文件是 [publication_history_contract.md](publication_history_contract.md) 与
[publication_ledger_contract.md](publication_ledger_contract.md) 的规范性组成部分，唯一拥有两个互不重叠的
closed registries：下列十三项 hand-authored named vectors，以及本节定义的 43 项 schema-complete generated
corpus（39 history kinds + 4 blocked-attempt kinds各恰一项）。fixture path是实现阶段必须创建的 canonical
path；本 Draft冻结生成规则/object/bytes/digest/oracle，不宣称文件或 runner已实现。调用方不得维护第三份
kind list、fixture object、mutation list、alias或 digest；新增、删除、改名或改变任一 bytes必须更新本
contract并重算 manifest，缺项、重复、unknown case或 digest drift均 fail closed。

除 `frontier_valid_v1` 外，fixture object exact schema为
`{case_id,expected,input,oracle,schema_version}`，`schema_version` exact 为
`GH700:publication-conformance-vector:v1`，`expected` exact 为 `accept`。以下单行 code span是 UTF-8、无 BOM、
无 trailing newline的 exact JCS bytes；digest是这些 bytes的 lowercase SHA-256，path相对 repository root。
runner须先核对 bytes digest，再执行 positive object与 `oracle.reject`列出的每个独立 mutation；缺 fixture、
digest不符、未执行 reject mutation或多余/unknown case均 fail closed。

## Schema-complete generated corpus

canonical schema source固定为 planned **schemas/publication_history.schema.json** 与
**schemas/blocked_attempt_ledger.schema.json**。每个 discriminator branch必须恰有一个
`x-gh700-conformance-positive-v1` annotation，其值是该 branch完整、schema-valid top-level record；
annotation不是 runtime record字段。history branch count必须 exact 39，按 discriminator ASCII升序后的
JCS string array digest必须 exact
`sha256:09a723fbc8526bcf7f29b91bf98fa607118362b5e1ffa7712c048e6857b35028`；blocked-attempt count
必须 exact 4且对应 digest exact
`sha256:a5c16a69ec07d3a21313c8035ee529f5d8d171eda1f487910edd2bc103be19ac`。count/set digest、
discriminator或 annotation不匹配时须在生成任何 case前失败。

planned **scripts/ci/validate_public_benchmark.py** 的
`--materialize-publication-conformance`模式须确定性生成：

- **tests/fixtures/public_benchmark/publication/generated/history/\<record_kind\>.json**；
- **tests/fixtures/public_benchmark/publication/generated/blocked_attempt/\<attempt_record_kind\>.json**；
- **tests/fixtures/public_benchmark/publication/generated/manifest.json**。

每个 per-kind file exact JCS object为
`{schema_version,case_id,domain,discriminator,expected,input,oracle}`；schema version exact
`GH700:publication-schema-vector:v1`，expected exact `accept`，input byte-equal branch annotation，
case ID为 `history_record_<record_kind>_v1`或
`blocked_attempt_record_<attempt_record_kind>_v1`，`domain` exact 为
`{history,blocked-attempt}`。文件 UTF-8、无 BOM、无 trailing newline。blocked-attempt input是 root ledger
contract的 attempt-record body；计算 frontier leaf前须包入其 exact `attempt_record` ledger envelope。

`oracle` exact 为 `{reject:[descriptor...]}`；descriptor exact closed union为
`{mutation_kind:"unknown_discriminator",json_pointer}`、
`{mutation_kind:"alias_discriminator",json_pointer,alias}`、
`{mutation_kind:"missing_required",json_pointer}`、
`{mutation_kind:"extra_member",json_pointer}`、
`{mutation_kind:"null_nonnullable",json_pointer}`或
`{mutation_kind:"unknown_enum_or_const",json_pointer}`，alias exact 为 `{kind,type,record_type}`。
`json_pointer`使用 RFC 6901 canonical encoding。unknown mutation把目标值替换 `"__unknown__"`；alias删除
discriminator并以同值插入 alias；missing删除 member；extra在目标 object插入
`"__unexpected__":true`；null替换为 null，除此之外 bytes不变。generator递归枚举 positive object及
resolved schema，descriptor按 `(mutation_kind,json_pointer,alias_or_empty)` ASCII升序，且每个 candidate
必须由 schema独立验证为 reject，否则生成失败。

generated manifest exact 为
`{schema_version,history_schema_digest,blocked_attempt_schema_digest,history_kind_count,
history_kind_set_digest,blocked_attempt_kind_count,blocked_attempt_kind_set_digest,cases,cases_digest}`；
schema version exact `GH700:publication-schema-corpus-manifest:v1`；
cases先 history后 blocked-attempt，各自按 discriminator ASCII升序，每项 exact 为
`{case_id,domain,discriminator,path,jcs_sha256,reject_set_digest,leaf_hash,successor_root,
successor_full_prefix_digest}`。`history_schema_digest`与`blocked_attempt_schema_digest`分别为 parsed schema
object的 JCS SHA-256；`jcs_sha256`为 exact per-kind file bytes SHA-256；
`reject_set_digest=SHA256(JCS(oracle.reject))`；`cases_digest=SHA256(JCS(cases))`；所有 digest编码 lowercase
`sha256:<64hex>`。leaf/root/full-prefix从
`repo_node_id="R_kgDOGH700"`的对应 length-zero frontier按 root framing独立重算；这是 schema/framing
golden，不表示每个 kind都可直接从 genesis发生。

Rust与 Python消费者必须分别从 schema+annotation生成 byte-identical corpus/manifest；shell harness核对
checked-in bytes、逐文件 SHA-256、reject-set/cases digest及两端输出。只读 checked-in结果而不重算，
或调用方手写 kind/payload副本，不算通过。

## Reconciliation watermark ledger leaf

### `reconciliation_watermark_leaf_v1`

- Planned canonical path: **tests/fixtures/public_benchmark/publication/reconciliation_watermark_leaf_v1.json**
- Exact fixture object/JCS bytes: `{"case_id":"reconciliation_watermark_leaf_v1","expected":"accept","input":{"ledger_leaf_kind":"reconciliation_watermark","predecessor_bound":true,"proof_digest_bound":true,"reconciliation_key_set":"exact","watermark_in_frontier":true},"oracle":{"reject":["direct_watermark_append","leaf_kind_alias","missing_predecessor","extra_leaf_member","null_leaf_member","proof_digest_substitution","missing_reconciliation","extra_reconciliation","duplicate_reconciliation","watermark_not_in_frontier"]},"schema_version":"GH700:publication-conformance-vector:v1"}`
- SHA-256: `73c638879255334cfb11aebaeb0cca37125f15870384961cd7b77e75ccf3bc8c`
- Oracle: exact watermark ledger envelope、predecessor/proof binding、proof key与 reconciliation key双向集合一致并进入
  frontier successor时 accept；十项 bypass/alias/missing/extra/null/substitution/set mismatch逐项 reject。

## Frontier

### `frontier_valid_v1`

- Planned canonical path: **tests/fixtures/public_benchmark/publication/frontier_valid_v1.json**
- Exact fixture object/JCS bytes: `{"full_prefix_digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","history_length":7,"history_root":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","repo_node_id":"R_kgDOGH700"}`
- SHA-256: `e52c3472ae93b565704e4f26a97f02260e7c9d2c724b8add3350a7f7317edf73`
- Oracle: accept exact frontier；分别加入 discriminator/frontier/mutation alias、missing/extra/null field时 reject。

## History recovery-blocked union

### `blocked_record_kinds_valid_v1`

- Planned canonical path: **tests/fixtures/public_benchmark/publication/blocked_record_kinds_valid_v1.json**
- Exact fixture object/JCS bytes: `{"case_id":"blocked_record_kinds_valid_v1","expected":"accept","input":{"record_kinds":["release_mutation_recovery_blocked","draft_recovery_blocked","decurrent_pr_recovery_blocked","rollback_recovery_blocked","marker_recovery_blocked","nonvalid_row_recovery_blocked","invalidation_recovery_blocked","release_recovery_blocked"]},"oracle":{"reject":["unknown_kind","kind_alias","inapplicable_blocked_reason_code"]},"schema_version":"GH700:publication-conformance-vector:v1"}`
- SHA-256: `2128b7c3828211cc0a3b46b42174fe59c2420936fa24e9554ad57d13592e91ab`
- Oracle: exact八种 blocked records与各自 applicable reason subset accept；三个 listed mutation逐项 reject。

## Mutation secret boundary

六项 fixture的 `capsule:"opaque"`表示只有 opaque capsule identifier可过历史边界，不是 raw secret；runner必须
用真实 typed test values替换占位 digest并保持字段关系，然后逐项执行八个 reject mutation。

### `mutation_secret_boundary_draft_create_v1`

- Planned canonical path: **tests/fixtures/public_benchmark/publication/mutation_secret_boundary_draft_create_v1.json**
- Exact fixture object/JCS bytes: `{"case_id":"mutation_secret_boundary_draft_create_v1","expected":"accept","input":{"capsule":"opaque","delivery_count":1,"effective_request_digest":"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","mutation_kind":"draft_create","mutation_nonce_digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111","request_template_digest":"sha256:2222222222222222222222222222222222222222222222222222222222222222"},"oracle":{"reject":["raw_nonce","reversible_nonce","secret_request_bytes","wrong_placeholder_count","capsule_substitution","slot_substitution","operation_substitution","second_send"]},"schema_version":"GH700:publication-conformance-vector:v1"}`
- SHA-256: `9a6c645ca850a0602ca1e725ae7984f7409bc3e4e38cb0d4e981dbcef2b15b39`

### `mutation_secret_boundary_draft_update_v1`

- Planned canonical path: **tests/fixtures/public_benchmark/publication/mutation_secret_boundary_draft_update_v1.json**
- Exact fixture object/JCS bytes: `{"case_id":"mutation_secret_boundary_draft_update_v1","expected":"accept","input":{"capsule":"opaque","delivery_count":1,"effective_request_digest":"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","mutation_kind":"draft_update","mutation_nonce_digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111","request_template_digest":"sha256:2222222222222222222222222222222222222222222222222222222222222222"},"oracle":{"reject":["raw_nonce","reversible_nonce","secret_request_bytes","wrong_placeholder_count","capsule_substitution","slot_substitution","operation_substitution","second_send"]},"schema_version":"GH700:publication-conformance-vector:v1"}`
- SHA-256: `9f5e227d3b4fddfb0dcda95ca349874550b8f73a1d832f6cf2f7c79080e4667e`

### `mutation_secret_boundary_draft_delete_v1`

- Planned canonical path: **tests/fixtures/public_benchmark/publication/mutation_secret_boundary_draft_delete_v1.json**
- Exact fixture object/JCS bytes: `{"case_id":"mutation_secret_boundary_draft_delete_v1","expected":"accept","input":{"capsule":"opaque","delivery_count":1,"effective_request_digest":"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","mutation_kind":"draft_delete","mutation_nonce_digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111","request_template_digest":"sha256:2222222222222222222222222222222222222222222222222222222222222222"},"oracle":{"reject":["raw_nonce","reversible_nonce","secret_request_bytes","wrong_placeholder_count","capsule_substitution","slot_substitution","operation_substitution","second_send"]},"schema_version":"GH700:publication-conformance-vector:v1"}`
- SHA-256: `f51503b86ce029747e80067fc43fd113abe1e60ea827149769f229a61c831229`

### `mutation_secret_boundary_asset_upload_v1`

- Planned canonical path: **tests/fixtures/public_benchmark/publication/mutation_secret_boundary_asset_upload_v1.json**
- Exact fixture object/JCS bytes: `{"case_id":"mutation_secret_boundary_asset_upload_v1","expected":"accept","input":{"capsule":"opaque","delivery_count":1,"effective_request_digest":"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","mutation_kind":"asset_upload","mutation_nonce_digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111","request_template_digest":"sha256:2222222222222222222222222222222222222222222222222222222222222222"},"oracle":{"reject":["raw_nonce","reversible_nonce","secret_request_bytes","wrong_placeholder_count","capsule_substitution","slot_substitution","operation_substitution","second_send"]},"schema_version":"GH700:publication-conformance-vector:v1"}`
- SHA-256: `caae009141712fcd3fb6a35d825a90b4807d1a6ca7bf064f9a96fff931b029d5`

### `mutation_secret_boundary_asset_delete_v1`

- Planned canonical path: **tests/fixtures/public_benchmark/publication/mutation_secret_boundary_asset_delete_v1.json**
- Exact fixture object/JCS bytes: `{"case_id":"mutation_secret_boundary_asset_delete_v1","expected":"accept","input":{"capsule":"opaque","delivery_count":1,"effective_request_digest":"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","mutation_kind":"asset_delete","mutation_nonce_digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111","request_template_digest":"sha256:2222222222222222222222222222222222222222222222222222222222222222"},"oracle":{"reject":["raw_nonce","reversible_nonce","secret_request_bytes","wrong_placeholder_count","capsule_substitution","slot_substitution","operation_substitution","second_send"]},"schema_version":"GH700:publication-conformance-vector:v1"}`
- SHA-256: `0721f79b916c137658b66b05fa90ed5e42e66901def4f67e193c4d142e89461f`

### `mutation_secret_boundary_publish_v1`

- Planned canonical path: **tests/fixtures/public_benchmark/publication/mutation_secret_boundary_publish_v1.json**
- Exact fixture object/JCS bytes: `{"case_id":"mutation_secret_boundary_publish_v1","expected":"accept","input":{"capsule":"opaque","delivery_count":1,"effective_request_digest":"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","mutation_kind":"publish","mutation_nonce_digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111","request_template_digest":"sha256:2222222222222222222222222222222222222222222222222222222222222222"},"oracle":{"reject":["raw_nonce","reversible_nonce","secret_request_bytes","wrong_placeholder_count","capsule_substitution","slot_substitution","operation_substitution","second_send"]},"schema_version":"GH700:publication-conformance-vector:v1"}`
- SHA-256: `d77a5b30daba827e08cbaceeadb3ca98a98762cbb244bd2e15fbd6c5f036f73f`

每个 mutation fixture的 positive oracle要求 exact kind、single delivery、opaque capsule、nonce/template/effective
digest三者各自验证；`oracle.reject`八项必须各生成一个 only-one-change negative case并全部 reject。

## Generated-PR delivery identity

### `generated_pr_delivery_send_once_v1`

- Planned canonical path: **tests/fixtures/public_benchmark/publication/generated_pr_delivery_send_once_v1.json**
- Exact fixture object/JCS bytes: `{"case_id":"generated_pr_delivery_send_once_v1","expected":"accept","input":{"generated_pr_delivery_id":"sha256:b27a6fdf4475889d6ca3ea8ea6756938a01f577001d11019674fa931dcec9817","planned_operation_id":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","repo_node_id":"R_kgDOGH700","send_count":1},"oracle":{"reject":["client_selected_delivery_id","delivery_id_substitution","planned_operation_substitution","same_plan_different_delivery","same_delivery_different_plan","second_send","takeover_new_delivery","send_after_uncertain"]},"schema_version":"GH700:publication-conformance-vector:v1"}`
- SHA-256: `efd60a7e1e20e214b30d7c33af52c2a5e09f39daaf343cf9ad062290894350b2`
- Oracle: root derivation重算 exact ID且第一次 send accept；八项 mutation逐项 reject。

## Trusted-time authority ownership

### `trusted_time_authority_owned_v1`

- Planned canonical path: **tests/fixtures/public_benchmark/publication/trusted_time_authority_owned_v1.json**
- Exact fixture object/JCS bytes: `{"case_id":"trusted_time_authority_owned_v1","expected":"accept","input":{"allowed_methods":["claim_publication_owner","renew_publication_owner","takeover_publication_owner"],"append_time_kinds":"rejected","client_supplied_time_fields":[],"preparation_states":["prepared","proof_frozen","transition_committed","anchor_confirmed"]},"oracle":{"reject":["client_proof_request","client_tsa_token","client_time_bounds","client_high_water","client_final_intent","generic_append_time_kind","second_nonce_after_crash","second_proof_after_freeze","committed_same_op_stale"]},"schema_version":"GH700:publication-conformance-vector:v1"}`
- SHA-256: `aed5508b165e7bf1c3412324d477d60e844fb0ca3c09c25383e158eb0151b817`
- Oracle: 三个专用 method与单调 durable preparation accept；九项 authority-bypass/crash/retry mutation逐项 reject。

## Post-invalidation suffix

### `post_invalidation_suffix_no_draft_v1`

- Planned canonical path: **tests/fixtures/public_benchmark/publication/post_invalidation_suffix_no_draft_v1.json**
- Exact fixture object/JCS bytes: `{"case_id":"post_invalidation_suffix_no_draft_v1","expected":"accept","input":{"candidate_identity":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","cleanup":{"broker_quiescence":true,"cleanup_kind":"draft_never_existed","draft_create_slots":"closed_not_applied","exhaustive_negative_discovery":true},"suffix_terminal_kind":"publication_terminal_no_publication"},"oracle":{"reject":["missing_cleanup","unknown_cleanup_kind","bound_draft","recovered_draft","publish_intent","public_release","pending_slot","blocked_slot","in_flight_slot"]},"schema_version":"GH700:publication-conformance-vector:v1"}`
- SHA-256: `0a83abafd9e073d83c5d875129bfe02bcbc5e456f959f629cabf93cde2e8c21a`
- Oracle: exact no-draft terminal suffix accept；九项 mutation逐项 reject。

### `post_invalidation_suffix_draft_deleted_v1`

- Planned canonical path: **tests/fixtures/public_benchmark/publication/post_invalidation_suffix_draft_deleted_v1.json**
- Exact fixture object/JCS bytes: `{"case_id":"post_invalidation_suffix_draft_deleted_v1","expected":"accept","input":{"candidate_identity":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","cleanup":{"broker_quiescence":true,"cleanup_kind":"draft_deleted","delete_or_compensation":"closed","draft_identity_digest":"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","post_delete_absence":true,"preimage_digest":"sha256:3333333333333333333333333333333333333333333333333333333333333333"},"suffix_terminal_kind":"publication_terminal_no_publication"},"oracle":{"reject":["missing_cleanup","forged_deletion","unclosed_deletion","wrong_draft","no_actual_draft"]},"schema_version":"GH700:publication-conformance-vector:v1"}`
- SHA-256: `1245344b00d4ae58b608e10cc106e0839ef26ceae45a40cf7aee674d256cca86`
- Oracle: exact bound/recovered draft的 closed delete/compensation suffix accept；五项 mutation逐项 reject。

除上述 43 个 normative schema cases与 named fixture negative mutations外，runner还须从 root contract生成获验签的 phase-neutral governance
record与 same-candidate takeover正例，并拒绝 forged/nonterminal/cross-candidate takeover、wrong governance
evidence、owner/phase/liveness mutation、current restoration、其它 owner及 unknown record；这些是 generated
behavioral cases，不得再命名为 hand-authored registry fixture。
