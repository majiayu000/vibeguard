use serde_json::{Value, json};
use std::io::Write;
use std::process::{Command, Output, Stdio};

fn write_hook(switch: Option<&str>, path: &str) -> Output {
    let input = json!({
        "hook_event_name": "PreToolUse",
        "tool_name": "Write",
        "cwd": "/repo",
        "tool_input": {"file_path": path, "content": "<!doctype html>"}
    })
    .to_string();
    let mut command = Command::new(env!("CARGO_BIN_EXE_vibeguard-runtime"));
    command
        .args(["hook", "claude"])
        .env_remove("VIBEGUARD_TEMP_PAGES")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(value) = switch {
        command.env("VIBEGUARD_TEMP_PAGES", value);
    }
    let mut child = command.spawn().unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(input.as_bytes())
        .unwrap();
    child.wait_with_output().unwrap()
}

#[test]
fn off_unless_switched_on() {
    let output = write_hook(None, "/tmp/demo.html");
    assert_eq!(output.status.code(), Some(0));
    assert!(output.stdout.is_empty());
}

#[test]
fn switched_on_it_denies_through_the_native_protocol() {
    let output = write_hook(Some("deny"), "/tmp/demo.html");
    assert_eq!(output.status.code(), Some(0));
    let reply: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(reply["hookSpecificOutput"]["permissionDecision"], "deny");
    let quiet = write_hook(Some("deny"), "/nowhere/pages/demo.html");
    assert_eq!(quiet.status.code(), Some(0));
    assert!(quiet.stdout.is_empty());
}

#[test]
fn a_mistyped_switch_is_a_visible_error() {
    let output = write_hook(Some("yes"), "/nowhere/pages/demo.html");
    assert_eq!(output.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&output.stderr).contains("VIBEGUARD_TEMP_PAGES"));
}
