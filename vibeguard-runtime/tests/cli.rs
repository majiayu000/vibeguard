mod common;

use common::{bin, run_runtime_with_stdin};

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
fn version_prints_package_version() {
    let out = bin().arg("version").output().unwrap();
    assert!(out.status.success());
    assert_eq!(
        String::from_utf8_lossy(&out.stdout).trim(),
        env!("CARGO_PKG_VERSION")
    );
    assert!(
        out.stderr.is_empty(),
        "expected empty stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}

#[test]
fn help_lists_all_commands() {
    let out = bin().output().unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr);
    for name in &[
        "version",
        "json-field",
        "json-bool-field",
        "json-two-fields",
        "churn-count",
        "warn-count",
        "reason-count",
        "post-edit-history",
        "post-edit-w15",
        "build-fails",
        "paralysis-count",
        "append-jsonl",
        "circuit-breaker",
        "pkg-rewrite",
        "pre-bash-check",
        "session-metrics",
        "observe",
        "active-constraints",
        "hook-context",
        "stop-reason",
        "codex-event-name",
        "codex-status-detail",
        "codex-status-matcher",
        "codex-status-from-output",
        "codex-pretool-deny",
        "codex-permission-deny",
        "codex-visible-failure",
        "codex-diag",
        "codex-hook-status",
        "codex-adapt-pretool",
        "codex-adapt-posttool",
        "codex-adapt-permission-request",
        "codex-normalize-apply-patch",
        "runtime-policy-check",
        "runtime-policy-downgrade-output",
        "runtime-policy-codex-error",
        "runtime-policy-diag",
        "runtime-config-get-int",
        "runtime-config-get-str",
        "wrapper-env",
        "project-config-validate",
        "project-config-value",
        "pre-write-check",
        "pre-edit-check",
        "u16-limit",
        "test-path-filter",
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

#[test]
fn test_path_filter_classifies_rust_tests_suffix_without_broad_matches() {
    let input = concat!(
        "src/foo_tests.rs\n",
        "src/nested/parser_tests.rs\n",
        "src/contest.rs\n",
        "src/latest.rs\n",
        "src/tests_support.rs\n",
        "src/foo_tests.py\n",
    );

    let test_output = run_runtime_with_stdin(&["test-path-filter", "--test"], input);
    assert!(test_output.status.success());
    assert_eq!(
        String::from_utf8_lossy(&test_output.stdout),
        "src/foo_tests.rs\nsrc/nested/parser_tests.rs\n"
    );

    let prod_output = run_runtime_with_stdin(&["test-path-filter", "--prod"], input);
    assert!(prod_output.status.success());
    assert_eq!(
        String::from_utf8_lossy(&prod_output.stdout),
        concat!(
            "src/contest.rs\n",
            "src/latest.rs\n",
            "src/tests_support.rs\n",
            "src/foo_tests.py\n",
        )
    );
}
