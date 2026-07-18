use super::*;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);
type TestResult = std::result::Result<(), Box<dyn std::error::Error>>;

fn temp_project(name: &str) -> PathBuf {
    let unique = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir().join(format!(
        "vibeguard_runtime_hook_checks_{name}_{}_{}",
        std::process::id(),
        unique
    ))
}

fn init_git_repo(root: &Path) -> io::Result<()> {
    fs::create_dir_all(root)?;
    let output = std::process::Command::new("git")
        .arg("-C")
        .arg(root)
        .arg("init")
        .arg("-q")
        .output()?;
    assert!(
        output.status.success(),
        "git init failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    Ok(())
}

#[test]
fn decision_block_json_escapes_reason_text() {
    let output = decision_block_json("old_string \"missing\"\nread first");
    let value: serde_json::Value =
        serde_json::from_str(&output).expect("decision output should be valid JSON");

    assert_eq!(value["decision"], "block");
    assert_eq!(value["reason"], "old_string \"missing\"\nread first");
}

#[test]
fn missing_required_args_return_usage_errors_before_stdin() {
    let pre_edit = pre_edit_check(&[]).expect_err("pre-edit args should be required");
    let post_edit = post_edit_fast_check(&[]).expect_err("post-edit args should be required");
    let post_write = post_write_fast_check(&[]).expect_err("post-write args should be required");

    assert!(pre_edit.to_string().contains("pre-edit-check"));
    assert!(post_edit.to_string().contains("post-edit-fast-check"));
    assert!(post_write.to_string().contains("post-write-fast-check"));
}

#[test]
fn pre_edit_reader_failure_propagates_without_a_safe_pass() -> TestResult {
    let root = temp_project("reader_failure");
    fs::create_dir_all(&root)?;
    let file_path = root.join("service.rs");
    fs::write(&file_path, "fn service() {}\n")?;
    let log_file = root.join("events.jsonl");
    let args = vec![
        "800".to_string(),
        "400".to_string(),
        log_file.to_string_lossy().into_owned(),
    ];
    let input = serde_json::json!({
        "tool_input": {
            "file_path": file_path,
            "old_string": "fn service() {}",
            "new_string": "fn service() { work(); }"
        }
    })
    .to_string();

    let error = pre_edit_check_with_readers(
        &args,
        || Ok(input),
        |_| Err(io::Error::other("injected pre-edit reader failure")),
    )
    .expect_err("source read failure must propagate instead of returning a safe pass");

    assert!(
        error
            .to_string()
            .contains("injected pre-edit reader failure")
    );
    assert!(
        !log_file.exists(),
        "read failure must not fabricate a pass log"
    );
    fs::remove_dir_all(root)?;
    Ok(())
}

#[test]
fn missing_file_candidates_distinguishes_empty_from_lookup_failure() -> TestResult {
    let root = temp_project("empty");
    init_git_repo(&root)?;
    let src_dir = root.join("src");
    fs::create_dir_all(&src_dir)?;
    let tracked = src_dir.join("lib.rs");
    fs::write(&tracked, "pub fn lib() {}\n")?;
    let add_output = std::process::Command::new("git")
        .arg("-C")
        .arg(&root)
        .arg("add")
        .arg("src/lib.rs")
        .output()?;
    assert!(
        add_output.status.success(),
        "git add failed: {}",
        String::from_utf8_lossy(&add_output.stderr)
    );

    let missing = root.join("src").join("missing_name.rs");
    assert_eq!(
        missing_file_candidates(missing.to_string_lossy().as_ref(), "missing_name"),
        MissingFileCandidates::Empty
    );

    fs::remove_dir_all(root)?;
    Ok(())
}

#[test]
fn missing_file_candidates_reports_git_lookup_failure() -> TestResult {
    let root = temp_project("bad_git");
    fs::create_dir_all(root.join(".git"))?;
    fs::create_dir_all(root.join("src"))?;
    let missing = root.join("src").join("lib.rs");

    let result = missing_file_candidates(missing.to_string_lossy().as_ref(), "lib");
    assert!(
        matches!(
            result,
            MissingFileCandidates::LookupFailed(ref detail) if detail.contains("git ls-files")
        ),
        "expected lookup failure that names git ls-files, got {result:?}"
    );

    fs::remove_dir_all(root)?;
    Ok(())
}

#[test]
fn post_edit_log_detail_preserves_delta_metadata() {
    assert_eq!(
        post_edit_log_detail("src/lib.rs", "old", "newer"),
        "src/lib.rs||delta=2"
    );
    assert_eq!(
        post_edit_log_detail("src/lib.rs", "abcdef", "xy"),
        "src/lib.rs||delta=-4"
    );
}
