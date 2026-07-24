use serde_json::Value;
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

use crate::event_schema::{decision, field, hook, tool};
use crate::hook_checks_common::{first_detail_path, write_log_event};
use crate::log_query::count_build_fail_events;
use crate::time_utils::{now_unix_secs, parse_iso_ts};

const POST_EDIT_HISTORY_LINES: usize = 500;

#[derive(Default)]
pub(crate) struct PostEditHistorySignals {
    churn_count: usize,
    build_fail_count: u32,
    warn_count: usize,
    w15_count: usize,
    overlap: Option<OverlapSignal>,
}

impl PostEditHistorySignals {
    pub(crate) fn needs_shell_w15_check(&self) -> bool {
        self.w15_count >= 2
    }
}

pub(crate) struct OverlapSignal {
    pub(crate) session: String,
    pub(crate) agent: String,
    pub(crate) hook: String,
    pub(crate) tool: String,
    pub(crate) normalized_file: String,
}

pub(crate) fn post_edit_history_signals(
    log_file: &str,
    session: &str,
    agent: &str,
    file_path: &str,
) -> io::Result<Option<PostEditHistorySignals>> {
    let lines = match read_tail_lines(log_file, POST_EDIT_HISTORY_LINES) {
        Ok(lines) => lines,
        Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(err) => return Err(err),
    };
    let mut events = Vec::new();
    for (index, line) in lines.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let event = serde_json::from_str::<Value>(line).map_err(|err| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "malformed post-edit history JSONL at line {}: {err}",
                    index + 1
                ),
            )
        })?;
        events.push(event);
    }
    if events.is_empty() {
        return Ok(None);
    }

    let churn_count = events
        .iter()
        .filter(|e| e.get(field::SESSION).and_then(Value::as_str) == Some(session))
        .filter(|e| e.get(field::TOOL).and_then(Value::as_str) == Some(tool::EDIT))
        .filter(|e| {
            e.get(field::DETAIL)
                .and_then(Value::as_str)
                .is_some_and(|detail| detail.contains(file_path))
        })
        .count();
    let warn_count = events
        .iter()
        .filter(|e| e.get(field::SESSION).and_then(Value::as_str) == Some(session))
        .filter(|e| e.get(field::HOOK).and_then(Value::as_str) == Some(hook::POST_EDIT_GUARD))
        .filter(|e| e.get(field::DECISION).and_then(Value::as_str) == Some(decision::WARN))
        .filter(|e| !is_churn_only_warning(e))
        .filter(|e| first_detail_path(e) == file_path)
        .count();
    let build_fail_count = if churn_count >= 20 {
        count_session_build_fail_events(&events, session, &current_project_root())
    } else {
        0
    };

    Ok(Some(PostEditHistorySignals {
        churn_count,
        build_fail_count,
        warn_count,
        w15_count: consecutive_post_edit_count(&events, session, file_path),
        overlap: recent_overlap(&events, session, agent, file_path),
    }))
}

fn count_session_build_fail_events(events: &[Value], session: &str, project: &str) -> u32 {
    let session_events = events
        .iter()
        .filter(|e| e.get(field::SESSION).and_then(Value::as_str) == Some(session))
        .cloned()
        .collect::<Vec<_>>();
    count_build_fail_events(&session_events, project)
}

fn consecutive_post_edit_count(events: &[Value], session: &str, file_path: &str) -> usize {
    let mut count = 0;
    for event in events.iter().rev().filter(|e| {
        e.get(field::SESSION).and_then(Value::as_str) == Some(session)
            && e.get(field::TOOL).and_then(Value::as_str) == Some(tool::EDIT)
            && e.get(field::HOOK).and_then(Value::as_str) == Some(hook::POST_EDIT_GUARD)
    }) {
        if first_detail_path(event) == file_path {
            count += 1;
        } else {
            break;
        }
    }
    count
}

fn is_churn_only_warning(event: &Value) -> bool {
    let reason = event
        .get(field::REASON)
        .and_then(Value::as_str)
        .unwrap_or("");
    reason.contains("[CHURN") && !reason.contains("\n---\n")
}

pub(crate) fn recent_overlap(
    events: &[Value],
    session: &str,
    agent: &str,
    file_path: &str,
) -> Option<OverlapSignal> {
    let normalized_file = normalize_path(file_path);
    let cutoff = now_unix_secs().saturating_sub(30 * 60);
    let mut last = None;
    for e in events {
        if !matches!(
            e.get(field::TOOL).and_then(Value::as_str),
            Some(tool::EDIT) | Some(tool::WRITE)
        ) {
            continue;
        }
        // Pre-hook events record intent to edit, not a completed write; they
        // must not count as another writer touching the file (issue #673).
        if e.get(field::HOOK)
            .and_then(Value::as_str)
            .is_some_and(|hook| hook.starts_with("pre-"))
        {
            continue;
        }
        let same_session = e.get(field::SESSION).and_then(Value::as_str) == Some(session);
        let other_agent = e.get("agent").and_then(Value::as_str).unwrap_or("") != agent;
        if same_session && !other_agent {
            continue;
        }
        let detail_path = first_detail_path(e);
        if detail_path != file_path && normalize_path(detail_path) != normalized_file {
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
        last = Some(OverlapSignal {
            session: e
                .get(field::SESSION)
                .and_then(Value::as_str)
                .unwrap_or("?")
                .to_string(),
            agent: e
                .get("agent")
                .and_then(Value::as_str)
                .unwrap_or("?")
                .to_string(),
            hook: e
                .get(field::HOOK)
                .and_then(Value::as_str)
                .unwrap_or("?")
                .to_string(),
            tool: e
                .get(field::TOOL)
                .and_then(Value::as_str)
                .unwrap_or("?")
                .to_string(),
            normalized_file: normalized_file.clone(),
        });
    }
    last
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

fn current_project_root() -> String {
    std::process::Command::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .ok()
        .filter(|output| output.status.success())
        .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_string())
        .filter(|path| !path.is_empty())
        .unwrap_or_else(|| {
            std::env::current_dir()
                .unwrap_or_else(|_| PathBuf::from("."))
                .to_string_lossy()
                .to_string()
        })
}

pub(crate) fn read_tail_lines(path: &str, max_lines: usize) -> io::Result<String> {
    let mut file = File::open(path)?;
    let mut pos = file.metadata()?.len();
    let mut buf = Vec::new();
    let mut newline_count = 0usize;

    while pos > 0 && newline_count <= max_lines {
        let read_size = usize::min(8192, pos as usize);
        pos -= read_size as u64;
        file.seek(SeekFrom::Start(pos))?;
        let mut chunk = vec![0u8; read_size];
        file.read_exact(&mut chunk)?;
        newline_count += chunk.iter().filter(|b| **b == b'\n').count();
        chunk.extend_from_slice(&buf);
        buf = chunk;
    }

    if newline_count > max_lines {
        let mut seen = 0usize;
        let mut start = 0usize;
        for (idx, byte) in buf.iter().enumerate().rev() {
            if *byte == b'\n' {
                seen += 1;
                if seen == max_lines + 1 {
                    start = idx + 1;
                    break;
                }
            }
        }
        buf = buf[start..].to_vec();
    }

    Ok(String::from_utf8_lossy(&buf).into_owned())
}

pub(crate) fn post_edit_history_warnings(
    file_path: &str,
    signals: &PostEditHistorySignals,
) -> String {
    let mut warnings = Vec::new();
    let basename = Path::new(file_path)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or(file_path);

    if signals.churn_count >= 20 && signals.build_fail_count >= 5 {
        warnings.push(format!(
            "[CHURN CRITICAL] [review] [this-file] OBSERVATION: {basename} has been edited {} times and the project has {} consecutive build failures - possible edit->fail->fix loop\nFIX: Pause and classify: planned refactor vs failed repair loop. If planned, make one scoped finishing edit and verify; if failed loop, stop and re-check root cause (W-02)\nDO NOT: Keep making equivalent fix attempts without fresh build output and a confirmed root cause",
            signals.churn_count,
            signals.build_fail_count
        ));
    } else if signals.churn_count >= 20 {
        warnings.push(format!(
            "[CHURN WARNING] [review] [this-file] OBSERVATION: {basename} has been edited {} times - high edit volume without repeated build-failure evidence\nFIX: Pause and classify: planned refactor vs failed repair loop. If planned, make one scoped finishing edit and verify.\nDO NOT: Treat edit count alone as proof of W-02 failure-loop behavior",
            signals.churn_count
        ));
    } else if signals.churn_count >= 10 {
        warnings.push(format!(
            "[CHURN WARNING] [info] [this-file] OBSERVATION: {basename} has been edited {} times, possible correction loop\nFIX: Run full build to see the complete picture, or use /vibeguard:learn to extract patterns\nDO NOT: Take any action - monitor and decide whether to continue",
            signals.churn_count
        ));
    } else if signals.churn_count >= 5 {
        warnings.push(format!(
            "[CHURN] [info] [this-file] OBSERVATION: {basename} has been edited {} times\nFIX: Check if you are in a correction loop before continuing\nDO NOT: Take any action - this is informational only",
            signals.churn_count
        ));
    }

    if let Some(overlap) = &signals.overlap {
        let agent = if overlap.agent.is_empty() {
            "unknown"
        } else {
            &overlap.agent
        };
        warnings.push(format!(
            "[W-14] [review] [this-file] OBSERVATION: another session or agent recently touched {basename} ({} via {}, session {}, agent {})\nFIX: Confirm file ownership before continuing; prefer a dedicated worktree or single-owner merge path\nDO NOT: Continue parallel/background edits to this file without explicit ownership",
            overlap.tool, overlap.hook, overlap.session, agent
        ));
    }

    if signals.w15_count >= 2 {
        let total = signals.w15_count + 1;
        warnings.push(format!(
            "[W-15] [review] [this-file] OBSERVATION: {total} consecutive edits to {basename} with no edits to other files in between (low-info loop suspect)\nFIX: Pause - are these {total} edits solving the same problem? If change scope shrinks each round, report a blocker instead of continuing to round {}\nDO NOT: Toggle between equivalent rewrites; do not continue same-direction micro-tuning without reporting",
            total + 1
        ));
    }

    warnings.join("\n---\n")
}

pub(crate) fn build_fast_warning_output(
    log_file: &str,
    file_path: &str,
    warnings: &str,
    history: Option<&PostEditHistorySignals>,
) -> io::Result<String> {
    let warn_count = history.map(|s| s.warn_count).unwrap_or(0);
    let event_decision = fast_warning_decision(warn_count, history);
    let final_warnings = if warn_count >= 3 {
        format!(
            "[ESCALATE] [review] [this-file] OBSERVATION: this file has triggered {warn_count} warnings - user intervention recommended\nFIX: Stop and review the warnings below before continuing\nDO NOT: Continue editing this file without reviewing all warnings\n---\n{warnings}"
        )
    } else {
        warnings.to_string()
    };
    write_fast_log_event(log_file, event_decision, &final_warnings, file_path)?;
    let prefix = if event_decision == decision::ESCALATE {
        "VIBEGUARD upgrade warning"
    } else {
        "VIBEGUARD quality warning"
    };
    let result = serde_json::json!({
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": format!("{prefix}:{}", final_warnings),
        }
    });
    Ok(serde_json::to_string(&result).unwrap_or_else(|_| "{}".to_string()))
}

fn fast_warning_decision(
    warn_count: usize,
    history: Option<&PostEditHistorySignals>,
) -> &'static str {
    if warn_count >= 3 {
        return decision::ESCALATE;
    }
    if history.is_some_and(|signals| signals.churn_count >= 20 && signals.build_fail_count >= 5) {
        return decision::ESCALATE;
    }
    if history.is_some_and(|signals| {
        signals.churn_count >= 5 && signals.overlap.is_none() && signals.w15_count < 2
    }) {
        return decision::CORRECTION;
    }
    decision::WARN
}

fn write_fast_log_event(
    log_file: &str,
    decision: &str,
    reason: &str,
    file_path: &str,
) -> io::Result<()> {
    write_log_event(
        log_file,
        "post-edit-guard",
        "Edit",
        decision,
        reason,
        file_path,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::time_utils::{format_unix_secs_utc, now_unix_secs};

    #[test]
    fn post_edit_fast_path_falls_back_for_history_signals() {
        let events = vec![
            serde_json::json!({
                "session": "current",
                "tool": "Edit",
                "hook": "post-edit-guard",
                "detail": "src/main.rs"
            }),
            serde_json::json!({
                "session": "current",
                "tool": "Edit",
                "hook": "post-edit-guard",
                "detail": "src/main.rs"
            }),
        ];
        assert_eq!(
            consecutive_post_edit_count(&events, "current", "src/main.rs"),
            2
        );
        let overlap = recent_overlap(
            &[serde_json::json!({
                "ts": format_unix_secs_utc(now_unix_secs()),
                "session": "other",
                "agent": "codex",
                "tool": "Edit",
                "detail": "/tmp/main.rs"
            })],
            "current",
            "codex",
            "/tmp/main.rs",
        )
        .expect("matching file should produce an overlap");
        assert_eq!(overlap.normalized_file, "/tmp/main.rs");
    }

    #[test]
    fn recent_overlap_ignores_pre_hook_intent_events() {
        let pre_only = [serde_json::json!({
            "ts": format_unix_secs_utc(now_unix_secs()),
            "session": "other",
            "agent": "codex",
            "tool": "Edit",
            "hook": "pre-edit-guard",
            "detail": "/tmp/main.rs"
        })];
        assert!(recent_overlap(&pre_only, "current", "codex", "/tmp/main.rs").is_none());

        let post = [serde_json::json!({
            "ts": format_unix_secs_utc(now_unix_secs()),
            "session": "other",
            "agent": "codex",
            "tool": "Write",
            "hook": "post-write-guard",
            "detail": "/tmp/main.rs"
        })];
        assert!(recent_overlap(&post, "current", "codex", "/tmp/main.rs").is_some());
    }

    #[test]
    fn history_signals_distinguish_no_history_from_malformed_history() {
        let root =
            std::env::temp_dir().join(format!("vibeguard-history-result-{}", std::process::id()));
        if root.exists() {
            std::fs::remove_dir_all(&root).unwrap();
        }
        std::fs::create_dir_all(&root).unwrap();
        let log_file = root.join("events.jsonl");
        let log_path = log_file.to_string_lossy();

        assert!(
            post_edit_history_signals(&log_path, "s", "", "src/lib.rs")
                .unwrap()
                .is_none()
        );
        std::fs::write(&log_file, "\n").unwrap();
        assert!(
            post_edit_history_signals(&log_path, "s", "", "src/lib.rs")
                .unwrap()
                .is_none()
        );
        std::fs::write(&log_file, "not-json\n").unwrap();
        let err = post_edit_history_signals(&log_path, "s", "", "src/lib.rs")
            .err()
            .expect("malformed non-empty history must fail");
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
        assert!(
            err.to_string()
                .contains("malformed post-edit history JSONL")
        );
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn bounded_history_reader_returns_only_requested_tail() {
        let log_file = std::env::temp_dir().join(format!(
            "vibeguard-history-tail-{}.jsonl",
            std::process::id()
        ));
        std::fs::write(&log_file, "first\nsecond\nthird\nfourth\n").unwrap();

        assert_eq!(
            read_tail_lines(log_file.to_string_lossy().as_ref(), 2).unwrap(),
            "third\nfourth\n"
        );
        assert_eq!(normalize_path(""), "");
        std::fs::remove_file(log_file).unwrap();
    }

    #[test]
    fn w15_candidate_requires_shell_delta_check() {
        let signals = PostEditHistorySignals {
            churn_count: 0,
            build_fail_count: 0,
            warn_count: 0,
            w15_count: 2,
            overlap: None,
        };
        assert!(signals.needs_shell_w15_check());

        let signals = PostEditHistorySignals {
            churn_count: 0,
            build_fail_count: 0,
            warn_count: 0,
            w15_count: 1,
            overlap: None,
        };
        assert!(!signals.needs_shell_w15_check());
    }

    #[test]
    fn fast_history_warning_logs_once() {
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let log_file = std::env::temp_dir().join(format!("vibeguard-fast-history-{unique}.jsonl"));
        let log_path = log_file.to_string_lossy().to_string();
        let signals = PostEditHistorySignals {
            churn_count: 5,
            build_fail_count: 0,
            warn_count: 0,
            w15_count: 0,
            overlap: None,
        };

        let warnings = post_edit_history_warnings("src/main.rs", &signals);
        assert!(warnings.contains("[CHURN]"));
        assert!(!log_file.exists());

        let output =
            build_fast_warning_output(&log_path, "src/main.rs", &warnings, Some(&signals)).unwrap();
        assert!(output.contains("VIBEGUARD quality warning"));

        let log_text = std::fs::read_to_string(&log_file).unwrap();
        let lines = log_text.lines().collect::<Vec<_>>();
        assert_eq!(lines.len(), 1);
        let event = serde_json::from_str::<Value>(lines[0]).unwrap();
        assert_eq!(
            event.get(field::DECISION).and_then(Value::as_str),
            Some(decision::CORRECTION)
        );

        let _ = std::fs::remove_file(log_file);
    }

    #[test]
    fn history_warn_count_excludes_churn_only_warnings() {
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let log_file = std::env::temp_dir().join(format!("vibeguard-warn-count-{unique}.jsonl"));
        let log_path = log_file.to_string_lossy().to_string();
        let events = [
            serde_json::json!({
                "session": "s",
                "tool": "Edit",
                "hook": "post-edit-guard",
                "decision": "warn",
                "reason": "[CHURN WARNING] edit volume only",
                "detail": "src/lib.rs"
            }),
            serde_json::json!({
                "session": "s",
                "tool": "Edit",
                "hook": "post-edit-guard",
                "decision": "warn",
                "reason": "[CHURN WARNING] edit volume\n---\n[RS-03] unwrap",
                "detail": "src/lib.rs"
            }),
            serde_json::json!({
                "session": "s",
                "tool": "Edit",
                "hook": "post-edit-guard",
                "decision": "warn",
                "reason": "[W-14] overlap",
                "detail": "src/lib.rs"
            }),
        ];
        let text = events
            .iter()
            .map(serde_json::Value::to_string)
            .collect::<Vec<_>>()
            .join("\n");
        std::fs::write(&log_file, format!("{text}\n")).unwrap();

        let signals = post_edit_history_signals(&log_path, "s", "", "src/lib.rs")
            .unwrap()
            .unwrap();
        assert_eq!(signals.warn_count, 2);

        let _ = std::fs::remove_file(log_file);
    }

    #[test]
    fn churn_only_fast_warnings_do_not_escalate() {
        let signals = PostEditHistorySignals {
            churn_count: 20,
            build_fail_count: 0,
            warn_count: 0,
            w15_count: 0,
            overlap: None,
        };
        let warnings = post_edit_history_warnings("src/lib.rs", &signals);

        assert!(warnings.contains("[CHURN WARNING]"));
        assert!(!warnings.contains("[CHURN CRITICAL]"));
        assert_eq!(
            fast_warning_decision(signals.warn_count, Some(&signals)),
            decision::CORRECTION
        );
        assert_eq!(fast_warning_decision(3, Some(&signals)), decision::ESCALATE);
    }

    #[test]
    fn churn_with_repeated_build_failures_stays_critical() {
        let signals = PostEditHistorySignals {
            churn_count: 20,
            build_fail_count: 5,
            warn_count: 0,
            w15_count: 0,
            overlap: None,
        };
        let warnings = post_edit_history_warnings("src/lib.rs", &signals);

        assert!(warnings.contains("[CHURN CRITICAL]"));
        assert!(warnings.contains("5 consecutive build failures"));
        assert_eq!(
            fast_warning_decision(signals.warn_count, Some(&signals)),
            decision::ESCALATE
        );
    }

    #[test]
    fn fast_history_build_failures_are_session_scoped() {
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let log_file =
            std::env::temp_dir().join(format!("vibeguard-build-fail-session-{unique}.jsonl"));
        let log_path = log_file.to_string_lossy().to_string();
        let project = current_project_root();
        let fail_detail = format!("{}/src/failing.rs", project.trim_end_matches('/'));
        let mut events = Vec::new();
        for _ in 0..20 {
            events.push(serde_json::json!({
                "session": "current",
                "tool": "Edit",
                "hook": "post-edit-guard",
                "decision": "pass",
                "detail": "src/lib.rs"
            }));
        }
        for _ in 0..5 {
            events.push(serde_json::json!({
                "session": "other",
                "tool": "Edit",
                "hook": "post-build-check",
                "decision": "warn",
                "detail": fail_detail
            }));
        }
        let text = events
            .iter()
            .map(serde_json::Value::to_string)
            .collect::<Vec<_>>()
            .join("\n");
        std::fs::write(&log_file, format!("{text}\n")).unwrap();

        let signals = post_edit_history_signals(&log_path, "current", "", "src/lib.rs")
            .unwrap()
            .unwrap();
        assert_eq!(signals.churn_count, 20);
        assert_eq!(signals.build_fail_count, 0);

        for _ in 0..5 {
            events.push(serde_json::json!({
                "session": "current",
                "tool": "Edit",
                "hook": "post-build-check",
                "decision": "warn",
                "detail": fail_detail
            }));
        }
        let text = events
            .iter()
            .map(serde_json::Value::to_string)
            .collect::<Vec<_>>()
            .join("\n");
        std::fs::write(&log_file, format!("{text}\n")).unwrap();

        let signals = post_edit_history_signals(&log_path, "current", "", "src/lib.rs")
            .unwrap()
            .unwrap();
        assert_eq!(signals.build_fail_count, 5);

        let _ = std::fs::remove_file(log_file);
    }
}
