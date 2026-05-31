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
    let entries = vec![
        HookStatusEntry {
            ts: "2026-05-31T00:00:00Z".to_string(),
            session: "s1".to_string(),
            source: "event_log".to_string(),
            hook: "vibeguard-post-build-check.sh".to_string(),
            event: "PostToolUse".to_string(),
            matcher: "Bash".to_string(),
            status: status::RUNNING.to_string(),
            decision: String::new(),
            reason: "npx tsc --noEmit".to_string(),
            detail: "Edit src/foo.ts".to_string(),
            duration_ms: None,
            elapsed_ms: Some(12_000),
            timeout_ms: Some(30_000),
            model_context: false,
            log_path: "events.jsonl".to_string(),
        },
        HookStatusEntry {
            ts: "2026-05-31T00:00:01Z".to_string(),
            session: "s1".to_string(),
            source: "event_log".to_string(),
            hook: "orca-bridge".to_string(),
            event: "PostToolUse".to_string(),
            matcher: "Bash".to_string(),
            status: status::SKIPPED.to_string(),
            decision: decision::PASS.to_string(),
            reason: "ORCA env absent".to_string(),
            detail: "Edit src/foo.ts".to_string(),
            duration_ms: Some(3),
            elapsed_ms: Some(3),
            timeout_ms: None,
            model_context: false,
            log_path: "events.jsonl".to_string(),
        },
    ];
    assert_eq!(
        minimal_line(&entries),
        "PostToolUse checks  1/2 running - 12s / 30s"
    );
}
