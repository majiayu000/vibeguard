# Atomic Launch Machine Contract — Request、Handoff 与 Process Template

## Linked Issue and normative owners

GH-702。本文是 [`product.md`](product.md)、[`tech.md`](tech.md) 与
[`monotonic-anchor-contract.md`](monotonic-anchor-contract.md) 的规范性 annex，只关闭 H-010
atomic launch 的 wire/process-template contract；它不批准 backend、平台或 trust root。三份 owner
文档与本 annex 的 exact digest 必须一起进入 `h010_decision_envelope`，任一 bytes drift 都使批准失效。

## Canonical wire rules

本文所有 object 都是 closed map，所有 enum 都是 closed enum。`schema_version` literal 为 `1`；
JSON 只接受 RFC 8785 JCS，拒绝 duplicate/unknown key、non-canonical base64url、NUL、空 ID、
非法时间/计数和条件字段错配。本文使用：

```text
H(domain, version, body) =
  sha256(JCS({digest_domain: domain, schema_version: version, body}))
```

domain 是下文逐项给出的 ASCII literal，不能由 object name、版本或调用者拼接。digest envelope
排除同 envelope 的 sibling digest/signature；raw suspended handle 和 resume token 只在 authenticated
IPC request/response 中出现，不能进入 digest preimage、HOME、journal、receipt、status 或 log。

## Canonical approved process-template inputs

`platform_process_abi` 只允许 `posix_bytes_v1|windows_utf16le_v1`。所有 `*_base64url` 是无 padding
canonical base64url：POSIX 字符串保存 exact non-NUL bytes；Windows 字符串保存 exact、偶数字节、
无终止 NUL 的 UTF-16LE。backend 必须从将交给 OS 的 exact native values 重算，不能摘要 shell command、
display string、继承环境或解析后的近似值。

```text
argv_body = {
  schema_version: 1,
  platform_process_abi,
  arguments: [{index, value_base64url}],
  command_line_base64url            // windows_utf16le_v1 必填；posix_bytes_v1 恒为 null
}
argv_digest = H(
  "vibeguard.gh702.approved-core-argv.v1", 1, argv_body)
```

**Windows command-line binding**：Windows 进程创建消费的是**单一 command-line 字符串**，而不是参数
数组。只签 `arguments` 会让 adapter 与 backend 在 `argv_digest` 上达成一致，被启动的进程却收到不同
的解析结果，独立实现之间也无法互认。因此 `windows_utf16le_v1` 必须同时绑定将要交给
`CreateProcessW` 的 exact `lpCommandLine` UTF-16LE bytes：

- `command_line_base64url` 保存该 exact、偶数字节、无终止 NUL 的 UTF-16LE 序列；
- 它必须由 `arguments` 按下述 canonical 序列化**唯一**产生，backend 重算后 byte-equal，否则拒绝；
- `posix_bytes_v1` 恒为 JSON `null`（POSIX 直接消费 argv 数组，无序列化歧义）。

canonical 序列化按 `index` 升序拼接，参数之间用单个 U+0020 分隔，每个参数：

1. 恒加首尾双引号 `"`，即使参数不含空格或特殊字符（不做条件引用，避免实现分歧）；
2. 参数内部：连续 `\` 后紧跟结尾引号时，每个 `\` 加倍；连续 `\` 后紧跟 `"` 时，每个 `\` 加倍并在
   该 `"` 前再加一个 `\`；其余 `\` 原样保留；
3. 不做任何 shell/`cmd.exe` 转义，不追加、重排或去重参数，不插入 program name 之外的内容。

这是 `CommandLineToArgvW` 的精确逆运算：backend 必须断言对 `command_line_base64url` 应用
`CommandLineToArgvW` 得到的序列与 `arguments` exact 相等，两侧任一不符即在启动前 nonzero。

```text
environment_body = {
  schema_version: 1,
  platform_process_abi,
  key_normalization: "posix_byte_exact_v1"|"windows_ascii_upper_v1",
  variables: [{name_ascii, comparison_name_ascii, value_base64url}]
}
environment_digest = H(
  "vibeguard.gh702.approved-core-environment.v1", 1, environment_body)

working_directory_body = {
  schema_version: 1,
  platform_process_abi,
  absolute_path_base64url,
  directory_identity:
    {kind: "posix_device_inode_v1", device_id_decimal, inode_decimal}
    | {kind: "windows_volume_file_id_v1", volume_serial_number_decimal,
       file_id_base64url}
}
working_directory_digest = H(
  "vibeguard.gh702.approved-core-working-directory.v1", 1,
  working_directory_body)

principal_identity_body = {
  schema_version: 1,
  platform_process_abi,
  principal:
    {kind: "posix_credentials_v1", uid_decimal, gid_decimal,
     supplementary_gids_decimal: [decimal]}
    | {kind: "windows_token_v1", user_sid, integrity_level_sid,
       logon_session_luid}
}
principal_identity_digest = H(
  "vibeguard.gh702.approved-core-principal-identity.v1", 1,
  principal_identity_body)

sandbox_profile_body = {
  schema_version: 1,
  platform_process_abi,
  sandbox:
    {mode: "enforced_v1", engine_id, engine_version,
     canonical_policy_format, canonical_policy_bytes_base64url}
    | {mode: "none_v1"}
}
sandbox_profile_digest = H(
  "vibeguard.gh702.approved-core-sandbox-profile.v1", 1,
  sandbox_profile_body)

ipc_profile_body = {
  schema_version: 1,
  platform_process_abi,
  endpoint:
    {kind: "posix_unix_socket_v1", path_base64url}
    | {kind: "windows_named_pipe_v1", name_base64url},
  protocol_id,
  protocol_version,
  server_principal_identity_digest,
  adapter_principal_identity_digest,
  peer_authentication: "mutual_platform_identity_v1",
  anti_replay: "session_challenge_transaction_v1",
  acl_principal_identity_digests: [digest]
}
ipc_profile_digest = H(
  "vibeguard.gh702.approved-core-ipc-profile.v1", 1, ipc_profile_body)

approved_core_process_template = {
  schema_version: 1, entrypoint_id, argv_digest, environment_digest,
  working_directory_digest, principal_identity_digest,
  sandbox_profile_digest, ipc_profile_digest
}
approved_core_process_template_digest = H(
  "vibeguard.gh702.approved-core-process-template.v1", 1,
  approved_core_process_template)
```

`arguments` 必须 non-empty，`index` 从 0 连续递增。environment name 只接受 portable ASCII
`[A-Za-z_][A-Za-z0-9_]*`，POSIX 的 comparison name 必须 exact 等于 name，Windows 必须是 ASCII
uppercase；variables 按 comparison name byte order 严格递增且无 duplicate，backend 启动时不得再继承
未列出的变量。supplementary GID、ACL digest 按数值/byte order 严格递增且唯一。working directory
必须在 create-suspended 的同一 authority 内重开并核对 object identity；symlink/path text 相同不能替代。
`none_v1` 没有其它 sandbox 字段且只能由获批 H-010 明确选择，不能由 engine unavailable 推导。

request 传 exact input bodies，backend 重算六个 subdigest 和 template digest；任一 mismatch 在 transaction
消费前失败。`requested_process_template_inputs` 是 closed map：

```text
requested_process_template_inputs = {
  entrypoint_id, argv_body, environment_body, working_directory_body,
  principal_identity_body, sandbox_profile_body, ipc_profile_body
}
```

## Policy、current state 与 launched-process identity

```text
consumed_transaction_tombstone_retention_body = {
  schema_version: 1,
  detail_retention_ms,
  compact_after_ms,
  permanent_reuse_guard: "nonrollback_consumed_transaction_set_v1"
}
consumed_transaction_tombstone_retention_digest = H(
  "vibeguard.gh702.consumed-transaction-retention.v1", 1,
  consumed_transaction_tombstone_retention_body)

launch_policy_body = {
  schema_version: 1, launch_authority_profile_digest, platform_id,
  platform_profile_family_id, global_platform_registry_entry_digest,
  approved_core_binary: {version, binary_digest},
  approved_host_adapter_binary: {version, binary_digest},
  approved_core_process_template,
  consumed_transaction_tombstone_retention_digest,
  enforcement_stage: "before_any_core_hook_v1"
}
launch_policy_digest = H(
  "vibeguard.gh702.launch-policy.v1", 1, launch_policy_body)

platform_launch_current_state_body = {
  schema_version: 1, launch_authority_backend_identity,
  current_platform_generation, backend_state_counter,
  previous_attestation_digest|null, monotonic_launch_floor,
  allowed_core_min_version, allowed_host_adapter_min_version
}
platform_launch_current_state_digest = H(
  "vibeguard.gh702.platform-launch-current-state.v1", 1,
  platform_launch_current_state_body)

launched_process_identity_body = {
  schema_version: 1, launch_authority_backend_identity,
  launch_policy_digest, platform_launch_current_state_digest,
  compare_current_state_consume_and_launch_request_digest,
  launch_session_id, challenge_nonce, launch_transaction_id,
  backend_process_instance_id, approved_core_process_template_digest,
  measured_core_binary_digest, requested_core_version,
  initial_process_state: "suspended_before_core_entry_v1"
}
launched_process_identity_digest = H(
  "vibeguard.gh702.launched-process-identity.v1", 1,
  launched_process_identity_body)
suspended_process_handle_digest =
  sha256(BASE64URL_DECODE_CANONICAL(suspended_process_handle))
resume_token_digest = sha256(BASE64URL_DECODE_CANONICAL(resume_token))
```

`detail_retention_ms > 0`，`0 <= compact_after_ms <= detail_retention_ms`，且 detail retention
至少覆盖 `max_attestation_validity_ms + max_suspended_lifetime_ms`。backend 必须在消费 transaction 前
校验该 retention digest exact 属于 launch policy；CLI/environment 不能覆盖。

## Atomic compare、consume and create-suspended

```text
compare_current_state_consume_and_launch_request_body = {
  schema_version: 1,
  launch_session_id, challenge_nonce, launch_transaction_id,
  authenticated_adapter_principal_identity_digest,
  launch_authority_profile_digest, launch_policy_digest,
  expected_platform_launch_current_state_digest,
  expected_current_platform_generation, expected_backend_state_counter,
  expected_monotonic_launch_floor,
  measured_host_adapter_binary_digest, requested_host_adapter_version,
  measured_core_binary_digest, requested_core_version,
  requested_process_template_inputs
}
compare_current_state_consume_and_launch_request_digest = H(
  "vibeguard.gh702.compare-consume-launch-request.v1", 1,
  compare_current_state_consume_and_launch_request_body)
compare_current_state_consume_and_launch_request = {
  digest_domain: "vibeguard.gh702.compare-consume-launch-request.v1",
  schema_version: 1,
  compare_current_state_consume_and_launch_request_body,
  compare_current_state_consume_and_launch_request_digest
}
```

**Adapter measurement must be external to the adapter**：`measured_host_adapter_binary_digest` 与
`requested_host_adapter_version` 是**调用方自报的字段**，不是调用方自身的 bytes。一个陈旧或被篡改
的 adapter 只要运行在获批 principal 下，就可以把获批 adapter 的 digest/version 填进请求；backend 若
只认证 principal 便消费 transaction，该未获批 adapter 仍会拿到 handle/token 并恢复 Core——self-report
在此等同于自证，不构成任何证据。

因此 backend 必须在消费 transaction 之前，**在 adapter 进程之外**独立度量调用方可执行文件：

- 从已认证的 IPC 连接解析对端进程（POSIX：peer credentials 得到的 PID 加上
  `posix_device_inode_v1` object identity；Windows：named-pipe 客户端 token 加上
  `windows_volume_file_id_v1` file id），再由 backend 自己读取该 image 计算 digest；
- 该 backend-measured digest 必须与 `launch_policy_body.approved_host_adapter_binary.binary_digest`
  exact 相等，并与请求中的 `measured_host_adapter_binary_digest` exact 相等；三者任一不符即在
  transaction 消费前 nonzero，不得回退为 principal-only 授权；
- 度量与 launch 必须在同一 external-TCB linearization point 内，对同一 pinned object identity 完成，
  防止度量后替换 image 的 TOCTOU；
- backend 无法解析对端进程或无法独立读取其 image 时，必须 conservative deny，而不是接受 self-report。

`measured_core_binary_digest` 同理由 backend 在 create-suspended 的同一 authority 内自行度量，
adapter 的自报值只作为必须匹配的断言，不作为真源。

```text
platform_launch_floor_attestation_envelope = {
  digest_domain: "vibeguard.gh702.platform-launch-floor-attestation.v1",
  schema_version: 1,
  platform_launch_floor_attestation_body: {
    launch_authority_profile_digest, launch_policy_digest,
    platform_launch_current_state_body, platform_launch_current_state_digest,
    compare_current_state_consume_and_launch_request_digest,
    launch_session_id, challenge_nonce, launch_transaction_id,
    launch_commit_counter, launched_process_identity_body,
    launched_process_identity_digest, suspended_process_handle_digest,
    resume_token_digest, resume_protocol: "single_use_external_tcb_resume_v1",
    measured_core_binary_digest, measured_host_adapter_binary_digest,
    requested_core_version, requested_host_adapter_version, issued_at, expires_at
  },
  platform_launch_floor_attestation_digest,
  signatures: [{signer_key_id, signature_algorithm, signature}]
}
platform_launch_floor_attestation_digest = H(
  "vibeguard.gh702.platform-launch-floor-attestation.v1", 1,
  platform_launch_floor_attestation_body)

compare_current_state_consume_and_launch_response_body = {
  schema_version: 1,
  compare_current_state_consume_and_launch_request_digest,
  platform_launch_floor_attestation_digest,
  suspended_process_handle_digest, resume_token_digest
}
compare_current_state_consume_and_launch_response_digest = H(
  "vibeguard.gh702.compare-consume-launch-response.v1", 1,
  compare_current_state_consume_and_launch_response_body)
compare_current_state_consume_and_launch_response = {
  digest_domain: "vibeguard.gh702.compare-consume-launch-response.v1",
  schema_version: 1,
  compare_current_state_consume_and_launch_response_body,
  compare_current_state_consume_and_launch_response_digest,
  platform_launch_floor_attestation_envelope,
  suspended_process_handle, resume_token
}
```

backend 必须把 authenticated channel 实测 peer identity 与 request 中 adapter principal exact 比较，
并在一个 external-TCB linearization point 内完成：compare exact current digest/generation/counter/floor；
拒绝已消费 transaction；永久登记 transaction + request digest + peer；按重算后 exact template 创建 suspended
process；写入 pending deadline/handle-token digests；递增 commit counter；返回 attestation。compare 失败不能消费；
消费后任一创建失败必须 terminalize 为 `launch_failed_after_consume_v1`，不能释放 transaction。

## Recover、resume、query and abort

```text
recover_launch_handoff_request_body = {
  schema_version: 1, launch_session_id, challenge_nonce,
  launch_transaction_id,
  compare_current_state_consume_and_launch_request_digest,
  authenticated_adapter_principal_identity_digest,
  compare_current_state_consume_and_launch_request
}
recover_launch_handoff_request_digest = H(
  "vibeguard.gh702.recover-launch-handoff-request.v1", 1,
  recover_launch_handoff_request_body)
recover_launch_handoff_request = {
  digest_domain: "vibeguard.gh702.recover-launch-handoff-request.v1",
  schema_version: 1, recover_launch_handoff_request_body,
  recover_launch_handoff_request_digest
}

launch_not_consumed_receipt_body = {
  schema_version: 1, launch_authority_backend_identity,
  launch_session_id, challenge_nonce, launch_transaction_id,
  compare_current_state_consume_and_launch_request_digest,
  authenticated_adapter_principal_identity_digest,
  recovery_counter,
  outcome: "prelinearization_not_consumed_cancelled_v1",
  cancelled_at
}
launch_not_consumed_receipt_digest = H(
  "vibeguard.gh702.launch-not-consumed-receipt.v1", 1,
  launch_not_consumed_receipt_body)
launch_not_consumed_receipt_envelope = {
  digest_domain: "vibeguard.gh702.launch-not-consumed-receipt.v1",
  schema_version: 1, launch_not_consumed_receipt_body,
  launch_not_consumed_receipt_digest,
  signatures: [{signer_key_id, signature_algorithm, signature}]
}

recover_launch_handoff_response_body = {
  schema_version: 1,
  recovery_state: "prelinearization_not_consumed_cancelled_v1"|
                  "existing_pending_handoff_v1"|"resumed_v1"|
                  "aborted_v1"|"timeout_terminated_v1"|
                  "launch_failed_after_consume_v1",
  compare_current_state_consume_and_launch_request_digest,
  launch_not_consumed_receipt_digest|null,
  platform_launch_floor_attestation_digest|null,
  suspended_process_handle_digest|null, resume_token_digest|null,
  resume_commit_receipt_digest|null,
  consumed_transaction_tombstone_digest|null
}
recover_launch_handoff_response_digest = H(
  "vibeguard.gh702.recover-launch-handoff-response.v1", 1,
  recover_launch_handoff_response_body)
recover_launch_handoff_response = {
  digest_domain: "vibeguard.gh702.recover-launch-handoff-response.v1",
  schema_version: 1, recover_launch_handoff_response_body,
  recover_launch_handoff_response_digest,
  launch_not_consumed_receipt_envelope|null,
  platform_launch_floor_attestation_envelope|null,
  suspended_process_handle|null, resume_token|null,
  resume_commit_receipt_envelope|null,
  consumed_transaction_tombstone_envelope|null
}

resume_suspended_process_request_body = {
  schema_version: 1, launch_session_id, launch_transaction_id,
  platform_launch_floor_attestation_digest,
  launched_process_identity_digest,
  suspended_process_handle_digest, resume_token_digest
}
resume_suspended_process_request_digest = H(
  "vibeguard.gh702.resume-suspended-process-request.v1", 1,
  resume_suspended_process_request_body)
resume_suspended_process_request = {
  digest_domain: "vibeguard.gh702.resume-suspended-process-request.v1",
  schema_version: 1, resume_suspended_process_request_body,
  resume_suspended_process_request_digest,
  suspended_process_handle, resume_token
}

resume_commit_receipt_body = {
  schema_version: 1, launch_session_id, launch_transaction_id,
  compare_current_state_consume_and_launch_request_digest,
  resume_suspended_process_request_digest,
  launched_process_identity_digest, suspended_process_handle_digest,
  launch_commit_counter, resume_commit_counter, committed_at,
  resume_state: "resume_committed_before_process_runnable_v1"
}
resume_commit_receipt_digest = H(
  "vibeguard.gh702.resume-commit-receipt.v1", 1,
  resume_commit_receipt_body)
resume_commit_receipt_envelope = {
  digest_domain: "vibeguard.gh702.resume-commit-receipt.v1",
  schema_version: 1, resume_commit_receipt_body,
  resume_commit_receipt_digest,
  signatures: [{signer_key_id, signature_algorithm, signature}]
}
resume_suspended_process_response_body = {
  schema_version: 1, state: "resumed_v1",
  resume_suspended_process_request_digest, resume_commit_receipt_digest
}
resume_suspended_process_response_digest = H(
  "vibeguard.gh702.resume-suspended-process-response.v1", 1,
  resume_suspended_process_response_body)
resume_suspended_process_response = {
  digest_domain: "vibeguard.gh702.resume-suspended-process-response.v1",
  schema_version: 1, resume_suspended_process_response_body,
  resume_suspended_process_response_digest, resume_commit_receipt_envelope
}

query_or_abort_suspended_process_request_body = {
  schema_version: 1, action: "query_v1"|"abort_v1",
  abort_reason_code: null|"adapter_validation_failed_v1"|
                     "adapter_shutdown_v1"|"operator_abort_v1",
  launch_session_id, launch_transaction_id,
  platform_launch_floor_attestation_digest,
  suspended_process_handle_digest
}
query_or_abort_suspended_process_request_digest = H(
  "vibeguard.gh702.query-or-abort-request.v1", 1,
  query_or_abort_suspended_process_request_body)
query_or_abort_suspended_process_request = {
  digest_domain: "vibeguard.gh702.query-or-abort-request.v1",
  schema_version: 1, query_or_abort_suspended_process_request_body,
  query_or_abort_suspended_process_request_digest,
  suspended_process_handle
}
query_or_abort_suspended_process_response_body = {
  schema_version: 1,
  query_or_abort_suspended_process_request_digest,
  state: "pending_v1"|"resumed_v1"|"aborted_v1"|
         "timeout_terminated_v1"|"launch_failed_after_consume_v1",
  pending_deadline|null,
  resume_commit_receipt_digest|null,
  consumed_transaction_tombstone_digest|null
}
query_or_abort_suspended_process_response_digest = H(
  "vibeguard.gh702.query-or-abort-response.v1", 1,
  query_or_abort_suspended_process_response_body)
query_or_abort_suspended_process_response = {
  digest_domain: "vibeguard.gh702.query-or-abort-response.v1",
  schema_version: 1, query_or_abort_suspended_process_response_body,
  query_or_abort_suspended_process_response_digest,
  resume_commit_receipt_envelope|null,
  consumed_transaction_tombstone_envelope|null
}
```

recover 只接受创建 transaction 时同一 channel-authenticated peer 与完整原 request；backend 重算 nested
domain/version/body/digest，并要求 session/challenge/transaction/peer 的 duplicated fields exact cross-equal。
backend 对该 transaction key 串行化 compare/recover：若 compare 已消费则返回原 pending/terminal proof；
若尚未 linearize，recover 必须原子证明 absent、写 permanent cancelled reuse guard，再签发 `not_consumed`
receipt。两者必有且只有一个胜出；adapter 验证 not-consumed receipt 后只能分配全新的 session/challenge/
transaction，延迟到达的旧 compare 必须被 guard 拒绝。任一 mismatch 返回 closed error，绝不 respawn。

resume 必须在 external TCB recovery-first transaction 内核对 pending peer/attestation/process/handle/token，
消费 token，先构造、签名并 durable commit receipt + permanent reuse guard，再把 state 标为
`resume_committed_process_suspended_v1`，最后才解除 exact process 的 suspension。crash 在 receipt commit 前保持
pending；commit 后、unblock 前必须由 backend restart/recover/query 确定性 roll forward 同一 process；任何 Core
instruction/hook 都不能在 receipt durable 前运行。response 丢失后只能 query。pending 只允许 deadline；resumed
只允许 receipt；三个 terminal failure state 只允许 tombstone。`abort_v1` 对 pending terminate 后返回 tombstone；
query 必须使用 null reason，abort 必须使用 non-null closed reason；对 resumed 不得 kill/rollback，对 terminal
state 幂等返回同一 receipt/tombstone。

## Consumed transaction tombstone and permanent reuse guard

```text
consumed_transaction_tombstone_body = {
  schema_version: 1, launch_authority_backend_identity,
  launch_policy_digest,
  consumed_transaction_tombstone_retention_digest,
  launch_session_id, challenge_nonce, launch_transaction_id,
  compare_current_state_consume_and_launch_request_digest,
  authenticated_adapter_principal_identity_digest,
  launched_process_identity_digest|null,
  suspended_process_handle_digest|null,
  terminal_state: "aborted_v1"|"timeout_terminated_v1"|
                  "launch_failed_after_consume_v1",
  terminal_reason_code: "adapter_validation_failed_v1"|
                        "adapter_shutdown_v1"|
                        "operator_abort_v1"|
                        "pending_deadline_expired_v1"|
                        "create_suspended_failed_v1"|
                        "authenticated_peer_lost_v1",
  consumed_at, terminalized_at, compact_at, detail_retain_until
}
consumed_transaction_tombstone_digest = H(
  "vibeguard.gh702.consumed-transaction-tombstone.v1", 1,
  consumed_transaction_tombstone_body)
consumed_transaction_tombstone_envelope = {
  digest_domain: "vibeguard.gh702.consumed-transaction-tombstone.v1",
  schema_version: 1, consumed_transaction_tombstone_body,
  consumed_transaction_tombstone_digest,
  signatures: [{signer_key_id, signature_algorithm, signature}]
}

consumed_transaction_reuse_guard_body = {
  schema_version: 1, launch_authority_backend_identity,
  launch_transaction_id,
  terminal_state: "prelinearization_not_consumed_cancelled_v1"|
                  "resumed_v1"|"aborted_v1"|
                  "timeout_terminated_v1"|
                  "launch_failed_after_consume_v1",
  terminal_evidence_digest,
  retention: "permanent_nonrollback_v1"
}
consumed_transaction_reuse_guard_digest = H(
  "vibeguard.gh702.consumed-transaction-reuse-guard.v1", 1,
  consumed_transaction_reuse_guard_body)
```

`consumed_at <= terminalized_at <= compact_at <= detail_retain_until`；`compact_at` 与
`detail_retain_until` 必须由 policy 的 two durations exact 推导。detail 到期只可删除 tombstone 外的辅助 audit
attachments；canonical signed tombstone envelope 与 external nonrollback reuse-guard body/digest 都必须永久保留，
且启动 compare 必须先查该 set。
`terminal_evidence_digest` 必须按 state exact 指向 not-consumed receipt、resume receipt 或 failure tombstone；
resumed/not-consumed 不另造 failure tombstone。raw handle/token 永不进入 tombstone/reuse guard。

## Non-secret handoff status

```text
launch_handoff_status_body = {
  schema_version: 1, launch_authority_backend_identity,
  launch_session_id, launch_transaction_id,
  compare_current_state_consume_and_launch_request_digest,
  state: "prelinearization_not_consumed_cancelled_v1"|"pending_v1"|
         "resume_committed_process_suspended_v1"|"resumed_v1"|
         "aborted_v1"|"timeout_terminated_v1"|
         "launch_failed_after_consume_v1",
  launched_process_identity_digest|null,
  suspended_process_handle_digest|null,
  resume_commit_receipt_digest|null,
  launch_not_consumed_receipt_digest|null,
  consumed_transaction_tombstone_digest|null,
  pending_deadline|null, updated_at
}
launch_handoff_status_digest = H(
  "vibeguard.gh702.launch-handoff-status.v1", 1,
  launch_handoff_status_body)
launch_handoff_status_envelope = {
  digest_domain: "vibeguard.gh702.launch-handoff-status.v1",
  schema_version: 1, launch_handoff_status_body,
  launch_handoff_status_digest,
  signatures: [{signer_key_id, signature_algorithm, signature}]
}
```

renderer 只能从 current authenticated backend response 生成该 envelope。pending 只显示 handle digest/deadline；
resume-committed/resumed 只显示 receipt digest；not-consumed 只显示 not-consumed receipt digest；failure terminal
state 只显示 tombstone digest。raw handle/token 必须 absent。`list/status/audit` 可因此在 response loss 后区分
prelinearization cancel、pending、durable-resume recovery、resumed 与 terminal failure，不查询 secret。

## Identity-registry closure

```text
atomic_launch_identity_schema_roots = [
  "/argv_body", "/environment_body", "/working_directory_body",
  "/principal_identity_body", "/sandbox_profile_body", "/ipc_profile_body",
  "/approved_core_process_template",
  "/consumed_transaction_tombstone_retention_body", "/launch_policy_body",
  "/platform_launch_current_state_body", "/launched_process_identity_body",
  "/compare_current_state_consume_and_launch_request",
  "/platform_launch_floor_attestation_envelope",
  "/compare_current_state_consume_and_launch_response",
  "/recover_launch_handoff_request", "/recover_launch_handoff_response",
  "/launch_not_consumed_receipt_envelope",
  "/resume_suspended_process_request", "/resume_suspended_process_response",
  "/resume_commit_receipt_envelope",
  "/query_or_abort_suspended_process_request",
  "/query_or_abort_suspended_process_response",
  "/consumed_transaction_tombstone_envelope",
  "/consumed_transaction_reuse_guard_body",
  "/launch_handoff_status_envelope"
]
```

schema compiler 必须从每个 root 递归枚举所有 closed leaf、union discriminant、array item leaf 和 envelope
domain/version/digest/signature leaf，生成 `atomic_launch_identity_schema_pointers`；checked-in expected set 与生成
set 必须全等，不能只登记 root。每个 pointer 都生成 omit/null/unknown/wrong-type/one-field-mutation negative；
新增字段而 expected registry 未更新必须使 fixture 失败。monotonic contract 的 H-010 registry 必须 join 此生成
registry，不能复制一份会漂移的手写子集。

## Targeted contract assertions

实现与 review fixture 必须至少断言：

- 六个 subdigest body 的 single-field mutation、domain/version mutation、argument/environment reorder、
  Windows comparison-name collision、cwd object substitution、principal/sandbox/IPC drift 全部在消费前拒绝；
- 每个 wire request/response 的 domain/version/body/digest mutation 均拒绝；request 缺 session/challenge/
  transaction/current state/measured identity/exact template input，或 digest/peer mismatch，均不能创建或消费；
  compare/recover race 只产生 pending 或 signed not-consumed-cancelled，后者使延迟 compare 永久不可消费；
- resume wrong handle/token/process/attestation、double resume、query/abort conditional-field mismatch、terminal respawn
  全部拒绝；crash 在 receipt durable 前保持 pending，durable 后必须在 process runnable 前可恢复；timeout/peer
  loss 必须 terminate 并产生同一 signed tombstone；
- detail compaction 前后都不能复用 transaction；backend restart、旧 adapter 和旧 Core 也必须命中 permanent
  reuse guard；status 覆盖全部 lifecycle/non-secret digests，raw handle/token canary 在 filesystem/log/status/receipt 中始终为零。

新增/删除任一 identity 字段时，fixture 必须同步更新本文的 closed positive schema、one-field mutation corpus 和
identity registry；只加 prose 或 anonymous response 不算关闭契约。
