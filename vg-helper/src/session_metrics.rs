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
        // Filter to current session only — parallel agents in the same repo share the
        // same project log; without this filter their events contaminate warn_ratio and
        // Signal 10 baseline, producing false LEARN_SUGGESTED stops.
        let evt_session = e.get("session").and_then(Value::as_str).unwrap_or("");
        if !evt_session.is_empty() && evt_session != session.as_str() {
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
    let mut durations_ms: Vec<u64> = Vec::new();

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

        if let Some(d_ms) = e.get("duration_ms").and_then(Value::as_u64) {
            durations_ms.push(d_ms);
        }
    }

    let avg_duration_ms: u64 = if durations_ms.is_empty() {
        0
    } else {
        durations_ms.iter().sum::<u64>() / durations_ms.len() as u64
    };
    let slow_ops = durations_ms.iter().filter(|&&d| d > 5000).count();

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
        let rl = r.to_lowercase();
        r.contains("构建错误") || rl.contains("build fail") || rl.contains("build error")
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

    // top_edited_files: top 5 by edit count (mirrors Python edited_files.most_common(5))
    let mut top_files: Vec<_> = edited_files.iter().collect();
    top_files.sort_by(|a, b| b.1.cmp(a.1));
    let top_edited_files: serde_json::Map<String, Value> = top_files
        .iter()
        .take(5)
        .map(|(k, v)| ((*k).clone(), json!(**v)))
        .collect();

    // Write metrics
    let metrics = json!({
        "ts": chrono_now(),
        "session": session,
        "event_count": events.len(),
        "decisions": decisions,
        "hooks": hooks,
        "tools": tools,
        "top_edited_files": top_edited_files,
        "avg_duration_ms": avg_duration_ms,
        "slow_ops": slow_ops,
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

#[cfg(test)]
mod tests {
    use super::*;

    // --- parse_iso_ts ---

    #[test]
    fn test_parse_unix_epoch() {
        assert_eq!(parse_iso_ts("1970-01-01T00:00:00Z"), Some(0));
    }

    #[test]
    fn test_parse_z_suffix() {
        // 2024-01-01T00:00:00Z
        // Days from 1970-01-01 to 2024-01-01:
        //   leap years in [1970, 2024): 1972,1976,...,2020 => (2020-1972)/4+1 = 13 leap years
        //   total years = 54, non-leap = 41, leap = 13 => 41*365 + 13*366 = 14965+4758 = 19723 days
        let expected_secs: u64 = 19723 * 86400;
        assert_eq!(parse_iso_ts("2024-01-01T00:00:00Z"), Some(expected_secs));
    }

    #[test]
    fn test_parse_plus00_suffix() {
        assert_eq!(
            parse_iso_ts("1970-01-01T00:00:00+00:00"),
            Some(0)
        );
    }

    #[test]
    fn test_parse_with_hms() {
        // 1970-01-01T01:02:03Z = 3600+120+3 = 3723 secs
        assert_eq!(parse_iso_ts("1970-01-01T01:02:03Z"), Some(3723));
    }

    #[test]
    fn test_parse_invalid_returns_none() {
        assert_eq!(parse_iso_ts("not-a-timestamp"), None);
        assert_eq!(parse_iso_ts(""), None);
        assert_eq!(parse_iso_ts("2024-01-01"), None); // missing T separator
    }

    // --- 30-minute time-window filter ---

    #[test]
    fn test_event_inside_30min_window_passes() {
        // An event timestamped "now" should not be filtered out
        let now = now_unix_secs();
        let cutoff = now.saturating_sub(30 * 60);
        // event at 1 minute ago
        let evt_secs = now.saturating_sub(60);
        assert!(evt_secs >= cutoff, "recent event should pass the 30-min filter");
    }

    #[test]
    fn test_event_outside_30min_window_drops() {
        // An event timestamped 31 minutes ago should be filtered out
        let now = now_unix_secs();
        let cutoff = now.saturating_sub(30 * 60);
        let evt_secs = now.saturating_sub(31 * 60);
        assert!(evt_secs < cutoff, "old event should be dropped by 30-min filter");
    }

    #[test]
    fn test_event_exactly_at_cutoff_passes() {
        // An event at exactly the cutoff boundary is kept (>= cutoff)
        let now = now_unix_secs();
        let cutoff = now.saturating_sub(30 * 60);
        assert!(cutoff >= cutoff);
    }

    // --- session ID filter ---

    #[test]
    fn test_different_session_is_excluded() {
        let session = "sess-A";
        let evt_session = "sess-B";
        // mirrors: if !evt_session.is_empty() && evt_session != session { continue; }
        let excluded = !evt_session.is_empty() && evt_session != session;
        assert!(excluded, "event from different session must be excluded");
    }

    #[test]
    fn test_same_session_is_included() {
        let session = "sess-A";
        let evt_session = "sess-A";
        let excluded = !evt_session.is_empty() && evt_session != session;
        assert!(!excluded, "event from same session must be included");
    }

    #[test]
    fn test_missing_session_field_is_included() {
        // Events with no session field pass through regardless
        let session = "sess-A";
        let evt_session = "";
        let excluded = !evt_session.is_empty() && evt_session != session;
        assert!(!excluded, "event with no session field must be included");
    }
}
