use super::VibeGuardGateStrategy;
use crate::codex_app_server_core::{GateStrategy, SessionState};
use serde_json::json;
use std::{
    fs,
    path::Path,
    time::{SystemTime, UNIX_EPOCH},
};

fn scoped_test_temp_dir(name: &str) -> String {
    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let root = std::env::temp_dir().join(format!(
        "vibeguard_runtime_scoped_{name}_{}_{}",
        std::process::id(),
        unique
    ));
    fs::create_dir_all(&root).expect("temp dir should be created");
    root.to_string_lossy().to_string()
}

fn write_scoped_test_hook(repo_dir: &str, name: &str, body: &str) {
    let hooks_dir = Path::new(repo_dir).join("hooks");
    fs::create_dir_all(&hooks_dir).expect("hooks dir should be created");
    fs::write(hooks_dir.join(name), body).expect("hook should be written");
}

fn write_scoped_test_project_policy(repo_dir: &str, body: &str) {
    fs::write(Path::new(repo_dir).join(".vibeguard.json"), body)
        .expect("project policy should be written");
}

#[test]
fn file_change_post_hooks_apply_scoped_suppression() {
    let repo_dir = scoped_test_temp_dir("file_change_post_hook");
    write_scoped_test_project_policy(
        &repo_dir,
        r#"{"scoped_suppressions":[{"hook":"post-edit-guard","rule_id":"RS-03","path":"src/lib.rs","action":"suppress","reason":"Known documentation example false positive"}]}"#,
    );
    write_scoped_test_hook(
        &repo_dir,
        "pre-edit-guard.sh",
        r#"#!/usr/bin/env bash
cat >/dev/null
printf '{"decision":"pass"}\n'
"#,
    );
    write_scoped_test_hook(
        &repo_dir,
        "post-edit-guard.sh",
        r#"#!/usr/bin/env bash
cat >/dev/null
printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"VIBEGUARD quality warning: [RS-03] unwrap should be hidden"}}\n'
"#,
    );
    let mut strategy =
        VibeGuardGateStrategy::new(&repo_dir, Some("guarded")).expect("strategy should init");
    let mut state = SessionState::default();
    strategy.on_client_message(
        &json!({"method": "thread/start", "params": {"threadId": "thread-scoped", "cwd": repo_dir}}),
        &mut state,
    );
    strategy.on_server_notification(
        json!({
            "method": "item/started",
            "params": {
                "threadId": "thread-scoped",
                "turnId": "turn-scoped",
                "item": {
                    "id": "item-scoped",
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

    let completed = strategy.on_server_notification(
        json!({
            "method": "item/completed",
            "params": {
                "threadId": "thread-scoped",
                "turnId": "turn-scoped",
                "item": {
                    "id": "item-scoped",
                    "type": "fileChange",
                    "status": "completed"
                }
            }
        }),
        &mut state,
    );

    let completed_text = completed.to_string();
    assert!(!completed_text.contains("unwrap should be hidden"));
    assert!(!completed_text.contains("VIBEGUARD scoped suppression"));

    let _ = fs::remove_dir_all(repo_dir);
}
