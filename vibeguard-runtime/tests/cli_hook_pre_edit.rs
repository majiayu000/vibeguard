mod common;

use common::{bin, unique_temp_dir};
use serde_json::{Value, json};
use std::fs;
use std::io::Write;
use std::path::Path;
use std::process::{Command, Output, Stdio};

fn pre_edit_command(log_file: &Path) -> Command {
    let mut command = bin();
    command
        .args([
            "pre-edit-check",
            "800",
            "400",
            log_file.to_string_lossy().as_ref(),
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .env("VIBEGUARD_PROJECT_HASH", "test-project")
        .env("VIBEGUARD_SESSION_ID", "test-session");
    command
}

fn run_pre_edit_check(input: &str, log_file: &Path) -> Output {
    run_pre_edit_check_with(input, log_file, |_| {})
}

fn run_pre_edit_check_with(
    input: &str,
    log_file: &Path,
    configure: impl FnOnce(&mut Command),
) -> Output {
    let mut command = pre_edit_command(log_file);
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

fn run_pre_edit_check_args(input: &str, args: &[&str]) -> Output {
    let mut command = bin();
    command
        .arg("pre-edit-check")
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .env("VIBEGUARD_PROJECT_HASH", "test-project")
        .env("VIBEGUARD_SESSION_ID", "test-session");
    let mut child = command.spawn().unwrap();
    child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(input.as_bytes())
        .unwrap();
    child.wait_with_output().unwrap()
}

fn edit_input(file_path: &Path, old_string: &str, new_string: &str) -> String {
    json!({
        "tool_input": {
            "file_path": file_path,
            "old_string": old_string,
            "new_string": new_string
        }
    })
    .to_string()
}

fn parse_events(log_file: &Path) -> Vec<Value> {
    fs::read_to_string(log_file)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}

fn init_git_repo(root: &Path) {
    fs::create_dir_all(root).unwrap();
    let output = Command::new("git")
        .args(["init", "-q"])
        .current_dir(root)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git init failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

fn numbered_lines(count: usize) -> String {
    (0..count)
        .map(|index| format!("fn line_{index}() {{}}"))
        .collect::<Vec<_>>()
        .join("\n")
}

#[test]
fn pre_edit_check_rejects_zero_and_one_argument_visibly() {
    for args in [Vec::<&str>::new(), vec!["800"]] {
        let out = run_pre_edit_check_args("", &args);
        assert_eq!(out.status.code(), Some(1));
        assert!(out.stdout.is_empty());
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(stderr.contains("vibeguard-runtime error"), "{stderr}");
        assert!(stderr.contains("pre-edit-check"), "{stderr}");
    }
}

#[test]
fn pre_edit_check_legacy_two_argument_form_uses_default_warn_limit() {
    let root = unique_temp_dir("pre-edit-legacy-args");
    fs::create_dir_all(&root).unwrap();
    let file_path = root.join("service.rs");
    fs::write(&file_path, numbered_lines(400)).unwrap();
    let log_file = root.join("events.jsonl");
    let input = json!({
        "tool_input": {
            "file_path": file_path,
            "old_string": "",
            "new_string": "one more line",
            "vibeguard_line_delta": 1
        }
    })
    .to_string();
    let log_arg = log_file.to_string_lossy().into_owned();

    let out = run_pre_edit_check_args(&input, &["800", &log_arg]);
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("[U-16] [advisory]"), "{stdout}");
    assert!(stdout.contains("401 lines"), "{stdout}");
    assert_eq!(parse_events(&log_file)[0]["decision"], "warn");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn pre_edit_check_invalid_limits_use_documented_defaults() {
    let root = unique_temp_dir("pre-edit-invalid-limits");
    fs::create_dir_all(&root).unwrap();
    let hard_file = root.join("hard.rs");
    fs::write(&hard_file, numbered_lines(800)).unwrap();
    let hard_log = root.join("hard.jsonl");
    let hard_input = json!({
        "tool_input": {
            "file_path": hard_file,
            "old_string": "",
            "new_string": "one more line",
            "vibeguard_line_delta": 1
        }
    })
    .to_string();
    let hard_log_arg = hard_log.to_string_lossy().into_owned();
    let hard_out = run_pre_edit_check_args(&hard_input, &["invalid", "400", &hard_log_arg]);
    assert_eq!(hard_out.status.code(), Some(0));
    assert!(
        String::from_utf8_lossy(&hard_out.stdout).contains("~801 lines (limit: 800)"),
        "{}",
        String::from_utf8_lossy(&hard_out.stdout)
    );

    let warn_file = root.join("warn.rs");
    fs::write(&warn_file, numbered_lines(400)).unwrap();
    let warn_log = root.join("warn.jsonl");
    let warn_input = json!({
        "tool_input": {
            "file_path": warn_file,
            "old_string": "",
            "new_string": "one more line",
            "vibeguard_line_delta": 1
        }
    })
    .to_string();
    let warn_log_arg = warn_log.to_string_lossy().into_owned();
    let warn_out = run_pre_edit_check_args(&warn_input, &["800", "invalid", &warn_log_arg]);
    assert_eq!(warn_out.status.code(), Some(0));
    assert!(
        String::from_utf8_lossy(&warn_out.stdout).contains("401 lines"),
        "{}",
        String::from_utf8_lossy(&warn_out.stdout)
    );
    assert_eq!(parse_events(&warn_log)[0]["decision"], "warn");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn pre_edit_check_blocks_missing_file_with_lookup_failure_visible() {
    let root = unique_temp_dir("pre-edit-missing-file");
    fs::create_dir_all(&root).unwrap();
    let file_path = root.join("src").join("missing_service.rs");
    let log_file = root.join("events.jsonl");
    let input = edit_input(&file_path, "old", "new");

    let out = run_pre_edit_check(&input, &log_file);
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.starts_with("FAST_OUTPUT\n"), "{stdout}");
    assert!(stdout.contains("\"decision\": \"block\""), "{stdout}");
    assert!(stdout.contains("File does not exist"), "{stdout}");
    assert!(stdout.contains("no git project root found"), "{stdout}");
    assert!(out.stderr.is_empty());
    let events = parse_events(&log_file);
    assert_eq!(events.len(), 1);
    assert_eq!(events[0]["decision"], "block");
    assert_eq!(events[0]["reason"], "File does not exist");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn pre_edit_check_exposes_missing_git_dependency() {
    let root = unique_temp_dir("pre-edit-missing-git");
    fs::create_dir_all(root.join(".git")).unwrap();
    let file_path = root.join("src").join("missing_service.rs");
    let log_file = root.join("events.jsonl");
    let input = edit_input(&file_path, "old", "new");

    let out = run_pre_edit_check_with(&input, &log_file, |command| {
        command.env("PATH", "");
    });
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.starts_with("FAST_OUTPUT\n"), "{stdout}");
    assert!(stdout.contains("\"decision\": \"block\""), "{stdout}");
    assert!(stdout.contains("git ls-files could not run"), "{stdout}");
    assert!(out.stderr.is_empty());
    assert_eq!(parse_events(&log_file)[0]["reason"], "File does not exist");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn pre_edit_check_blocks_stale_old_string() {
    let root = unique_temp_dir("pre-edit-stale-old-string");
    fs::create_dir_all(&root).unwrap();
    let file_path = root.join("lib.rs");
    fs::write(&file_path, "fn current() {}\n").unwrap();
    let log_file = root.join("events.jsonl");
    let input = edit_input(&file_path, "fn stale() {}", "fn replacement() {}");

    let out = run_pre_edit_check(&input, &log_file);
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.starts_with("FAST_OUTPUT\n"), "{stdout}");
    assert!(stdout.contains("\"decision\": \"block\""), "{stdout}");
    assert!(stdout.contains("old_string does not exist"), "{stdout}");
    assert!(stdout.contains("use the Read tool"), "{stdout}");
    assert!(out.stderr.is_empty());
    assert_eq!(
        parse_events(&log_file)[0]["reason"],
        "old_string does not exist"
    );
    let _ = fs::remove_dir_all(root);
}

#[test]
fn pre_edit_check_keeps_block_visible_when_log_append_fails() {
    let root = unique_temp_dir("pre-edit-block-log-failure");
    fs::create_dir_all(&root).unwrap();
    let blocking_parent = root.join("not-a-directory");
    fs::write(&blocking_parent, "blocks log parent creation").unwrap();
    let log_file = blocking_parent.join("events.jsonl");

    let out = run_pre_edit_check("not-json", &log_file);
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stdout.starts_with("FAST_OUTPUT\n"), "{stdout}");
    assert!(stdout.contains("\"decision\": \"block\""), "{stdout}");
    assert!(stdout.contains("VG-INTERNAL-LOG-APPEND"), "{stdout}");
    assert!(stdout.contains("failure_kind=runtime"), "{stdout}");
    assert!(stdout.contains("project=test-project"), "{stdout}");
    assert!(stdout.contains("session=test-session"), "{stdout}");
    assert!(
        stderr.contains("pre-edit block log append failed"),
        "{stderr}"
    );
    assert!(
        !log_file.exists(),
        "failed logging must not claim persistence"
    );
    let _ = fs::remove_dir_all(root);
}

#[test]
fn pre_edit_check_malformed_input_blocks_and_logs() {
    let root = unique_temp_dir("pre-edit-malformed");
    fs::create_dir_all(&root).unwrap();
    let log_file = root.join("events.jsonl");

    let out = run_pre_edit_check("not-json", &log_file);
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("\"decision\": \"block\""), "{stdout}");
    assert!(stdout.contains("malformed PreToolUse(Edit)"), "{stdout}");
    let event = &parse_events(&log_file)[0];
    assert_eq!(event["decision"], "block");
    assert_eq!(event["reason"], "Malformed hook input");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn pre_edit_check_empty_file_path_keeps_legacy_skip_without_log() {
    let root = unique_temp_dir("pre-edit-empty-path");
    fs::create_dir_all(&root).unwrap();
    let log_file = root.join("events.jsonl");

    let out = run_pre_edit_check(
        r#"{"tool_input":{"old_string":"old","new_string":"new"}}"#,
        &log_file,
    );
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "SKIP\n");
    assert!(out.stderr.is_empty());
    assert!(
        !log_file.exists(),
        "legacy skip must not fabricate a pass log"
    );
    let _ = fs::remove_dir_all(root);
}

#[test]
fn pre_edit_check_blocks_w12_test_infrastructure_before_file_lookup() {
    let root = unique_temp_dir("pre-edit-w12");
    fs::create_dir_all(&root).unwrap();
    let file_path = root.join("conftest.py");
    let log_file = root.join("events.jsonl");
    let input = edit_input(&file_path, "old", "new");

    let out = run_pre_edit_check(&input, &log_file);
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("\"decision\": \"block\""), "{stdout}");
    assert!(stdout.contains("W-12 interception"), "{stdout}");
    assert!(stdout.contains("conftest.py"), "{stdout}");
    let event = &parse_events(&log_file)[0];
    assert_eq!(event["decision"], "block");
    assert_eq!(
        event["reason"],
        "Test Infrastructure File Protection (W-12)"
    );
    let _ = fs::remove_dir_all(root);
}

#[test]
fn pre_edit_check_positive_delta_blocks_above_u16_hard_limit() {
    let root = unique_temp_dir("pre-edit-positive-delta");
    fs::create_dir_all(&root).unwrap();
    let file_path = root.join("service.rs");
    fs::write(&file_path, numbered_lines(10)).unwrap();
    let log_file = root.join("events.jsonl");
    let input = json!({
        "tool_input": {
            "file_path": file_path,
            "old_string": "",
            "new_string": "generated",
            "vibeguard_line_delta": 791
        }
    })
    .to_string();

    let out = run_pre_edit_check(&input, &log_file);
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("[U-16] block"), "{stdout}");
    assert!(stdout.contains("~801 lines"), "{stdout}");
    assert_eq!(parse_events(&log_file)[0]["decision"], "block");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn pre_edit_check_negative_delta_passes_below_advisory_and_saturates_at_zero() {
    let root = unique_temp_dir("pre-edit-negative-delta");
    fs::create_dir_all(&root).unwrap();
    let file_path = root.join("service.rs");
    fs::write(&file_path, numbered_lines(450)).unwrap();
    let log_file = root.join("events.jsonl");
    let input = json!({
        "tool_input": {
            "file_path": file_path,
            "old_string": "",
            "new_string": "smaller",
            "vibeguard_line_delta": -100
        }
    })
    .to_string();

    let out = run_pre_edit_check(&input, &log_file);
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "FAST_LOGGED\n");
    assert_eq!(parse_events(&log_file)[0]["decision"], "pass");

    let extreme_log = root.join("extreme.jsonl");
    let extreme_input = json!({
        "tool_input": {
            "file_path": file_path,
            "old_string": "",
            "new_string": "smaller",
            "vibeguard_line_delta": i64::MIN
        }
    })
    .to_string();
    let extreme = run_pre_edit_check(&extreme_input, &extreme_log);
    assert_eq!(extreme.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&extreme.stdout), "FAST_LOGGED\n");
    assert_eq!(parse_events(&extreme_log)[0]["decision"], "pass");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn pre_edit_check_single_replacement_stays_at_hard_limit() {
    let root = unique_temp_dir("pre-edit-single-replacement");
    fs::create_dir_all(&root).unwrap();
    let file_path = root.join("service.rs");
    let content = format!("target();\ntarget();\n{}", numbered_lines(797));
    fs::write(&file_path, content).unwrap();
    let log_file = root.join("events.jsonl");
    let input = edit_input(&file_path, "target();", "first();\nsecond();");

    let out = run_pre_edit_check(&input, &log_file);
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.starts_with("FAST_OUTPUT\n"), "{stdout}");
    assert!(stdout.contains("with 800 lines"), "{stdout}");
    assert!(!stdout.contains("[U-16] block"), "{stdout}");
    assert_eq!(parse_events(&log_file)[0]["decision"], "warn");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn pre_edit_check_replace_all_counts_every_occurrence() {
    let root = unique_temp_dir("pre-edit-replace-all");
    fs::create_dir_all(&root).unwrap();
    let file_path = root.join("service.rs");
    let content = format!("target();\ntarget();\n{}", numbered_lines(797));
    fs::write(&file_path, content).unwrap();
    let log_file = root.join("events.jsonl");
    let input = json!({
        "tool_input": {
            "file_path": file_path,
            "old_string": "target();",
            "new_string": "first();\nsecond();",
            "replace_all": true
        }
    })
    .to_string();

    let out = run_pre_edit_check(&input, &log_file);
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("[U-16] block"), "{stdout}");
    assert!(stdout.contains("~801 lines"), "{stdout}");
    assert_eq!(parse_events(&log_file)[0]["decision"], "block");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn pre_edit_check_without_delta_or_complete_replacement_logs_pass() {
    let root = unique_temp_dir("pre-edit-no-delta");
    fs::create_dir_all(&root).unwrap();
    let file_path = root.join("service.rs");
    fs::write(&file_path, numbered_lines(850)).unwrap();
    let log_file = root.join("events.jsonl");
    let input = edit_input(&file_path, "", "new content");

    let out = run_pre_edit_check(&input, &log_file);
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "FAST_LOGGED\n");
    assert_eq!(parse_events(&log_file)[0]["decision"], "pass");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn pre_edit_check_clean_pass_log_failure_is_visible() {
    let root = unique_temp_dir("pre-edit-pass-log-failure");
    fs::create_dir_all(&root).unwrap();
    let file_path = root.join("service.rs");
    fs::write(&file_path, "fn service() {}\n").unwrap();
    let blocking_parent = root.join("not-a-directory");
    fs::write(&blocking_parent, "blocks log parent creation").unwrap();
    let log_file = blocking_parent.join("events.jsonl");
    let input = edit_input(&file_path, "fn service() {}", "fn service() { work(); }");

    let out = run_pre_edit_check(&input, &log_file);
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.starts_with("FALLBACK\n"), "{stdout}");
    assert!(
        stdout.lines().nth(1).is_some_and(|line| !line.is_empty()),
        "{stdout}"
    );
    assert!(!log_file.exists());
    let _ = fs::remove_dir_all(root);
}

#[test]
fn pre_edit_check_project_u16_exemption_suppresses_advisory() {
    let root = unique_temp_dir("pre-edit-u16-exempt");
    init_git_repo(&root);
    let src_dir = root.join("src");
    fs::create_dir_all(&src_dir).unwrap();
    fs::write(
        root.join("CLAUDE.md"),
        "U-16 exempt: `src/exempt.rs` may contain 1000 lines.\n",
    )
    .unwrap();
    let file_path = src_dir.join("exempt.rs");
    fs::write(&file_path, numbered_lines(850)).unwrap();
    let log_file = root.join("events.jsonl");
    let input = json!({
        "tool_input": {
            "file_path": file_path,
            "old_string": "",
            "new_string": "localized edit",
            "vibeguard_line_delta": 0
        }
    })
    .to_string();

    let out = run_pre_edit_check(&input, &log_file);
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "FAST_LOGGED\n");
    assert_eq!(parse_events(&log_file)[0]["decision"], "pass");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn pre_edit_check_advisory_is_visible_and_logged_as_warn() {
    let root = unique_temp_dir("pre-edit-advisory");
    fs::create_dir_all(&root).unwrap();
    let file_path = root.join("service.rs");
    fs::write(&file_path, numbered_lines(400)).unwrap();
    let log_file = root.join("events.jsonl");
    let input = json!({
        "tool_input": {
            "file_path": file_path,
            "old_string": "",
            "new_string": "one more line",
            "vibeguard_line_delta": 1
        }
    })
    .to_string();

    let out = run_pre_edit_check(&input, &log_file);
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.starts_with("FAST_OUTPUT\n"), "{stdout}");
    assert!(stdout.contains("[U-16] [advisory]"), "{stdout}");
    assert!(stdout.contains("401 lines"), "{stdout}");
    let event = &parse_events(&log_file)[0];
    assert_eq!(event["decision"], "warn");
    assert!(event["reason"].as_str().unwrap().contains("401 > 400"));
    let _ = fs::remove_dir_all(root);
}

#[test]
fn pre_edit_check_advisory_remains_visible_when_log_append_fails() {
    let root = unique_temp_dir("pre-edit-advisory-log-failure");
    fs::create_dir_all(&root).unwrap();
    let file_path = root.join("service.rs");
    fs::write(&file_path, numbered_lines(401)).unwrap();
    let blocking_parent = root.join("not-a-directory");
    fs::write(&blocking_parent, "blocks log parent creation").unwrap();
    let log_file = blocking_parent.join("events.jsonl");
    let input = json!({
        "tool_input": {
            "file_path": file_path,
            "old_string": "",
            "new_string": "advisory",
            "vibeguard_line_delta": 0
        }
    })
    .to_string();

    let out = run_pre_edit_check(&input, &log_file);
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.starts_with("FALLBACK_OUTPUT\n"), "{stdout}");
    assert!(stdout.contains("[U-16] [advisory]"), "{stdout}");
    assert!(!log_file.exists());
    let _ = fs::remove_dir_all(root);
}

#[test]
fn pre_edit_check_lock_failure_reports_lock_recovery() {
    let root = unique_temp_dir("pre-edit-lock-failure");
    fs::create_dir_all(&root).unwrap();
    let log_file = root.join("events.jsonl");
    let lock_dir = root.join("events.jsonl.lock.d");
    fs::create_dir_all(&lock_dir).unwrap();

    let out = run_pre_edit_check_with("not-json", &log_file, |command| {
        command
            .env("VIBEGUARD_LOG_LOCK_ATTEMPTS", "1")
            .env("VIBEGUARD_LOG_LOCK_SLEEP_SECONDS", "0")
            .env("VIBEGUARD_LOG_LOCK_STALE_SECONDS", "3600");
    });
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("failure_kind=lock"), "{stdout}");
    assert!(stdout.contains("rmdir"), "{stdout}");
    assert!(stdout.contains("events.jsonl.lock.d"), "{stdout}");
    assert!(lock_dir.is_dir(), "active lock fixture must be preserved");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn pre_edit_check_missing_file_suggests_tracked_candidates() {
    let root = unique_temp_dir("pre-edit-candidate-found");
    init_git_repo(&root);
    fs::create_dir_all(root.join("src")).unwrap();
    fs::write(root.join("src/user_service.rs"), "fn user_service() {}\n").unwrap();
    let add = Command::new("git")
        .args(["add", "src/user_service.rs"])
        .current_dir(&root)
        .output()
        .unwrap();
    assert!(add.status.success());
    let file_path = root.join("src/user.rs");
    let log_file = root.join("events.jsonl");

    let out = run_pre_edit_check(&edit_input(&file_path, "old", "new"), &log_file);
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("Likely candidates"), "{stdout}");
    assert!(stdout.contains("src/user_service.rs"), "{stdout}");
    assert_eq!(parse_events(&log_file)[0]["decision"], "block");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn pre_edit_check_missing_file_reports_empty_candidate_search() {
    let root = unique_temp_dir("pre-edit-candidate-empty");
    init_git_repo(&root);
    fs::create_dir_all(root.join("src")).unwrap();
    let file_path = root.join("src/absent_service.rs");
    let log_file = root.join("events.jsonl");

    let out = run_pre_edit_check(&edit_input(&file_path, "old", "new"), &log_file);
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        stdout.contains("No similar tracked files found"),
        "{stdout}"
    );
    assert_eq!(parse_events(&log_file)[0]["reason"], "File does not exist");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn pre_edit_check_can_disable_missing_file_suggestions_in_child() {
    let root = unique_temp_dir("pre-edit-suggestion-disabled");
    init_git_repo(&root);
    let file_path = root.join("missing.rs");
    let log_file = root.join("events.jsonl");

    let out = run_pre_edit_check_with(
        &edit_input(&file_path, "old", "new"),
        &log_file,
        |command| {
            command.env("VIBEGUARD_PRE_EDIT_SUGGEST", "0");
        },
    );
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("use Glob/Grep"), "{stdout}");
    assert!(!stdout.contains("Likely candidates"), "{stdout}");
    assert!(!stdout.contains("No similar tracked files"), "{stdout}");
    let _ = fs::remove_dir_all(root);
}
