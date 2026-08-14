use super::*;
use serde_json::{Value, json};
use std::fs;

fn temp_root(label: &str) -> std::path::PathBuf {
    let root = std::env::temp_dir().join(format!(
        "vg-post-history-review-{label}-{}",
        std::process::id()
    ));
    if root.exists() {
        fs::remove_dir_all(&root).unwrap();
    }
    fs::create_dir_all(&root).unwrap();
    root
}

fn review_context(log_file: std::path::PathBuf) -> RuntimeContext {
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

fn read_test_events(path: &Path) -> Vec<Value> {
    fs::read_to_string(path)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}

fn edit_events(count: usize, file_path: &str) -> Vec<Value> {
    (0..count)
        .map(|_| {
            json!({
                "session": "current",
                "hook": "post-edit-guard",
                "tool": "Edit",
                "decision": "pass",
                "detail": format!("{file_path}||delta=1"),
            })
        })
        .collect()
}

fn assert_churn_warning(root: &Path, count: usize, marker: &str, expected_reason: &str) {
    let ctx = review_context(root.join(format!("churn-{count}.jsonl")));
    let events = edit_events(count, "src/main.rs");
    let mut warnings = Vec::new();
    detect_churn(
        &ctx,
        Instant::now(),
        "src/main.rs",
        false,
        &events,
        &events,
        &mut warnings,
    );

    assert_eq!(warnings.len(), 1);
    assert!(warnings[0].contains(marker));
    let logged = read_test_events(&ctx.log_file);
    assert_eq!(logged.len(), 1);
    assert_eq!(logged[0][field::DECISION], decision::CORRECTION);
    assert_eq!(logged[0][field::REASON], expected_reason);
}

#[test]
fn churn_thresholds_and_w15_shrinking_radius_are_behavioral() {
    let root = temp_root("churn");
    let four_ctx = review_context(root.join("four.jsonl"));
    let four = edit_events(4, "src/main.rs");
    let mut warnings = Vec::new();
    detect_churn(
        &four_ctx,
        Instant::now(),
        "src/main.rs",
        false,
        &four,
        &four,
        &mut warnings,
    );
    assert!(warnings.is_empty());
    assert!(!four_ctx.log_file.exists());

    assert_churn_warning(&root, 5, "[CHURN]", "churn 5x");
    assert_churn_warning(&root, 10, "[CHURN WARNING]", "churn 10x warning");

    let volume_ctx = review_context(root.join("volume.jsonl"));
    let volume = edit_events(20, "src/main.rs");
    detect_churn(
        &volume_ctx,
        Instant::now(),
        "src/main.rs",
        false,
        &volume,
        &volume,
        &mut warnings,
    );
    assert_eq!(warnings.len(), 1);
    assert!(warnings[0].contains("[CHURN WARNING]"));
    assert!(warnings[0].contains("high edit volume"));
    let volume_events = read_test_events(&volume_ctx.log_file);
    assert_eq!(volume_events.len(), 1);
    assert_eq!(volume_events[0][field::DECISION], decision::CORRECTION);
    assert_eq!(volume_events[0][field::REASON], "churn 20x volume");

    let critical_ctx = review_context(root.join("critical.jsonl"));
    let mut critical = edit_events(20, "src/main.rs");
    let project = current_git_root_by_marker().unwrap();
    let failure_path = project.join("src/failing.rs").to_string_lossy().to_string();
    critical.extend((0..5).map(|_| {
        json!({
            "session": "current",
            "hook": "post-build-check",
            "tool": "Bash",
            "decision": "warn",
            "detail": failure_path.clone(),
        })
    }));
    let mut critical_warnings = Vec::new();
    detect_churn(
        &critical_ctx,
        Instant::now(),
        "src/main.rs",
        false,
        &critical,
        &critical,
        &mut critical_warnings,
    );
    assert_eq!(critical_warnings.len(), 1);
    assert!(critical_warnings[0].contains("[CHURN CRITICAL]"));
    assert!(critical_warnings[0].contains("5 consecutive build failures"));
    let critical_events = read_test_events(&critical_ctx.log_file);
    assert_eq!(critical_events.len(), 1);
    assert_eq!(critical_events[0][field::DECISION], decision::ESCALATE);
    assert_eq!(
        critical_events[0][field::REASON],
        "churn 20x critical build_fails 5x"
    );

    let w15_ctx = review_context(root.join("w15.jsonl"));
    let w15_events = vec![
        json!({"session":"current","hook":"post-edit-guard","tool":"Edit","detail":"src/main.rs||delta=9"}),
        json!({"session":"current","hook":"post-edit-guard","tool":"Edit","detail":"src/main.rs||delta=5"}),
    ];
    let mut w15_warnings = Vec::new();
    detect_w15(
        &w15_ctx,
        Instant::now(),
        "src/main.rs",
        "",
        "abc",
        &w15_events,
        &mut w15_warnings,
    );
    assert_eq!(w15_warnings.len(), 1);
    assert!(w15_warnings[0].contains("[W-15]"));
    assert!(w15_warnings[0].contains("9→5→3"));
    fs::remove_dir_all(root).unwrap();
}

fn overlap_event(file_path: &str, now: u64) -> Value {
    json!({
        "ts": crate::time_utils::format_unix_secs_utc(now),
        "session": "peer",
        "agent": "peer-agent",
        "hook": "post-edit-guard",
        "tool": "Edit",
        "decision": "pass",
        "detail": file_path,
    })
}

fn shown_event(file_path: &str, key: &str, now: u64) -> Value {
    let agent = std::env::var("VIBEGUARD_AGENT_TYPE").unwrap_or_default();
    json!({
        "ts": crate::time_utils::format_unix_secs_utc(now),
        "session": "current",
        "agent": agent,
        "hook": "post-edit-guard",
        "tool": "Edit",
        "decision": "warn",
        "status": "warn",
        "reason": "[W-14] overlap shown session peer agent peer-agent",
        "detail": w14_event_detail(file_path, key),
    })
}

#[test]
fn w14_main_path_records_show_suppresses_and_restores_on_append_failure() {
    let root = temp_root("w14");
    let file_path = root.join("src/main.rs").to_string_lossy().to_string();
    let now = now_unix_secs();
    let overlap = overlap_event(&file_path, now);

    let shown_ctx = review_context(root.join("shown.jsonl"));
    let mut shown_warnings = Vec::new();
    detect_w14_at(
        &shown_ctx,
        Instant::now(),
        &file_path,
        false,
        std::slice::from_ref(&overlap),
        &mut shown_warnings,
        now,
        60,
    );
    assert_eq!(shown_warnings.len(), 1);
    assert!(shown_warnings[0].contains("[W-14]"));
    assert!(shown_warnings[0].contains("session peer"));
    let shown_events = read_test_events(&shown_ctx.log_file);
    assert_eq!(shown_events.len(), 1);
    assert_eq!(shown_events[0][field::DECISION], decision::WARN);
    assert_eq!(shown_events[0][field::STATUS], status::WARN);
    assert!(
        shown_events[0][field::REASON]
            .as_str()
            .unwrap()
            .starts_with(W14_SHOWN_REASON_PREFIX)
    );

    let current_agent = std::env::var("VIBEGUARD_AGENT_TYPE").unwrap_or_default();
    let overlap_signal = recent_overlap(
        std::slice::from_ref(&overlap),
        "current",
        &current_agent,
        &file_path,
    )
    .unwrap();
    let key = w14_key("current", "peer", &overlap_signal.normalized_file).unwrap();
    let history = vec![overlap.clone(), shown_event(&file_path, &key, now)];
    let suppressed_ctx = review_context(root.join("suppressed.jsonl"));
    let mut suppressed_warnings = Vec::new();
    detect_w14_at(
        &suppressed_ctx,
        Instant::now(),
        &file_path,
        false,
        &history,
        &mut suppressed_warnings,
        now,
        60,
    );
    assert!(suppressed_warnings.is_empty());
    let suppressed_events = read_test_events(&suppressed_ctx.log_file);
    assert_eq!(suppressed_events.len(), 1);
    assert_eq!(suppressed_events[0][field::DECISION], decision::PASS);
    assert_eq!(suppressed_events[0][field::STATUS], status::SKIPPED);
    assert_eq!(
        suppressed_events[0][field::REASON],
        W14_SUPPRESSED_REASON_PREFIX
    );

    let blocking_parent = root.join("not-a-directory");
    fs::write(&blocking_parent, "blocks append").unwrap();
    let failed_ctx = review_context(blocking_parent.join("events.jsonl"));
    let mut restored_warnings = Vec::new();
    detect_w14_at(
        &failed_ctx,
        Instant::now(),
        &file_path,
        false,
        &history,
        &mut restored_warnings,
        now,
        60,
    );
    assert_eq!(restored_warnings.len(), 1);
    assert!(restored_warnings[0].contains("[W-14]"));
    assert!(restored_warnings[0].contains("session peer"));
    assert!(!failed_ctx.log_file.exists());
    assert!(blocking_parent.is_file());
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn w14_ignores_pre_hook_intent_events() {
    let root = temp_root("w14-pre-intent");
    let file_path = root.join("src/main.rs").to_string_lossy().to_string();
    let now = now_unix_secs();
    let mut pre_event = overlap_event(&file_path, now);
    pre_event["hook"] = json!("pre-edit-guard");

    let ctx = review_context(root.join("events.jsonl"));
    let mut warnings = Vec::new();
    detect_w14_at(
        &ctx,
        Instant::now(),
        &file_path,
        false,
        std::slice::from_ref(&pre_event),
        &mut warnings,
        now,
        60,
    );
    assert!(warnings.is_empty());
    assert!(!ctx.log_file.exists());
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn w14_downgrades_to_info_without_logical_codex_identity() {
    let root = temp_root("w14-low-confidence");
    let file_path = root.join("src/main.rs").to_string_lossy().to_string();
    let now = now_unix_secs();
    let overlap = overlap_event(&file_path, now);

    let mut ctx = review_context(root.join("events.jsonl"));
    ctx.session_source = String::new();
    let mut warnings = Vec::new();
    detect_w14_at(
        &ctx,
        Instant::now(),
        &file_path,
        false,
        std::slice::from_ref(&overlap),
        &mut warnings,
        now,
        60,
    );
    assert_eq!(warnings.len(), 1);
    assert!(warnings[0].contains("[W-14] [info]"));
    assert!(warnings[0].contains("low-confidence"));
    assert!(!warnings[0].contains("git worktree add"));
    let events = read_test_events(&ctx.log_file);
    assert_eq!(events.len(), 1);
    assert_eq!(events[0][field::DECISION], decision::WARN);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn full_history_reader_treats_whitespace_only_log_as_empty() {
    let root = temp_root("empty-lines");
    let ctx = review_context(root.join("events.jsonl"));
    fs::write(&ctx.log_file, "\n   \n\t\n").unwrap();

    let events = read_post_edit_history_events(&ctx).unwrap();
    assert!(events.is_empty());
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn session_temp_suppression_leaves_evidence_only_for_real_findings() {
    let root = temp_root("temp-evidence");
    let scratch = "/private/tmp/claude-x/session/scratchpad/report.html";
    let now = now_unix_secs();

    // Ordinary temp write: no finding would fire -> zero events (issue #691).
    let quiet_ctx = review_context(root.join("quiet.jsonl"));
    let quiet = edit_events(2, scratch);
    let mut quiet_warnings = Vec::new();
    detect_churn(
        &quiet_ctx,
        Instant::now(),
        scratch,
        true,
        &quiet,
        &quiet,
        &mut quiet_warnings,
    );
    detect_w14_at(
        &quiet_ctx,
        Instant::now(),
        scratch,
        true,
        &quiet,
        &mut quiet_warnings,
        now,
        60,
    );
    assert!(quiet_warnings.is_empty());
    assert!(!quiet_ctx.log_file.exists());

    // Churn would have warned -> suppressed evidence, no user warning.
    let churn_ctx = review_context(root.join("churn.jsonl"));
    let churny = edit_events(6, scratch);
    let mut churn_warnings = Vec::new();
    detect_churn(
        &churn_ctx,
        Instant::now(),
        scratch,
        true,
        &churny,
        &churny,
        &mut churn_warnings,
    );
    assert!(churn_warnings.is_empty());
    let churn_events = read_test_events(&churn_ctx.log_file);
    assert_eq!(churn_events.len(), 1);
    assert_eq!(churn_events[0][field::DECISION], decision::PASS);
    assert_eq!(churn_events[0][field::STATUS], status::SKIPPED);
    assert_eq!(
        churn_events[0][field::REASON],
        CHURN_SUPPRESSED_REASON_PREFIX
    );
    assert!(
        churn_events[0][field::DETAIL]
            .as_str()
            .unwrap()
            .ends_with("||churn=6")
    );

    // W-14 overlap would have warned -> suppressed evidence, no user warning.
    let w14_ctx = review_context(root.join("w14.jsonl"));
    let overlap = overlap_event(scratch, now);
    let mut w14_warnings = Vec::new();
    detect_w14_at(
        &w14_ctx,
        Instant::now(),
        scratch,
        true,
        std::slice::from_ref(&overlap),
        &mut w14_warnings,
        now,
        60,
    );
    assert!(w14_warnings.is_empty());
    let w14_events = read_test_events(&w14_ctx.log_file);
    assert_eq!(w14_events.len(), 1);
    assert_eq!(w14_events[0][field::DECISION], decision::PASS);
    assert_eq!(w14_events[0][field::STATUS], status::SKIPPED);
    assert_eq!(
        w14_events[0][field::REASON],
        W14_TEMP_SUPPRESSED_REASON_PREFIX
    );
    assert!(
        w14_events[0][field::DETAIL]
            .as_str()
            .unwrap()
            .ends_with("||peer=peer")
    );
    fs::remove_dir_all(root).unwrap();
}
