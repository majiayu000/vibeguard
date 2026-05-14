use super::*;
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
