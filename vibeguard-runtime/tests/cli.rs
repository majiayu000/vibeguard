use std::fs;
use std::io::Write;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};

fn bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_vibeguard-runtime"))
}

fn unique_temp_dir(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!(
        "vibeguard-runtime-{label}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ))
}

#[cfg(unix)]
fn file_mode(path: &std::path::Path) -> u32 {
    fs::metadata(path).unwrap().permissions().mode() & 0o777
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
        "churn-count",
        "warn-count",
        "post-edit-history",
        "build-fails",
        "paralysis-count",
        "append-jsonl",
        "circuit-breaker",
        "pkg-rewrite",
        "pre-bash-check",
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

fn run_pre_bash_check(input: &str) -> std::process::Output {
    let mut child = bin()
        .args(["pre-bash-check", "/repo"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(input.as_bytes())
        .unwrap();
    child.wait_with_output().unwrap()
}

#[test]
fn pre_bash_check_blocks_dangerous_command() {
    let out = run_pre_bash_check(r#"{"tool_input":{"command":"git checkout ."}}"#);
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.starts_with("BLOCK\n"), "{stdout}");
    assert!(stdout.contains("Disable git checkout/restore"), "{stdout}");
    assert!(
        stdout.contains("\\\"decision\\\": \\\"block\\\""),
        "{stdout}"
    );
}

#[test]
fn pre_bash_check_warns_for_nonstandard_markdown() {
    let out = run_pre_bash_check(r#"{"tool_input":{"command":"printf x > notes.md"}}"#);
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.starts_with("WARN\n"), "{stdout}");
    assert!(
        stdout.contains("\\\"hookEventName\\\": \\\"PreToolUse\\\""),
        "{stdout}"
    );
}

#[test]
fn pre_bash_check_reports_correction_payload() {
    let out = run_pre_bash_check(r#"{"tool_input":{"command":"npm install lodash"}}"#);
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.starts_with("CORRECTION\n"), "{stdout}");
    assert!(
        stdout.contains("\"corrected\":\"pnpm add lodash\""),
        "{stdout}"
    );
    assert!(
        stdout.contains("\\\"command\\\": \\\"pnpm add lodash\\\""),
        "{stdout}"
    );
}

#[test]
fn pre_bash_check_pass_marks_precommit_bridge() {
    let out = run_pre_bash_check(r#"{"tool_input":{"command":"git commit -m ok"}}"#);
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.starts_with("PASS\n"), "{stdout}");
    assert!(stdout.contains("\"precommit\":true"), "{stdout}");
}

#[test]
fn pre_bash_check_malformed_input_fails_closed() {
    let out = run_pre_bash_check(r#"{"tool_input":"#);
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.starts_with("BLOCK\n"), "{stdout}");
    assert!(
        stdout.contains("invalid Bash hook input JSON; fail-closed"),
        "{stdout}"
    );
}

fn run_circuit_breaker(
    action: &str,
    hook: &str,
    state_file: &std::path::Path,
    lock_file: &std::path::Path,
    session: &str,
) -> std::process::Output {
    bin()
        .args([
            "circuit-breaker",
            action,
            hook,
            state_file.to_str().unwrap(),
            lock_file.to_str().unwrap(),
            "2",
            "9999",
            "0",
        ])
        .env("VIBEGUARD_SESSION_ID", session)
        .output()
        .unwrap()
}

#[test]
fn circuit_breaker_command_opens_and_resets_state() {
    let dir = unique_temp_dir("circuit-breaker-state");
    let state_file = dir.join("hook.cb");
    let lock_file = dir.join("hook.cb.lock");

    let out = run_circuit_breaker("check", "cb-hook", &state_file, &lock_file, "session-a");
    assert_eq!(
        out.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(String::from_utf8_lossy(&out.stdout), "RUN\n");

    let out = run_circuit_breaker(
        "record-block",
        "cb-hook",
        &state_file,
        &lock_file,
        "session-a",
    );
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "RECORDED\n");

    let out = run_circuit_breaker(
        "record-block",
        "cb-hook",
        &state_file,
        &lock_file,
        "session-a",
    );
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("OPENED"));
    assert!(stdout.contains("CB tripped OPEN"));

    let out = run_circuit_breaker("check", "cb-hook", &state_file, &lock_file, "session-a");
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("AUTO_PASS"));
    assert!(stdout.contains("CB OPEN: auto-pass"));

    let out = run_circuit_breaker(
        "record-pass",
        "cb-hook",
        &state_file,
        &lock_file,
        "session-a",
    );
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "RECORDED\n");

    let out = run_circuit_breaker("check", "cb-hook", &state_file, &lock_file, "session-a");
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "RUN\n");

    let _ = fs::remove_dir_all(dir);
}

#[cfg(unix)]
#[test]
fn circuit_breaker_command_lock_timeout_is_error() {
    use std::os::fd::AsRawFd;

    let dir = unique_temp_dir("circuit-breaker-lock-timeout");
    fs::create_dir_all(&dir).unwrap();
    let state_file = dir.join("hook.cb");
    let lock_file = dir.join("hook.cb.lock");
    let file = fs::OpenOptions::new()
        .create(true)
        .write(true)
        .open(&lock_file)
        .unwrap();
    let lock_rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    assert_eq!(lock_rc, 0);

    let out = run_circuit_breaker("check", "cb-hook", &state_file, &lock_file, "session-a");
    assert_eq!(out.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("circuit breaker lock timeout"),
        "expected lock timeout in stderr: {stderr}"
    );

    unsafe {
        let _ = libc::flock(file.as_raw_fd(), libc::LOCK_UN);
    }
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn circuit_breaker_command_mkdir_lock_timeout_is_error() {
    let dir = unique_temp_dir("circuit-breaker-mkdir-lock-timeout");
    fs::create_dir_all(&dir).unwrap();
    let state_file = dir.join("hook.cb");
    let lock_file = dir.join("hook.cb.lock");
    fs::create_dir(&dir.join("hook.cb.lock.d")).unwrap();

    let out = run_circuit_breaker("check", "cb-hook", &state_file, &lock_file, "session-a");
    assert_eq!(out.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("circuit breaker lock timeout"),
        "expected mkdir lock timeout in stderr: {stderr}"
    );

    let _ = fs::remove_dir_all(dir);
}

#[test]
fn append_jsonl_command_appends_one_line() {
    let dir = unique_temp_dir("append-jsonl-one-line");
    fs::create_dir_all(&dir).unwrap();
    let log_file = dir.join("events.jsonl");
    let mut child = bin()
        .args(["append-jsonl", log_file.to_str().unwrap()])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"{\"ok\":true}\n")
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(
        out.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(String::from_utf8_lossy(&out.stdout), "");
    let content = fs::read_to_string(&log_file).unwrap();
    assert_eq!(content, "{\"ok\":true}\n");
    serde_json::from_str::<serde_json::Value>(content.trim_end()).unwrap();
    #[cfg(unix)]
    assert_eq!(file_mode(&log_file), 0o600);
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn append_jsonl_command_rejects_multiline_input() {
    let dir = unique_temp_dir("append-jsonl-multiline");
    fs::create_dir_all(&dir).unwrap();
    let log_file = dir.join("events.jsonl");
    let mut child = bin()
        .args(["append-jsonl", log_file.to_str().unwrap()])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"{\"first\":true}\n{\"second\":true}")
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(out.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("exactly one JSONL line"),
        "expected single-line error in stderr: {stderr}"
    );
    assert!(!log_file.exists());
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn append_jsonl_command_rejects_invalid_json() {
    let dir = unique_temp_dir("append-jsonl-invalid-json");
    fs::create_dir_all(&dir).unwrap();
    let log_file = dir.join("events.jsonl");
    let mut child = bin()
        .args(["append-jsonl", log_file.to_str().unwrap()])
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
        "expected runtime error in stderr: {stderr}"
    );
    assert!(!log_file.exists());
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn append_jsonl_command_rejects_non_object_json() {
    let dir = unique_temp_dir("append-jsonl-non-object-json");
    fs::create_dir_all(&dir).unwrap();
    let log_file = dir.join("events.jsonl");
    let mut child = bin()
        .args(["append-jsonl", log_file.to_str().unwrap()])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(b"null").unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(out.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("JSON object"),
        "expected object-shape error in stderr: {stderr}"
    );
    assert!(!log_file.exists());
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn append_jsonl_command_lock_timeout_does_not_write_unlocked() {
    let dir = unique_temp_dir("append-jsonl-lock-timeout");
    fs::create_dir_all(&dir).unwrap();
    let log_file = dir.join("events.jsonl");
    fs::create_dir(format!("{}.lock.d", log_file.display())).unwrap();
    let mut child = bin()
        .args(["append-jsonl", log_file.to_str().unwrap()])
        .env("VIBEGUARD_LOG_LOCK_ATTEMPTS", "1")
        .env("VIBEGUARD_LOG_LOCK_SLEEP_SECONDS", "0")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"{\"locked\":true}")
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(out.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("timed out waiting for JSONL append lock"),
        "expected lock timeout in stderr: {stderr}"
    );
    assert!(!log_file.exists());
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn append_jsonl_command_zero_lock_attempts_acts_as_one_attempt() {
    let dir = unique_temp_dir("append-jsonl-zero-lock-attempts");
    fs::create_dir_all(&dir).unwrap();
    let log_file = dir.join("events.jsonl");
    fs::create_dir(format!("{}.lock.d", log_file.display())).unwrap();
    let mut child = bin()
        .args(["append-jsonl", log_file.to_str().unwrap()])
        .env("VIBEGUARD_LOG_LOCK_ATTEMPTS", "0")
        .env("VIBEGUARD_LOG_LOCK_SLEEP_SECONDS", "0.05")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"{\"locked\":true}")
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(out.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("after 1 attempts"),
        "zero lock attempts should coerce to one attempt: {stderr}"
    );
    let _ = fs::remove_dir_all(dir);
}

#[cfg(unix)]
#[test]
fn append_jsonl_command_tightens_existing_file_permissions() {
    let dir = unique_temp_dir("append-jsonl-permissions");
    fs::create_dir_all(&dir).unwrap();
    let log_file = dir.join("events.jsonl");
    fs::write(&log_file, "{\"old\":true}\n").unwrap();
    fs::set_permissions(&log_file, fs::Permissions::from_mode(0o644)).unwrap();

    let mut child = bin()
        .args(["append-jsonl", log_file.to_str().unwrap()])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"{\"new\":true}")
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(
        out.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(file_mode(&log_file), 0o600);
    let content = fs::read_to_string(&log_file).unwrap();
    assert!(content.contains("{\"old\":true}\n{\"new\":true}\n"));
    let _ = fs::remove_dir_all(dir);
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
