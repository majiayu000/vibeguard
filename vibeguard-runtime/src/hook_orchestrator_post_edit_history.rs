use serde_json::Value;
use std::env;
use std::path::Path;
use std::time::Instant;

use crate::event_schema::{decision, field, hook, status, tool};
use crate::git_root::current_git_root_by_marker;
use crate::hook_checks_common::{first_detail_path, known_w14_session};
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
const W14_TEMP_SUPPRESSED_REASON_PREFIX: &str = "[W-14] overlap suppressed session-temp";
const CHURN_SUPPRESSED_REASON_PREFIX: &str = "[CHURN] suppressed session-temp";

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
    // Session-scoped temp paths cannot have cross-session ownership conflicts
    // and long-doc scratchpad builds are not correction loops (issue #681).
    // The exemption is applied inside detect_churn / detect_w14 so that a
    // suppressed finding leaves evidence while ordinary temp writes stay
    // silent (issue #691).
    let session_temp = crate::hook_checks_common::is_session_temp_path(file_path);
    detect_churn(
        ctx,
        start,
        file_path,
        session_temp,
        &session_events,
        events,
        warnings,
    );
    detect_w14(ctx, start, file_path, session_temp, events, warnings);
    detect_w15(
        ctx, start, file_path, old_string, new_string, events, warnings,
    );
}

fn detect_churn(
    ctx: &RuntimeContext,
    start: Instant,
    file_path: &str,
    session_temp: bool,
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
    // Session-temp exemption (issues #681/#691): suppress the finding but
    // leave evidence only when churn would actually have warned, so ordinary
    // temp writes add no log volume.
    if session_temp {
        if churn_count >= 5 {
            let detail = format!("{file_path}||churn={churn_count}");
            let detail_limit = detail.chars().count();
            if let Err(err) = append_hook_event_with_status(
                ctx,
                HookKind::PostEdit,
                decision::PASS,
                status::SKIPPED,
                CHURN_SUPPRESSED_REASON_PREFIX,
                (&detail, detail_limit),
                elapsed_ms(start),
            ) {
                eprintln!("VIBEGUARD: churn suppressed telemetry append failed: {err}");
            }
        }
        return;
    }
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
    session_temp: bool,
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
        session_temp,
        events,
        warnings,
        now_unix_secs(),
        cooldown_seconds,
    );
}

#[allow(clippy::too_many_arguments)]
fn detect_w14_at(
    ctx: &RuntimeContext,
    start: Instant,
    file_path: &str,
    session_temp: bool,
    events: &[Value],
    warnings: &mut Vec<String>,
    now: u64,
    cooldown_seconds: u64,
) {
    let agent = env::var("VIBEGUARD_AGENT_TYPE").unwrap_or_default();
    let Some(overlap) = recent_overlap(events, &ctx.session_id, &agent, file_path) else {
        return;
    };
    // Session-temp exemption (issues #681/#691): the overlap would have
    // warned — suppress it but leave evidence, like the cooldown path.
    if session_temp {
        let detail = format!("{file_path}||peer={}", overlap.session);
        let detail_limit = detail.chars().count();
        if let Err(err) = append_hook_event_with_status(
            ctx,
            HookKind::PostEdit,
            decision::PASS,
            status::SKIPPED,
            W14_TEMP_SUPPRESSED_REASON_PREFIX,
            (&detail, detail_limit),
            elapsed_ms(start),
        ) {
            eprintln!("VIBEGUARD: W-14 suppressed telemetry append failed: {err}");
        }
        return;
    }
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
    // Codex sessions without a payload-derived logical identity fall back to
    // process-derived ids that can fragment within one logical thread (issue
    // #673). A PID-difference alone is then too weak to demand a worktree.
    let low_confidence_identity = ctx.cli == "codex" && ctx.session_source != "codex-thread";
    if low_confidence_identity {
        warnings.push(format!("[W-14] [info] [this-file] OBSERVATION: a possibly different session recently touched {} ({} via {}, session {}, agent {}) — writer identity is process-derived and low-confidence\nFIX: Confirm a second signal (another Codex thread or agent actually editing this file) before isolating; if confirmed, create a dedicated worktree\nDO NOT: Treat process-id/session differences alone as proof of another writer", post_edit_history_file_name(file_path), overlap.tool, overlap.hook, overlap.session, if overlap.agent.is_empty() { "unknown" } else { &overlap.agent }));
    } else {
        warnings.push(format!("[W-14] [review] [this-file] OBSERVATION: another session or agent recently touched {} ({} via {}, session {}, agent {})\nFIX: Isolate via a dedicated worktree before continuing. Copy-paste:\n  REPO=$(git rev-parse --show-toplevel) && SID=${{VIBEGUARD_SESSION_ID:-$(date +%s)}}\n  BASE=${{VIBEGUARD_WORKTREE_BASE:-${{REPO}}.wt}}\n  case \"$BASE\" in /*) ;; *) BASE=\"${{REPO}}/${{BASE}}\" ;; esac\n  BASE=${{BASE%/}}\n  git worktree add \"$BASE/$SID\" -b \"vg/$SID\" HEAD\n  cd \"$BASE/$SID\"\nDO NOT: Continue parallel/background edits to this file without an isolated worktree", post_edit_history_file_name(file_path), overlap.tool, overlap.hook, overlap.session, if overlap.agent.is_empty() { "unknown" } else { &overlap.agent }));
    }
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
#[path = "hook_orchestrator_post_edit_history_unit_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "hook_orchestrator_post_edit_history_tests.rs"]
mod review_tests;
