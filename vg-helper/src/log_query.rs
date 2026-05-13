//! JSONL log queries — replaces churn/escalation/build-fail/paralysis Python calls.
//! All functions read from stdin (piped from `tail -N`) for bounded reads.

use serde_json::Value;
use std::io::{self, BufRead};
use std::path::{Path, PathBuf};

use crate::event_schema::{decision, field, hook, tool};
use crate::time_utils::{now_unix_secs, parse_iso_ts};

type Result = std::result::Result<(), Box<dyn std::error::Error>>;
const PARALYSIS_WINDOW_SECS: u64 = 30 * 60;

fn read_events(session: &str) -> Vec<Value> {
    read_all_events()
        .into_iter()
        .filter(|v| v.get(field::SESSION).and_then(Value::as_str) == Some(session))
        .collect()
}

fn read_all_events() -> Vec<Value> {
    let stdin = io::stdin();
    let mut reader = io::BufReader::new(stdin.lock());
    let mut events = Vec::new();
    let mut buf = Vec::new();
    loop {
        buf.clear();
        match reader.read_until(b'\n', &mut buf) {
            Ok(0) => break,
            Ok(_) => {}
            Err(_) => break,
        }
        // Use lossy decoding so malformed UTF-8 bytes become U+FFFD rather than
        // dropping the entire line — preserves recoverable JSONL events.
        let line = String::from_utf8_lossy(&buf);
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        if let Ok(v) = serde_json::from_str::<Value>(line) {
            events.push(v);
        }
    }
    events
}

fn event_within_time_window(e: &Value, cutoff_secs: u64) -> bool {
    match e.get(field::TS) {
        None => true,
        Some(ts_val) => match ts_val.as_str().and_then(parse_iso_ts) {
            Some(evt_secs) => evt_secs >= cutoff_secs,
            None => false,
        },
    }
}

fn count_churn_events(events: &[Value], file_path: &str) -> usize {
    events
        .iter()
        .filter(|e| {
            e.get(field::TOOL).and_then(Value::as_str) == Some(tool::EDIT)
                && e.get(field::DETAIL)
                    .and_then(Value::as_str)
                    .is_some_and(|d| d.contains(file_path))
        })
        .count()
}

fn count_warn_events(events: &[Value], file_path: &str) -> usize {
    events
        .iter()
        .filter(|e| {
            e.get(field::HOOK).and_then(Value::as_str) == Some(hook::POST_EDIT_GUARD)
                && e.get(field::DECISION).and_then(Value::as_str) == Some(decision::WARN)
                && e.get(field::DETAIL)
                    .and_then(Value::as_str)
                    .is_some_and(|d| d.split("||").next().unwrap_or("").trim() == file_path)
        })
        .count()
}

fn normalize_path(path: &str) -> String {
    let path = path.trim();
    if path.is_empty() {
        return String::new();
    }
    let path_buf = if Path::new(path).is_absolute() {
        PathBuf::from(path)
    } else {
        std::env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .join(path)
    };
    let canonical = std::fs::canonicalize(&path_buf).unwrap_or(path_buf);
    canonical.to_string_lossy().to_string()
}

fn first_detail_path(e: &Value) -> &str {
    e.get(field::DETAIL)
        .and_then(Value::as_str)
        .unwrap_or("")
        .split("||")
        .next()
        .unwrap_or("")
        .trim()
}

fn consecutive_same_file_edits(events: &[Value], session: &str, file_path: &str) -> usize {
    let edits = events
        .iter()
        .filter(|e| {
            e.get(field::SESSION).and_then(Value::as_str) == Some(session)
                && e.get(field::TOOL).and_then(Value::as_str) == Some(tool::EDIT)
                && e.get(field::HOOK).and_then(Value::as_str) == Some(hook::POST_EDIT_GUARD)
        })
        .map(first_detail_path)
        .collect::<Vec<_>>();
    let mut count = 0;
    for path in edits.iter().rev() {
        if *path == file_path {
            count += 1;
        } else {
            break;
        }
    }
    count
}

fn recent_overlap(
    events: &[Value],
    session: &str,
    agent: &str,
    file_path: &str,
    now_secs: u64,
) -> Option<(String, String, String, String)> {
    let normalized_file = normalize_path(file_path);
    let cutoff = now_secs.saturating_sub(30 * 60);
    let mut last = None;
    for e in events {
        if !matches!(
            e.get(field::TOOL).and_then(Value::as_str),
            Some(tool::EDIT) | Some(tool::WRITE)
        ) {
            continue;
        }
        let detail_path = first_detail_path(e);
        if detail_path != file_path && normalize_path(detail_path) != normalized_file {
            continue;
        }
        let same_session = e.get(field::SESSION).and_then(Value::as_str) == Some(session);
        let other_agent = e.get("agent").and_then(Value::as_str).unwrap_or("") != agent;
        if same_session && !other_agent {
            continue;
        }
        let Some(ts) = e
            .get(field::TS)
            .and_then(Value::as_str)
            .and_then(parse_iso_ts)
        else {
            continue;
        };
        if ts < cutoff {
            continue;
        }
        last = Some((
            e.get(field::SESSION)
                .and_then(Value::as_str)
                .unwrap_or("?")
                .to_string(),
            e.get("agent")
                .and_then(Value::as_str)
                .unwrap_or("?")
                .to_string(),
            e.get(field::HOOK)
                .and_then(Value::as_str)
                .unwrap_or("?")
                .to_string(),
            e.get(field::TOOL)
                .and_then(Value::as_str)
                .unwrap_or("?")
                .to_string(),
        ));
    }
    last
}

fn count_build_fail_events(events: &[Value], project: &str) -> u32 {
    let project_prefix = format!("{}/", project.trim_end_matches('/'));
    let mut count = 0u32;
    for e in events.iter().rev() {
        if e.get(field::HOOK).and_then(Value::as_str) != Some(hook::POST_BUILD_CHECK) {
            continue;
        }
        let detail = e.get(field::DETAIL).and_then(Value::as_str).unwrap_or("");
        if !project.is_empty() && !detail.is_empty() && !detail.starts_with(&project_prefix) {
            continue;
        }
        match e.get(field::DECISION).and_then(Value::as_str) {
            Some(decision::PASS) => break,
            Some(decision::WARN) => count += 1,
            _ => {}
        }
    }
    count
}

fn count_paralysis_events(events: &[Value], now_secs: u64) -> u32 {
    let cutoff_secs = now_secs.saturating_sub(PARALYSIS_WINDOW_SECS);
    let mut consecutive = 0u32;
    for e in events.iter().rev() {
        if !event_within_time_window(e, cutoff_secs) {
            break;
        }
        let hook_name = e.get(field::HOOK).and_then(Value::as_str).unwrap_or("");
        let decision_name = e.get(field::DECISION).and_then(Value::as_str).unwrap_or("");
        if hook_name == hook::ANALYSIS_PARALYSIS_GUARD && decision_name != decision::PASS {
            continue;
        }
        match e.get(field::TOOL).and_then(Value::as_str) {
            Some(tool_name) if tool::RESEARCH_ONLY.contains(&tool_name) => consecutive += 1,
            Some(tool_name) if tool::MUTATING.contains(&tool_name) => break,
            _ => {}
        }
    }
    consecutive
}

/// Count how many times a file was edited in the current session.
/// Usage: tail -500 log | vg-helper churn-count <session> <file_path>
pub fn churn_count(args: &[String]) -> Result {
    if args.len() < 2 {
        return Err("Usage: tail -N log | vg-helper churn-count <session> <file_path>".into());
    }
    let (session, file_path) = (&args[0], &args[1]);
    let events = read_events(session);
    let count = count_churn_events(&events, file_path);
    println!("{count}");
    Ok(())
}

/// Count warn events for a specific file in the current session.
/// Usage: tail -500 log | vg-helper warn-count <session> <file_path>
pub fn warn_count(args: &[String]) -> Result {
    if args.len() < 2 {
        return Err("Usage: tail -N log | vg-helper warn-count <session> <file_path>".into());
    }
    let (session, file_path) = (&args[0], &args[1]);
    let events = read_events(session);
    let count = count_warn_events(&events, file_path);
    println!("{count}");
    Ok(())
}

/// Combined post-edit history query. Replaces multiple tail+Python/helper calls.
/// Usage: tail -500 log | vg-helper post-edit-history <session> <file_path> [agent]
pub fn post_edit_history(args: &[String]) -> Result {
    if args.len() < 2 {
        return Err(
            "Usage: tail -N log | vg-helper post-edit-history <session> <file_path> [agent]".into(),
        );
    }
    let session = &args[0];
    let file_path = &args[1];
    let agent = args.get(2).map(String::as_str).unwrap_or("");
    let events = read_all_events();
    let session_events = events
        .iter()
        .filter(|e| e.get(field::SESSION).and_then(Value::as_str) == Some(session))
        .cloned()
        .collect::<Vec<_>>();

    println!("CHURN\t{}", count_churn_events(&session_events, file_path));
    println!(
        "W15\t{}",
        consecutive_same_file_edits(&events, session, file_path)
    );
    println!(
        "WARN_COUNT\t{}",
        count_warn_events(&session_events, file_path)
    );
    if let Some((session_id, agent_name, hook_name, tool_name)) =
        recent_overlap(&events, session, agent, file_path, now_unix_secs())
    {
        println!("W14\t{session_id}\t{agent_name}\t{hook_name}\t{tool_name}");
    }
    Ok(())
}

/// Count consecutive build failures (backwards from end, stop at first pass).
/// Usage: tail -200 log | vg-helper build-fails <session> <project_root>
pub fn build_fails(args: &[String]) -> Result {
    if args.len() < 2 {
        return Err("Usage: tail -N log | vg-helper build-fails <session> <project>".into());
    }
    let (session, project) = (&args[0], &args[1]);
    let events = read_events(session);
    let count = count_build_fail_events(&events, project);
    println!("{count}");
    Ok(())
}

/// Count consecutive research-only tool calls at the tail of the session.
/// Usage: tail -300 log | vg-helper paralysis-count <session>
pub fn paralysis_count(args: &[String]) -> Result {
    if args.is_empty() {
        return Err("Usage: tail -N log | vg-helper paralysis-count <session>".into());
    }
    let session = &args[0];
    let events = read_events(session);
    let consecutive = count_paralysis_events(&events, now_unix_secs());
    println!("{consecutive}");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn churn_count_matches_edit_detail_for_requested_file() {
        let events = vec![
            json!({"tool": "Edit", "detail": "src/lib.rs"}),
            json!({"tool": "Write", "detail": "src/lib.rs"}),
            json!({"tool": "Edit", "detail": "src/main.rs"}),
            json!({"tool": "Edit", "detail": "notes.txt"}),
        ];

        assert_eq!(count_churn_events(&events, "src/"), 2);
        assert_eq!(count_churn_events(&events, "src/lib.rs"), 1);
    }

    #[test]
    fn warn_count_uses_post_edit_warn_and_first_detail_field() {
        let events = vec![
            json!({"hook": "post-edit-guard", "decision": "warn", "detail": "src/lib.rs || RS-03"}),
            json!({"hook": "post-edit-guard", "decision": "warn", "detail": " src/lib.rs  || DEBUG"}),
            json!({"hook": "post-edit-guard", "decision": "pass", "detail": "src/lib.rs || OK"}),
            json!({"hook": "pre-edit-guard", "decision": "warn", "detail": "src/lib.rs || BLOCK"}),
            json!({"hook": "post-edit-guard", "decision": "warn", "detail": "src/main.rs || RS-03"}),
        ];

        assert_eq!(count_warn_events(&events, "src/lib.rs"), 2);
    }

    #[test]
    fn consecutive_same_file_edits_counts_tail_run_only() {
        let events = vec![
            json!({"session": "s", "tool": "Edit", "hook": "post-edit-guard", "detail": "src/a.rs || one"}),
            json!({"session": "s", "tool": "Edit", "hook": "post-edit-guard", "detail": "src/b.rs || two"}),
            json!({"session": "s", "tool": "Edit", "hook": "post-edit-guard", "detail": "src/a.rs || three"}),
            json!({"session": "s", "tool": "Edit", "hook": "post-edit-guard", "detail": "src/a.rs || four"}),
        ];

        assert_eq!(consecutive_same_file_edits(&events, "s", "src/a.rs"), 2);
    }

    #[test]
    fn build_fails_counts_tail_warnings_until_project_pass() {
        let events = vec![
            json!({"hook": "post-build-check", "decision": "warn", "detail": "/repo/src/old.rs"}),
            json!({"hook": "post-build-check", "decision": "pass", "detail": "/repo/src/lib.rs"}),
            json!({"hook": "post-build-check", "decision": "warn", "detail": "/other/src/lib.rs"}),
            json!({"hook": "post-build-check", "decision": "warn", "detail": "/repo/src/lib.rs"}),
            json!({"hook": "post-build-check", "decision": "warn", "detail": "/repo/src/main.rs"}),
        ];

        assert_eq!(count_build_fail_events(&events, "/repo"), 2);
        assert_eq!(count_build_fail_events(&events, "/other"), 1);
    }

    #[test]
    fn paralysis_count_skips_guard_warnings_and_stops_at_mutation() {
        let events = vec![
            json!({"tool": "Read", "ts": "2026-05-01T00:00:00Z"}),
            json!({"tool": "Edit", "ts": "2026-05-01T00:10:00Z"}),
            json!({"hook": "analysis-paralysis-guard", "decision": "warn", "tool": "Read", "ts": "2026-05-01T00:11:00Z"}),
            json!({"tool": "Read", "ts": "2026-05-01T00:12:00Z"}),
            json!({"tool": "Grep", "ts": "2026-05-01T00:13:00Z"}),
        ];

        let now = parse_iso_ts("2026-05-01T00:20:00Z").expect("valid timestamp");
        assert_eq!(count_paralysis_events(&events, now), 2);
    }

    #[test]
    fn paralysis_count_stops_at_stale_timestamp_but_keeps_legacy_events() {
        let events = vec![
            json!({"tool": "Read", "ts": "2026-05-01T00:00:00Z"}),
            json!({"tool": "Read"}),
            json!({"tool": "Read", "ts": "2026-05-01T01:00:00Z"}),
        ];

        let now = parse_iso_ts("2026-05-01T01:05:00Z").expect("valid timestamp");
        assert_eq!(count_paralysis_events(&events, now), 2);
    }
}
