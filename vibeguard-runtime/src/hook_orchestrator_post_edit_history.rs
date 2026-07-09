use serde_json::Value;
use std::env;
use std::path::Path;
use std::time::Instant;

use crate::event_schema::{decision, field, hook, status, tool};
use crate::git_root::current_git_root_by_marker;
use crate::hook_checks_common::first_detail_path;
use crate::hook_checks_history::{read_tail_lines, recent_overlap};
use crate::hook_orchestrator::{HookKind, append_hook_event, elapsed_ms};
use crate::hook_orchestrator_context::RuntimeContext;
use crate::log_query::count_build_fail_events;

const POST_EDIT_HISTORY_LINES: usize = 500;

pub(crate) fn detect_history_warnings(
    ctx: &RuntimeContext,
    start: Instant,
    file_path: &str,
    detail: &str,
    old_string: &str,
    new_string: &str,
    warnings: &mut Vec<String>,
) {
    let events = read_post_edit_history_events(ctx);
    let session_events = events
        .iter()
        .filter(|event| {
            event.get(field::SESSION).and_then(Value::as_str) == Some(ctx.session_id.as_str())
        })
        .cloned()
        .collect::<Vec<_>>();
    detect_churn(ctx, start, file_path, &session_events, &events, warnings);
    detect_w14(ctx, start, file_path, &events, warnings);
    detect_w15(
        ctx, start, file_path, detail, old_string, new_string, &events, warnings,
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
            warnings.push(format!("[CHURN CRITICAL] [review] [this-file] OBSERVATION: {basename} has been edited {churn_count} times and the project has {build_fail_count} consecutive build failures — possible edit->fail->fix loop\nFIX: Pause and classify: planned refactor vs failed repair loop. If planned, make one scoped finishing edit and verify; if failed loop, stop and re-check root cause (W-02)\nDO NOT: Keep making equivalent fix attempts without fresh build output and a confirmed root cause"));
            append_history_event(
                ctx,
                start,
                decision::ESCALATE,
                &format!("churn {churn_count}x critical build_fails {build_fail_count}x"),
                file_path,
            );
        } else {
            warnings.push(format!("[CHURN WARNING] [review] [this-file] OBSERVATION: {basename} has been edited {churn_count} times — high edit volume without repeated build-failure evidence\nFIX: Pause and classify: planned refactor vs failed repair loop. If planned, make one scoped finishing edit and verify.\nDO NOT: Treat edit count alone as proof of W-02 failure-loop behavior"));
            append_history_event(
                ctx,
                start,
                decision::CORRECTION,
                &format!("churn {churn_count}x volume"),
                file_path,
            );
        }
    } else if churn_count >= 10 {
        warnings.push(format!("[CHURN WARNING] [info] [this-file] OBSERVATION: {basename} has been edited {churn_count} times — high edit volume\nFIX: Run full build to see the complete picture, or classify whether this is a planned refactor before continuing\nDO NOT: Take any action — monitor and decide whether to continue"));
        append_history_event(
            ctx,
            start,
            decision::CORRECTION,
            &format!("churn {churn_count}x warning"),
            file_path,
        );
    } else if churn_count >= 5 {
        warnings.push(format!("[CHURN] [info] [this-file] OBSERVATION: {basename} has been edited {churn_count} times\nFIX: Check if you are in a correction loop before continuing\nDO NOT: Take any action — this is informational only"));
        append_history_event(
            ctx,
            start,
            decision::CORRECTION,
            &format!("churn {churn_count}x"),
            file_path,
        );
    }
}

fn detect_w14(
    ctx: &RuntimeContext,
    start: Instant,
    file_path: &str,
    events: &[Value],
    warnings: &mut Vec<String>,
) {
    let agent = env::var("VIBEGUARD_AGENT_TYPE").unwrap_or_default();
    let Some(overlap) = recent_overlap(events, &ctx.session_id, &agent, file_path) else {
        return;
    };
    warnings.push(format!("[W-14] [review] [this-file] OBSERVATION: another session or agent recently touched {} ({} via {}, session {}, agent {})\nFIX: Isolate via a dedicated worktree before continuing. Copy-paste:\n  REPO=$(git rev-parse --show-toplevel) && SID=${{VIBEGUARD_SESSION_ID:-$(date +%s)}}\n  BASE=${{VIBEGUARD_WORKTREE_BASE:-${{REPO}}.wt}}\n  case \"$BASE\" in /*) ;; *) BASE=\"${{REPO}}/${{BASE}}\" ;; esac\n  BASE=${{BASE%/}}\n  git worktree add \"$BASE/$SID\" -b \"vg/$SID\" HEAD\n  cd \"$BASE/$SID\"\nDO NOT: Continue parallel/background edits to this file without an isolated worktree", post_edit_history_file_name(file_path), overlap.tool, overlap.hook, overlap.session, if overlap.agent.is_empty() { "unknown" } else { &overlap.agent }));
    append_history_event(
        ctx,
        start,
        decision::WARN,
        &format!(
            "w14 overlap recent session {} agent {}",
            overlap.session,
            if overlap.agent.is_empty() {
                "unknown"
            } else {
                &overlap.agent
            }
        ),
        file_path,
    );
}

#[expect(
    clippy::too_many_arguments,
    reason = "W-15 detection consumes the complete edit and history context"
)]
fn detect_w15(
    ctx: &RuntimeContext,
    start: Instant,
    file_path: &str,
    detail: &str,
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
        warnings.push(format!("[W-15] [review] [this-file] OBSERVATION: {total} consecutive edits to {} with shrinking change radius (|Δ| {prev2}→{prev}→{cur} chars; latest <300)\nFIX: Pause — are these {total} edits solving the same problem? If radius keeps shrinking, report a blocker instead of continuing to round {}\nDO NOT: Toggle between equivalent rewrites; do not continue same-direction micro-tuning without reporting\nESCAPE: set VIBEGUARD_SUPPRESS_W15=1 to suppress (e.g. for long-document writing)", post_edit_history_file_name(file_path), total + 1));
        append_history_event(
            ctx,
            start,
            decision::WARN,
            &format!("w15 shrinking radius {prev2}>{prev}>{cur}"),
            detail,
        );
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

pub(crate) fn count_prior_warn_events(ctx: &RuntimeContext, file_path: &str) -> usize {
    read_post_edit_history_events(ctx)
        .into_iter()
        .filter(|event| {
            let reason = event
                .get(field::REASON)
                .and_then(Value::as_str)
                .unwrap_or("");
            let churn_only = reason.contains("[CHURN") && !reason.contains("\n---\n");
            event.get(field::SESSION).and_then(Value::as_str) == Some(ctx.session_id.as_str())
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
) {
    let status_value = match decision_value {
        decision::ESCALATE => status::ESCALATE,
        decision::CORRECTION => status::CORRECTION,
        decision::WARN => status::WARN,
        _ => decision_value,
    };
    let _ = append_hook_event(
        ctx,
        HookKind::PostEdit,
        decision_value,
        status_value,
        reason,
        detail,
        elapsed_ms(start),
    );
}

fn read_post_edit_history_events(ctx: &RuntimeContext) -> Vec<Value> {
    let log_file = ctx.log_file.to_string_lossy();
    let Ok(text) = read_tail_lines(&log_file, POST_EDIT_HISTORY_LINES) else {
        return Vec::new();
    };
    text.lines()
        .filter_map(|line| serde_json::from_str::<Value>(line.trim()).ok())
        .collect()
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
}
