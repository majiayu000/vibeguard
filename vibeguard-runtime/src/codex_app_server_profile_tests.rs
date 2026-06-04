use super::*;
use std::fs;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

#[test]
fn command_approval_minimal_profile_skips_analysis_observation() {
    let unique = match SystemTime::now().duration_since(UNIX_EPOCH) {
        Ok(duration) => duration.as_nanos(),
        Err(err) => panic!("system time should be after unix epoch: {err}"),
    };
    let root = std::env::temp_dir().join(format!(
        "vibeguard_runtime_profile_minimal_no_analysis_{}_{}",
        std::process::id(),
        unique
    ));
    if let Err(err) = fs::create_dir_all(&root) {
        panic!("temp dir should be created: {err}");
    }
    let repo_dir = root.to_string_lossy().to_string();
    if let Err(err) = fs::write(
        Path::new(&repo_dir).join(".vibeguard.json"),
        r#"{"profile":"minimal"}"#,
    ) {
        panic!("project policy should be written: {err}");
    }
    let hooks_dir = Path::new(&repo_dir).join("hooks");
    if let Err(err) = fs::create_dir_all(&hooks_dir) {
        panic!("hooks dir should be created: {err}");
    }
    if let Err(err) = fs::write(
        hooks_dir.join("pre-bash-guard.sh"),
        r#"#!/usr/bin/env bash
cat >/dev/null
printf '{"decision":"pass"}\n'
"#,
    ) {
        panic!("hook should be written: {err}");
    }
    let mut strategy = match VibeGuardGateStrategy::new(&repo_dir, Some("guarded")) {
        Ok(strategy) => strategy,
        Err(err) => panic!("strategy should init: {err}"),
    };
    let mut state = SessionState::default();
    strategy.on_client_message(
        &json!({"method": "thread/start", "params": {"threadId": "thread-minimal", "cwd": repo_dir}}),
        &mut state,
    );

    let mut outputs = Vec::new();
    for i in 0..3 {
        let handled = strategy.handle_server_request(
            &json!({
                "id": format!("req-minimal-{i}"),
                "method": "item/commandExecution/requestApproval",
                "params": {"threadId": "thread-minimal", "command": "rg TODO src"}
            }),
            &mut state,
            &mut |value| outputs.push(value),
        );
        assert!(!handled);
    }

    let rendered = outputs.iter().map(Value::to_string).collect::<String>();
    let thread = match state.threads.get("thread-minimal") {
        Some(thread) => thread,
        None => panic!("thread should exist"),
    };
    assert_eq!(thread.research_streak, 0);
    assert!(!rendered.contains("analysis paralysis warning"));

    if let Err(err) = fs::remove_dir_all(&repo_dir) {
        panic!("temp strategy dir should be removed: {err}");
    }
}
