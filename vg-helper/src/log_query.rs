//! JSONL log queries — replaces churn/escalation/build-fail/paralysis Python calls.
//! All functions read from stdin (piped from `tail -N`) for bounded reads.

use serde_json::Value;
use std::io::{self, BufRead};

type Result = std::result::Result<(), Box<dyn std::error::Error>>;

fn read_events(session: &str) -> Vec<Value> {
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
            if v.get("session").and_then(Value::as_str) == Some(session) {
                events.push(v);
            }
        }
    }
    events
}

/// Count how many times a file was edited in the current session.
/// Usage: tail -500 log | vg-helper churn-count <session> <file_path>
pub fn churn_count(args: &[String]) -> Result {
    if args.len() < 2 {
        return Err("Usage: tail -N log | vg-helper churn-count <session> <file_path>".into());
    }
    let (session, file_path) = (&args[0], &args[1]);
    let events = read_events(session);
    let count = events
        .iter()
        .filter(|e| {
            e.get("tool").and_then(Value::as_str) == Some("Edit")
                && e.get("detail")
                    .and_then(Value::as_str)
                    .is_some_and(|d| d.contains(file_path.as_str()))
        })
        .count();
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
    let count = events
        .iter()
        .filter(|e| {
            e.get("hook").and_then(Value::as_str) == Some("post-edit-guard")
                && e.get("decision").and_then(Value::as_str) == Some("warn")
                && e.get("detail").and_then(Value::as_str).is_some_and(|d| {
                    d.split("||").next().unwrap_or("").trim() == file_path.as_str()
                })
        })
        .count();
    println!("{count}");
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
    let project_prefix = format!("{}/", project.trim_end_matches('/'));
    let mut count = 0u32;
    for e in events.iter().rev() {
        if e.get("hook").and_then(Value::as_str) != Some("post-build-check") {
            continue;
        }
        let detail = e.get("detail").and_then(Value::as_str).unwrap_or("");
        if !project.is_empty() && !detail.is_empty() && !detail.starts_with(&project_prefix) {
            continue;
        }
        match e.get("decision").and_then(Value::as_str) {
            Some("pass") => break,
            Some("warn") => count += 1,
            _ => {}
        }
    }
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
    let mut consecutive = 0u32;
    for e in events.iter().rev() {
        let hook = e.get("hook").and_then(Value::as_str).unwrap_or("");
        let decision = e.get("decision").and_then(Value::as_str).unwrap_or("");
        if hook == "analysis-paralysis-guard" && decision != "pass" {
            continue;
        }
        match e.get("tool").and_then(Value::as_str) {
            Some("Read" | "Glob" | "Grep") => consecutive += 1,
            Some("Write" | "Edit" | "Bash") => break,
            _ => {}
        }
    }
    println!("{consecutive}");
    Ok(())
}
