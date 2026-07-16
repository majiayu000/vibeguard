mod common;

use common::{run_runtime_with_stdin, unique_temp_dir};
use std::fs;

#[test]
fn runtime_policy_diag_parent_create_error_is_visible() {
    let repo = unique_temp_dir("policy-diag-parent-error");
    fs::create_dir_all(&repo).expect("temporary directory should be created");
    let blocked_parent = repo.join("not-a-directory");
    fs::write(&blocked_parent, "unchanged").expect("blocking file should be written");
    let diag_file = blocked_parent.join("policy.jsonl");

    let output = run_runtime_with_stdin(
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
    let _ = fs::remove_dir_all(repo);
}

#[cfg(target_os = "linux")]
#[test]
fn runtime_policy_diag_write_error_is_visible() {
    let output = run_runtime_with_stdin(
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
