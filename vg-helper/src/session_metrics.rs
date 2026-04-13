//! Session metrics collection + correction signal detection.
//! Replaces hooks/_lib/session_metrics.py.

use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs::OpenOptions;
use std::io::{self, BufRead, Write};

type Result = std::result::Result<(), Box<dyn std::error::Error>>;

/// Usage: tail -1000 $LOG | vg-helper session-metrics <session_id> <project_log_dir>
pub fn run(args: &[String]) -> Result {
    if args.len() < 2 {
        return Err("Usage: tail -N log | vg-helper session-metrics <session> <dir>".into());
    }
    let session = &args[0];
    let project_dir = &args[1];

    let stdin = io::stdin();
    let mut events: Vec<Value> = Vec::new();
    let skip = ["stop-guard", "learn-evaluator"];
    for line in stdin.lock().lines() {
        let line = line?;
        let line = line.trim().to_string();
        if line.is_empty() {
            continue;
        }
        let Ok(e) = serde_json::from_str::<Value>(&line) else { continue };
        let hook = e.get("hook").and_then(Value::as_str).unwrap_or("");
        if skip.contains(&hook) {
            continue;
        }
        events.push(e);
    }

    if events.len() < 3 {
        return Ok(());
    }

    // Aggregate
    let mut decisions: HashMap<String, u64> = HashMap::new();
    let mut hooks: HashMap<String, u64> = HashMap::new();
    let mut tools: HashMap<String, u64> = HashMap::new();
    let mut edited_files: HashMap<String, u64> = HashMap::new();

    for e in &events {
        let d = e.get("decision").and_then(Value::as_str).unwrap_or("unknown");
        *decisions.entry(d.into()).or_default() += 1;
        let h = e.get("hook").and_then(Value::as_str).unwrap_or("unknown");
        *hooks.entry(h.into()).or_default() += 1;
        let t = e.get("tool").and_then(Value::as_str).unwrap_or("unknown");
        *tools.entry(t.into()).or_default() += 1;

        if t == "Edit" {
            if let Some(detail) = e.get("detail").and_then(Value::as_str) {
                if let Some(last) = detail.split_whitespace().last() {
                    *edited_files.entry(last.into()).or_default() += 1;
                }
            }
        }
    }

    let total = events.len() as f64;
    let negative = *decisions.get("warn").unwrap_or(&0)
        + *decisions.get("block").unwrap_or(&0)
        + *decisions.get("escalate").unwrap_or(&0)
        + *decisions.get("correction").unwrap_or(&0);
    let warn_ratio = negative as f64 / total;

    let mut signals: Vec<String> = Vec::new();

    // Signal 1: High friction (>25%, >=3)
    if warn_ratio > 0.25 && negative >= 3 {
        signals.push(format!(
            "High friction session: {negative}/{} events ({:.0}%)",
            events.len(),
            warn_ratio * 100.0
        ));
    }

    // Signal 2: File churn (adaptive threshold)
    let distinct = edited_files.values().filter(|&&c| c >= 1).count();
    let thresh: u64 = if distinct >= 5 { 7 } else { 3 };
    let mut top_files: Vec<_> = edited_files.iter().collect();
    top_files.sort_by(|a, b| b.1.cmp(a.1));
    for (f, c) in top_files.iter().take(5) {
        if **c >= thresh {
            let base = f.rsplit('/').next().unwrap_or(f);
            signals.push(format!("{base} edited {c} times (repeated correction)"));
        }
    }

    // Signal 3-4: correction + escalate
    let corr = *decisions.get("correction").unwrap_or(&0);
    if corr > 0 {
        signals.push(format!("{corr} real-time correction detection triggers"));
    }
    let esc = *decisions.get("escalate").unwrap_or(&0);
    if esc > 0 {
        signals.push(format!("{esc} upgrade warnings"));
    }

    // Signal 5: blocks
    let blocks = *decisions.get("block").unwrap_or(&0);
    if blocks > 0 {
        let reasons: Vec<String> = events
            .iter()
            .filter(|e| e.get("decision").and_then(Value::as_str) == Some("block"))
            .filter_map(|e| e.get("reason").and_then(Value::as_str))
            .map(|r| r.chars().take(60).collect())
            .collect();
        let unique: Vec<&String> = {
            let mut seen = Vec::new();
            for r in &reasons {
                if !seen.contains(&r) {
                    seen.push(r);
                }
                if seen.len() >= 3 { break; }
            }
            seen
        };
        let joined = unique.iter().map(|s| s.as_str()).collect::<Vec<_>>().join("; ");
        signals.push(format!("{blocks} block(s): {joined}"));
    }

    // Signal 6: paralysis
    let paralysis: Vec<_> = events
        .iter()
        .filter(|e| e.get("reason").and_then(Value::as_str).is_some_and(|r| r.contains("paralysis")))
        .collect();
    if paralysis.len() >= 2 {
        signals.push(format!("Analysis paralysis: {} triggers", paralysis.len()));
    }

    // Signal 7: rule repeat (same rule 3+ times)
    let mut rule_counts: HashMap<String, u64> = HashMap::new();
    for e in &events {
        let d = e.get("decision").and_then(Value::as_str).unwrap_or("");
        if !["warn", "block", "escalate"].contains(&d) { continue; }
        let reason = e.get("reason").and_then(Value::as_str).unwrap_or("");
        if let Some(end) = reason.find(']') {
            let tag = &reason[..=end];
            *rule_counts.entry(tag.into()).or_default() += 1;
        }
    }
    for (tag, count) in &rule_counts {
        if *count >= 3 {
            signals.push(format!("Rule {tag} triggered {count} times (pattern)"));
        }
    }

    // Signal 8: build failure cluster
    let bf = events.iter().filter(|e| {
        let r = e.get("reason").and_then(Value::as_str).unwrap_or("");
        r.contains("构建错误") || r.to_lowercase().contains("build fail")
    }).count();
    if bf >= 3 {
        signals.push(format!("{bf} build failures in session (spiral risk)"));
    }

    // Signal 9: circuit breaker trips
    let cb = events.iter().filter(|e| {
        e.get("reason").and_then(Value::as_str).is_some_and(|r| r.contains("CB tripped"))
    }).count();
    if cb > 0 {
        signals.push(format!("Circuit breaker tripped {cb} time(s)"));
    }

    // Write metrics
    let metrics = json!({
        "ts": chrono_now(),
        "session": session,
        "event_count": events.len(),
        "decisions": decisions,
        "hooks": hooks,
        "tools": tools,
        "correction_signals": signals,
        "warn_ratio": (warn_ratio * 100.0).round() / 100.0,
    });

    let metrics_path = format!("{project_dir}/session-metrics.jsonl");
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(&metrics_path) {
        let _ = writeln!(f, "{}", serde_json::to_string(&metrics)?);
    }

    // Output
    if !signals.is_empty() {
        println!("LEARN_SUGGESTED");
        for sig in &signals {
            println!("{sig}");
        }
    }
    Ok(())
}

fn chrono_now() -> String {
    // Simple UTC timestamp without chrono crate dependency
    let output = std::process::Command::new("date").args(["-u", "+%Y-%m-%dT%H:%M:%SZ"]).output();
    match output {
        Ok(o) => String::from_utf8_lossy(&o.stdout).trim().to_string(),
        Err(_) => "1970-01-01T00:00:00Z".into(),
    }
}
