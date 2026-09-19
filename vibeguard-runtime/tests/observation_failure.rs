use serde_json::{Value, json};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};

static SEQUENCE: AtomicU64 = AtomicU64::new(0);

struct TestDir(PathBuf);

impl TestDir {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "vibeguard-observation-failure-{}-{}",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).expect("create isolated test directory");
        Self(path)
    }

    fn blocked_state(&self) -> PathBuf {
        let path = self.0.join("state-is-a-file");
        fs::write(&path, b"preserve this user file").unwrap();
        path
    }
}

impl Drop for TestDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn invoke(host: &str, state: &Path, input: &Value) -> Output {
    let mut child = Command::new(env!("CARGO_BIN_EXE_vibeguard-runtime"))
        .args(["hook", host, "--state-dir"])
        .arg(state)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(serde_json::to_string(input).unwrap().as_bytes())
        .unwrap();
    child.wait_with_output().unwrap()
}

fn payload(event: &str, command: &str) -> Value {
    json!({
        "hook_event_name": event,
        "tool_name": "Bash",
        "tool_input": {"command": command},
        "tool_use_id": "observation-test",
        "cwd": "/repo"
    })
}

fn warning(output: &Output) -> Value {
    assert_eq!(
        output.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let value: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert!(value["systemMessage"].as_str().unwrap().contains("older"));
    assert!(String::from_utf8_lossy(&output.stderr).contains("optional observation"));
    value
}

#[test]
fn allowed_calls_are_not_blocked_by_observation_failure() {
    let dir = TestDir::new();
    let state = dir.blocked_state();
    for host in ["claude", "codex"] {
        let output = invoke(host, &state, &payload("PreToolUse", "echo private-canary"));
        let value = warning(&output);
        assert!(value.get("hookSpecificOutput").is_none());
        assert!(value.get("decision").is_none());
        assert!(value.get("continue").is_none());
        assert!(!String::from_utf8_lossy(&output.stdout).contains("private-canary"));
        assert!(!String::from_utf8_lossy(&output.stderr).contains("private-canary"));
    }
    assert_eq!(fs::read(&state).unwrap(), b"preserve this user file");
}

#[test]
fn denied_calls_keep_the_native_policy_decision() {
    let dir = TestDir::new();
    let state = dir.blocked_state();
    for host in ["claude", "codex"] {
        // This is JSON input to a recognizer. No Git cleanup command is executed.
        let value = warning(&invoke(host, &state, &payload("PreToolUse", "git clean -fd")));
        assert_eq!(value["hookSpecificOutput"]["hookEventName"], "PreToolUse");
        assert_eq!(value["hookSpecificOutput"]["permissionDecision"], "deny");
        assert!(
            value["hookSpecificOutput"]["permissionDecisionReason"]
                .as_str()
                .unwrap()
                .contains("Forced git clean")
        );
    }
}

#[test]
fn completed_tool_results_are_not_replaced_by_diagnostic_failure() {
    let dir = TestDir::new();
    let state = dir.blocked_state();
    for host in ["claude", "codex"] {
        for exit_code in [0, 1] {
            let mut input = payload("PostToolUse", "echo private-canary");
            input["tool_response"] = json!({"exit_code": exit_code});
            let value = warning(&invoke(host, &state, &input));
            assert!(value.get("decision").is_none());
            assert!(value.get("continue").is_none());
            assert!(value.get("hookSpecificOutput").is_none());
        }
    }
    let mut input = payload("PostToolUseFailure", "echo private-canary");
    input["error"] = json!("private-error-canary");
    let output = invoke("claude", &state, &input);
    let value = warning(&output);
    assert!(value.get("decision").is_none());
    assert!(!String::from_utf8_lossy(&output.stdout).contains("private-error-canary"));
    assert!(!String::from_utf8_lossy(&output.stderr).contains("private-error-canary"));
}

#[test]
fn protocol_errors_remain_errors_even_when_observations_are_unavailable() {
    let dir = TestDir::new();
    let state = dir.blocked_state();
    for host in ["claude", "codex"] {
        let output = invoke(host, &state, &json!({}));
        assert_eq!(output.status.code(), Some(2));
        assert!(output.stdout.is_empty());
        assert!(!String::from_utf8_lossy(&output.stderr).contains("optional observation"));
    }
}

#[test]
fn healthy_recording_preserves_quiet_success_and_real_outcomes() {
    let dir = TestDir::new();
    let state = dir.0.join("state");
    for host in ["claude", "codex"] {
        let mut input = payload("PostToolUse", "echo private-canary");
        input["tool_response"] = json!({"exit_code": 1});
        let output = invoke(host, &state, &input);
        assert_eq!(output.status.code(), Some(0));
        assert!(output.stdout.is_empty());
        assert!(output.stderr.is_empty());
        let bytes = fs::read(state.join(format!("{host}.json"))).unwrap();
        let record: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(record["outcome"], "exited_nonzero");
        assert_eq!(record["exit_code"], 1);
        assert!(!String::from_utf8_lossy(&bytes).contains("private-canary"));
    }
}
