# GH700 Publication Conformance Vectors

本文件是 [publication_history_contract.md](publication_history_contract.md)、
[publication_ledger_contract.md](publication_ledger_contract.md) 与
[publication_authority_protocol_contract.md](publication_authority_protocol_contract.md) 的规范性组成部分，唯一拥有两个互不重叠的
closed registries：下列十五项 hand-authored named vectors，以及本节定义的 43 项 schema-complete generated
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
`{mutation_kind:"null_nonnullable",json_pointer}`、
`{mutation_kind:"unknown_enum_or_const",json_pointer}`或
`{mutation_kind:"inapplicable_value",json_pointer,value}`，alias exact 为 `{kind,type,record_type}`。
`json_pointer`使用 RFC 6901 canonical encoding。unknown mutation把目标值替换 `"__unknown__"`；alias删除
discriminator并以同值插入 alias；missing删除 member；extra在目标 object插入
`"__unexpected__":true`；null替换为 null，除此之外 bytes不变。generator递归枚举 positive object及
resolved root schema。对 positive instance中每个 scalar或 array-element pointer，汇集 root各 alternative在
同一 pointer由 `const`/`enum`、各 branch的 `x-gh700-conformance-positive-v1` canonical example或显式
`x-gh700-inapplicable-values-v1`声明的全部 canonical JSON values，按 `JCS(value)` UTF-8 bytes去重升序；
除 current value外逐个 only-one-change替换，完整 root schema仍 accept的跳过，每个 reject value都生成
`inapplicable_value`。descriptor按
`(mutation_kind,json_pointer,alias_or_empty,value_jcs_or_empty)` UTF-8 bytes升序，非 applicability descriptor
的最后一项为 empty bytes；任一有限 reject alternative漏发或任一 candidate不被 schema独立 reject都使生成失败。

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

## Backup KMS context

### `backup_kms_context_v1`

- Planned canonical path: **tests/fixtures/public_benchmark/publication/backup_kms_context_v1.json**
- Exact fixture object/JCS bytes: `{"case_id":"backup_kms_context_v1","expected":"accept","input":{"kms_context":{"authority_id":"authority-gh700","backup_id":"backup-0001","object_kind":"snapshot","prior_anchor_digest":"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","repo_node_id":"R_kgDOGH700","schema_version":"GH700:backup-data-key-context:v1","successor_frontiers_digest":"sha256:e4b3a58ab2aaca9acbd7421819eccbc9dfe3154f1b2b52485348f748d1a8bb5c"},"successor_frontiers_preimage":{"frontiers":[{"frontier":{"full_prefix_digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","history_length":7,"history_root":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","repo_node_id":"R_kgDOGH700"},"frontier_kind":"publication_history"},{"frontier":{"full_prefix_digest":"sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff","ledger_length":5,"ledger_root":"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","repo_node_id":"R_kgDOGH700"},"frontier_kind":"blocked_attempt_ledger"}],"v":"GH700:successor-frontiers:v1"}},"oracle":{"reject":["frontier_order_swap","frontier_kind_alias","missing_frontier_field","extra_frontier_field","successor_frontiers_digest_mismatch","raw_frontiers_in_kms_context","missing_kms_context_field","extra_kms_context_field","unknown_object_kind"]},"schema_version":"GH700:publication-conformance-vector:v1"}`
- SHA-256: `c5ca93ad26cc5c863c2bceeb1b585e36f9c44e416ed1bf3ab718f8a80cce8480`
- Oracle: ordered preimage的两种 exact frontier、其 JCS digest与 exact KMS context accept；九项 order/kind/
  field/digest/context/object-kind mutation逐项 reject。fixture的 frontier preimage digest必须 exact
  `sha256:e4b3a58ab2aaca9acbd7421819eccbc9dfe3154f1b2b52485348f748d1a8bb5c`。

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

## Effective request digest

### `release_effective_request_digest_v1`

- Planned canonical path: **tests/fixtures/public_benchmark/publication/release_effective_request_digest_v1.json**
- Exact fixture object/JCS bytes: `{"case_id":"release_effective_request_digest_v1","expected":"accept","input":{"authorization_context":{"app_node_id":"A_kgDOGH700","credential_kind":"github_app_installation_token_v1","expires_at_unix_seconds":1700003600,"installation_id":700,"issued_at_unix_seconds":1700000000,"issuer_identity_digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111","permission_scopes":["contents:write"],"repository_node_id":"R_kgDOGH700","token_key_id":"test-key-v1","v":"GH700:release-authorization-context:v1"},"body_bytes_b64u":"eyJkcmFmdCI6dHJ1ZSwidGFnX25hbWUiOiJ2MS4wLjAifQ","effective_header_block":[{"name":"authorization","value_b64u":"QmVhcmVyIHRlc3QtdG9rZW4"},{"name":"x-vibeguard-draft-claim","value_b64u":"dGVzdC1kcmFmdC1jbGFpbQ"},{"name":"x-vibeguard-mutation-nonce","value_b64u":"dGVzdC1tdXRhdGlvbi1ub25jZQ"}],"release_effective_request":{"authorization_context_digest":"sha256:f685a8e80c03c7d2e5f9a2cc0eb583831005f9a50c3332f45a41e9d2df4e9024","body_bytes_digest":"sha256:bfad1194117b9952b56beeedd55e65caaed3787bae3b527cca876561e67902bc","body_encoding":"jcs_json_v1","body_length":34,"broker_delivery_id":"sha256:4444444444444444444444444444444444444444444444444444444444444444","effective_header_block_digest":"sha256:d1dad20349b99dac5499ac369214f1ca477d5836e0f0cccef34b88b25df1ba0c","endpoint":{"host_ascii":"api.github.com","path_segments":["repos","octo","demo","releases"],"port":443,"query_pairs":[],"scheme":"https"},"method":"POST","mutation_slot_id":"sha256:3333333333333333333333333333333333333333333333333333333333333333","planned_operation_id":"sha256:2222222222222222222222222222222222222222222222222222222222222222","repo_node_id":"R_kgDOGH700","request_commitment":"sha256:5555555555555555555555555555555555555555555555555555555555555555","request_target_bytes_digest":"sha256:984d8109716a3d7f428b30e76d150be6b04c81f9febed75d9f66c0ef1bb279a9","request_template_digest":"sha256:cbfeb6306e7528b04edd99cbc954ad92f3395588614b2fb610b77b86218addf8","v":"GH700:release-effective-request:v1"},"release_request_template":{"body_encoding":"jcs_json_v1","body_template":{"draft":true,"tag_name":"v1.0.0"},"endpoint":{"host_ascii":"api.github.com","path_segments":["repos","octo","demo","releases"],"port":443,"query_pairs":[],"scheme":"https"},"header_template":[{"name":"authorization","value_parts":[{"part_kind":"literal_utf8","value":"Bearer "},{"part_kind":"secret_placeholder","placeholder_kind":"authorization_credential"}]},{"name":"x-vibeguard-draft-claim","value_parts":[{"part_kind":"secret_placeholder","placeholder_kind":"draft_claim_nonce"}]},{"name":"x-vibeguard-mutation-nonce","value_parts":[{"part_kind":"secret_placeholder","placeholder_kind":"mutation_nonce"}]}],"method":"POST","secret_placeholder_kinds":["authorization_credential","draft_claim_nonce","mutation_nonce"],"v":"GH700:release-request-template:v1"},"request_target_bytes_b64u":"L3JlcG9zL29jdG8vZGVtby9yZWxlYXNlcw"},"oracle":{"effective_request_digest":"sha256:e430629075bbe644ef67529e729ef1733ad6990a5c41d4ec832f976a0f0e8b69","reject":["endpoint_substitution","request_target_encoding_substitution","method_substitution","header_substitution","authorization_substitution","body_substitution","body_length_substitution","template_substitution","plan_substitution"]},"schema_version":"GH700:publication-conformance-vector:v1"}`
- SHA-256: `ef89d0905d5b76ce55d80bd68fb42b88818e67180f9b0a1c71c78b9377c3f2e8`
- Oracle: exact target/template/header/auth/body subdigests及 final effective-request digest重算 accept；九项 only-one-change mutation逐项 reject。fixture中的 secret bytes只是假值测试材料，不是 production secret。

## Generated-PR delivery identity

### `generated_pr_delivery_send_once_v1`

- Planned canonical path: **tests/fixtures/public_benchmark/publication/generated_pr_delivery_send_once_v1.json**
- Exact fixture object/JCS bytes: `{"case_id":"generated_pr_delivery_send_once_v1","expected":"accept","input":{"generated_pr_delivery_id":"sha256:b27a6fdf4475889d6ca3ea8ea6756938a01f577001d11019674fa931dcec9817","planned_operation_id":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","repo_node_id":"R_kgDOGH700","send_count":1},"oracle":{"reject":["client_selected_delivery_id","delivery_id_substitution","planned_operation_substitution","same_plan_different_delivery","same_delivery_different_plan","second_send","takeover_new_delivery","send_after_uncertain"]},"schema_version":"GH700:publication-conformance-vector:v1"}`
- SHA-256: `efd60a7e1e20e214b30d7c33af52c2a5e09f39daaf343cf9ad062290894350b2`
- Oracle: root derivation重算 exact ID且第一次 send accept；八项 mutation逐项 reject。

## Trusted-time authority ownership

### `trusted_time_authority_owned_v1`

- Planned canonical path: **tests/fixtures/public_benchmark/publication/trusted_time_authority_owned_v1.json**
- Exact fixture object/JCS bytes: `{"case_id":"trusted_time_authority_owned_v1","expected":"accept","input":{"allowed_methods":["claim_publication_owner","renew_publication_owner","takeover_publication_owner"],"append_time_kinds":"rejected","claim_preparation_states":["claim_reserved","claim_capsule_frozen"],"client_supplied_time_fields":[],"predecessor_binding":"exact","preparation_states":["prepared","proof_frozen","transition_committed","anchor_confirmed"],"reauthorization_recovery":"same_preparation","time_bound_request_id":"recomputed"},"oracle":{"reject":["client_proof_request","client_tsa_token","client_time_bounds","client_high_water","client_final_intent","generic_append_time_kind","predecessor_mismatch","forged_time_bound_request_id","capsule_before_claim_reserved","second_claim_capsule_after_crash","second_nonce_after_crash","second_proof_after_freeze","second_preparation_after_reauthorization","committed_same_op_stale"]},"schema_version":"GH700:publication-conformance-vector:v1"}`
- SHA-256: `ac92842f496125320bf444d96eb9783e1dc83c3f681048480f51fc1f69731a1f`
- Oracle: 三个专用 method、exact predecessor/request ID、claim pre-nonce durable states与后续单调 preparation accept；
  十四项 authority-bypass/crash/reauthorization/retry mutation逐项 reject。

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
behavioral cases，不得再命名为 hand-authored registry fixture。behavioral generator还须覆盖 takeover/terminal
run-tuple substitution与 same-payload-different-operation、valid claim→invalidate、missing/wrong invalidation
context及 direct non-invalidate PR kind；六种 mutation-secret positive须重算 exact effective-request digest并
逐一拒绝 endpoint/method/header/body/auth/body-length/plan substitution；control API须拒绝 unknown method、
method/body mismatch、extra/null、peer-role交叉、uid-only/wrong executable、same nonce different bytes、
same operation different core、response-loss duplicate mutation、bootstrap twice、stale migrate、
wrong restore kind/backup/anchor及 ready challenge replay；另须拒绝 request-target encoding、secret
cross-location、unsigned/tampered response、wrong response signer/key version、peer-policy/code-sign/
environment-protection mismatch及 approval roster/class/incident substitution。
trust revocation behavioral cases还须逐一拒绝 unknown reason、wrong replacement nullability/class、same key
ID/version/SPKI、quorum或管理域下降、bootstrap-pinned key、inactive/already-revoked key及
compromise/loss伪装 scheduled/superseded reason。
同一 generator还须覆盖 bootstrap-initial-time purpose/subject/RFC3161 fractional `genTime`，并对 durable ceremony逐项
注入 approval/projection/journal-path、event gap/fork/state regression、second nonce/logical request、request-byte substitution、
per-source token replacement、proof ack-loss、consumed replay及 bootstrap ceremony/receipt/manifest cross-digest drift。
trusted-time policy须分别拒绝旧 `max_accuracy_seconds`、缺失/负值/错位 numeric编码的 `maximum_tsa_accuracy_ns`、
quorum preimage删域/extra/source reorder/domain替换/digest mismatch与 missing/invalid/overflow accuracy。
numeric generator须遍历四份 contract schema inventory中的每个 integer scalar，而非只测 execution identity：对 signed safe
边界 `±9007199254740991`及越界±1、u16/u32/u64 的 0/max/max+1、nonzero zero、attestation times、body length、threshold、
key version、durable/SQLite sequence、frontier/epoch/fence/run/slot逐项生成 safe-as-string、unsafe-as-number、fraction、
exponent、`+`、leading zero、`-0`、whitespace、overflow与 decoded-numeric ordering negatives；任何未登记 scalar使生成失败。
secret capsule须覆盖 initial-response ack-loss后新 TLS session read-confirm、original-exporter inequality但 current exporter valid、
same-capsule fresh read audit，并拒绝未认证 replay、source/request/slot/actor substitution、second capsule及 ciphertext/KMS drift。
backup KMS须接受三个 object各自 response ARN/actual `KeyMaterialId`/CiphertextBlob attestation及 nested set digests，拒绝
logical `kms_key_version`、KeyId-as-UUID、missing/malformed/material substitution、Describe/current-material冒充 actual response、
request/context/blob/attestation/set-digest drift；generated-PR nullability与 exhaustive anchor-class negatives继续逐项生成。
这些约束的 unknown/extra/alias/null/applicability reject与所属 contract schema一并生成，不得由 consumer维护本地例外。

## Closed-wire model and mutation matrix

[publication_authority_api.schema.json](publication_authority_api.schema.json) 与
[publication_authority_api.models.json](publication_authority_api.models.json) 是新增的 spec-local machine inputs；
它们不复制到 root `schemas/`，Draft阶段也不生成 runtime code。conformance runner须：

1. 以 Draft 2020-12 meta-schema编译 schema；所有 local `$ref`须存在且不可形成 ref-only cycle；
2. 要求 registry exact 17 client + 5 control、method与 positive model ID分别唯一、无 alias/dangling ref；
3. 按 models文件声明递归展开 `$fixture`，再 shallow-merge patch，逐 method分别用 registry
   `request_ref`/`success_ref`验证 request与success，且 model method/surface byte-equal registry；
4. 对每个正例生成 missing/extra/null/alias/wrong-method/wrong-result、P/B CAS flip、wrong authorization kind/
   authorized method/operation/delivery/frontier/principal、nonce padding/length/character、same nonce different bytes、
   replay principal substitution及 response error/result collision negatives；wrong principal须对四类 authorization
   的每个物化 branch重算 signing/request/response digests后仍被 request-binding语义拒绝；每项都必须 reject；
5. 对 prebootstrap policy/deployment policy cross-branch、terminal/source binding cross-field、genesis sentinel用于
   non-genesis、null prior anchor无 sentinel、capsule key ARN/material/attestation substitution及 takeover run tuple
   substitution分别生成独立 negatives；
6. 对 `x-gh700-digest-dag`验证 node unique、edge endpoint declared且拓扑排序完整；
   `publication_digest_domains.py`须持有每个 node的 exact concrete runtime-domain set，并与 schema完整集合相等；
   每个 node的 added/removed/replaced domain mutation都必须使 verifier失败；client/control request/result/response
   必须额外执行“全局允许但当前 surface 错误”的 contextual-domain mutation，禁止回边、自 digest或未声明 digest source；
7. 对 sole binding matrix执行 missing/duplicate/unknown row、model、profile、relation/operator/path/alias mutation，
   并证明 22 个 operation与 35 个 positive model exact-once；每条 active relation都生成 one-end mutation并拒绝；
8. capsule-bearing model逐个重算 nested GenerateDataKey request/response attestation、manifest binding与 receipt digest，
   ARN、KeyMaterialId、manifest binding任一 substitution均拒绝；delivery state须 exact 映射 receipt kind/nullability；
9. release attestation/proof使用 typed interval，允许等边界，但拒绝倒置及 containment 越界；host-time alias不存在。

spec-local verifier不得把 root `oneOf`验证当成 per-method验证的替代：每个 materialized positive（含同
method的 auxiliary branch model）必须重新查 exact `(surface,method)` registry row，并同时通过该 row的
`request_ref`、`success_ref`与 root schema。Draft 2020-12 `unevaluatedProperties:false`必须传播同一 instance上
`$ref`、`allOf`、成功 `anyOf`/唯一 `oneOf`及选中 `then`/`else`产生的 evaluated-property annotations；未知
semantic validator标记、closed wire extra/alias或 `$ref` sibling遗漏均 fail closed。

`$defs.uint64.x-gh700-semantic-validator=uint64` 是 decimal-string上界的 machine binding：所有物化正例中
每个适用 uint64 instance都须生成 `2^64` overflow mutation，并经同一个 full pair verifier拒绝，禁止仅对
独立 scalar sample调用 helper后宣称 wire coverage。runner还须对每个正例逐一执行 missing、extra、null、
forbidden alias、wrong method/result、same-shape nonce substitution、response error/result collision及 applicable
P/B CAS flip；结构类 mutation必须由 exact request/success schema自身拒绝，禁止用 stale digest失败代替 closure证据。对
`x-gh700-digest-dag.nodes` 每个 node逐一执行 added、removed及replaced runtime-domain mutation，并证明 exact-set验证
fail closed；只替换一个当前允许值不得作为“没有额外允许值”的证据。
最终成功摘要必须分别报告 closed `unevaluatedProperties`、per-relation、matrix closure、contextual domain、nested KMS、
物化 uint64与 digest-node mutation数；任一集合为空、未覆盖全部正例或未覆盖全部 digest node都失败。

九个 review finding cluster与 machine ownership exact 映射如下；architecture omission不得藏入 prose-only例外：

| finding cluster | authoritative machine/protocol location |
| --- | --- |
| `TRUSTED_TIME_SCHEMA`（accuracy + trusted nonce） | history quorum schema、protocol proof profile、bootstrap model |
| `TERMINAL_BINDING_BRANCH` | `$defs/terminal_binding_evidence` / `$defs/source_binding_evidence` |
| `GENESIS_PRIOR_ANCHOR` | genesis sentinel metadata + protocol/history KMS/AAD branch |
| `CAPSULE_KEY_SOURCE` | `$defs/authority_capsule_key_attestation` + `$defs/capsule_receipt` |
| `RELEASE_ATTESTATION_TIME` | prebootstrap control semantic gate |
| `TAKEOVER_RUN_TUPLE` | authority takeover payload core + time-bound positive model |
| `CLIENT_NONCE_REPLAY` | nonce format + `$defs/client_api_replay_row` + response binding |
| `FRONTIER_CAS` | all 17 registry `frontier_profile` values + request refs |
| `AUTHORIZATION_OBJECTS` | append/delivery/ledger authorization defs + registry refs |

architecture omissions map to the exact 22-row registry, prebootstrap tagged policy branch, per-method request/success/error
refs, durable replay rows, response/result digest domains, forbidden-alias inventory and acyclic digest DAG。CI未来接入时须直接
消费这些 artifacts；不得手写第二份 method switch、CAS table或 wire type。
