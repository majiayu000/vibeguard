use std::fs;
use std::io::Write;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};

fn bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_vibeguard-runtime"))
}

fn unique_temp_dir(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!(
        "vibeguard-runtime-{label}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ))
}

#[cfg(unix)]
fn file_mode(path: &std::path::Path) -> u32 {
    fs::metadata(path).unwrap().permissions().mode() & 0o777
}

#[test]
fn no_args_exits_2() {
    let out = bin().output().unwrap();
    assert_eq!(out.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("Usage:"),
        "expected 'Usage:' in stderr: {stderr}"
    );
}

#[test]
fn unknown_command_exits_2() {
    let out = bin().arg("bogus-cmd").output().unwrap();
    assert_eq!(out.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("Unknown command"),
        "expected 'Unknown command' in stderr: {stderr}"
    );
}

#[test]
fn help_lists_all_commands() {
    let out = bin().output().unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr);
    for name in &[
        "json-field",
        "json-two-fields",
        "churn-count",
        "warn-count",
        "post-edit-history",
        "build-fails",
        "paralysis-count",
        "append-jsonl",
        "circuit-breaker",
        "pkg-rewrite",
        "pre-bash-check",
        "session-metrics",
        "observe",
        "codex-event-name",
        "codex-status-detail",
        "codex-status-matcher",
        "codex-status-from-output",
        "codex-pretool-deny",
        "codex-permission-deny",
        "codex-adapt-pretool",
        "codex-adapt-posttool",
        "codex-adapt-permission-request",
        "codex-normalize-apply-patch",
        "pre-write-check",
        "pre-edit-check",
        "post-edit-fast-check",
        "post-write-fast-check",
        "post-write-check",
        "codex-app-server-wrapper",
    ] {
        assert!(
            stderr.contains(name),
            "expected '{name}' in help output: {stderr}"
        );
    }
}

#[test]
fn observe_export_prometheus_omits_raw_sensitive_labels() {
    let root = unique_temp_dir("observe-prometheus");
    fs::create_dir_all(&root).unwrap();
    let input = root.join("events.jsonl");
    let output_file = root.join("metrics.prom");
    fs::write(
        &input,
        concat!(
            "{\"ts\":\"2026-05-31T00:00:00Z\",\"session\":\"secret-session\",",
            "\"hook\":\"post-edit-guard\",\"tool\":\"Edit\",\"decision\":\"warn\",",
            "\"reason\":\"U-16 block for customer@example.com command cargo test -- --ignored\",",
            "\"detail\":\"Edit /Users/alice/project/src/private_token.rs\",",
            "\"duration_ms\":250}\n"
        ),
    )
    .unwrap();

    let out = bin()
        .args([
            "observe",
            "export",
            "prometheus",
            "--since",
            "all",
            "--input-file",
        ])
        .arg(&input)
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("vibeguard_event_total"), "{stdout}");
    assert!(
        stdout.contains("vibeguard_tool_total{tool=\"Edit\"} 1"),
        "{stdout}"
    );
    assert!(stdout.contains("rule_id=\"U-16\""), "{stdout}");
    assert!(
        stdout.contains("reason_code=\"rule_violation\""),
        "{stdout}"
    );
    assert!(stdout.contains("file_ext=\"rs\""), "{stdout}");
    for raw in [
        "secret-session",
        "customer@example.com",
        "cargo test -- --ignored",
        "/Users/alice",
        "private_token",
    ] {
        assert!(!stdout.contains(raw), "raw value leaked: {raw}\n{stdout}");
    }

    let file_out = bin()
        .args([
            "observe",
            "export",
            "prometheus",
            "--since",
            "all",
            "--input-file",
        ])
        .arg(&input)
        .args(["--file"])
        .arg(&output_file)
        .output()
        .unwrap();
    assert_eq!(file_out.status.code(), Some(0));
    assert!(file_out.stdout.is_empty());
    let file_metrics = fs::read_to_string(&output_file).unwrap();
    assert!(file_metrics.contains("vibeguard_guard_violation_total"));
    assert!(!file_metrics.contains("customer@example.com"));
    let _ = fs::remove_dir_all(root);
}

#[test]
fn observe_export_prometheus_project_scope_reads_project_log_dir() {
    let root = unique_temp_dir("observe-project-scope");
    let project_root = root.join("repo");
    let log_root = root.join("logs");
    let project_log_dir = log_root.join("projects").join("abcdef12");
    fs::create_dir_all(&project_root).unwrap();
    fs::create_dir_all(&project_log_dir).unwrap();
    fs::write(
        project_log_dir.join(".project-root"),
        project_root.to_string_lossy().as_ref(),
    )
    .unwrap();
    fs::write(
        project_log_dir.join("events.jsonl"),
        "{\"hook\":\"pre-bash-guard\",\"tool\":\"Bash\",\"decision\":\"block\",\"reason\":\"force push denied\",\"detail\":\"git push --force\"}\n",
    )
    .unwrap();

    let out = bin()
        .args(["observe", "export", "prometheus", "--project"])
        .arg(&project_root)
        .args(["--since", "all"])
        .env("VIBEGUARD_LOG_DIR", &log_root)
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("vibeguard_events_total 1"), "{stdout}");
    assert!(
        stdout.contains("reason_code=\"dangerous_command\""),
        "{stdout}"
    );
    assert!(!stdout.contains("git push --force"), "{stdout}");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn observe_export_prometheus_missing_log_reports_error_without_output_file() {
    let root = unique_temp_dir("observe-missing-log");
    fs::create_dir_all(&root).unwrap();
    let missing = root.join("missing-events.jsonl");
    let output_file = root.join("metrics.prom");

    let out = bin()
        .args([
            "observe",
            "export",
            "prometheus",
            "--since",
            "all",
            "--input-file",
        ])
        .arg(&missing)
        .args(["--file"])
        .arg(&output_file)
        .output()
        .unwrap();

    assert_eq!(out.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("Log file does not exist"), "{stderr}");
    assert!(
        stderr.contains(&missing.to_string_lossy().to_string()),
        "{stderr}"
    );
    assert!(!output_file.exists());
    let _ = fs::remove_dir_all(root);
}

fn run_runtime_with_stdin(args: &[&str], input: &str) -> std::process::Output {
    let mut child = bin()
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(input.as_bytes())
        .unwrap();
    child.wait_with_output().unwrap()
}

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

fn run_post_write_check(input: &str, log_file: &std::path::Path) -> std::process::Output {
    let mut child = bin()
        .args([
            "post-write-check",
            "800",
            "400",
            "5000",
            "20",
            "5",
            log_file.to_string_lossy().as_ref(),
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .env("VIBEGUARD_HOOK_START_MS", "1")
        .spawn()
        .unwrap();
    child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(input.as_bytes())
        .unwrap();
    child.wait_with_output().unwrap()
}

#[test]
fn post_edit_fast_check_reports_malformed_json() {
    let root = unique_temp_dir("post-edit-malformed");
    fs::create_dir_all(&root).unwrap();
    let log_file = root.join("events.jsonl");
    let out = run_runtime_with_stdin(
        &[
            "post-edit-fast-check",
            "400",
            "test-session",
            "codex",
            log_file.to_string_lossy().as_ref(),
        ],
        "not-json",
    );

    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("FAST_OUTPUT"), "{stdout}");
    assert!(stdout.contains("PostToolUse"), "{stdout}");
    assert!(stdout.contains("malformed PostToolUse(Edit)"), "{stdout}");
    let log_text = fs::read_to_string(&log_file).unwrap();
    assert!(log_text.contains("Malformed hook input"), "{log_text}");
    assert!(log_text.contains("\"decision\":\"warn\""), "{log_text}");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn post_write_check_reports_malformed_json() {
    let root = unique_temp_dir("post-write-malformed");
    fs::create_dir_all(&root).unwrap();
    let log_file = root.join("events.jsonl");
    let out = run_post_write_check("not-json", &log_file);

    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("PostToolUse"), "{stdout}");
    assert!(stdout.contains("malformed PostToolUse(Write)"), "{stdout}");
    let log_text = fs::read_to_string(&log_file).unwrap();
    assert!(log_text.contains("Malformed hook input"), "{log_text}");
    assert!(log_text.contains("\"decision\":\"warn\""), "{log_text}");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn post_write_check_reports_duplicate_definition() {
    let root = unique_temp_dir("post-write-dup");
    fs::create_dir_all(root.join(".git")).unwrap();
    fs::create_dir_all(root.join("src")).unwrap();
    fs::write(
        root.join("src").join("existing.py"),
        "def processOrder():\n    return 1\n",
    )
    .unwrap();
    let log_file = root.join("events.jsonl");
    let input = serde_json::json!({
        "tool_input": {
            "file_path": root.join("src").join("new.py"),
            "content": "def processOrder():\n    return 2\n"
        }
    })
    .to_string();

    let out = run_post_write_check(&input, &log_file);
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("PostToolUse"), "{stdout}");
    assert!(stdout.contains("duplicate definition"), "{stdout}");
    assert!(
        fs::read_to_string(&log_file)
            .unwrap()
            .contains("processOrder")
    );
    let _ = fs::remove_dir_all(root);
}

#[test]
fn post_write_check_silent_pass_for_non_source() {
    let root = unique_temp_dir("post-write-pass");
    fs::create_dir_all(root.join(".git")).unwrap();
    let log_file = root.join("events.jsonl");
    let input = serde_json::json!({
        "tool_input": {
            "file_path": root.join("README.md"),
            "content": "# title"
        }
    })
    .to_string();

    let out = run_post_write_check(&input, &log_file);
    assert_eq!(out.status.code(), Some(0));
    assert!(out.stdout.is_empty());
    let log_text = fs::read_to_string(&log_file).unwrap();
    assert!(log_text.contains("Non-source file"));
    assert!(log_text.contains("\"duration_ms\":"), "{log_text}");
    let _ = fs::remove_dir_all(root);
}

fn run_pre_bash_check(input: &str) -> std::process::Output {
    let mut child = bin()
        .args(["pre-bash-check", "/repo"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(input.as_bytes())
        .unwrap();
    child.wait_with_output().unwrap()
}

#[test]
fn pre_bash_check_blocks_dangerous_command() {
    let out = run_pre_bash_check(r#"{"tool_input":{"command":"git checkout ."}}"#);
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.starts_with("BLOCK\n"), "{stdout}");
    assert!(stdout.contains("Disable git checkout/restore"), "{stdout}");
    assert!(
        stdout.contains("\\\"decision\\\": \\\"block\\\""),
        "{stdout}"
    );
}

#[test]
fn pre_bash_check_warns_for_nonstandard_markdown() {
    let out = run_pre_bash_check(r#"{"tool_input":{"command":"printf x > notes.md"}}"#);
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.starts_with("WARN\n"), "{stdout}");
    assert!(
        stdout.contains("\\\"hookEventName\\\": \\\"PreToolUse\\\""),
        "{stdout}"
    );
}

#[test]
fn pre_bash_check_reports_correction_payload() {
    let out = run_pre_bash_check(r#"{"tool_input":{"command":"npm install lodash"}}"#);
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.starts_with("CORRECTION\n"), "{stdout}");
    assert!(
        stdout.contains("\"corrected\":\"pnpm add lodash\""),
        "{stdout}"
    );
    assert!(
        stdout.contains("\\\"command\\\": \\\"pnpm add lodash\\\""),
        "{stdout}"
    );
}

#[test]
fn pre_bash_check_pass_marks_precommit_bridge() {
    let out = run_pre_bash_check(r#"{"tool_input":{"command":"git commit -m ok"}}"#);
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.starts_with("PASS\n"), "{stdout}");
    assert!(stdout.contains("\"precommit\":true"), "{stdout}");
}

#[test]
fn pre_bash_check_malformed_input_fails_closed() {
    let out = run_pre_bash_check(r#"{"tool_input":"#);
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.starts_with("BLOCK\n"), "{stdout}");
    assert!(
        stdout.contains("invalid Bash hook input JSON; fail-closed"),
        "{stdout}"
    );
}

fn run_circuit_breaker(
    action: &str,
    hook: &str,
    state_file: &std::path::Path,
    lock_file: &std::path::Path,
    session: &str,
) -> std::process::Output {
    bin()
        .args([
            "circuit-breaker",
            action,
            hook,
            state_file.to_str().unwrap(),
            lock_file.to_str().unwrap(),
            "2",
            "9999",
            "0",
        ])
        .env("VIBEGUARD_SESSION_ID", session)
        .output()
        .unwrap()
}

#[test]
fn circuit_breaker_command_opens_and_resets_state() {
    let dir = unique_temp_dir("circuit-breaker-state");
    let state_file = dir.join("hook.cb");
    let lock_file = dir.join("hook.cb.lock");

    let out = run_circuit_breaker("check", "cb-hook", &state_file, &lock_file, "session-a");
    assert_eq!(
        out.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(String::from_utf8_lossy(&out.stdout), "RUN\n");

    let out = run_circuit_breaker(
        "record-block",
        "cb-hook",
        &state_file,
        &lock_file,
        "session-a",
    );
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "RECORDED\n");

    let out = run_circuit_breaker(
        "record-block",
        "cb-hook",
        &state_file,
        &lock_file,
        "session-a",
    );
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("OPENED"));
    assert!(stdout.contains("CB tripped OPEN"));

    let out = run_circuit_breaker("check", "cb-hook", &state_file, &lock_file, "session-a");
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("AUTO_PASS"));
    assert!(stdout.contains("CB OPEN: auto-pass"));

    let out = run_circuit_breaker(
        "record-pass",
        "cb-hook",
        &state_file,
        &lock_file,
        "session-a",
    );
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "RECORDED\n");

    let out = run_circuit_breaker("check", "cb-hook", &state_file, &lock_file, "session-a");
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "RUN\n");

    let _ = fs::remove_dir_all(dir);
}

#[cfg(unix)]
#[test]
fn circuit_breaker_command_lock_timeout_is_error() {
    use std::os::fd::AsRawFd;

    let dir = unique_temp_dir("circuit-breaker-lock-timeout");
    fs::create_dir_all(&dir).unwrap();
    let state_file = dir.join("hook.cb");
    let lock_file = dir.join("hook.cb.lock");
    let file = fs::OpenOptions::new()
        .create(true)
        .write(true)
        .open(&lock_file)
        .unwrap();
    let lock_rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    assert_eq!(lock_rc, 0);

    let out = run_circuit_breaker("check", "cb-hook", &state_file, &lock_file, "session-a");
    assert_eq!(out.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("circuit breaker lock timeout"),
        "expected lock timeout in stderr: {stderr}"
    );

    unsafe {
        let _ = libc::flock(file.as_raw_fd(), libc::LOCK_UN);
    }
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn circuit_breaker_command_mkdir_lock_timeout_is_error() {
    let dir = unique_temp_dir("circuit-breaker-mkdir-lock-timeout");
    fs::create_dir_all(&dir).unwrap();
    let state_file = dir.join("hook.cb");
    let lock_file = dir.join("hook.cb.lock");
    fs::create_dir(&dir.join("hook.cb.lock.d")).unwrap();

    let out = run_circuit_breaker("check", "cb-hook", &state_file, &lock_file, "session-a");
    assert_eq!(out.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("circuit breaker lock timeout"),
        "expected mkdir lock timeout in stderr: {stderr}"
    );

    let _ = fs::remove_dir_all(dir);
}

#[test]
fn append_jsonl_command_appends_one_line() {
    let dir = unique_temp_dir("append-jsonl-one-line");
    fs::create_dir_all(&dir).unwrap();
    let log_file = dir.join("events.jsonl");
    let mut child = bin()
        .args(["append-jsonl", log_file.to_str().unwrap()])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"{\"ok\":true}\n")
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(
        out.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(String::from_utf8_lossy(&out.stdout), "");
    let content = fs::read_to_string(&log_file).unwrap();
    assert_eq!(content, "{\"ok\":true}\n");
    serde_json::from_str::<serde_json::Value>(content.trim_end()).unwrap();
    #[cfg(unix)]
    assert_eq!(file_mode(&log_file), 0o600);
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn append_jsonl_command_rejects_multiline_input() {
    let dir = unique_temp_dir("append-jsonl-multiline");
    fs::create_dir_all(&dir).unwrap();
    let log_file = dir.join("events.jsonl");
    let mut child = bin()
        .args(["append-jsonl", log_file.to_str().unwrap()])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"{\"first\":true}\n{\"second\":true}")
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(out.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("exactly one JSONL line"),
        "expected single-line error in stderr: {stderr}"
    );
    assert!(!log_file.exists());
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn append_jsonl_command_rejects_invalid_json() {
    let dir = unique_temp_dir("append-jsonl-invalid-json");
    fs::create_dir_all(&dir).unwrap();
    let log_file = dir.join("events.jsonl");
    let mut child = bin()
        .args(["append-jsonl", log_file.to_str().unwrap()])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(b"not-json").unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(out.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("vibeguard-runtime error:"),
        "expected runtime error in stderr: {stderr}"
    );
    assert!(!log_file.exists());
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn append_jsonl_command_rejects_non_object_json() {
    let dir = unique_temp_dir("append-jsonl-non-object-json");
    fs::create_dir_all(&dir).unwrap();
    let log_file = dir.join("events.jsonl");
    let mut child = bin()
        .args(["append-jsonl", log_file.to_str().unwrap()])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(b"null").unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(out.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("JSON object"),
        "expected object-shape error in stderr: {stderr}"
    );
    assert!(!log_file.exists());
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn append_jsonl_command_lock_timeout_does_not_write_unlocked() {
    let dir = unique_temp_dir("append-jsonl-lock-timeout");
    fs::create_dir_all(&dir).unwrap();
    let log_file = dir.join("events.jsonl");
    fs::create_dir(format!("{}.lock.d", log_file.display())).unwrap();
    let mut child = bin()
        .args(["append-jsonl", log_file.to_str().unwrap()])
        .env("VIBEGUARD_LOG_LOCK_ATTEMPTS", "1")
        .env("VIBEGUARD_LOG_LOCK_SLEEP_SECONDS", "0")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"{\"locked\":true}")
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(out.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("timed out waiting for JSONL append lock"),
        "expected lock timeout in stderr: {stderr}"
    );
    assert!(!log_file.exists());
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn append_jsonl_command_zero_lock_attempts_acts_as_one_attempt() {
    let dir = unique_temp_dir("append-jsonl-zero-lock-attempts");
    fs::create_dir_all(&dir).unwrap();
    let log_file = dir.join("events.jsonl");
    fs::create_dir(format!("{}.lock.d", log_file.display())).unwrap();
    let mut child = bin()
        .args(["append-jsonl", log_file.to_str().unwrap()])
        .env("VIBEGUARD_LOG_LOCK_ATTEMPTS", "0")
        .env("VIBEGUARD_LOG_LOCK_SLEEP_SECONDS", "0.05")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"{\"locked\":true}")
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(out.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("after 1 attempts"),
        "zero lock attempts should coerce to one attempt: {stderr}"
    );
    let _ = fs::remove_dir_all(dir);
}

#[cfg(unix)]
#[test]
fn append_jsonl_command_tightens_existing_file_permissions() {
    let dir = unique_temp_dir("append-jsonl-permissions");
    fs::create_dir_all(&dir).unwrap();
    let log_file = dir.join("events.jsonl");
    fs::write(&log_file, "{\"old\":true}\n").unwrap();
    fs::set_permissions(&log_file, fs::Permissions::from_mode(0o644)).unwrap();

    let mut child = bin()
        .args(["append-jsonl", log_file.to_str().unwrap()])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"{\"new\":true}")
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(
        out.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(file_mode(&log_file), 0o600);
    let content = fs::read_to_string(&log_file).unwrap();
    assert!(content.contains("{\"old\":true}\n{\"new\":true}\n"));
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn known_command_exits_0() {
    let mut child = bin()
        .args(["json-field", "tool"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"{\"tool\": \"bash\"}")
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(
        out.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}

#[test]
fn missing_field_exits_0_with_blank_stdout() {
    let mut child = bin()
        .args(["json-field", "missing"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"{\"tool\": \"bash\"}")
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(
        out.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(String::from_utf8_lossy(&out.stdout), "\n");
}

#[test]
fn strict_missing_field_exits_1_with_error() {
    let mut child = bin()
        .args(["json-field", "--strict", "missing"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"{\"tool\": \"bash\"}")
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("missing field: missing"),
        "expected missing-field error in stderr: {stderr}"
    );
}

#[test]
fn strict_empty_string_exits_0_with_blank_stdout() {
    let mut child = bin()
        .args(["json-field", "--strict", "tool"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"{\"tool\": \"\"}")
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(
        out.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(String::from_utf8_lossy(&out.stdout), "\n");
}

#[test]
fn strict_null_field_exits_1_with_error() {
    let mut child = bin()
        .args(["json-field", "--strict", "tool"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"{\"tool\": null}")
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(out.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("null field: tool"),
        "expected null-field error in stderr: {stderr}"
    );
}

#[test]
fn invalid_json_exits_1() {
    let mut child = bin()
        .args(["json-field", "tool"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(b"not-json").unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(out.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("vibeguard-runtime error:"),
        "expected 'vibeguard-runtime error:' in stderr: {stderr}"
    );
}

#[test]
fn invalid_json_two_fields_exits_1() {
    let mut child = bin()
        .args(["json-two-fields", "tool", "session"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(b"not-json").unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(out.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("vibeguard-runtime error:"),
        "expected 'vibeguard-runtime error:' in stderr: {stderr}"
    );
}

#[test]
fn handler_bad_args_exits_1() {
    let out = bin()
        .arg("json-field")
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("vibeguard-runtime error:"),
        "expected 'vibeguard-runtime error:' in stderr: {stderr}"
    );
}

#[test]
fn paralysis_count_ignores_old_read_only_events() {
    let mut child = bin()
        .args(["paralysis-count", "sess-A"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"{\"session\":\"sess-A\",\"tool\":\"Read\",\"ts\":\"1970-01-01T00:00:00Z\"}\n")
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "0\n");
}

#[test]
fn paralysis_count_keeps_legacy_events_without_ts() {
    let mut child = bin()
        .args(["paralysis-count", "sess-A"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"{\"session\":\"sess-A\",\"tool\":\"Read\"}\n")
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "1\n");
}
