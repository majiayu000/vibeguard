mod common;

use common::{bin, unique_temp_dir};
use serde_json::{Value, json};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

fn post_edit_command(repo: &Path, log_root: &Path, log_file: &Path) -> Command {
    let mut command = bin();
    let project_log_dir = log_root.join("projects").join("post-edit-project");
    command
        .current_dir(repo)
        .env("VIBEGUARD_LOG_DIR", log_root)
        .env("VIBEGUARD_PROJECT_LOG_DIR", project_log_dir)
        .env("VIBEGUARD_LOG_FILE", log_file)
        .env("VIBEGUARD_PROJECT_HASH", "post-edit-project")
        .env("VIBEGUARD_CLI", "codex")
        .env("VIBEGUARD_CLIENT", "codex")
        .env("VIBEGUARD_SESSION_ID", "post-edit-session")
        .env("VIBEGUARD_CALLER_EVIDENCE", "explicit-test")
        .env("VIBEGUARD_AGENT_TYPE", "codex");
    command
}

fn run_post_edit(repo: &Path, log_root: &Path, log_file: &Path, input: &str) -> Output {
    let mut child = post_edit_command(repo, log_root, log_file)
        .args(["hook", "post-edit"])
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

fn case_paths(label: &str) -> (PathBuf, PathBuf, PathBuf, PathBuf) {
    let root = unique_temp_dir(label);
    let repo = root.join("repo");
    let log_root = root.join("logs");
    let project_log_dir = log_root.join("projects").join("post-edit-project");
    let log_file = project_log_dir.join("events.jsonl");
    fs::create_dir_all(repo.join(".git")).unwrap();
    fs::create_dir_all(&project_log_dir).unwrap();
    (root, repo, log_root, log_file)
}

fn edit_input(file_path: &str, old_string: &str, new_string: &str) -> String {
    json!({
        "tool_input": {
            "file_path": file_path,
            "old_string": old_string,
            "new_string": new_string
        }
    })
    .to_string()
}

fn parse_test_event_log(path: &Path) -> Vec<Value> {
    fs::read_to_string(path)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}

#[test]
fn post_edit_malformed_input_warns_visibly_and_logs() {
    let (root, repo, log_root, log_file) = case_paths("post-edit-malformed");
    let out = run_post_edit(&repo, &log_root, &log_file, "not-json");

    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("PostToolUse"), "{stdout}");
    assert!(stdout.contains("malformed PostToolUse(Edit)"), "{stdout}");
    let events = parse_test_event_log(&log_file);
    assert_eq!(events.len(), 1);
    assert_eq!(events[0]["decision"], "warn");
    assert_eq!(events[0]["reason"], "Malformed hook input");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn post_edit_missing_fields_stay_silent_without_pass_log() {
    let (root, repo, log_root, log_file) = case_paths("post-edit-missing-fields");

    for input in [
        r#"{"tool_input":{"new_string":"fn clean() {}"}}"#,
        r#"{"tool_input":{"file_path":"src/lib.rs"}}"#,
    ] {
        let out = run_post_edit(&repo, &log_root, &log_file, input);
        assert_eq!(out.status.code(), Some(0));
        assert!(out.stdout.is_empty());
        assert!(out.stderr.is_empty());
    }
    assert!(!log_file.exists(), "skip must not fabricate a pass event");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn post_edit_clean_edit_logs_pass_and_delta() {
    let (root, repo, log_root, log_file) = case_paths("post-edit-pass");
    let input = edit_input("src/lib.rs", "fn old() {}", "fn clean() {}");
    let out = run_post_edit(&repo, &log_root, &log_file, &input);

    assert_eq!(out.status.code(), Some(0));
    assert!(out.stdout.is_empty());
    assert!(out.stderr.is_empty());
    let events = parse_test_event_log(&log_file);
    let event = events.last().unwrap();
    assert_eq!(event["decision"], "pass");
    assert_eq!(event["status"], "pass");
    assert_eq!(event["detail"], "src/lib.rs||delta=2");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn post_edit_rust_warning_is_visible_and_logged() {
    let (root, repo, log_root, log_file) = case_paths("post-edit-warning");
    let input = edit_input("src/lib.rs", "safe_call()?", "unsafe_call().unwrap()");
    let out = run_post_edit(&repo, &log_root, &log_file, &input);

    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("VIBEGUARD quality warning"), "{stdout}");
    assert!(stdout.contains("[RS-03]"), "{stdout}");
    assert!(stdout.contains("unwrap()/expect()"), "{stdout}");
    let events = parse_test_event_log(&log_file);
    let event = events.last().unwrap();
    assert_eq!(event["decision"], "warn");
    assert!(event["reason"].as_str().unwrap().contains("[RS-03]"));
    let _ = fs::remove_dir_all(root);
}

#[test]
fn post_edit_prior_warnings_escalate_current_warning() {
    let (root, repo, log_root, log_file) = case_paths("post-edit-escalate");
    let prior = (0..3)
        .map(|index| {
            json!({
                "schema_version": 1,
                "ts": format!("2026-07-15T19:00:0{index}Z"),
                "session": "post-edit-session",
                "hook": "post-edit-guard",
                "tool": "Edit",
                "decision": "warn",
                "status": "warn",
                "reason": "[RS-03] prior warning",
                "detail": "src/lib.rs||delta=4"
            })
            .to_string()
        })
        .collect::<Vec<_>>()
        .join("\n");
    fs::write(&log_file, format!("{prior}\n")).unwrap();

    let input = edit_input("src/lib.rs", "safe_call()?", "unsafe_call().unwrap()");
    let out = run_post_edit(&repo, &log_root, &log_file, &input);
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("VIBEGUARD upgrade warning"), "{stdout}");
    assert!(stdout.contains("triggered 3 warnings"), "{stdout}");
    assert!(stdout.contains("[RS-03]"), "{stdout}");
    let events = parse_test_event_log(&log_file);
    let event = events.last().unwrap();
    assert_eq!(event["decision"], "escalate");
    assert!(event["reason"].as_str().unwrap().contains("[ESCALATE]"));
    let _ = fs::remove_dir_all(root);
}

#[test]
fn post_edit_pass_log_failure_is_reported_visibly() {
    let (root, repo, log_root, _) = case_paths("post-edit-pass-log-failure");
    let blocking_parent = root.join("not-a-directory");
    fs::write(&blocking_parent, "blocks log parent creation").unwrap();
    let log_file = blocking_parent.join("events.jsonl");
    let input = edit_input("src/lib.rs", "fn old() {}", "fn clean() {}");
    let out = run_post_edit(&repo, &log_root, &log_file, &input);

    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("VG-INTERNAL-LOG-APPEND"), "{stdout}");
    assert!(stdout.contains("mode=allow"), "{stdout}");
    assert!(stdout.contains("project=post-edit-project"), "{stdout}");
    assert!(stdout.contains("session=post-edit-session"), "{stdout}");
    assert!(!log_file.exists());
    let _ = fs::remove_dir_all(root);
}

#[test]
fn post_edit_warning_survives_log_failure_with_internal_error() {
    let (root, repo, log_root, _) = case_paths("post-edit-warn-log-failure");
    let blocking_parent = root.join("not-a-directory");
    fs::write(&blocking_parent, "blocks log parent creation").unwrap();
    let log_file = blocking_parent.join("events.jsonl");
    let input = edit_input("src/lib.rs", "safe_call()?", "unsafe_call().unwrap()");
    let out = run_post_edit(&repo, &log_root, &log_file, &input);

    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("VG-INTERNAL-LOG-APPEND"), "{stdout}");
    assert!(stdout.contains("VIBEGUARD quality warning"), "{stdout}");
    assert!(stdout.contains("[RS-03]"), "{stdout}");
    assert!(!log_file.exists());
    let _ = fs::remove_dir_all(root);
}
