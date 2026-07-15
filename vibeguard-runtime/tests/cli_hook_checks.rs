mod common;

use common::{bin, unique_temp_dir};
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

fn run_post_edit_fast_check(input: &str, log_file: &std::path::Path) -> std::process::Output {
    let mut child = bin()
        .args([
            "post-edit-fast-check",
            "800",
            "test-session",
            "codex",
            log_file.to_string_lossy().as_ref(),
        ])
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

fn run_pre_edit_check(input: &str, log_file: &std::path::Path) -> std::process::Output {
    run_pre_edit_check_with(input, log_file, |_| {})
}

fn run_pre_edit_check_with(
    input: &str,
    log_file: &std::path::Path,
    configure: impl FnOnce(&mut std::process::Command),
) -> std::process::Output {
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

#[test]
fn post_edit_fast_check_reports_malformed_json() {
    let root = unique_temp_dir("post-edit-malformed");
    fs::create_dir_all(&root).unwrap();
    let log_file = root.join("events.jsonl");
    let out = run_post_edit_fast_check("not-json", &log_file);

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
fn post_edit_fast_check_keeps_malformed_warning_visible_when_log_fails() {
    let root = unique_temp_dir("post-edit-malformed-log-failure");
    fs::create_dir_all(&root).unwrap();
    let blocking_parent = root.join("not-a-directory");
    fs::write(&blocking_parent, "blocks log parent creation").unwrap();
    let log_file = blocking_parent.join("events.jsonl");

    let out = run_post_edit_fast_check("not-json", &log_file);
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stdout.contains("FAST_OUTPUT"), "{stdout}");
    assert!(stdout.contains("malformed PostToolUse(Edit)"), "{stdout}");
    assert!(stdout.contains("VG-INTERNAL-LOG-APPEND"), "{stdout}");
    assert!(stdout.contains("mode=allow"), "{stdout}");
    assert!(
        stderr.contains("post-edit malformed input log failed"),
        "{stderr}"
    );
    assert!(!log_file.exists());
    let _ = fs::remove_dir_all(root);
}

#[test]
fn post_edit_fast_check_skips_missing_required_fields() {
    let root = unique_temp_dir("post-edit-missing-fields");
    fs::create_dir_all(&root).unwrap();
    let log_file = root.join("events.jsonl");

    for input in [
        r#"{"tool_input":{"new_string":"fn clean() {}"}}"#,
        r#"{"tool_input":{"file_path":"src/lib.rs"}}"#,
    ] {
        let out = run_post_edit_fast_check(input, &log_file);
        assert_eq!(out.status.code(), Some(0));
        assert_eq!(String::from_utf8_lossy(&out.stdout), "SKIP\n");
        assert!(out.stderr.is_empty());
    }
    assert!(!log_file.exists(), "skip must not fabricate a pass log");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn post_edit_fast_check_exposes_non_clean_edit_fallback() {
    let root = unique_temp_dir("post-edit-fallback");
    fs::create_dir_all(&root).unwrap();
    let log_file = root.join("events.jsonl");
    let input = serde_json::json!({
        "tool_input": {
            "file_path": "src/lib.rs",
            "old_string": "safe_call()?",
            "new_string": "unsafe_call().unwrap()"
        }
    })
    .to_string();

    let out = run_post_edit_fast_check(&input, &log_file);
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "FALLBACK\n");
    assert!(out.stderr.is_empty());
    assert!(!log_file.exists(), "fallback must defer the final decision");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn post_edit_fast_check_logs_pass_when_history_file_is_missing() {
    let root = unique_temp_dir("post-edit-missing-history");
    fs::create_dir_all(&root).unwrap();
    let log_file = root.join("events.jsonl");
    let input = serde_json::json!({
        "tool_input": {
            "file_path": "src/lib.rs",
            "old_string": "fn old() {}",
            "new_string": "fn clean() {}"
        }
    })
    .to_string();

    let out = run_post_edit_fast_check(&input, &log_file);
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "FAST_LOGGED\n");
    assert!(out.stderr.is_empty());
    let log_text = fs::read_to_string(&log_file).unwrap();
    assert!(log_text.contains("\"decision\":\"pass\""), "{log_text}");
    assert!(log_text.contains("src/lib.rs||delta=2"), "{log_text}");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn post_edit_fast_check_malformed_history_falls_back_visibly() {
    let root = unique_temp_dir("post-edit-malformed-history");
    fs::create_dir_all(&root).unwrap();
    let log_file = root.join("events.jsonl");
    fs::write(&log_file, "not-json\n").unwrap();
    let input = serde_json::json!({
        "tool_input": {
            "file_path": "src/lib.rs",
            "old_string": "fn old() {}",
            "new_string": "fn clean() {}"
        }
    })
    .to_string();

    let out = run_post_edit_fast_check(&input, &log_file);
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "FALLBACK\n");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("post-edit history read failed"), "{stderr}");
    assert!(
        stderr.contains("malformed post-edit history JSONL"),
        "{stderr}"
    );
    assert_eq!(fs::read_to_string(&log_file).unwrap(), "not-json\n");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn post_edit_fast_check_history_io_error_falls_back_visibly() {
    let root = unique_temp_dir("post-edit-history-io-error");
    fs::create_dir_all(&root).unwrap();
    let log_file = root.join("events-as-directory");
    fs::create_dir_all(&log_file).unwrap();
    let input = serde_json::json!({
        "tool_input": {
            "file_path": "src/lib.rs",
            "old_string": "fn old() {}",
            "new_string": "fn clean() {}"
        }
    })
    .to_string();

    let out = run_post_edit_fast_check(&input, &log_file);
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "FALLBACK\n");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("post-edit history read failed"), "{stderr}");
    assert!(
        log_file.is_dir(),
        "history I/O fixture must remain a directory"
    );
    let _ = fs::remove_dir_all(root);
}

#[test]
fn post_edit_fast_check_emits_churn_and_overlap_warning_from_history() {
    let root = unique_temp_dir("post-edit-history-warning");
    fs::create_dir_all(&root).unwrap();
    let log_file = root.join("events.jsonl");
    let mut events = (0..5)
        .map(|_| {
            serde_json::json!({
                "ts": "2099-01-01T00:00:00Z",
                "session": "test-session",
                "agent": "codex",
                "hook": "post-edit-guard",
                "tool": "Edit",
                "decision": "pass",
                "detail": "src/lib.rs||delta=1"
            })
        })
        .collect::<Vec<_>>();
    events.push(serde_json::json!({
        "ts": "2099-01-01T00:00:00Z",
        "session": "test-session",
        "agent": "codex",
        "hook": "post-edit-guard",
        "tool": "Edit",
        "decision": "pass",
        "detail": "src/other.rs||delta=1"
    }));
    events.push(serde_json::json!({
        "ts": "2099-01-01T00:00:00Z",
        "session": "peer-session",
        "agent": "claude",
        "hook": "post-edit-guard",
        "tool": "Edit",
        "decision": "pass",
        "detail": "src/lib.rs||delta=1"
    }));
    let history = events
        .iter()
        .map(serde_json::Value::to_string)
        .collect::<Vec<_>>()
        .join("\n");
    fs::write(&log_file, format!("{history}\n")).unwrap();
    let input = serde_json::json!({
        "tool_input": {
            "file_path": "src/lib.rs",
            "old_string": "fn old() {}",
            "new_string": "fn clean() {}"
        }
    })
    .to_string();

    let out = run_post_edit_fast_check(&input, &log_file);
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.starts_with("FAST_OUTPUT\n"), "{stdout}");
    assert!(stdout.contains("[CHURN]"), "{stdout}");
    assert!(stdout.contains("[W-14]"), "{stdout}");
    assert!(stdout.contains("peer-session"), "{stdout}");
    let log_text = fs::read_to_string(&log_file).unwrap();
    assert!(log_text.contains("\"decision\":\"warn\""), "{log_text}");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn post_edit_fast_check_defers_consecutive_history_to_shell_w15() {
    let root = unique_temp_dir("post-edit-history-w15-fallback");
    fs::create_dir_all(&root).unwrap();
    let log_file = root.join("events.jsonl");
    let event = serde_json::json!({
        "session": "test-session",
        "hook": "post-edit-guard",
        "tool": "Edit",
        "decision": "pass",
        "detail": "src/lib.rs||delta=1"
    });
    fs::write(&log_file, format!("{event}\n{event}\n")).unwrap();
    let before = fs::read_to_string(&log_file).unwrap();
    let input = serde_json::json!({
        "tool_input": {
            "file_path": "src/lib.rs",
            "old_string": "fn old() {}",
            "new_string": "fn clean() {}"
        }
    })
    .to_string();

    let out = run_post_edit_fast_check(&input, &log_file);
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "FALLBACK\n");
    assert!(out.stderr.is_empty());
    assert_eq!(fs::read_to_string(&log_file).unwrap(), before);
    let _ = fs::remove_dir_all(root);
}

#[test]
fn post_edit_fast_check_exposes_history_read_failure_before_pass_log() {
    let root = unique_temp_dir("post-edit-log-failure");
    fs::create_dir_all(&root).unwrap();
    let blocking_parent = root.join("not-a-directory");
    fs::write(&blocking_parent, "blocks log parent creation").unwrap();
    let log_file = blocking_parent.join("events.jsonl");
    let input = serde_json::json!({
        "tool_input": {
            "file_path": "src/lib.rs",
            "old_string": "fn old() {}",
            "new_string": "fn clean() {}"
        }
    })
    .to_string();

    let out = run_post_edit_fast_check(&input, &log_file);
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert_eq!(stdout, "FALLBACK\n");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("post-edit history read failed"), "{stderr}");
    assert!(
        !log_file.exists(),
        "failed logging must not claim persistence"
    );
    let _ = fs::remove_dir_all(root);
}

#[test]
fn pre_edit_check_blocks_missing_file_with_lookup_failure_visible() {
    let root = unique_temp_dir("pre-edit-missing-file");
    fs::create_dir_all(&root).unwrap();
    let file_path = root.join("src").join("missing_service.rs");
    let log_file = root.join("events.jsonl");
    let input = serde_json::json!({
        "tool_input": {
            "file_path": file_path,
            "old_string": "old",
            "new_string": "new"
        }
    })
    .to_string();

    let out = run_pre_edit_check(&input, &log_file);
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.starts_with("FAST_OUTPUT\n"), "{stdout}");
    assert!(stdout.contains("\"decision\": \"block\""), "{stdout}");
    assert!(stdout.contains("File does not exist"), "{stdout}");
    assert!(stdout.contains("no git project root found"), "{stdout}");
    assert!(out.stderr.is_empty());
    let log_text = fs::read_to_string(&log_file).unwrap();
    assert!(log_text.contains("\"decision\":\"block\""), "{log_text}");
    assert!(log_text.contains("File does not exist"), "{log_text}");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn pre_edit_check_exposes_missing_git_dependency() {
    let root = unique_temp_dir("pre-edit-missing-git");
    fs::create_dir_all(root.join(".git")).unwrap();
    let file_path = root.join("src").join("missing_service.rs");
    let log_file = root.join("events.jsonl");
    let input = serde_json::json!({
        "tool_input": {
            "file_path": file_path,
            "old_string": "old",
            "new_string": "new"
        }
    })
    .to_string();

    let out = run_pre_edit_check_with(&input, &log_file, |command| {
        command.env("PATH", "");
    });
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.starts_with("FAST_OUTPUT\n"), "{stdout}");
    assert!(stdout.contains("\"decision\": \"block\""), "{stdout}");
    assert!(stdout.contains("git ls-files could not run"), "{stdout}");
    assert!(out.stderr.is_empty());
    let log_text = fs::read_to_string(&log_file).unwrap();
    assert!(log_text.contains("File does not exist"), "{log_text}");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn pre_edit_check_blocks_stale_old_string() {
    let root = unique_temp_dir("pre-edit-stale-old-string");
    fs::create_dir_all(&root).unwrap();
    let file_path = root.join("lib.rs");
    fs::write(&file_path, "fn current() {}\n").unwrap();
    let log_file = root.join("events.jsonl");
    let input = serde_json::json!({
        "tool_input": {
            "file_path": file_path,
            "old_string": "fn stale() {}",
            "new_string": "fn replacement() {}"
        }
    })
    .to_string();

    let out = run_pre_edit_check(&input, &log_file);
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.starts_with("FAST_OUTPUT\n"), "{stdout}");
    assert!(stdout.contains("\"decision\": \"block\""), "{stdout}");
    assert!(stdout.contains("old_string does not exist"), "{stdout}");
    assert!(stdout.contains("use the Read tool"), "{stdout}");
    assert!(out.stderr.is_empty());
    let log_text = fs::read_to_string(&log_file).unwrap();
    assert!(log_text.contains("old_string does not exist"), "{log_text}");
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
