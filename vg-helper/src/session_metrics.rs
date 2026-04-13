//! Session metrics collection + correction signal detection.
//! Replaces hooks/_lib/session_metrics.py.

use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs::OpenOptions;
use std::io::{self, BufRead, Write};

type Result = std::result::Result<(), Box<dyn std::error::Error>>;

/// Returns seconds since Unix epoch via SystemTime.
fn now_unix_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

/// Parse ISO 8601 UTC timestamp (YYYY-MM-DDTHH:MM:SSZ or +00:00) to Unix seconds.
/// Returns None if the string cannot be parsed.
fn parse_iso_ts(ts: &str) -> Option<u64> {
    let s = ts.trim_end_matches('Z');
    let s = s.strip_suffix("+00:00").unwrap_or(s);
    let (date_part, time_part) = s.split_once('T')?;
    let dp: Vec<&str> = date_part.split('-').collect();
    let tp: Vec<&str> = time_part.split(':').collect();
    if dp.len() < 3 || tp.len() < 3 {
        return None;
    }
    let year: i64 = dp[0].parse().ok()?;
    let month: i64 = dp[1].parse().ok()?;
    let day: i64 = dp[2].parse().ok()?;
    let hour: i64 = tp[0].parse().ok()?;
    let min: i64 = tp[1].parse().ok()?;
    let sec: i64 = tp[2].trim_end_matches('Z').parse().ok()?;

    let is_leap = |y: i64| (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
    let mut days: i64 = 0;
    for y in 1970..year {
        days += if is_leap(y) { 366 } else { 365 };
    }
    let month_days: [i64; 12] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    for m in 1..month {
        days += month_days[(m - 1) as usize];
        if m == 2 && is_leap(year) {
            days += 1;
        }
    }
    days += day - 1;

    let total = days * 86400 + hour * 3600 + min * 60 + sec;
    if total < 0 {
        return None;
    }
    Some(total as u64)
}

/// Usage: tail -1000 $LOG | vg-helper session-metrics <session_id> <project_log_dir>
pub fn run(args: &[String]) -> Result {
    if args.len() < 2 {
        return Err("Usage: tail -N log | vg-helper session-metrics <session> <dir>".into());
    }
    let session = &args[0];
    let project_dir = &args[1];

    // 30-minute cutoff — mirrors Python predecessor hooks/_lib/session_metrics.py:36-52
    let cutoff_secs = now_unix_secs().saturating_sub(30 * 60);

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
        // Drop events older than 30 minutes to prevent cross-session contamination
        if let Some(ts) = e.get("ts").and_then(Value::as_str) {
            if let Some(evt_secs) = parse_iso_ts(ts) {
                if evt_secs < cutoff_secs {
                    continue;
                }
            }
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

    // Signal 10: warn trend regression vs project baseline
    // Mirrors Python predecessor hooks/_lib/session_metrics.py:166-187
    let metrics_path = format!("{project_dir}/session-metrics.jsonl");
    if let Ok(content) = std::fs::read_to_string(&metrics_path) {
        let recent_ratios: Vec<f64> = content
            .lines()
            .filter(|l| !l.trim().is_empty())
            .filter_map(|l| serde_json::from_str::<Value>(l).ok())
            .filter_map(|m| m.get("warn_ratio").and_then(Value::as_f64))
            .filter(|&r| r > 0.0)
            .collect();
        if recent_ratios.len() >= 10 {
            let window: Vec<f64> = recent_ratios.iter().rev().take(20).cloned().collect();
            let baseline = window.iter().sum::<f64>() / window.len() as f64;
            if warn_ratio > baseline * 2.0 && warn_ratio > 0.1 {
                signals.push(format!(
                    "Warn rate regression: {:.0}% vs baseline {:.0}% (2x+)",
                    warn_ratio * 100.0,
                    baseline * 100.0
                ));
            }
        }
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
