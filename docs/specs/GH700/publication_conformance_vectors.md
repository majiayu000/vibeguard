# GH700 Publication Conformance Vectors

本文件是 [publication_history_contract.md](publication_history_contract.md) 的规范性组成部分，唯一拥有
GH700 publication named-vector registry。这里的 fixture path是实现阶段必须创建的 canonical path；本 Draft
只冻结 fixture object/bytes/digest/oracle，不宣称文件或 runner已实现。registry exact closed set为下列十项；
新增、改名或改变 bytes须更新本 contract并重新计算 digest，调用方不得维护 alias或本地副本。

除 `frontier_valid_v1` 外，fixture object exact schema为
`{case_id,expected,input,oracle,schema_version}`，`schema_version` exact 为
`GH700:publication-conformance-vector:v1`，`expected` exact 为 `accept`。以下单行 code span是 UTF-8、无 BOM、
无 trailing newline的 exact JCS bytes；digest是这些 bytes的 lowercase SHA-256，path相对 repository root。
runner须先核对 bytes digest，再执行 positive object与 `oracle.reject`列出的每个独立 mutation；缺 fixture、
digest不符、未执行 reject mutation或多余/unknown case均 fail closed。

## Frontier

### `frontier_valid_v1`

- Planned canonical path: **tests/fixtures/public_benchmark/publication/frontier_valid_v1.json**
- Exact fixture object/JCS bytes: `{"full_prefix_digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","history_length":7,"history_root":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","repo_node_id":"R_kgDOGH700"}`
- SHA-256: `e52c3472ae93b565704e4f26a97f02260e7c9d2c724b8add3350a7f7317edf73`
- Oracle: accept exact frontier；分别加入 discriminator/frontier/mutation alias、missing/extra/null field时 reject。

## Blocked record union

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

除 named fixture内的 negative mutations外，runner还须从 root contract生成获验签的 phase-neutral governance
record与 same-candidate takeover正例，并拒绝 forged/nonterminal/cross-candidate takeover、wrong governance
evidence、owner/phase/liveness mutation、current restoration、其它 owner及 unknown record；这些是 generated
cases，不得再命名为 registry fixture。
