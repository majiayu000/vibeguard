mod common;

use common::bin;
use std::io::Write;
use std::process::Stdio;

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
fn missing_field_exits_0_with_blank_stdout() {
    let mut child = bin()
        .args(["json-field", "missing"])
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
    assert_eq!(String::from_utf8_lossy(&out.stdout), "\n");
}

#[test]
fn strict_missing_field_exits_1_with_error() {
    let mut child = bin()
        .args(["json-field", "--strict", "missing"])
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
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("missing field: missing"),
        "expected missing-field error in stderr: {stderr}"
    );
}

#[test]
fn strict_empty_string_exits_0_with_blank_stdout() {
    let mut child = bin()
        .args(["json-field", "--strict", "tool"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"{\"tool\": \"\"}")
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(
        out.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(String::from_utf8_lossy(&out.stdout), "\n");
}

#[test]
fn strict_null_field_exits_1_with_error() {
    let mut child = bin()
        .args(["json-field", "--strict", "tool"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"{\"tool\": null}")
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(out.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("null field: tool"),
        "expected null-field error in stderr: {stderr}"
    );
}

#[test]
fn invalid_json_exits_1() {
    let mut child = bin()
        .args(["json-field", "tool"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(b"not-json").unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(out.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("vibeguard-runtime error:"),
        "expected 'vibeguard-runtime error:' in stderr: {stderr}"
    );
}

#[test]
fn invalid_json_two_fields_exits_1() {
    let mut child = bin()
        .args(["json-two-fields", "tool", "session"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(b"not-json").unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(out.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("vibeguard-runtime error:"),
        "expected 'vibeguard-runtime error:' in stderr: {stderr}"
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
        stderr.contains("vibeguard-runtime error:"),
        "expected 'vibeguard-runtime error:' in stderr: {stderr}"
    );
}

#[test]
fn paralysis_count_ignores_old_read_only_events() {
    let mut child = bin()
        .args(["paralysis-count", "sess-A"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"{\"session\":\"sess-A\",\"tool\":\"Read\",\"ts\":\"1970-01-01T00:00:00Z\"}\n")
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "0\n");
}

#[test]
fn paralysis_count_keeps_legacy_events_without_ts() {
    let mut child = bin()
        .args(["paralysis-count", "sess-A"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"{\"session\":\"sess-A\",\"tool\":\"Read\"}\n")
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "1\n");
}
