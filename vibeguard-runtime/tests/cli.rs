use std::io::Write;
use std::process::{Command, Stdio};

fn bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_vibeguard-runtime"))
}

#[test]
fn no_args_exits_2() {
    let out = bin().output().unwrap();
    assert_eq!(out.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("Usage:"),
        "expected 'Usage:' in stderr: {stderr}"
    );
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
fn help_lists_all_commands() {
    let out = bin().output().unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr);
    for name in &[
        "json-field",
        "json-two-fields",
        "config-get",
        "bash-preprocess",
        "allow-command-json",
        "churn-count",
        "warn-count",
        "post-edit-history",
        "build-fails",
        "paralysis-count",
        "pkg-rewrite",
        "session-metrics",
        "pre-write-check",
        "pre-edit-check",
        "post-edit-fast-check",
        "post-write-fast-check",
        "codex-app-server-wrapper",
    ] {
        assert!(
            stderr.contains(name),
            "expected '{name}' in help output: {stderr}"
        );
    }
}

#[test]
fn bash_preprocess_emits_nul_separated_derived_commands() {
    let command = "git commit -m \"docs; git checkout .\"\ncat <<'EOF'\nrm -rf /\nEOF\n";
    let mut child = bin()
        .arg("bash-preprocess")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(command.as_bytes())
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(
        out.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );

    let fields: Vec<&[u8]> = out.stdout.split(|byte| *byte == 0).collect();
    assert_eq!(fields.len(), 5, "expected 4 NUL-terminated fields");
    assert_eq!(
        String::from_utf8_lossy(fields[0]),
        "git commit -m \"docs; git checkout .\"\ncat <<'EOF'\n"
    );
    assert_eq!(
        String::from_utf8_lossy(fields[1]),
        "git commit -m \"\"\ncat <<''\n"
    );
    assert_eq!(
        String::from_utf8_lossy(fields[2]),
        "git commit -m docs; git checkout .\ncat <<EOF\n"
    );
    assert_eq!(
        String::from_utf8_lossy(fields[3]),
        "git commit -m \"\"\ncat <<''\n"
    );
}

#[test]
fn allow_command_json_emits_nested_updated_input() {
    let mut child = bin()
        .arg("allow-command-json")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"pnpm add \"a b\"")
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(
        out.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );

    let value: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(value["decision"], "allow");
    assert_eq!(value["updatedInput"]["command"], "pnpm add \"a b\"");
}

#[test]
fn config_get_extracts_typed_values() {
    let config_path = std::env::temp_dir().join(format!(
        "vibeguard-runtime-config-{}-{}.json",
        std::process::id(),
        "typed"
    ));
    std::fs::write(
        &config_path,
        r#"{"u16":{"limit":1234},"write_mode":"block"}"#,
    )
    .unwrap();

    let int_out = bin()
        .args([
            "config-get",
            "int",
            config_path.to_str().unwrap(),
            "u16.limit",
        ])
        .output()
        .unwrap();
    assert_eq!(
        int_out.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&int_out.stderr)
    );
    assert_eq!(String::from_utf8_lossy(&int_out.stdout), "1234\n");

    let string_out = bin()
        .args([
            "config-get",
            "string",
            config_path.to_str().unwrap(),
            "write_mode",
        ])
        .output()
        .unwrap();
    assert_eq!(
        string_out.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&string_out.stderr)
    );
    assert_eq!(String::from_utf8_lossy(&string_out.stdout), "block\n");

    let _ = std::fs::remove_file(config_path);
}

#[test]
fn config_get_rejects_missing_or_wrong_type() {
    let config_path = std::env::temp_dir().join(format!(
        "vibeguard-runtime-config-{}-{}.json",
        std::process::id(),
        "wrong-type"
    ));
    std::fs::write(&config_path, r#"{"u16":{"limit":"1234"}}"#).unwrap();

    let out = bin()
        .args([
            "config-get",
            "int",
            config_path.to_str().unwrap(),
            "u16.limit",
        ])
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(1));

    let missing = bin()
        .args([
            "config-get",
            "string",
            config_path.to_str().unwrap(),
            "write_mode",
        ])
        .output()
        .unwrap();
    assert_eq!(missing.status.code(), Some(1));

    let _ = std::fs::remove_file(config_path);
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
