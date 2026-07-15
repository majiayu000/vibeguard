use serde_json::Value;
use std::env;
use std::path::Path;
use std::time::Instant;

use crate::event_schema::{decision, field, hook, status, tool};
use crate::git_root::current_git_root_by_marker;
use crate::hook_checks_common::first_detail_path;
use crate::hook_checks_history::{read_tail_lines, recent_overlap};
use crate::hook_orchestrator::{
    HookKind, append_hook_event, append_hook_event_with_status, elapsed_ms,
};
use crate::hook_orchestrator_context::RuntimeContext;
use crate::log_query::count_build_fail_events;
use crate::runtime_config::runtime_config_int_value;
use crate::setup_support::sha256_text;
use crate::time_utils::{now_unix_secs, parse_iso_ts};

const POST_EDIT_HISTORY_LINES: usize = 500;
const W14_COOLDOWN_DEFAULT_SECONDS: &str = "3600";
const W14_SHOWN_REASON_PREFIX: &str = "[W-14] overlap shown";
const W14_SUPPRESSED_REASON_PREFIX: &str = "[W-14] overlap suppressed cooldown";

pub(crate) fn detect_history_warnings(
    ctx: &RuntimeContext,
    start: Instant,
    file_path: &str,
    old_string: &str,
    new_string: &str,
    events: &[Value],
    warnings: &mut Vec<String>,
) {
    let session_events = events
        .iter()
        .filter(|event| {
            event.get(field::SESSION).and_then(Value::as_str) == Some(ctx.session_id.as_str())
        })
        .cloned()
        .collect::<Vec<_>>();
    detect_churn(ctx, start, file_path, &session_events, events, warnings);
    detect_w14(ctx, start, file_path, events, warnings);
    detect_w15(
        ctx, start, file_path, old_string, new_string, events, warnings,
    );
}

fn detect_churn(
    ctx: &RuntimeContext,
    start: Instant,
    file_path: &str,
    session_events: &[Value],
    events: &[Value],
    warnings: &mut Vec<String>,
) {
    let churn_count = session_events
        .iter()
        .filter(|event| {
            event.get(field::TOOL).and_then(Value::as_str) == Some(tool::EDIT)
                && event
                    .get(field::DETAIL)
                    .and_then(Value::as_str)
                    .is_some_and(|detail| detail.contains(file_path))
        })
        .count();
    let basename = post_edit_history_file_name(file_path);
    if churn_count >= 20 {
        let build_fail_count = count_build_failures(events);
        if build_fail_count >= 5 {
            let warning = format!(
                "[CHURN CRITICAL] [review] [this-file] OBSERVATION: {basename} has been edited {churn_count} times and the project has {build_fail_count} consecutive build failures — possible edit->fail->fix loop\nFIX: Pause and classify: planned refactor vs failed repair loop. If planned, make one scoped finishing edit and verify; if failed loop, stop and re-check root cause (W-02)\nDO NOT: Keep making equivalent fix attempts without fresh build output and a confirmed root cause"
            );
            preserve_warning_after_append(ctx, warnings, warning, || {
                append_history_event(
                    ctx,
                    start,
                    decision::ESCALATE,
                    &format!("churn {churn_count}x critical build_fails {build_fail_count}x"),
                    file_path,
                )
            });
        } else {
            let warning = format!(
                "[CHURN WARNING] [review] [this-file] OBSERVATION: {basename} has been edited {churn_count} times — high edit volume without repeated build-failure evidence\nFIX: Pause and classify: planned refactor vs failed repair loop. If planned, make one scoped finishing edit and verify.\nDO NOT: Treat edit count alone as proof of W-02 failure-loop behavior"
            );
            preserve_warning_after_append(ctx, warnings, warning, || {
                append_history_event(
                    ctx,
                    start,
                    decision::CORRECTION,
                    &format!("churn {churn_count}x volume"),
                    file_path,
                )
            });
        }
    } else if churn_count >= 10 {
        let warning = format!(
            "[CHURN WARNING] [info] [this-file] OBSERVATION: {basename} has been edited {churn_count} times — high edit volume\nFIX: Run full build to see the complete picture, or classify whether this is a planned refactor before continuing\nDO NOT: Take any action — monitor and decide whether to continue"
        );
        preserve_warning_after_append(ctx, warnings, warning, || {
            append_history_event(
                ctx,
                start,
                decision::CORRECTION,
                &format!("churn {churn_count}x warning"),
                file_path,
            )
        });
    } else if churn_count >= 5 {
        let warning = format!(
            "[CHURN] [info] [this-file] OBSERVATION: {basename} has been edited {churn_count} times\nFIX: Check if you are in a correction loop before continuing\nDO NOT: Take any action — this is informational only"
        );
        preserve_warning_after_append(ctx, warnings, warning, || {
            append_history_event(
                ctx,
                start,
                decision::CORRECTION,
                &format!("churn {churn_count}x"),
                file_path,
            )
        });
    }
}

fn detect_w14(
    ctx: &RuntimeContext,
    start: Instant,
    file_path: &str,
    events: &[Value],
    warnings: &mut Vec<String>,
) {
    let cooldown_seconds = runtime_config_int_value(
        "VIBEGUARD_W14_COOLDOWN_SECONDS",
        "w14.cooldown_seconds",
        W14_COOLDOWN_DEFAULT_SECONDS,
    );
    detect_w14_at(
        ctx,
        start,
        file_path,
        events,
        warnings,
        now_unix_secs(),
        cooldown_seconds,
    );
}

fn detect_w14_at(
    ctx: &RuntimeContext,
    start: Instant,
    file_path: &str,
    events: &[Value],
    warnings: &mut Vec<String>,
    now: u64,
    cooldown_seconds: u64,
) {
    let agent = env::var("VIBEGUARD_AGENT_TYPE").unwrap_or_default();
    let Some(overlap) = recent_overlap(events, &ctx.session_id, &agent, file_path) else {
        return;
    };
    let key = w14_key(&ctx.session_id, &overlap.session, &overlap.normalized_file);
    if let Some(key) = key.as_deref() {
        let eligible = cooldown_seconds > 0
            && has_recent_w14_shown(events, &ctx.session_id, key, now, cooldown_seconds);
        match suppress_after_audit(eligible, || {
            let detail = w14_event_detail(file_path, key);
            let detail_limit = detail.chars().count();
            append_hook_event_with_status(
                ctx,
                HookKind::PostEdit,
                decision::PASS,
                status::SKIPPED,
                W14_SUPPRESSED_REASON_PREFIX,
                (&detail, detail_limit),
                elapsed_ms(start),
            )
        }) {
            Ok(true) => return,
            Ok(false) => {}
            Err(err) => {
                eprintln!("VIBEGUARD: W-14 suppressed telemetry append failed: {err}");
            }
        }
    }
    warnings.push(format!("[W-14] [review] [this-file] OBSERVATION: another session or agent recently touched {} ({} via {}, session {}, agent {})\nFIX: Isolate via a dedicated worktree before continuing. Copy-paste:\n  REPO=$(git rev-parse --show-toplevel) && SID=${{VIBEGUARD_SESSION_ID:-$(date +%s)}}\n  BASE=${{VIBEGUARD_WORKTREE_BASE:-${{REPO}}.wt}}\n  case \"$BASE\" in /*) ;; *) BASE=\"${{REPO}}/${{BASE}}\" ;; esac\n  BASE=${{BASE%/}}\n  git worktree add \"$BASE/$SID\" -b \"vg/$SID\" HEAD\n  cd \"$BASE/$SID\"\nDO NOT: Continue parallel/background edits to this file without an isolated worktree", post_edit_history_file_name(file_path), overlap.tool, overlap.hook, overlap.session, if overlap.agent.is_empty() { "unknown" } else { &overlap.agent }));
    let detail = key
        .as_deref()
        .map(|key| w14_event_detail(file_path, key))
        .unwrap_or_else(|| file_path.to_string());
    let detail_limit = detail.chars().count();
    if let Err(err) = append_hook_event_with_status(
        ctx,
        HookKind::PostEdit,
        decision::WARN,
        status::WARN,
        &format!(
            "{W14_SHOWN_REASON_PREFIX} session {} agent {}",
            overlap.session,
            if overlap.agent.is_empty() {
                "unknown"
            } else {
                &overlap.agent
            }
        ),
        (&detail, detail_limit),
        elapsed_ms(start),
    ) {
        eprintln!("VIBEGUARD: W-14 shown evidence append failed: {err}");
    }
}

fn w14_key(current_session: &str, peer_session: &str, normalized_file: &str) -> Option<String> {
    if !known_w14_session(current_session)
        || !known_w14_session(peer_session)
        || normalized_file.is_empty()
    {
        return None;
    }
    let tuple = format!(
        "{}:{current_session}{}:{peer_session}{}:{normalized_file}",
        current_session.len(),
        peer_session.len(),
        normalized_file.len()
    );
    Some(sha256_text(&tuple))
}

fn known_w14_session(session: &str) -> bool {
    let session = session.trim();
    !session.is_empty() && session != "?" && !session.eq_ignore_ascii_case("unknown")
}

fn w14_event_detail(file_path: &str, key: &str) -> String {
    format!("{file_path}||w14_key={key}")
}

fn has_recent_w14_shown(
    events: &[Value],
    current_session: &str,
    key: &str,
    now: u64,
    cooldown_seconds: u64,
) -> bool {
    if cooldown_seconds == 0 || !known_w14_session(current_session) {
        return false;
    }
    events
        .iter()
        .rev()
        .take(POST_EDIT_HISTORY_LINES)
        .any(|event| {
            event.get(field::SESSION).and_then(Value::as_str) == Some(current_session)
                && event.get(field::HOOK).and_then(Value::as_str) == Some(hook::POST_EDIT_GUARD)
                && event.get(field::TOOL).and_then(Value::as_str) == Some(tool::EDIT)
                && event.get(field::DECISION).and_then(Value::as_str) == Some(decision::WARN)
                && event.get(field::STATUS).and_then(Value::as_str) == Some(status::WARN)
                && event
                    .get(field::REASON)
                    .and_then(Value::as_str)
                    .is_some_and(|reason| reason.starts_with(W14_SHOWN_REASON_PREFIX))
                && event
                    .get(field::DETAIL)
                    .and_then(Value::as_str)
                    .and_then(w14_key_from_detail)
                    == Some(key)
                && event
                    .get(field::TS)
                    .and_then(Value::as_str)
                    .and_then(parse_iso_ts)
                    .and_then(|timestamp| now.checked_sub(timestamp))
                    .is_some_and(|age| age < cooldown_seconds)
        })
}

fn w14_key_from_detail(detail: &str) -> Option<&str> {
    detail
        .split("||")
        .skip(1)
        .find_map(|part| part.strip_prefix("w14_key="))
        .filter(|key| key.len() == 64 && key.bytes().all(|byte| byte.is_ascii_hexdigit()))
}

fn suppress_after_audit<E>(
    eligible: bool,
    append: impl FnOnce() -> Result<(), E>,
) -> Result<bool, E> {
    if !eligible {
        return Ok(false);
    }
    append().map(|()| true)
}

fn detect_w15(
    ctx: &RuntimeContext,
    start: Instant,
    file_path: &str,
    old_string: &str,
    new_string: &str,
    events: &[Value],
    warnings: &mut Vec<String>,
) {
    if env::var("VIBEGUARD_SUPPRESS_W15").as_deref() == Ok("1") || w15_doc_skip(file_path) {
        return;
    }
    let current_delta = new_string.chars().count() as i64 - old_string.chars().count() as i64;
    let trail = same_file_edit_trail(events, &ctx.session_id, file_path);
    if trail.consecutive < 2 || trail.deltas.len() < 2 {
        return;
    }
    let prev = trail.deltas[0].unsigned_abs();
    let prev2 = trail.deltas[1].unsigned_abs();
    let cur = current_delta.unsigned_abs();
    if prev2 >= prev && prev >= cur && cur < 300 {
        let total = trail.consecutive + 1;
        let warning = format!(
            "[W-15] [review] [this-file] OBSERVATION: {total} consecutive edits to {} with shrinking change radius (|Δ| {prev2}→{prev}→{cur} chars; latest <300)\nFIX: Pause — are these {total} edits solving the same problem? If radius keeps shrinking, report a blocker instead of continuing to round {}\nDO NOT: Toggle between equivalent rewrites; do not continue same-direction micro-tuning without reporting\nESCAPE: set VIBEGUARD_SUPPRESS_W15=1 to suppress (e.g. for long-document writing)",
            post_edit_history_file_name(file_path),
            total + 1
        );
        preserve_warning_after_append(ctx, warnings, warning, || {
            append_history_event(
                ctx,
                start,
                decision::WARN,
                &format!("w15 shrinking radius {prev2}>{prev}>{cur}"),
                &format!("{file_path}||delta={current_delta}"),
            )
        });
    }
}

struct W15Trail {
    consecutive: usize,
    deltas: Vec<i64>,
}

fn same_file_edit_trail(events: &[Value], session: &str, file_path: &str) -> W15Trail {
    let mut consecutive = 0usize;
    let mut deltas = Vec::new();
    for event in events.iter().rev().filter(|event| {
        event.get(field::SESSION).and_then(Value::as_str) == Some(session)
            && event.get(field::TOOL).and_then(Value::as_str) == Some(tool::EDIT)
            && event.get(field::HOOK).and_then(Value::as_str) == Some(hook::POST_EDIT_GUARD)
    }) {
        if first_detail_path(event) != file_path {
            break;
        }
        consecutive += 1;
        if let Some(delta) = event
            .get(field::DETAIL)
            .and_then(Value::as_str)
            .and_then(post_edit_delta_from_detail)
        {
            deltas.push(delta);
        }
    }
    W15Trail {
        consecutive,
        deltas,
    }
}

pub(crate) fn count_prior_warn_events(events: &[Value], session: &str, file_path: &str) -> usize {
    count_prior_warn_events_in(events, session, file_path)
}

fn count_prior_warn_events_in(events: &[Value], session: &str, file_path: &str) -> usize {
    events
        .iter()
        .filter(|event| {
            let reason = event
                .get(field::REASON)
                .and_then(Value::as_str)
                .unwrap_or("");
            let churn_only = reason.contains("[CHURN") && !reason.contains("\n---\n");
            event.get(field::SESSION).and_then(Value::as_str) == Some(session)
                && event.get(field::HOOK).and_then(Value::as_str) == Some(hook::POST_EDIT_GUARD)
                && event.get(field::DECISION).and_then(Value::as_str) == Some(decision::WARN)
                && !churn_only
                && first_detail_path(event) == file_path
        })
        .count()
}

fn append_history_event(
    ctx: &RuntimeContext,
    start: Instant,
    decision_value: &str,
    reason: &str,
    detail: &str,
) -> crate::hook_orchestrator::Result {
    let status_value = match decision_value {
        decision::ESCALATE => status::ESCALATE,
        decision::CORRECTION => status::CORRECTION,
        decision::WARN => status::WARN,
        _ => decision_value,
    };
    append_hook_event(
        ctx,
        HookKind::PostEdit,
        decision_value,
        status_value,
        reason,
        detail,
        elapsed_ms(start),
    )
}

fn preserve_warning_after_append<E: std::fmt::Display>(
    ctx: &RuntimeContext,
    warnings: &mut Vec<String>,
    warning: String,
    append: impl FnOnce() -> std::result::Result<(), E>,
) {
    warnings.push(warning);
    if let Err(err) = append() {
        warnings.push(format!(
            "VIBEGUARD internal error [VG-INTERNAL-LOG-APPEND]: hook=post-edit-guard tool=Edit failure_kind=runtime mode=allow project={} session={} log_path={} recovery=bash scripts/hook-health.sh 24 detail=post-edit history telemetry append failed: {err}",
            ctx.project_hash,
            ctx.session_id,
            ctx.log_file.display()
        ));
    }
}

pub(crate) fn read_post_edit_history_events(ctx: &RuntimeContext) -> std::io::Result<Vec<Value>> {
    let log_file = ctx.log_file.to_string_lossy();
    let text = match read_tail_lines(&log_file, POST_EDIT_HISTORY_LINES) {
        Ok(text) => text,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(err) => return Err(err),
    };
    let mut events = Vec::new();
    for (index, line) in text.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let event = serde_json::from_str::<Value>(line).map_err(|err| {
            std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                format!(
                    "malformed post-edit history JSONL at line {}: {err}",
                    index + 1
                ),
            )
        })?;
        events.push(event);
    }
    Ok(events)
}

fn count_build_failures(events: &[Value]) -> u32 {
    let project = current_git_root_by_marker()
        .map(|path| path.to_string_lossy().to_string())
        .unwrap_or_default();
    count_build_fail_events(events, &project)
}

fn w15_doc_skip(file_path: &str) -> bool {
    if env::var("VIBEGUARD_W15_SKIP_DOCS").as_deref() == Ok("0") {
        return false;
    }
    let path = file_path.replace('\\', "/");
    let basename = post_edit_history_file_name(&path);
    matches!(
        post_edit_history_extension(&path).as_str(),
        "md" | "markdown" | "rst" | "txt" | "adoc"
    ) || path.starts_with("notes/")
        || path.contains("/notes/")
        || path.starts_with("docs/daily/")
        || path.contains("/docs/daily/")
        || basename.starts_with("CHANGELOG")
        || basename.starts_with("TODO")
        || basename.starts_with("HISTORY")
}

fn post_edit_delta_from_detail(detail: &str) -> Option<i64> {
    detail.split("||").skip(1).find_map(|part| {
        part.trim()
            .strip_prefix("delta=")
            .and_then(|value| value.parse::<i64>().ok())
    })
}

fn post_edit_history_file_name(path: &str) -> &str {
    Path::new(path)
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or(path)
}

fn post_edit_history_extension(file_path: &str) -> String {
    Path::new(file_path)
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or("")
        .to_string()
}

#[cfg(test)]
mod tests {
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
}

#[cfg(test)]
#[path = "hook_orchestrator_post_edit_history_tests.rs"]
mod review_tests;
