use serde_json::{Value, json};
use std::io::Write;
use std::process::{Command, Output, Stdio};

fn write_hook(switch: Option<&str>, path: &str) -> Output {
    write_hook_in(switch, path, None)
}

fn write_hook_in(switch: Option<&str>, path: &str, temp_dir: Option<&str>) -> Output {
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
    if let Some(dir) = temp_dir {
        command.env("TMPDIR", dir);
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

#[test]
fn a_temporary_directory_that_names_no_directory_refuses_nothing_else() {
    // A wrapper that writes `TMPDIR=` or sets it to "." or "/" doesn't make every page
    // temporary; the fixed roots still count.
    for dir in ["", ".", "/"] {
        let kept = write_hook_in(Some("deny"), "/nowhere/pages/demo.html", Some(dir));
        assert_eq!(kept.status.code(), Some(0), "{dir:?}");
        let words = String::from_utf8_lossy(&kept.stdout);
        assert!(words.is_empty(), "{dir:?}: {words}");
        let temp = write_hook_in(Some("deny"), "/tmp/demo.html", Some(dir));
        let reply: Value = serde_json::from_slice(&temp.stdout).unwrap();
        assert_eq!(reply["hookSpecificOutput"]["permissionDecision"], "deny");
    }
}
