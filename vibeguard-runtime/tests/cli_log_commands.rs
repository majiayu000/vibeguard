mod common;

#[cfg(unix)]
use common::file_mode;
use common::{bin, unique_temp_dir};
use std::fs;
use std::io::Write;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::process::Stdio;

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
