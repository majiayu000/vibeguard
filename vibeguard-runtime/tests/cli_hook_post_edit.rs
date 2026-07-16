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
        .env("VIBEGUARD_AGENT_TYPE", "codex")
        .env("VG_U16_LIMIT", "800")
        .env("VG_U16_WARN_LIMIT", "400");
    command
}

fn run_post_edit(repo: &Path, log_root: &Path, log_file: &Path, input: &str) -> Output {
    run_post_edit_with(repo, log_root, log_file, input, |_| {})
}

fn run_post_edit_with(
    repo: &Path,
    log_root: &Path,
    log_file: &Path,
    input: &str,
    configure: impl FnOnce(&mut Command),
) -> Output {
    let mut command = post_edit_command(repo, log_root, log_file);
    command
        .args(["hook", "post-edit"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    configure(&mut command);
    let mut child = command.spawn().unwrap();
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

fn write_numbered_lines(path: &Path, count: usize) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let content = (0..count)
        .map(|index| format!("fn line_{index}() {{}}"))
        .collect::<Vec<_>>()
        .join("\n");
    fs::write(path, content).unwrap();
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
fn post_edit_malformed_input_keeps_warning_visible_when_log_fails() {
    let (root, repo, log_root, _) = case_paths("post-edit-malformed-log-failure");
    let blocking_parent = root.join("not-a-directory");
    fs::write(&blocking_parent, "blocks log parent creation").unwrap();
    let log_file = blocking_parent.join("events.jsonl");
    let out = run_post_edit(&repo, &log_root, &log_file, "not-json");

    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("malformed PostToolUse(Edit)"), "{stdout}");
    assert!(stdout.contains("VG-INTERNAL-LOG-APPEND"), "{stdout}");
    assert!(stdout.contains("mode=allow"), "{stdout}");
    assert!(!log_file.exists());
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
fn post_edit_rs10_warning_is_visible_logged_and_rule_scoped() {
    let (root, repo, log_root, log_file) = case_paths("post-edit-rs10-warning");
    let new_string = concat!(
        "// vibeguard-disable-next-line RS-10 -- intentional discard\n",
        "let _ = intentionally_ignored();\n",
        "let _ = must_be_reviewed();\n",
        "let value = fallible_call().unwrap();\n"
    );
    let input = edit_input("src/lib.rs", "fn old() {}", new_string);
    let out = run_post_edit(&repo, &log_root, &log_file, &input);

    assert_eq!(out.status.code(), Some(0));
    assert!(out.stderr.is_empty());
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("VIBEGUARD quality warning"), "{stdout}");
    assert!(stdout.contains("[RS-10]"), "{stdout}");
    assert!(
        stdout.contains("1 new let _ = silent discard(s) added"),
        "{stdout}"
    );
    assert!(!stdout.contains("2 new let _ = silent discard(s) added"));
    assert!(stdout.contains("[RS-03]"), "{stdout}");
    assert!(
        stdout.contains("1 new unwrap()/expect() call(s) added"),
        "{stdout}"
    );

    let events = parse_test_event_log(&log_file);
    assert_eq!(events.len(), 1);
    let event = &events[0];
    assert_eq!(event["decision"], "warn");
    assert_eq!(event["status"], "warn");
    let reason = event["reason"].as_str().unwrap();
    assert!(reason.contains("[RS-10]"), "{reason}");
    assert!(
        reason.contains("1 new let _ = silent discard(s) added"),
        "{reason}"
    );
    assert!(reason.contains("[RS-03]"), "{reason}");
    assert!(
        reason.contains("1 new unwrap()/expect() call(s) added"),
        "{reason}"
    );
    assert!(
        event["detail"]
            .as_str()
            .unwrap()
            .starts_with("src/lib.rs||delta=")
    );
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
fn post_edit_malformed_history_is_reported_visibly() {
    let (root, repo, log_root, log_file) = case_paths("post-edit-malformed-history");
    fs::write(&log_file, "not-json\n").unwrap();
    let input = edit_input("src/lib.rs", "safe_call()?", "unsafe_call().unwrap()");
    let out = run_post_edit(&repo, &log_root, &log_file, &input);

    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("VG-INTERNAL-HISTORY-READ"), "{stdout}");
    assert!(
        stdout.contains("malformed post-edit history JSONL"),
        "{stdout}"
    );
    assert!(stdout.contains("[RS-03]"), "{stdout}");
    let log_text = fs::read_to_string(&log_file).unwrap();
    assert!(log_text.starts_with("not-json\n"), "{log_text}");
    assert!(log_text.contains("VG-INTERNAL-HISTORY-READ"), "{log_text}");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn post_edit_history_read_failure_preserves_stateless_warning() {
    let (root, repo, log_root, _) = case_paths("post-edit-history-read-failure");
    let log_file = log_root.join("projects/post-edit-project/events-as-directory");
    fs::create_dir_all(&log_file).unwrap();
    let input = edit_input("src/lib.rs", "safe_call()?", "unsafe_call().unwrap()");
    let out = run_post_edit(&repo, &log_root, &log_file, &input);

    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("VG-INTERNAL-HISTORY-READ"), "{stdout}");
    assert!(stdout.contains("[RS-03]"), "{stdout}");
    assert!(stdout.contains("VG-INTERNAL-LOG-APPEND"), "{stdout}");
    assert!(log_file.is_dir());
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

#[test]
fn post_edit_u16_intentional_skips_and_small_source_log_pass() {
    let (root, repo, log_root, log_file) = case_paths("post-edit-u16-skips");
    let non_source = repo.join("notes.md");
    let test_source = repo.join("tests/generated.rs");
    let missing_source = repo.join("src/missing.rs");
    let small_source = repo.join("src/small.rs");
    write_numbered_lines(&non_source, 801);
    write_numbered_lines(&test_source, 801);
    write_numbered_lines(&small_source, 400);

    for file_path in [&non_source, &test_source, &missing_source, &small_source] {
        let input = edit_input(file_path.to_string_lossy().as_ref(), "old", "fn clean() {}");
        let out = run_post_edit(&repo, &log_root, &log_file, &input);
        assert_eq!(out.status.code(), Some(0));
        assert!(
            out.stdout.is_empty(),
            "{}",
            String::from_utf8_lossy(&out.stdout)
        );
        assert!(out.stderr.is_empty());
    }

    let events = parse_test_event_log(&log_file);
    assert_eq!(events.len(), 4);
    assert!(events.iter().all(|event| event["decision"] == "pass"));
    assert!(
        events
            .iter()
            .all(|event| !event["reason"].as_str().unwrap().contains("U-16"))
    );
    let _ = fs::remove_dir_all(root);
}

#[test]
fn post_edit_u16_advisory_is_visible_and_logged() {
    let (root, repo, log_root, log_file) = case_paths("post-edit-u16-advisory");
    let file_path = repo.join("src/advisory.rs");
    write_numbered_lines(&file_path, 401);
    let input = edit_input(file_path.to_string_lossy().as_ref(), "old", "fn clean() {}");

    let out = run_post_edit(&repo, &log_root, &log_file, &input);
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("VIBEGUARD quality warning"), "{stdout}");
    assert!(stdout.contains("[U-16] [advisory]"), "{stdout}");
    assert!(stdout.contains("401 lines"), "{stdout}");
    let event = parse_test_event_log(&log_file).pop().unwrap();
    assert_eq!(event["decision"], "warn");
    assert!(
        event["reason"]
            .as_str()
            .unwrap()
            .contains("[U-16] [advisory]")
    );
    let _ = fs::remove_dir_all(root);
}

#[test]
fn post_edit_u16_hard_limit_warning_is_visible_and_logged() {
    let (root, repo, log_root, log_file) = case_paths("post-edit-u16-hard");
    let file_path = repo.join("src/oversized.rs");
    write_numbered_lines(&file_path, 801);
    let input = edit_input(file_path.to_string_lossy().as_ref(), "old", "fn clean() {}");

    let out = run_post_edit(&repo, &log_root, &log_file, &input);
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("[U-16] [review]"), "{stdout}");
    assert!(stdout.contains("801 lines"), "{stdout}");
    assert!(stdout.contains("exceeding 800-line limit"), "{stdout}");
    let event = parse_test_event_log(&log_file).pop().unwrap();
    assert_eq!(event["decision"], "warn");
    assert!(
        event["reason"]
            .as_str()
            .unwrap()
            .contains("[U-16] [review]")
    );
    let _ = fs::remove_dir_all(root);
}

#[test]
fn post_edit_u16_project_exemption_suppresses_typical_range_warning() {
    let (root, repo, log_root, log_file) = case_paths("post-edit-u16-exempt");
    fs::write(
        repo.join("CLAUDE.md"),
        "U-16 exempt: `src/exempt.rs` may contain 1000 lines.\n",
    )
    .unwrap();
    let file_path = repo.join("src/exempt.rs");
    write_numbered_lines(&file_path, 850);
    let input = edit_input(file_path.to_string_lossy().as_ref(), "old", "fn clean() {}");

    let out = run_post_edit(&repo, &log_root, &log_file, &input);
    assert_eq!(out.status.code(), Some(0));
    assert!(
        out.stdout.is_empty(),
        "{}",
        String::from_utf8_lossy(&out.stdout)
    );
    assert!(out.stderr.is_empty());
    let event = parse_test_event_log(&log_file).pop().unwrap();
    assert_eq!(event["decision"], "pass");
    assert_eq!(event["reason"], "");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn post_edit_u16_warning_survives_event_log_failure() {
    let (root, repo, log_root, _) = case_paths("post-edit-u16-log-failure");
    let file_path = repo.join("src/advisory.rs");
    write_numbered_lines(&file_path, 401);
    let blocking_parent = root.join("not-a-directory");
    fs::write(&blocking_parent, "blocks log parent creation").unwrap();
    let log_file = blocking_parent.join("events.jsonl");
    let input = edit_input(file_path.to_string_lossy().as_ref(), "old", "fn clean() {}");

    let out = run_post_edit(&repo, &log_root, &log_file, &input);
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("VG-INTERNAL-LOG-APPEND"), "{stdout}");
    assert!(stdout.contains("[U-16] [advisory]"), "{stdout}");
    assert!(stdout.contains("mode=allow"), "{stdout}");
    assert!(!log_file.exists());
    let _ = fs::remove_dir_all(root);
}
