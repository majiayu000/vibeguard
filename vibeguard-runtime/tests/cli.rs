mod common;

use common::bin;

#[test]
fn no_args_exits_2() {
    let out = bin().output().unwrap();
    assert_eq!(out.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("Usage:"),
        "expected 'Usage:' in stderr: {stderr}"
    );
}

#[test]
fn unknown_command_exits_2() {
    let out = bin().arg("bogus-cmd").output().unwrap();
    assert_eq!(out.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("Unknown command"),
        "expected 'Unknown command' in stderr: {stderr}"
    );
}

#[test]
fn help_lists_all_commands() {
    let out = bin().output().unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr);
    for name in &[
        "json-field",
        "json-two-fields",
        "churn-count",
        "warn-count",
        "post-edit-history",
        "build-fails",
        "paralysis-count",
        "append-jsonl",
        "circuit-breaker",
        "pkg-rewrite",
        "pre-bash-check",
        "session-metrics",
        "observe",
        "codex-event-name",
        "codex-status-detail",
        "codex-status-matcher",
        "codex-status-from-output",
        "codex-pretool-deny",
        "codex-permission-deny",
        "codex-adapt-pretool",
        "codex-adapt-posttool",
        "codex-adapt-permission-request",
        "codex-normalize-apply-patch",
        "pre-write-check",
        "pre-edit-check",
        "post-edit-fast-check",
        "post-write-fast-check",
        "post-write-check",
        "codex-app-server-wrapper",
    ] {
        assert!(
            stderr.contains(name),
            "expected '{name}' in help output: {stderr}"
        );
    }
}
