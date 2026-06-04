use super::*;
use crate::codex_app_server_core::file_change_key;
use std::fs;
use std::time::{SystemTime, UNIX_EPOCH};

fn temp_dir(name: &str) -> String {
    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let root = std::env::temp_dir().join(format!(
        "vibeguard_runtime_strategy_{name}_{}_{}",
        std::process::id(),
        unique
    ));
    fs::create_dir_all(&root).expect("temp dir should be created");
    root.to_string_lossy().to_string()
}

fn write_hook(repo_dir: &str, name: &str, body: &str) {
    let hooks_dir = Path::new(repo_dir).join("hooks");
    fs::create_dir_all(&hooks_dir).expect("hooks dir should be created");
    fs::write(hooks_dir.join(name), body).expect("hook should be written");
}

fn write_project_policy(repo_dir: &str, body: &str) {
    fs::write(Path::new(repo_dir).join(".vibeguard.json"), body)
        .expect("project policy should be written");
}

#[test]
fn analysis_strategy_classifies_read_and_write_commands() {
    let analysis = AnalysisParalysisStrategy::new().expect("regexes should compile");

    assert!(analysis.read_re.is_match("rg TODO src"));
    assert!(analysis.read_re.is_match("git diff -- src/lib.rs"));
    assert!(analysis.write_re.is_match("apply_patch <<'PATCH'"));
    assert!(analysis.write_re.is_match("git commit -m fix"));
    assert!(analysis.threshold >= 1);
}

#[test]
fn client_messages_record_thread_context() {
    let repo_dir = temp_dir("thread_context");
    let mut strategy =
        VibeGuardGateStrategy::new(&repo_dir, Some("advisory")).expect("strategy should init");
    let mut state = SessionState::default();

    strategy.on_client_message(
        &json!({"method": "thread/start", "params": {"threadId": "thread-1", "cwd": repo_dir}}),
        &mut state,
    );
    strategy.on_client_message(
        &json!({"method": "turn/start", "params": {"threadId": "thread-1", "turnId": "turn-1"}}),
        &mut state,
    );

    let thread = state.threads.get("thread-1").expect("thread should exist");
    assert!(thread.cwd.is_some());
    assert_eq!(thread.turn_id.as_deref(), Some("turn-1"));
    assert!(
        thread
            .session_id
            .as_deref()
            .is_some_and(|id| id.starts_with("codex-thread-thread-1-"))
    );

    let _ = fs::remove_dir_all(thread.cwd.as_deref().unwrap_or_default());
}

#[test]
fn patch_update_records_pending_file_changes() {
    let repo_dir = temp_dir("patch_update");
    let mut strategy =
        VibeGuardGateStrategy::new(&repo_dir, Some("advisory")).expect("strategy should init");
    let mut state = SessionState::default();

    strategy.on_server_notification(
        json!({
            "method": "item/fileChange/patchUpdated",
            "params": {
                "threadId": "thread-2",
                "turnId": "turn-2",
                "itemId": "item-2",
                "changes": [{"path": "src/lib.rs", "kind": "update", "diff": "@@\n-old\n+new\n"}]
            }
        }),
        &mut state,
    );

    let thread = state.threads.get("thread-2").expect("thread should exist");
    let key = file_change_key(Some("turn-2"), Some("item-2")).expect("key should build");
    let patches = thread
        .pending_file_changes
        .get(&key)
        .expect("patches should be cached");

    assert_eq!(thread.turn_id.as_deref(), Some("turn-2"));
    assert_eq!(patches[0].normalized_kind(), "update");

    let _ = fs::remove_dir_all(repo_dir);
}

#[test]
fn command_approval_skips_disabled_pre_bash_policy() {
    let repo_dir = temp_dir("disabled_pre_bash");
    write_project_policy(
        &repo_dir,
        r#"{"enforcement":"warn","disabled_hooks":["pre-bash-guard"]}"#,
    );
    write_hook(
        &repo_dir,
        "pre-bash-guard.sh",
        r#"#!/usr/bin/env bash
cat >/dev/null
printf '{"decision":"block","reason":"should not run"}\n'
"#,
    );
    let mut strategy =
        VibeGuardGateStrategy::new(&repo_dir, Some("guarded")).expect("strategy should init");
    let mut state = SessionState::default();
    strategy.on_client_message(
        &json!({"method": "thread/start", "params": {"threadId": "thread-policy", "cwd": repo_dir}}),
        &mut state,
    );

    let mut outputs = Vec::new();
    let handled = strategy.handle_server_request(
        &json!({
            "id": "req-policy",
            "method": "item/commandExecution/requestApproval",
            "params": {"threadId": "thread-policy", "command": "rm -rf /"}
        }),
        &mut state,
        &mut |value| outputs.push(value),
    );

    assert!(!handled);
    assert!(outputs.iter().any(|value| {
        value
            .to_string()
            .contains("disabled_hooks contains pre-bash-guard")
    }));
    assert!(
        !outputs
            .iter()
            .any(|value| value.to_string().contains("\"decision\":\"decline\""))
    );

    let _ = fs::remove_dir_all(repo_dir);
}

#[test]
fn command_policy_skip_does_not_emit_analysis_warnings() {
    let repo_dir = temp_dir("policy_skip_no_analysis");
    write_project_policy(&repo_dir, r#"{"enforcement":"off"}"#);
    let mut strategy =
        VibeGuardGateStrategy::new(&repo_dir, Some("guarded")).expect("strategy should init");
    let mut state = SessionState::default();
    strategy.on_client_message(
        &json!({"method": "thread/start", "params": {"threadId": "thread-off", "cwd": repo_dir}}),
        &mut state,
    );

    let mut outputs = Vec::new();
    for i in 0..7 {
        let handled = strategy.handle_server_request(
            &json!({
                "id": format!("req-off-{i}"),
                "method": "item/commandExecution/requestApproval",
                "params": {"threadId": "thread-off", "command": "rg TODO src"}
            }),
            &mut state,
            &mut |value| outputs.push(value),
        );
        assert!(!handled);
    }

    let rendered = outputs.iter().map(Value::to_string).collect::<String>();
    assert!(rendered.contains("enforcement=off"));
    assert!(!rendered.contains("analysis paralysis warning"));

    let _ = fs::remove_dir_all(repo_dir);
}

#[test]
fn command_approval_fails_closed_when_required_pre_bash_missing() {
    let repo_dir = temp_dir("missing_pre_bash");
    fs::create_dir_all(Path::new(&repo_dir).join("hooks")).expect("hooks dir should be created");
    let mut strategy =
        VibeGuardGateStrategy::new(&repo_dir, Some("guarded")).expect("strategy should init");
    let mut state = SessionState::default();
    strategy.on_client_message(
        &json!({"method": "thread/start", "params": {"threadId": "thread-missing", "cwd": repo_dir}}),
        &mut state,
    );

    let mut outputs = Vec::new();
    let handled = strategy.handle_server_request(
        &json!({
            "id": "req-missing",
            "method": "item/commandExecution/requestApproval",
            "params": {"threadId": "thread-missing", "command": "rm -rf /"}
        }),
        &mut state,
        &mut |value| outputs.push(value),
    );

    assert!(handled);
    assert!(outputs.iter().any(|value| {
        value.get("id").and_then(Value::as_str) == Some("req-missing")
            && value
                .get("result")
                .and_then(|v| v.get("decision"))
                .and_then(Value::as_str)
                == Some("decline")
    }));
    assert!(outputs.iter().any(|value| {
        value
            .to_string()
            .contains("missing required hook pre-bash-guard.sh")
    }));

    let _ = fs::remove_dir_all(repo_dir);
}

#[test]
fn command_approval_reports_invalid_project_policy() {
    let repo_dir = temp_dir("invalid_policy");
    write_project_policy(&repo_dir, "{");
    write_hook(
        &repo_dir,
        "pre-bash-guard.sh",
        r#"#!/usr/bin/env bash
cat >/dev/null
printf '{"decision":"pass"}\n'
"#,
    );
    let mut strategy =
        VibeGuardGateStrategy::new(&repo_dir, Some("guarded")).expect("strategy should init");
    let mut state = SessionState::default();
    strategy.on_client_message(
        &json!({"method": "thread/start", "params": {"threadId": "thread-invalid", "cwd": repo_dir}}),
        &mut state,
    );

    let mut outputs = Vec::new();
    let handled = strategy.handle_server_request(
        &json!({
            "id": "req-invalid",
            "method": "item/commandExecution/requestApproval",
            "params": {"threadId": "thread-invalid", "command": "cargo test"}
        }),
        &mut state,
        &mut |value| outputs.push(value),
    );

    assert!(handled);
    assert!(
        outputs
            .iter()
            .any(|value| value.to_string().contains("project config invalid JSON"))
    );

    let _ = fs::remove_dir_all(repo_dir);
}

#[test]
fn command_approval_downgrades_blocking_hook_in_project_warn_mode() {
    let repo_dir = temp_dir("warn_policy");
    write_project_policy(&repo_dir, r#"{"enforcement":"warn"}"#);
    write_hook(
        &repo_dir,
        "pre-bash-guard.sh",
        r#"#!/usr/bin/env bash
cat >/dev/null
printf '{"decision":"block","reason":"dangerous command"}\n'
"#,
    );
    let mut strategy =
        VibeGuardGateStrategy::new(&repo_dir, Some("guarded")).expect("strategy should init");
    let mut state = SessionState::default();
    strategy.on_client_message(
        &json!({"method": "thread/start", "params": {"threadId": "thread-warn", "cwd": repo_dir}}),
        &mut state,
    );

    let mut outputs = Vec::new();
    let handled = strategy.handle_server_request(
        &json!({
            "id": "req-warn",
            "method": "item/commandExecution/requestApproval",
            "params": {"threadId": "thread-warn", "command": "rm -rf /tmp/demo"}
        }),
        &mut state,
        &mut |value| outputs.push(value),
    );

    assert!(!handled);
    assert!(outputs.iter().any(|value| {
        value
            .to_string()
            .contains("warn-mode advisory: dangerous command")
    }));
    assert!(
        !outputs
            .iter()
            .any(|value| value.to_string().contains("\"decision\":\"decline\""))
    );

    let _ = fs::remove_dir_all(repo_dir);
}

#[cfg(test)]
mod file_change_approval_tests {
    use super::*;

    #[test]
    fn item_started_file_change_approval_uses_cached_changes() {
        let repo_dir = temp_dir("item_started_file_change");
        write_hook(
            &repo_dir,
            "pre-write-guard.sh",
            r#"#!/usr/bin/env bash
cat >/dev/null
printf '{"decision":"block","reason":"blocked from item started"}\n'
"#,
        );
        let mut strategy =
            VibeGuardGateStrategy::new(&repo_dir, Some("guarded")).expect("strategy should init");
        let mut state = SessionState::default();

        strategy.on_server_notification(
        json!({
            "method": "item/started",
            "params": {
                "threadId": "thread-started",
                "turnId": "turn-started",
                "item": {
                    "id": "item-started",
                    "type": "fileChange",
                    "changes": [{"path": "src/lib.rs", "kind": "add", "diff": "@@\n+fn main() {}\n"}]
                }
            }
        }),
        &mut state,
    );

        let mut outputs = Vec::new();
        let handled = strategy.handle_server_request(
            &json!({
                "id": "req-started",
                "method": "item/fileChange/requestApproval",
                "params": {
                    "threadId": "thread-started",
                    "turnId": "turn-started",
                    "itemId": "item-started"
                }
            }),
            &mut state,
            &mut |value| outputs.push(value),
        );

        assert!(handled);
        assert!(outputs.iter().any(|value| {
            value.get("id").and_then(Value::as_str) == Some("req-started")
                && value
                    .get("result")
                    .and_then(|v| v.get("decision"))
                    .and_then(Value::as_str)
                    == Some("decline")
        }));
        assert!(
            outputs
                .iter()
                .any(|value| { value.to_string().contains("blocked from item started") })
        );

        let _ = fs::remove_dir_all(repo_dir);
    }

    #[test]
    fn delete_file_changes_run_pre_edit_guard() {
        let repo_dir = temp_dir("delete_file_change");
        write_hook(
            &repo_dir,
            "pre-edit-guard.sh",
            r#"#!/usr/bin/env bash
cat >/dev/null
printf '{"decision":"block","reason":"protected delete"}\n'
"#,
        );
        let mut strategy =
            VibeGuardGateStrategy::new(&repo_dir, Some("guarded")).expect("strategy should init");
        let mut state = SessionState::default();

        strategy.on_server_notification(
            json!({
                "method": "item/started",
                "params": {
                    "threadId": "thread-delete",
                    "turnId": "turn-delete",
                    "item": {
                        "id": "item-delete",
                        "type": "fileChange",
                        "changes": [{
                            "path": "conftest.py",
                            "kind": "delete",
                            "diff": "--- a/conftest.py\n+++ /dev/null\n@@\n-fixture\n"
                        }]
                    }
                }
            }),
            &mut state,
        );

        let mut outputs = Vec::new();
        let handled = strategy.handle_server_request(
            &json!({
                "id": "req-delete",
                "method": "item/fileChange/requestApproval",
                "params": {
                    "threadId": "thread-delete",
                    "turnId": "turn-delete",
                    "itemId": "item-delete"
                }
            }),
            &mut state,
            &mut |value| outputs.push(value),
        );

        assert!(handled);
        assert!(outputs.iter().any(|value| {
            value.get("id").and_then(Value::as_str) == Some("req-delete")
                && value
                    .get("result")
                    .and_then(|v| v.get("decision"))
                    .and_then(Value::as_str)
                    == Some("decline")
        }));
        assert!(
            outputs
                .iter()
                .any(|value| value.to_string().contains("protected delete"))
        );

        let _ = fs::remove_dir_all(repo_dir);
    }

    #[test]
    fn file_change_post_hooks_wait_for_item_completed() {
        let repo_dir = temp_dir("file_change_completed");
        write_hook(
            &repo_dir,
            "pre-edit-guard.sh",
            r#"#!/usr/bin/env bash
cat >/dev/null
printf '{"decision":"pass"}\n'
"#,
        );
        write_hook(
            &repo_dir,
            "post-edit-guard.sh",
            r#"#!/usr/bin/env bash
cat >/dev/null
printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"post edit ran"}}\n'
"#,
        );
        let mut strategy =
            VibeGuardGateStrategy::new(&repo_dir, Some("guarded")).expect("strategy should init");
        let mut state = SessionState::default();
        strategy.on_client_message(
            &json!({"method": "thread/start", "params": {"threadId": "thread-post", "cwd": repo_dir}}),
            &mut state,
        );

        strategy.on_server_notification(
            json!({
                "method": "item/started",
                "params": {
                    "threadId": "thread-post",
                    "turnId": "turn-post",
                    "item": {
                        "id": "item-post",
                        "type": "fileChange",
                        "changes": [{
                            "path": "src/lib.rs",
                            "kind": "update",
                            "diff": "--- a/src/lib.rs\n+++ b/src/lib.rs\n@@\n-old\n+new\n"
                        }]
                    }
                }
            }),
            &mut state,
        );

        let mut outputs = Vec::new();
        let handled = strategy.handle_server_request(
            &json!({
                "id": "req-post",
                "method": "item/fileChange/requestApproval",
                "params": {
                    "threadId": "thread-post",
                    "turnId": "turn-post",
                    "itemId": "item-post"
                }
            }),
            &mut state,
            &mut |value| outputs.push(value),
        );

        assert!(!handled);
        assert!(
            !outputs
                .iter()
                .any(|value| value.to_string().contains("post edit ran"))
        );

        let completed = strategy.on_server_notification(
            json!({
                "method": "item/completed",
                "params": {
                    "threadId": "thread-post",
                    "turnId": "turn-post",
                    "item": {
                        "id": "item-post",
                        "type": "fileChange",
                        "status": "completed"
                    }
                }
            }),
            &mut state,
        );

        assert!(completed.to_string().contains("post edit ran"));
        let thread = state
            .threads
            .get("thread-post")
            .expect("thread should exist");
        assert!(thread.pending_file_changes.is_empty());

        let _ = fs::remove_dir_all(repo_dir);
    }

    #[test]
    fn declined_file_change_drops_pending_patch_without_post_hooks() {
        let repo_dir = temp_dir("file_change_declined");
        write_hook(
            &repo_dir,
            "pre-edit-guard.sh",
            r#"#!/usr/bin/env bash
cat >/dev/null
printf '{"decision":"pass"}\n'
"#,
        );
        write_hook(
            &repo_dir,
            "post-edit-guard.sh",
            r#"#!/usr/bin/env bash
cat >/dev/null
printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"post edit ran"}}\n'
"#,
        );
        let mut strategy =
            VibeGuardGateStrategy::new(&repo_dir, Some("guarded")).expect("strategy should init");
        let mut state = SessionState::default();

        strategy.on_server_notification(
            json!({
                "method": "item/started",
                "params": {
                    "threadId": "thread-declined",
                    "turnId": "turn-declined",
                    "item": {
                        "id": "item-declined",
                        "type": "fileChange",
                        "changes": [{
                            "path": "src/lib.rs",
                            "kind": "update",
                            "diff": "--- a/src/lib.rs\n+++ b/src/lib.rs\n@@\n-old\n+new\n"
                        }]
                    }
                }
            }),
            &mut state,
        );

        let mut outputs = Vec::new();
        let handled = strategy.handle_server_request(
            &json!({
                "id": "req-declined",
                "method": "item/fileChange/requestApproval",
                "params": {
                    "threadId": "thread-declined",
                    "turnId": "turn-declined",
                    "itemId": "item-declined"
                }
            }),
            &mut state,
            &mut |value| outputs.push(value),
        );
        assert!(!handled);

        let completed = strategy.on_server_notification(
            json!({
                "method": "item/completed",
                "params": {
                    "threadId": "thread-declined",
                    "turnId": "turn-declined",
                    "item": {
                        "id": "item-declined",
                        "type": "fileChange",
                        "status": "declined"
                    }
                }
            }),
            &mut state,
        );

        assert!(!completed.to_string().contains("post edit ran"));
        let thread = state
            .threads
            .get("thread-declined")
            .expect("thread should exist");
        assert!(thread.pending_file_changes.is_empty());

        let _ = fs::remove_dir_all(repo_dir);
    }

    #[test]
    fn file_change_flow_honors_disabled_pre_and_post_hooks() {
        let repo_dir = temp_dir("file_policy_disabled");
        write_project_policy(
            &repo_dir,
            r#"{"disabled_hooks":["pre-write-guard","post-write-guard"]}"#,
        );
        write_hook(
            &repo_dir,
            "pre-write-guard.sh",
            r#"#!/usr/bin/env bash
cat >/dev/null
printf '{"decision":"block","reason":"pre should not run"}\n'
"#,
        );
        write_hook(
            &repo_dir,
            "post-write-guard.sh",
            r#"#!/usr/bin/env bash
cat >/dev/null
printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"post should not run"}}\n'
"#,
        );
        let mut strategy =
            VibeGuardGateStrategy::new(&repo_dir, Some("guarded")).expect("strategy should init");
        let mut state = SessionState::default();
        strategy.on_client_message(
            &json!({"method": "thread/start", "params": {"threadId": "thread-file-policy", "cwd": repo_dir}}),
            &mut state,
        );
        strategy.on_server_notification(
            json!({
                "method": "item/started",
                "params": {
                    "threadId": "thread-file-policy",
                    "turnId": "turn-file-policy",
                    "item": {
                        "id": "item-file-policy",
                        "type": "fileChange",
                        "changes": [{"path": "new.py", "kind": "add", "diff": "@@\n+print('x')\n"}]
                    }
                }
            }),
            &mut state,
        );

        let mut outputs = Vec::new();
        let handled = strategy.handle_server_request(
            &json!({
                "id": "req-file-policy",
                "method": "item/fileChange/requestApproval",
                "params": {
                    "threadId": "thread-file-policy",
                    "turnId": "turn-file-policy",
                    "itemId": "item-file-policy"
                }
            }),
            &mut state,
            &mut |value| outputs.push(value),
        );

        assert!(!handled);
        assert!(outputs.iter().any(|value| {
            value
                .to_string()
                .contains("disabled_hooks contains pre-write-guard")
        }));
        assert!(
            !outputs
                .iter()
                .any(|value| value.to_string().contains("\"decision\":\"decline\""))
        );

        let completed = strategy.on_server_notification(
            json!({
                "method": "item/completed",
                "params": {
                    "threadId": "thread-file-policy",
                    "turnId": "turn-file-policy",
                    "item": {
                        "id": "item-file-policy",
                        "type": "fileChange",
                        "status": "completed"
                    }
                }
            }),
            &mut state,
        );

        assert!(
            completed
                .to_string()
                .contains("disabled_hooks contains post-write-guard")
        );
        assert!(!completed.to_string().contains("post should not run"));

        let _ = fs::remove_dir_all(repo_dir);
    }
}

#[test]
fn changed_files_filters_to_source_extensions() {
    let repo_dir = temp_dir("changed_files");
    let _ = Command::new("git")
        .arg("-C")
        .arg(&repo_dir)
        .arg("init")
        .output();
    fs::write(Path::new(&repo_dir).join("src.rs"), "fn main() {}\n")
        .expect("rust file should be written");
    fs::write(Path::new(&repo_dir).join("notes.md"), "# notes\n")
        .expect("markdown file should be written");

    assert_eq!(changed_files(&repo_dir), vec!["src.rs".to_string()]);

    let _ = fs::remove_dir_all(repo_dir);
}

#[test]
fn turn_completed_reads_nested_turn_payload() {
    let repo_dir = temp_dir("nested_turn_completed");
    write_hook(
        &repo_dir,
        "stop-guard.sh",
        r#"#!/usr/bin/env bash
cat >/dev/null
printf '{"stopReason":"stop ran"}\n'
"#,
    );
    let mut strategy =
        VibeGuardGateStrategy::new(&repo_dir, Some("advisory")).expect("strategy should init");
    let mut state = SessionState::default();
    strategy.on_client_message(
        &json!({"method": "thread/start", "params": {"threadId": "thread-nested", "cwd": repo_dir}}),
        &mut state,
    );
    state
        .ensure_thread("thread-nested")
        .pending_file_changes
        .insert("turn-nested:item-nested".into(), Vec::new());

    let completed = strategy.on_server_notification(
        json!({
            "method": "turn/completed",
            "params": {
                "turn": {
                    "id": "turn-nested",
                    "threadId": "thread-nested"
                }
            }
        }),
        &mut state,
    );

    assert!(completed.to_string().contains("stop ran"));
    let thread = state
        .threads
        .get("thread-nested")
        .expect("thread should exist");
    assert_eq!(thread.turn_id.as_deref(), Some("turn-nested"));
    assert!(thread.pending_file_changes.is_empty());

    let _ = fs::remove_dir_all(repo_dir);
}
