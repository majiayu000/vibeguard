use super::*;
use serde_json::json;

fn test_context(log_file: std::path::PathBuf) -> RuntimeContext {
    RuntimeContext {
        log_root: log_file.parent().unwrap().to_path_buf(),
        log_file,
        project_hash: "test-project".into(),
        session_id: "current".into(),
        cli: "codex".into(),
        client: "codex".into(),
        client_variant: "codex-cli-hooks".into(),
        caller_evidence: "explicit-test".into(),
        session_source: "codex-thread".into(),
    }
}

fn w14_shown_event(session: &str, key: &str, timestamp: u64) -> Value {
    json!({
        "ts": crate::time_utils::format_unix_secs_utc(timestamp),
        "session": session,
        "hook": "post-edit-guard",
        "tool": "Edit",
        "decision": "warn",
        "status": "warn",
        "reason": "[W-14] overlap shown session peer agent codex",
        "detail": format!("src/main.rs||w14_key={key}"),
    })
}

#[test]
fn delta_metadata_is_read_from_post_edit_detail() {
    assert_eq!(
        post_edit_delta_from_detail("src/main.rs||delta=-42"),
        Some(-42)
    );
    assert_eq!(post_edit_delta_from_detail("src/main.rs||other=1"), None);
}

#[test]
fn same_file_trail_stops_at_first_other_file() {
    let events = vec![
        json!({"session":"s","tool":"Edit","hook":"post-edit-guard","detail":"src/a.rs||delta=9"}),
        json!({"session":"s","tool":"Edit","hook":"post-edit-guard","detail":"src/b.rs||delta=8"}),
        json!({"session":"s","tool":"Edit","hook":"post-edit-guard","detail":"src/a.rs||delta=5"}),
        json!({"session":"s","tool":"Edit","hook":"post-edit-guard","detail":"src/a.rs||delta=3"}),
    ];

    let trail = same_file_edit_trail(&events, "s", "src/a.rs");
    assert_eq!(trail.consecutive, 2);
    assert_eq!(trail.deltas, vec![3, 5]);
}

#[test]
fn history_file_helpers_match_common_paths() {
    assert_eq!(post_edit_history_file_name("src/main.rs"), "main.rs");
    assert_eq!(post_edit_history_extension("docs/guide.md"), "md");
}

#[test]
fn w14_key_is_directed_and_rejects_unknown_sessions() {
    let Some(forward) = w14_key("current", "peer", "/repo/src/main.rs") else {
        panic!("known sessions and file should produce a key");
    };
    let Some(reverse) = w14_key("peer", "current", "/repo/src/main.rs") else {
        panic!("reversed known sessions should produce a key");
    };
    let Some(other_file) = w14_key("current", "peer", "/repo/src/lib.rs") else {
        panic!("a different known file should produce a key");
    };

    assert_eq!(forward.len(), 64);
    assert!(forward.bytes().all(|byte| byte.is_ascii_hexdigit()));
    assert_ne!(forward, reverse);
    assert_ne!(forward, other_file);
    assert_eq!(w14_key("unknown", "peer", "/repo/src/main.rs"), None);
    assert_eq!(w14_key("current", "?", "/repo/src/main.rs"), None);
}

#[test]
fn w14_detail_keeps_the_full_path_and_key_at_platform_scale() {
    let key = "a".repeat(64);
    let path = "x".repeat(8192);
    let detail = w14_event_detail(&path, &key);
    let detail_limit = detail.chars().count();

    assert_eq!(detail_limit, path.chars().count() + 10 + key.len());
    assert_eq!(first_detail_path(&json!({"detail": detail})), path);
    assert!(detail.ends_with(&format!("||w14_key={key}")));
    assert_eq!(w14_key_from_detail(&detail), Some(key.as_str()));
}

#[test]
fn shown_evidence_obeys_time_key_and_bounded_history_contract() {
    let now = 1_800_000_000;
    let key = "b".repeat(64);
    let shown = w14_shown_event("current", &key, now - 59);
    assert!(has_recent_w14_shown(
        std::slice::from_ref(&shown),
        "current",
        &key,
        now,
        60
    ));

    let exact_boundary = w14_shown_event("current", &key, now - 60);
    assert!(!has_recent_w14_shown(
        &[exact_boundary],
        "current",
        &key,
        now,
        60
    ));
    let future = w14_shown_event("current", &key, now + 1);
    assert!(!has_recent_w14_shown(&[future], "current", &key, now, 60));
    let mut invalid_timestamp = shown.clone();
    invalid_timestamp[field::TS] = json!("not-a-timestamp");
    assert!(!has_recent_w14_shown(
        &[invalid_timestamp],
        "current",
        &key,
        now,
        60
    ));
    assert!(!has_recent_w14_shown(
        std::slice::from_ref(&shown),
        "other-current",
        &key,
        now,
        60
    ));
    assert!(!has_recent_w14_shown(
        std::slice::from_ref(&shown),
        "current",
        &"c".repeat(64),
        now,
        60
    ));

    let suppressed = json!({
        "ts": crate::time_utils::format_unix_secs_utc(now - 1),
        "session": "current",
        "hook": "post-edit-guard",
        "tool": "Edit",
        "decision": "pass",
        "status": "skipped",
        "reason": "[W-14] overlap suppressed cooldown",
        "detail": format!("src/main.rs||w14_key={key}"),
    });
    assert!(!has_recent_w14_shown(
        &[suppressed],
        "current",
        &key,
        now,
        60
    ));

    let mut beyond_tail = vec![shown];
    beyond_tail.extend((0..POST_EDIT_HISTORY_LINES).map(|index| {
        json!({
            "ts": crate::time_utils::format_unix_secs_utc(now - 1),
            "session": format!("filler-{index}"),
        })
    }));
    assert!(!has_recent_w14_shown(
        &beyond_tail,
        "current",
        &key,
        now,
        60
    ));
}

#[test]
fn suppression_requires_successful_audit_append() {
    let called = std::cell::Cell::new(false);
    assert_eq!(
        suppress_after_audit(false, || {
            called.set(true);
            Ok::<(), ()>(())
        }),
        Ok(false)
    );
    assert!(!called.get());
    assert_eq!(suppress_after_audit(true, || Ok::<(), ()>(())), Ok(true));
    assert_eq!(
        suppress_after_audit(true, || Err::<(), _>("locked")),
        Err("locked")
    );
}

#[test]
fn suppressed_w14_does_not_increase_prior_warn_count() {
    let key = "d".repeat(64);
    let events = vec![
        w14_shown_event("current", &key, 1_800_000_000),
        json!({
            "session": "current",
            "hook": "post-edit-guard",
            "tool": "Edit",
            "decision": "pass",
            "status": "skipped",
            "reason": "[W-14] overlap suppressed cooldown",
            "detail": format!("src/main.rs||w14_key={key}"),
        }),
    ];

    assert_eq!(
        count_prior_warn_events_in(&events, "current", "src/main.rs"),
        1
    );
}

#[test]
fn shared_history_snapshot_drives_warnings_and_prior_count() {
    let root = std::env::temp_dir().join(format!("vg-history-snapshot-{}", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();
    let ctx = test_context(root.join("events.jsonl"));
    let event = json!({
        "session":"current", "hook":"post-edit-guard", "tool":"Edit",
        "decision":"warn", "reason":"[RS-03] prior", "detail":"src/main.rs||delta=9"
    });
    std::fs::write(&ctx.log_file, format!("{event}\n")).unwrap();

    let events = read_post_edit_history_events(&ctx).unwrap();
    assert_eq!(
        count_prior_warn_events(&events, "current", "src/main.rs"),
        1
    );
    assert_eq!(
        same_file_edit_trail(&events, "current", "src/main.rs").consecutive,
        1
    );
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn append_failure_preserves_churn_and_w15_warnings() {
    let ctx = test_context(std::path::PathBuf::from("/not-written/events.jsonl"));
    for label in ["[CHURN] original warning", "[W-15] original warning"] {
        let mut warnings = Vec::new();
        preserve_warning_after_append(&ctx, &mut warnings, label.to_string(), || {
            Err::<(), _>(std::io::Error::other("injected append failure"))
        });
        assert_eq!(warnings[0], label);
        assert!(warnings[1].contains("VG-INTERNAL-LOG-APPEND"));
        assert!(warnings[1].contains("history telemetry append failed"));
    }
}
