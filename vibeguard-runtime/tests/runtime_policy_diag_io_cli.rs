mod common;

use common::{bin, unique_temp_dir};
use std::fs;
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_STDIN_FIXTURE_ID: AtomicU64 = AtomicU64::new(0);

fn run_runtime_with_file_stdin(args: &[&str], input: &str) -> std::process::Output {
    let fixture_id = NEXT_STDIN_FIXTURE_ID.fetch_add(1, Ordering::Relaxed);
    let fixture_dir = unique_temp_dir(&format!("policy-diag-stdin-{fixture_id}"));
    fs::create_dir_all(&fixture_dir).expect("stdin fixture directory should be created");
    let input_path = fixture_dir.join("stdin");
    fs::write(&input_path, input).expect("stdin fixture should be written");
    let input_file = fs::File::open(&input_path).expect("stdin fixture should be opened");

    let output = bin()
        .args(args)
        .stdin(Stdio::from(input_file))
        .output()
        .expect("runtime helper should finish");

    fs::remove_dir_all(fixture_dir).expect("stdin fixture directory should be removed");
    output
}

#[test]
fn runtime_policy_diag_parent_create_error_is_visible() {
    let repo = unique_temp_dir("policy-diag-parent-error");
    fs::create_dir_all(&repo).expect("temporary directory should be created");
    let blocked_parent = repo.join("not-a-directory");
    fs::write(&blocked_parent, "unchanged").expect("blocking file should be written");
    let diag_file = blocked_parent.join("policy.jsonl");

    let output = run_runtime_with_file_stdin(
        &[
            "runtime-policy-diag",
            diag_file.to_str().expect("diagnostic path should be UTF-8"),
            "pre-bash-guard.sh",
            "PreToolUse",
            "policy_error",
            "run-hook-codex.sh",
        ],
        "runtime missing",
    );

    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    assert!(!output.stderr.is_empty());
    assert_eq!(fs::read_to_string(&blocked_parent).unwrap(), "unchanged");
    fs::remove_dir_all(repo).expect("temporary directory should be removed");
}

#[test]
fn runtime_policy_diag_open_error_is_visible() {
    let repo = unique_temp_dir("diag-open-error");
    fs::create_dir_all(&repo).expect("diagnostic directory should be created");

    let output = run_runtime_with_file_stdin(
        &[
            "runtime-policy-diag",
            repo.to_str().expect("diagnostic path should be UTF-8"),
            "pre-bash-guard.sh",
            "PreToolUse",
            "policy_error",
            "run-hook-codex.sh",
        ],
        "runtime missing",
    );

    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    assert!(!output.stderr.is_empty());
    assert!(repo.is_dir());
    fs::remove_dir_all(repo).expect("diagnostic directory should be removed");
}

#[cfg(target_os = "linux")]
#[test]
fn runtime_policy_diag_write_error_is_visible() {
    let output = run_runtime_with_file_stdin(
        &[
            "runtime-policy-diag",
            "/dev/full",
            "pre-bash-guard.sh",
            "PreToolUse",
            "policy_error",
            "run-hook-codex.sh",
        ],
        "runtime missing",
    );

    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    assert!(!output.stderr.is_empty());
}
