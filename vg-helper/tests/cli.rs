use std::io::Write;
use std::process::{Command, Stdio};

fn bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_vg-helper"))
}

#[test]
fn no_args_exits_2() {
    let out = bin().output().unwrap();
    assert_eq!(out.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("Usage:"), "expected 'Usage:' in stderr: {stderr}");
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
fn help_lists_all_8_commands() {
    let out = bin().output().unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr);
    for name in &[
        "json-field",
        "json-two-fields",
        "churn-count",
        "warn-count",
        "build-fails",
        "paralysis-count",
        "pkg-rewrite",
        "session-metrics",
    ] {
        assert!(
            stderr.contains(name),
            "expected '{name}' in help output: {stderr}"
        );
    }
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
fn handler_bad_args_exits_1() {
    let out = bin()
        .arg("json-field")
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("vg-helper error:"),
        "expected 'vg-helper error:' in stderr: {stderr}"
    );
}
