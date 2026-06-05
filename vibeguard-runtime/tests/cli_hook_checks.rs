mod common;

use common::{bin, run_runtime_with_stdin, unique_temp_dir};
use std::fs;
use std::io::Write;
use std::process::Stdio;

fn run_post_write_check(input: &str, log_file: &std::path::Path) -> std::process::Output {
    let mut child = bin()
        .args([
            "post-write-check",
            "800",
            "400",
            "5000",
            "20",
            "5",
            log_file.to_string_lossy().as_ref(),
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .env("VIBEGUARD_HOOK_START_MS", "1")
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
fn post_edit_fast_check_reports_malformed_json() {
    let root = unique_temp_dir("post-edit-malformed");
    fs::create_dir_all(&root).unwrap();
    let log_file = root.join("events.jsonl");
    let out = run_runtime_with_stdin(
        &[
            "post-edit-fast-check",
            "400",
            "test-session",
            "codex",
            log_file.to_string_lossy().as_ref(),
        ],
        "not-json",
    );

    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("FAST_OUTPUT"), "{stdout}");
    assert!(stdout.contains("PostToolUse"), "{stdout}");
    assert!(stdout.contains("malformed PostToolUse(Edit)"), "{stdout}");
    let log_text = fs::read_to_string(&log_file).unwrap();
    assert!(log_text.contains("Malformed hook input"), "{log_text}");
    assert!(log_text.contains("\"decision\":\"warn\""), "{log_text}");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn post_write_check_reports_malformed_json() {
    let root = unique_temp_dir("post-write-malformed");
    fs::create_dir_all(&root).unwrap();
    let log_file = root.join("events.jsonl");
    let out = run_post_write_check("not-json", &log_file);

    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("PostToolUse"), "{stdout}");
    assert!(stdout.contains("malformed PostToolUse(Write)"), "{stdout}");
    let log_text = fs::read_to_string(&log_file).unwrap();
    assert!(log_text.contains("Malformed hook input"), "{log_text}");
    assert!(log_text.contains("\"decision\":\"warn\""), "{log_text}");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn post_write_check_reports_duplicate_definition() {
    let root = unique_temp_dir("post-write-dup");
    fs::create_dir_all(root.join(".git")).unwrap();
    fs::create_dir_all(root.join("src")).unwrap();
    fs::write(
        root.join("src").join("existing.py"),
        "def processOrder():\n    return 1\n",
    )
    .unwrap();
    let log_file = root.join("events.jsonl");
    let input = serde_json::json!({
        "tool_input": {
            "file_path": root.join("src").join("new.py"),
            "content": "def processOrder():\n    return 2\n"
        }
    })
    .to_string();

    let out = run_post_write_check(&input, &log_file);
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("PostToolUse"), "{stdout}");
    assert!(stdout.contains("duplicate definition"), "{stdout}");
    assert!(
        fs::read_to_string(&log_file)
            .unwrap()
            .contains("processOrder")
    );
    let _ = fs::remove_dir_all(root);
}

#[test]
fn post_write_check_silent_pass_for_non_source() {
    let root = unique_temp_dir("post-write-pass");
    fs::create_dir_all(root.join(".git")).unwrap();
    let log_file = root.join("events.jsonl");
    let input = serde_json::json!({
        "tool_input": {
            "file_path": root.join("README.md"),
            "content": "# title"
        }
    })
    .to_string();

    let out = run_post_write_check(&input, &log_file);
    assert_eq!(out.status.code(), Some(0));
    assert!(out.stdout.is_empty());
    let log_text = fs::read_to_string(&log_file).unwrap();
    assert!(log_text.contains("Non-source file"));
    assert!(log_text.contains("\"duration_ms\":"), "{log_text}");
    let _ = fs::remove_dir_all(root);
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
