mod common;

use common::{bin, unique_temp_dir};
use serde_json::{Value, json};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Output, Stdio};

fn run_pre_edit(repo: &Path, log_root: &Path, log_file: &Path, input: &str) -> Output {
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
        .args(["hook", "pre-edit"])
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
fn pre_edit_does_not_warn_for_preexisting_empty_catch() {
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
    let out = run_pre_edit(&repo, &log_root, &log_file, &input);

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
fn pre_edit_warns_once_for_introduced_empty_catch() {
    let (root, repo, log_root, log_file) = case_paths("post-edit-empty-catch-introduced");
    let source = repo.join("src/service.mjs");
    fs::create_dir_all(source.parent().unwrap()).unwrap();
    fs::write(&source, "const ready = true;\n").unwrap();
    let input = edit_input(
        source.to_string_lossy().as_ref(),
        "const ready = true;",
        "try { run(); } catch (error) { }\nconst ready = true;",
    );
    let out = run_pre_edit(&repo, &log_root, &log_file, &input);

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
fn pre_edit_does_not_warn_when_empty_catch_is_filled_in() {
    let (root, repo, log_root, log_file) = case_paths("post-edit-empty-catch-filled");
    let source = repo.join("src/service.mjs");
    fs::create_dir_all(source.parent().unwrap()).unwrap();
    fs::write(&source, "try { run(); } catch (error) { }\n").unwrap();
    let input = edit_input(
        source.to_string_lossy().as_ref(),
        "catch (error) { }",
        "catch (error) { report(error); }",
    );
    let out = run_pre_edit(&repo, &log_root, &log_file, &input);

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

#[test]
fn pre_edit_warns_when_handler_snippet_becomes_empty() {
    let (root, repo, log_root, log_file) = case_paths("post-edit-empty-catch-handler-snippet");
    let source = repo.join("src/service.mjs");
    fs::create_dir_all(source.parent().unwrap()).unwrap();
    fs::write(&source, "try { run(); } catch (error) { report(error); }\n").unwrap();
    let input = edit_input(
        source.to_string_lossy().as_ref(),
        "catch (error) { report(error); }",
        "catch (error) { }",
    );
    let out = run_pre_edit(&repo, &log_root, &log_file, &input);

    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        stdout.contains("[JS-EMPTY-CATCH]"),
        "emptying a catch handler snippet must warn: {stdout}"
    );
    let events = parse_test_event_log(&log_file);
    assert_eq!(events.last().unwrap()["decision"], "warn");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn pre_edit_uses_file_context_for_body_deletion_and_catch_methods() {
    for (label, before, old, new, should_warn) in [
        (
            "body-delete",
            "try { run(); } catch (e) { report(e); }",
            "report(e);",
            "",
            true,
        ),
        (
            "class-method",
            "class C { catch(e) { report(e); } }",
            "catch(e) { report(e); }",
            "catch(e) {}",
            false,
        ),
        (
            "object-method",
            "const c = { catch(e) { report(e); } };",
            "catch(e) { report(e); }",
            "catch(e) {}",
            false,
        ),
        (
            "old-catch-deletion-elsewhere",
            "try { run(); } catch {}\nreport(e);",
            "report(e);",
            "",
            false,
        ),
        (
            "new-beside-old",
            "try { old(); } catch {}\ntry { run(); } catch (e) { report(e); }",
            "report(e);",
            "",
            true,
        ),
        (
            "comment-best-effort",
            "try { run(); } catch (e) { /* best effort */ }\nconst x = 1;",
            "const x = 1;",
            "const x = 2;",
            false,
        ),
    ] {
        let (root, repo, log_root, log_file) = case_paths(label);
        let source = repo.join("service.js");
        fs::write(&source, before).unwrap();
        let input = edit_input(source.to_str().unwrap(), old, new);
        let out = run_pre_edit(&repo, &log_root, &log_file, &input);
        assert_eq!(out.status.code(), Some(0), "{label}: {:?}", out);
        let stdout = String::from_utf8_lossy(&out.stdout);
        assert_eq!(
            stdout.contains("[JS-EMPTY-CATCH]"),
            should_warn,
            "{label}: {stdout}"
        );
        assert_eq!(fs::read_to_string(&source).unwrap(), before);
        fs::remove_dir_all(root).unwrap();
    }
}

#[test]
fn post_edit_does_not_duplicate_the_pre_edit_warning() {
    let (root, repo, log_root, log_file) = case_paths("post-edit-no-duplicate");
    let source = repo.join("service.js");
    fs::write(&source, "try { run(); } catch {};").unwrap();
    let mut child = bin()
        .current_dir(&repo)
        .env("VIBEGUARD_LOG_DIR", &log_root)
        .env("VIBEGUARD_LOG_FILE", &log_file)
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
        .write_all(
            edit_input(
                source.to_str().unwrap(),
                "report(e);",
                "try { run(); } catch {};",
            )
            .as_bytes(),
        )
        .unwrap();
    let out = child.wait_with_output().unwrap();
    assert!(out.status.success(), "{:?}", out);
    assert!(!String::from_utf8_lossy(&out.stdout).contains("[JS-EMPTY-CATCH]"));
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn pre_edit_keeps_empty_catch_review_alongside_size_advisory() {
    let (root, repo, log_root, log_file) = case_paths("empty-catch-size-advisory");
    let source = repo.join("service.js");
    fs::write(
        &source,
        format!(
            "{}try {{ run(); }} catch (e) {{ report(e); }}\n",
            "// existing line\n".repeat(410)
        ),
    )
    .unwrap();
    let out = run_pre_edit(
        &repo,
        &log_root,
        &log_file,
        &edit_input(source.to_str().unwrap(), "report(e);", " "),
    );
    assert!(out.status.success(), "{:?}", out);
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("[JS-EMPTY-CATCH]"), "{stdout}");
    assert!(stdout.contains("U-16"), "{stdout}");
    fs::remove_dir_all(root).unwrap();
}
