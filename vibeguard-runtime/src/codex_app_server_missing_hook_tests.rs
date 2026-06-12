use super::*;
use std::fs;
use std::time::{SystemTime, UNIX_EPOCH};

fn temp_missing_hook_repo(name: &str) -> String {
    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let root = std::env::temp_dir().join(format!(
        "vibeguard_runtime_missing_hook_{name}_{}_{}",
        std::process::id(),
        unique
    ));
    fs::create_dir_all(&root).expect("temp dir should be created");
    root.to_string_lossy().to_string()
}

fn request_file_change(change: Value, expected_hook: &str) {
    let repo_dir = temp_missing_hook_repo(expected_hook);
    let mut strategy =
        VibeGuardGateStrategy::new(&repo_dir, Some("guarded")).expect("strategy should init");
    let mut state = SessionState::default();

    strategy.on_client_message(
        &json!({"method": "thread/start", "params": {"threadId": "thread-missing-hook", "cwd": repo_dir}}),
        &mut state,
    );
    strategy.on_server_notification(
        json!({
            "method": "item/started",
            "params": {
                "threadId": "thread-missing-hook",
                "turnId": "turn-missing-hook",
                "item": {
                    "id": "item-missing-hook",
                    "type": "fileChange",
                    "changes": [change]
                }
            }
        }),
        &mut state,
    );

    let mut outputs = Vec::new();
    let handled = strategy.handle_server_request(
        &json!({
            "id": "req-missing-hook",
            "method": "item/fileChange/requestApproval",
            "params": {
                "threadId": "thread-missing-hook",
                "turnId": "turn-missing-hook",
                "itemId": "item-missing-hook"
            }
        }),
        &mut state,
        &mut |value| outputs.push(value),
    );

    assert!(handled);
    assert!(outputs.iter().any(|value| {
        value.get("id").and_then(Value::as_str) == Some("req-missing-hook")
            && value
                .get("result")
                .and_then(|v| v.get("decision"))
                .and_then(Value::as_str)
                == Some("decline")
    }));
    assert!(outputs.iter().any(|value| {
        value
            .to_string()
            .contains(&format!("missing required hook {expected_hook}"))
    }));

    let _ = fs::remove_dir_all(repo_dir);
}

#[test]
fn file_change_add_fails_closed_when_pre_write_hook_missing() {
    request_file_change(
        json!({"path": "new.py", "kind": "add", "diff": "@@\n+print('x')\n"}),
        "pre-write-guard.sh",
    );
}

#[test]
fn file_change_update_fails_closed_when_pre_edit_hook_missing() {
    request_file_change(
        json!({"path": "src/lib.rs", "kind": "update", "diff": "--- a/src/lib.rs\n+++ b/src/lib.rs\n@@\n-old\n+new\n"}),
        "pre-edit-guard.sh",
    );
}
