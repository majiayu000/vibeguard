mod common;

#[cfg(unix)]
use common::file_mode;
use common::{bin, unique_temp_dir};
use std::fs;
use std::io::Write;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::process::Stdio;

#[test]
fn observe_export_prometheus_omits_raw_sensitive_labels() {
    let root = unique_temp_dir("observe-prometheus");
    fs::create_dir_all(&root).unwrap();
    let input = root.join("events.jsonl");
    let output_file = root.join("metrics.prom");
    fs::write(
        &input,
        concat!(
            "{\"ts\":\"2026-05-31T00:00:00Z\",\"session\":\"secret-session\",",
            "\"hook\":\"post-edit-guard\",\"tool\":\"Edit\",\"decision\":\"warn\",",
            "\"reason\":\"U-16 block for customer@example.com command cargo test -- --ignored\",",
            "\"detail\":\"Edit /Users/alice/project/src/private_token.rs\",",
            "\"duration_ms\":250}\n"
        ),
    )
    .unwrap();

    let out = bin()
        .args([
            "observe",
            "export",
            "prometheus",
            "--since",
            "all",
            "--input-file",
        ])
        .arg(&input)
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("vibeguard_event_total"), "{stdout}");
    assert!(
        stdout.contains("vibeguard_tool_total{tool=\"Edit\"} 1"),
        "{stdout}"
    );
    assert!(stdout.contains("rule_id=\"U-16\""), "{stdout}");
    assert!(
        stdout.contains("reason_code=\"rule_violation\""),
        "{stdout}"
    );
    assert!(stdout.contains("file_ext=\"rs\""), "{stdout}");
    for raw in [
        "secret-session",
        "customer@example.com",
        "cargo test -- --ignored",
        "/Users/alice",
        "private_token",
    ] {
        assert!(!stdout.contains(raw), "raw value leaked: {raw}\n{stdout}");
    }

    let file_out = bin()
        .args([
            "observe",
            "export",
            "prometheus",
            "--since",
            "all",
            "--input-file",
        ])
        .arg(&input)
        .args(["--file"])
        .arg(&output_file)
        .output()
        .unwrap();
    assert_eq!(file_out.status.code(), Some(0));
    assert!(file_out.stdout.is_empty());
    let file_metrics = fs::read_to_string(&output_file).unwrap();
    assert!(file_metrics.contains("vibeguard_guard_violation_total"));
    assert!(!file_metrics.contains("customer@example.com"));
    let _ = fs::remove_dir_all(root);
}

#[test]
fn observe_export_prometheus_project_scope_reads_project_log_dir() {
    let root = unique_temp_dir("observe-project-scope");
    let project_root = root.join("repo");
    let log_root = root.join("logs");
    let project_log_dir = log_root.join("projects").join("abcdef12");
    fs::create_dir_all(&project_root).unwrap();
    fs::create_dir_all(&project_log_dir).unwrap();
    fs::write(
        project_log_dir.join(".project-root"),
        project_root.to_string_lossy().as_ref(),
    )
    .unwrap();
    fs::write(
        project_log_dir.join("events.jsonl"),
        "{\"hook\":\"pre-bash-guard\",\"tool\":\"Bash\",\"decision\":\"block\",\"reason\":\"force push denied\",\"detail\":\"git push --force\"}\n",
    )
    .unwrap();

    let out = bin()
        .args(["observe", "export", "prometheus", "--project"])
        .arg(&project_root)
        .args(["--since", "all"])
        .env("VIBEGUARD_LOG_DIR", &log_root)
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("vibeguard_events_total 1"), "{stdout}");
    assert!(
        stdout.contains("reason_code=\"dangerous_command\""),
        "{stdout}"
    );
    assert!(!stdout.contains("git push --force"), "{stdout}");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn observe_export_prometheus_missing_log_reports_error_without_output_file() {
    let root = unique_temp_dir("observe-missing-log");
    fs::create_dir_all(&root).unwrap();
    let missing = root.join("missing-events.jsonl");
    let output_file = root.join("metrics.prom");

    let out = bin()
        .args([
            "observe",
            "export",
            "prometheus",
            "--since",
            "all",
            "--input-file",
        ])
        .arg(&missing)
        .args(["--file"])
        .arg(&output_file)
        .output()
        .unwrap();

    assert_eq!(out.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("Log file does not exist"), "{stderr}");
    assert!(
        stderr.contains(&missing.to_string_lossy().to_string()),
        "{stderr}"
    );
    assert!(!output_file.exists());
    let _ = fs::remove_dir_all(root);
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
fn append_jsonl_mirror_command_appends_to_primary_and_mirror() {
    let dir = unique_temp_dir("append-jsonl-mirror");
    fs::create_dir_all(&dir).unwrap();
    let primary_file = dir.join("project-events.jsonl");
    let mirror_file = dir.join("events.jsonl");
    let mut child = bin()
        .args([
            "append-jsonl-mirror",
            primary_file.to_str().unwrap(),
            mirror_file.to_str().unwrap(),
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"{\"mirrored\":true}\n")
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(
        out.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(
        fs::read_to_string(&primary_file).unwrap(),
        "{\"mirrored\":true}\n"
    );
    assert_eq!(
        fs::read_to_string(&mirror_file).unwrap(),
        "{\"mirrored\":true}\n"
    );
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn append_jsonl_mirror_command_reports_mirror_failure_after_primary_write() {
    let dir = unique_temp_dir("append-jsonl-mirror-failure");
    fs::create_dir_all(&dir).unwrap();
    let primary_file = dir.join("project-events.jsonl");
    let mirror_file = dir.join("events.jsonl");
    fs::create_dir(format!("{}.lock.d", mirror_file.display())).unwrap();

    let mut child = bin()
        .args([
            "append-jsonl-mirror",
            primary_file.to_str().unwrap(),
            mirror_file.to_str().unwrap(),
        ])
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
        .write_all(b"{\"mirrored\":true}\n")
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(out.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("mirror JSONL append failed"),
        "expected mirror failure in stderr: {stderr}"
    );
    assert_eq!(
        fs::read_to_string(&primary_file).unwrap(),
        "{\"mirrored\":true}\n"
    );
    assert!(!mirror_file.exists());
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn append_jsonl_mirror_command_writes_mirror_after_primary_failure() {
    let dir = unique_temp_dir("append-jsonl-primary-failure");
    fs::create_dir_all(&dir).unwrap();
    let primary_file = dir.join("project-events.jsonl");
    let mirror_file = dir.join("events.jsonl");
    fs::create_dir(format!("{}.lock.d", primary_file.display())).unwrap();

    let mut child = bin()
        .args([
            "append-jsonl-mirror",
            primary_file.to_str().unwrap(),
            mirror_file.to_str().unwrap(),
        ])
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
        .write_all(b"{\"mirrored\":true}\n")
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!(out.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("primary JSONL append failed"),
        "expected primary failure in stderr: {stderr}"
    );
    assert!(!primary_file.exists());
    assert_eq!(
        fs::read_to_string(&mirror_file).unwrap(),
        "{\"mirrored\":true}\n"
    );
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
