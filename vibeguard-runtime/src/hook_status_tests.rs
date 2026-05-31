use super::*;

#[test]
fn normalizes_skip_without_model_context() {
    let event = json!({
        "ts": "2026-05-31T00:00:00Z",
        "hook": "post-build-check",
        "tool": "PostToolUse",
        "decision": "pass",
        "reason": "skip: missing file_path",
        "duration_ms": 28
    });
    let entry = normalize_hook_event(&event, "events.jsonl", DEFAULT_SLOW_MS);
    assert_eq!(entry.status, status::SKIPPED);
    assert_eq!(entry.reason, "missing file_path");
    assert!(!entry.model_context);
}

#[test]
fn warn_and_block_are_model_context() {
    assert!(model_context_for_status(status::WARN));
    assert!(model_context_for_status(status::BLOCK));
    assert!(!model_context_for_status(status::PASS));
    assert!(!model_context_for_status(status::SKIPPED));
}

#[test]
fn pass_over_threshold_becomes_slow() {
    assert_eq!(
        normalize_status("", decision::PASS, "", Some(2_500), DEFAULT_SLOW_MS, false),
        status::SLOW
    );
}

#[test]
fn timeout_reason_wins_over_warn_decision() {
    assert_eq!(
        normalize_status(
            "",
            decision::WARN,
            "post-build-check timeout after 30s",
            None,
            DEFAULT_SLOW_MS,
            false,
        ),
        status::TIMEOUT
    );
}

#[test]
fn diag_adapter_reason_becomes_adapter_error() {
    let event = json!({
        "ts": "2026-05-31T00:00:00Z",
        "hook": "vibeguard-post-build-check.sh",
        "event": "PostToolUse",
        "reason": "posttool-adapter-failed",
        "detail": "{}"
    });
    let entry = normalize_diag_event(&event, "codex-wrapper.jsonl");
    assert_eq!(entry.status, status::ADAPTER_ERROR);
    assert!(!entry.model_context);
}

#[test]
fn running_summary_shows_elapsed_and_timeout() {
    let running = json!({
        "ts": "2026-05-31T00:00:00Z",
        "hook": "vibeguard-post-build-check.sh",
        "event": "PostToolUse",
        "matcher": "Bash",
        "status": "running",
        "reason": "npx tsc --noEmit",
        "detail": "Edit src/foo.ts",
        "elapsed_ms": 12000,
        "timeout_ms": 30000
    });
    let skipped = json!({
        "ts": "2026-05-31T00:00:01Z",
        "hook": "orca-bridge",
        "event": "PostToolUse",
        "matcher": "Bash",
        "decision": "pass",
        "reason": "skip: ORCA env absent",
        "detail": "Edit src/foo.ts",
        "duration_ms": 3
    });
    let entries = vec![
        normalize_hook_event(&running, "events.jsonl", DEFAULT_SLOW_MS),
        normalize_hook_event(&skipped, "events.jsonl", DEFAULT_SLOW_MS),
    ];
    assert_eq!(
        minimal_line(&entries),
        "PostToolUse checks  1/2 running - 12s / 30s"
    );
}
