use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

fn posttool_bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_vibeguard-runtime"))
}

fn posttool_temp_dir(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!(
        "vibeguard-runtime-{label}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ))
}

fn run_posttool_runtime(args: &[&str], input: &str) -> Output {
    let mut child = posttool_bin()
        .args(args)
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

fn run_posttool_write_check(input: &str, log_file: &Path) -> Output {
    run_posttool_runtime(
        &[
            "post-write-check",
            "800",
            "400",
            "5000",
            "20",
            "5",
            log_file.to_string_lossy().as_ref(),
        ],
        input,
    )
}

#[test]
fn post_edit_fast_check_reports_malformed_input() {
    let root = posttool_temp_dir("post-edit-malformed");
    fs::create_dir_all(&root).unwrap();
    let log_file = root.join("events.jsonl");
    let log_path = log_file.to_string_lossy().into_owned();

    let out = run_posttool_runtime(
        &["post-edit-fast-check", "400", "session", "codex", &log_path],
        "not-json",
    );

    assert_eq!(out.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "MALFORMED\n");
    assert!(!log_file.exists());
    let _ = fs::remove_dir_all(root);
}

#[test]
fn post_edit_fast_check_keeps_non_file_events_silent_for_shell() {
    let root = posttool_temp_dir("post-edit-non-file");
    fs::create_dir_all(&root).unwrap();
    let log_file = root.join("events.jsonl");
    let log_path = log_file.to_string_lossy().into_owned();
    let input = serde_json::json!({
        "hook_event_name": "PostToolUse",
        "tool_name": "Bash",
        "tool_input": {
            "command": "echo ok"
        }
    })
    .to_string();

    let out = run_posttool_runtime(
        &["post-edit-fast-check", "400", "session", "codex", &log_path],
        &input,
    );

    assert_eq!(out.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "SKIP\n");
    assert!(!log_file.exists());
    let _ = fs::remove_dir_all(root);
}

#[test]
fn post_write_check_reports_malformed_input() {
    let root = posttool_temp_dir("post-write-malformed");
    fs::create_dir_all(&root).unwrap();
    let log_file = root.join("events.jsonl");

    let out = run_posttool_write_check("not-json", &log_file);

    assert_eq!(out.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "MALFORMED\n");
    assert!(!log_file.exists());
    let _ = fs::remove_dir_all(root);
}

#[test]
fn post_write_check_keeps_non_file_events_silent() {
    let root = posttool_temp_dir("post-write-non-file");
    fs::create_dir_all(&root).unwrap();
    let log_file = root.join("events.jsonl");
    let input = serde_json::json!({
        "hook_event_name": "PostToolUse",
        "tool_name": "Bash",
        "tool_input": {
            "command": "echo ok"
        }
    })
    .to_string();

    let out = run_posttool_write_check(&input, &log_file);

    assert_eq!(out.status.code(), Some(0));
    assert!(out.stdout.is_empty());
    assert!(!log_file.exists());
    let _ = fs::remove_dir_all(root);
}
