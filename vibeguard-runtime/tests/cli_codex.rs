mod common;

use common::run_runtime_with_stdin;

#[test]
fn codex_event_name_extracts_event_and_tolerates_invalid_json() {
    let out = run_runtime_with_stdin(
        &["codex-event-name"],
        r#"{"hook_event_name":"PermissionRequest"}"#,
    );
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "PermissionRequest\n");

    let invalid = run_runtime_with_stdin(&["codex-event-name"], "{not-json");
    assert_eq!(invalid.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&invalid.stdout), "\n");
}

#[test]
fn codex_status_helpers_extract_matcher_and_detail() {
    let payload =
        r#"{"tool_name":"Bash","tool_input":{"file_path":"src/lib.rs","command":"cargo test"}}"#;
    let matcher = run_runtime_with_stdin(&["codex-status-matcher"], payload);
    assert_eq!(matcher.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&matcher.stdout), "Bash\n");

    let detail = run_runtime_with_stdin(&["codex-status-detail"], payload);
    assert_eq!(detail.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&detail.stdout), "src/lib.rs\n");

    let command_detail = run_runtime_with_stdin(
        &["codex-status-detail"],
        r#"{"tool_input":{"command":"rg TODO"}}"#,
    );
    assert_eq!(command_detail.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&command_detail.stdout), "rg TODO\n");
}

#[test]
fn codex_status_from_output_maps_decisions_and_invalid_json() {
    let block = run_runtime_with_stdin(
        &["codex-status-from-output"],
        r#"{"decision":"block","reason":"no"}"#,
    );
    assert_eq!(block.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&block.stdout), "block\tno\n");

    let nested = run_runtime_with_stdin(
        &["codex-status-from-output"],
        r#"{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"stop"}}}"#,
    );
    assert_eq!(nested.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&nested.stdout), "block\t\n");

    let invalid = run_runtime_with_stdin(&["codex-status-from-output"], "{not-json");
    assert_eq!(invalid.status.code(), Some(0));
    assert_eq!(
        String::from_utf8_lossy(&invalid.stdout),
        "hook_error\tinvalid-json\n"
    );
}

#[test]
fn codex_deny_helpers_emit_native_deny_payloads() {
    let pretool = run_runtime_with_stdin(&["codex-pretool-deny"], "blocked");
    assert_eq!(pretool.status.code(), Some(0));
    let pretool_json: serde_json::Value = serde_json::from_slice(&pretool.stdout).unwrap();
    assert_eq!(
        pretool_json["hookSpecificOutput"]["permissionDecision"],
        "deny"
    );
    assert_eq!(
        pretool_json["hookSpecificOutput"]["permissionDecisionReason"],
        "blocked"
    );

    let permission = run_runtime_with_stdin(&["codex-permission-deny"], "blocked");
    assert_eq!(permission.status.code(), Some(0));
    let permission_json: serde_json::Value = serde_json::from_slice(&permission.stdout).unwrap();
    assert_eq!(
        permission_json["hookSpecificOutput"]["decision"]["behavior"],
        "deny"
    );
    assert_eq!(
        permission_json["hookSpecificOutput"]["decision"]["message"],
        "blocked"
    );
}

#[test]
fn codex_adapter_commands_map_wrapped_outputs() {
    let pretool = run_runtime_with_stdin(
        &["codex-adapt-pretool"],
        r#"{"decision":"block","reason":"force push denied"}"#,
    );
    assert_eq!(pretool.status.code(), Some(0));
    let pretool_json: serde_json::Value = serde_json::from_slice(&pretool.stdout).unwrap();
    assert_eq!(
        pretool_json["hookSpecificOutput"]["permissionDecision"],
        "deny"
    );
    assert_eq!(
        pretool_json["hookSpecificOutput"]["permissionDecisionReason"],
        "force push denied"
    );

    let rewrite = run_runtime_with_stdin(
        &["codex-adapt-pretool"],
        r#"{"decision":"allow","updatedInput":{"command":"pnpm install"}}"#,
    );
    assert_eq!(rewrite.status.code(), Some(0));
    let rewrite_json: serde_json::Value = serde_json::from_slice(&rewrite.stdout).unwrap();
    assert!(
        rewrite_json["systemMessage"]
            .as_str()
            .unwrap()
            .contains("pnpm install")
    );

    let posttool = run_runtime_with_stdin(
        &["codex-adapt-posttool"],
        r#"{"decision":"escalate","reason":"build failed"}"#,
    );
    assert_eq!(posttool.status.code(), Some(0));
    let posttool_json: serde_json::Value = serde_json::from_slice(&posttool.stdout).unwrap();
    assert_eq!(posttool_json["decision"], "block");
    assert_eq!(
        posttool_json["hookSpecificOutput"]["additionalContext"],
        "build failed"
    );

    let permission = run_runtime_with_stdin(
        &["codex-adapt-permission-request"],
        r#"{"decision":"block","reason":"permission denied"}"#,
    );
    assert_eq!(permission.status.code(), Some(0));
    let permission_json: serde_json::Value = serde_json::from_slice(&permission.stdout).unwrap();
    assert_eq!(
        permission_json["hookSpecificOutput"]["decision"]["behavior"],
        "deny"
    );
    assert_eq!(
        permission_json["hookSpecificOutput"]["decision"]["message"],
        "permission denied"
    );
}

#[test]
fn codex_adapter_commands_fail_closed_on_invalid_json() {
    let pretool = run_runtime_with_stdin(&["codex-adapt-pretool"], "{not-json");
    assert_eq!(pretool.status.code(), Some(3));
    let pretool_json: serde_json::Value = serde_json::from_slice(&pretool.stdout).unwrap();
    assert_eq!(
        pretool_json["hookSpecificOutput"]["permissionDecision"],
        "deny"
    );

    let posttool = run_runtime_with_stdin(&["codex-adapt-posttool"], "{not-json");
    assert_eq!(posttool.status.code(), Some(3));
    assert!(posttool.stdout.is_empty());

    let permission = run_runtime_with_stdin(&["codex-adapt-permission-request"], "{not-json");
    assert_eq!(permission.status.code(), Some(3));
    let permission_json: serde_json::Value = serde_json::from_slice(&permission.stdout).unwrap();
    assert_eq!(
        permission_json["hookSpecificOutput"]["decision"]["behavior"],
        "deny"
    );
}

#[test]
fn codex_apply_patch_normalizer_maps_file_hook_payloads() {
    let input = serde_json::json!({
        "hook_event_name": "PreToolUse",
        "tool_name": "apply_patch",
        "tool_input": {
            "command": "*** Begin Patch\n*** Add File: src/new.rs\n+fn main() {}\n*** Update File: src/existing.rs\n-old\n+new\n*** End Patch"
        }
    })
    .to_string();

    let write = run_runtime_with_stdin(
        &[
            "codex-normalize-apply-patch",
            "vibeguard-pre-write-guard.sh",
        ],
        &input,
    );
    assert_eq!(write.status.code(), Some(0));
    let write_lines = String::from_utf8_lossy(&write.stdout);
    let write_json: Vec<serde_json::Value> = write_lines
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(write_json.len(), 1);
    assert_eq!(write_json[0]["tool_name"], "Write");
    assert_eq!(write_json[0]["tool_input"]["file_path"], "src/new.rs");
    assert_eq!(write_json[0]["tool_input"]["content"], "fn main() {}");

    let edit = run_runtime_with_stdin(
        &["codex-normalize-apply-patch", "vibeguard-pre-edit-guard.sh"],
        &input,
    );
    assert_eq!(edit.status.code(), Some(0));
    let edit_lines = String::from_utf8_lossy(&edit.stdout);
    let edit_json: Vec<serde_json::Value> = edit_lines
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(edit_json.len(), 1);
    assert_eq!(edit_json[0]["tool_name"], "Edit");
    assert_eq!(edit_json[0]["tool_input"]["file_path"], "src/existing.rs");
    assert_eq!(edit_json[0]["tool_input"]["new_string"], "new");
    assert_eq!(edit_json[0]["tool_input"]["vibeguard_line_delta"], 0);

    let post_build = run_runtime_with_stdin(
        &[
            "codex-normalize-apply-patch",
            "vibeguard-post-build-check.sh",
        ],
        &input,
    );
    assert_eq!(post_build.status.code(), Some(0));
    let post_build_lines = String::from_utf8_lossy(&post_build.stdout);
    let post_build_json: Vec<serde_json::Value> = post_build_lines
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(post_build_json.len(), 2);
    assert_eq!(post_build_json[0]["tool_name"], "Write");
    assert_eq!(post_build_json[1]["tool_name"], "Edit");

    let moved_delete_input = serde_json::json!({
        "hook_event_name": "PostToolUse",
        "tool_name": "apply_patch",
        "tool_input": {
            "command": "*** Begin Patch\n*** Update File: src/old.rs\n*** Move to: src/current.rs\n-old\n+new\n*** Delete File: src/dead.rs\n-gone\n*** End Patch"
        }
    })
    .to_string();
    let moved_delete = run_runtime_with_stdin(
        &[
            "codex-normalize-apply-patch",
            "vibeguard-post-edit-guard.sh",
        ],
        &moved_delete_input,
    );
    assert_eq!(moved_delete.status.code(), Some(0));
    let moved_delete_lines = String::from_utf8_lossy(&moved_delete.stdout);
    let moved_delete_json: Vec<serde_json::Value> = moved_delete_lines
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(moved_delete_json.len(), 2);
    assert_eq!(moved_delete_json[0]["hook_event_name"], "PostToolUse");
    assert_eq!(
        moved_delete_json[0]["tool_input"]["file_path"],
        "src/current.rs"
    );
    assert_eq!(moved_delete_json[0]["tool_input"]["new_string"], "new");
    assert_eq!(
        moved_delete_json[1]["tool_input"]["file_path"],
        "src/dead.rs"
    );
    assert_eq!(moved_delete_json[1]["tool_input"]["new_string"], "");
    assert_eq!(
        moved_delete_json[1]["tool_input"]["vibeguard_line_delta"],
        -1
    );
}
