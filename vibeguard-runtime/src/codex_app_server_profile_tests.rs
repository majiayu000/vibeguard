use super::*;
use std::fs;
use std::time::{SystemTime, UNIX_EPOCH};

fn temp_profile_repo(name: &str, policy: &str, pre_bash_hook: bool) -> String {
    let unique = match SystemTime::now().duration_since(UNIX_EPOCH) {
        Ok(duration) => duration.as_nanos(),
        Err(err) => panic!("system time should be after unix epoch: {err}"),
    };
    let root = std::env::temp_dir().join(format!(
        "vibeguard_runtime_profile_{name}_{}_{}",
        std::process::id(),
        unique
    ));
    if let Err(err) = fs::create_dir_all(&root) {
        panic!("temp dir should be created: {err}");
    }
    let repo_dir = root.to_string_lossy().to_string();
    if let Err(err) = fs::write(root.join(".vibeguard.json"), policy) {
        panic!("project policy should be written: {err}");
    }
    if !pre_bash_hook {
        return repo_dir;
    }
    let hooks_dir = root.join("hooks");
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
    repo_dir
}

fn run_read_approvals(repo_dir: &str, thread_id: &str) -> (SessionState, String) {
    let mut strategy = match VibeGuardGateStrategy::new(repo_dir, Some("guarded")) {
        Ok(strategy) => strategy,
        Err(err) => panic!("strategy should init: {err}"),
    };
    let mut state = SessionState::default();
    strategy.on_client_message(
        &json!({"method": "thread/start", "params": {"threadId": thread_id, "cwd": repo_dir}}),
        &mut state,
    );

    let mut outputs = Vec::new();
    for i in 0..3 {
        let handled = strategy.handle_server_request(
            &json!({
                "id": format!("req-{thread_id}-{i}"),
                "method": "item/commandExecution/requestApproval",
                "params": {"threadId": thread_id, "command": "rg TODO src"}
            }),
            &mut state,
            &mut |value| outputs.push(value),
        );
        assert!(!handled);
    }

    (state, outputs.iter().map(Value::to_string).collect())
}

#[test]
fn command_approval_minimal_profile_skips_analysis_observation() {
    let repo_dir = temp_profile_repo("minimal_no_analysis", r#"{"profile":"minimal"}"#, true);
    let (state, rendered) = run_read_approvals(&repo_dir, "thread-minimal");
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

#[test]
fn command_approval_disabled_pre_bash_keeps_analysis_observation() {
    let repo_dir = temp_profile_repo(
        "disabled_pre_bash_analysis",
        r#"{"disabled_hooks":["pre-bash-guard"]}"#,
        false,
    );
    let (state, rendered) = run_read_approvals(&repo_dir, "thread-disabled-pre-bash");
    let thread = match state.threads.get("thread-disabled-pre-bash") {
        Some(thread) => thread,
        None => panic!("thread should exist"),
    };
    assert_eq!(thread.research_streak, 3);
    assert!(rendered.contains("disabled_hooks contains pre-bash-guard"));

    if let Err(err) = fs::remove_dir_all(&repo_dir) {
        panic!("temp strategy dir should be removed: {err}");
    }
}
