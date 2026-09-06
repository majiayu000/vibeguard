mod common;

use common::{bin, unique_temp_dir};
use serde_json::{Value, json};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Output, Stdio};

fn run_post_edit(repo: &Path, log_root: &Path, log_file: &Path, input: &str) -> Output {
    let project_log_dir = log_root.join("projects").join("post-edit-project");
    let mut child = bin()
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
        .env("VG_U16_WARN_LIMIT", "400")
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
fn post_edit_does_not_warn_for_preexisting_empty_catch() {
    let (root, repo, log_root, log_file) = case_paths("post-edit-empty-catch-preexisting");
    let source = repo.join("src/service.mjs");
    fs::create_dir_all(source.parent().unwrap()).unwrap();
    fs::write(
        &source,
        "try { run(); } catch (error) { }\nconst ready = true;\n",
    )
    .unwrap();
    let input = edit_input(
        source.to_string_lossy().as_ref(),
        "const ready = true;",
        "const ready = false;",
    );
    let out = run_post_edit(&repo, &log_root, &log_file, &input);

    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        !stdout.contains("[JS-EMPTY-CATCH]"),
        "pre-existing empty catch must not warn on an unrelated edit: {stdout}"
    );
    let events = parse_test_event_log(&log_file);
    assert_eq!(events.last().unwrap()["decision"], "pass");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn post_edit_warns_once_for_introduced_empty_catch() {
    let (root, repo, log_root, log_file) = case_paths("post-edit-empty-catch-introduced");
    let source = repo.join("src/service.mjs");
    fs::create_dir_all(source.parent().unwrap()).unwrap();
    fs::write(&source, "const ready = true;\n").unwrap();
    let input = edit_input(
        source.to_string_lossy().as_ref(),
        "const ready = true;",
        "try { run(); } catch (error) { }\nconst ready = true;",
    );
    let out = run_post_edit(&repo, &log_root, &log_file, &input);

    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("[JS-EMPTY-CATCH]"), "{stdout}");
    assert!(stdout.contains("[this-edit]"), "{stdout}");
    assert!(
        stdout.contains("this edit introduces 1 empty catch block"),
        "{stdout}"
    );
    assert!(stdout.contains("existing error path"), "{stdout}");
    assert!(stdout.contains("intentionally best-effort"), "{stdout}");
    assert!(stdout.contains("create logging infrastructure"), "{stdout}");
    assert!(stdout.contains("change public APIs"), "{stdout}");
    assert!(!stdout.contains("[this-file]"), "{stdout}");
    let events = parse_test_event_log(&log_file);
    assert_eq!(events.last().unwrap()["decision"], "warn");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn post_edit_does_not_warn_when_empty_catch_is_filled_in() {
    let (root, repo, log_root, log_file) = case_paths("post-edit-empty-catch-filled");
    let source = repo.join("src/service.mjs");
    fs::create_dir_all(source.parent().unwrap()).unwrap();
    fs::write(&source, "try { run(); } catch (error) { }\n").unwrap();
    let input = edit_input(
        source.to_string_lossy().as_ref(),
        "catch (error) { }",
        "catch (error) { report(error); }",
    );
    let out = run_post_edit(&repo, &log_root, &log_file, &input);

    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        !stdout.contains("[JS-EMPTY-CATCH]"),
        "filling an empty catch must not warn: {stdout}"
    );
    let events = parse_test_event_log(&log_file);
    assert_eq!(events.last().unwrap()["decision"], "pass");
    let _ = fs::remove_dir_all(root);
}
