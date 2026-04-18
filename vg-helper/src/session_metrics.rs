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
    if month < 1 || month > 12 {
        return None;
    }
    let hour: i64 = tp[0].parse().ok()?;
    let min: i64 = tp[1].parse().ok()?;
    let sec: i64 = tp[2].trim_end_matches('Z').parse().ok()?;
    if hour < 0 || hour > 23 || min < 0 || min > 59 || sec < 0 || sec > 59 {
        return None;
    }

    let is_leap = |y: i64| (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
    let month_days: [i64; 12] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    let max_day = if month == 2 && is_leap(year) { 29 } else { month_days[(month - 1) as usize] };
    if day < 1 || day > max_day {
        return None;
    }

    let mut days: i64 = 0;
    for y in 1970..year {
        days += if is_leap(y) { 366 } else { 365 };
    }
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

/// Returns true if the event should be included in session metrics.
/// Events whose `ts` field is present but not a parseable ISO-8601 string are
/// excluded to prevent filter bypass from corrupt log lines (including non-string types).
fn event_passes_time_filter(e: &Value, cutoff_secs: u64) -> bool {
    match e.get("ts") {
        None => true,
        Some(ts_val) => match ts_val.as_str() {
            Some(ts) => match parse_iso_ts(ts) {
                Some(evt_secs) => evt_secs >= cutoff_secs,
                None => false,
            },
            None => false,
        },
    }
}

/// Returns true if the event belongs to the given session (or has no session field).
fn event_passes_session_filter(evt: &Value, session: &str) -> bool {
    let evt_session = evt.get("session").and_then(Value::as_str).unwrap_or("");
    evt_session.is_empty() || evt_session == session
}

/// Usage: tail -1000 $LOG | vg-helper session-metrics <session_id> <project_log_dir>
pub fn run(args: &[String]) -> Result {
    let cutoff_secs = now_unix_secs().saturating_sub(30 * 60);
    run_inner(args, io::stdin().lock(), &mut io::stdout(), cutoff_secs)
}

fn run_inner(
    args: &[String],
    stdin: impl BufRead,
    out: &mut impl Write,
    cutoff_secs: u64,
) -> Result {
    if args.len() < 2 {
        return Err("Usage: tail -N log | vg-helper session-metrics <session> <dir>".into());
    }
    let session = &args[0];
    let project_dir = &args[1];

    let mut events: Vec<Value> = Vec::new();
    let skip = ["stop-guard", "learn-evaluator"];
    for line in stdin.lines() {
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
        if !event_passes_session_filter(&e, session) {
            continue;
        }
        // Drop events outside the 30-minute window.  Events whose `ts` is
        // present but unparseable are also dropped (not passed through).
        if !event_passes_time_filter(&e, cutoff_secs) {
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
        writeln!(out, "LEARN_SUGGESTED")?;
        for sig in &signals {
            writeln!(out, "{sig}")?;
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

    #[test]
    fn test_parse_out_of_range_month_returns_none() {
        // month=13 would index month_days[12] — out of bounds without validation
        assert_eq!(parse_iso_ts("2024-13-01T00:00:00Z"), None);
        assert_eq!(parse_iso_ts("2024-00-01T00:00:00Z"), None);
    }

    #[test]
    fn test_parse_out_of_range_day_returns_none() {
        assert_eq!(parse_iso_ts("2026-04-00T12:00:00Z"), None); // day=0
        assert_eq!(parse_iso_ts("2026-04-31T12:00:00Z"), None); // April has 30 days
        assert_eq!(parse_iso_ts("2026-02-29T12:00:00Z"), None); // 2026 is not a leap year
        assert_eq!(parse_iso_ts("2026-02-31T12:00:00Z"), None); // Feb never has 31 days
        assert!(parse_iso_ts("2024-02-29T12:00:00Z").is_some()); // 2024 is a leap year
    }

    #[test]
    fn test_parse_out_of_range_time_returns_none() {
        assert_eq!(parse_iso_ts("2026-04-18T99:00:00Z"), None); // hour=99
        assert_eq!(parse_iso_ts("2026-04-18T24:00:00Z"), None); // hour=24
        assert_eq!(parse_iso_ts("2026-04-18T00:60:00Z"), None); // min=60
        assert_eq!(parse_iso_ts("2026-04-18T00:00:60Z"), None); // sec=60
        assert_eq!(parse_iso_ts("2026-04-00T99:99:99Z"), None); // day+time all invalid
        // negative time components must also be rejected
        assert_eq!(parse_iso_ts("2026-04-18T-1:00:00Z"), None); // hour=-1
        assert_eq!(parse_iso_ts("2026-04-18T00:-1:00Z"), None); // min=-1
        assert_eq!(parse_iso_ts("2026-04-18T00:00:-1Z"), None); // sec=-1
    }

    // --- 30-minute time-window filter (via production event_passes_time_filter) ---

    #[test]
    fn test_event_inside_30min_window_passes() {
        // epoch+60s is inside a window whose cutoff is 0 — must pass
        assert!(
            event_passes_time_filter(&serde_json::json!({"ts": "1970-01-01T00:01:00Z"}), 0),
            "recent event should pass the 30-min filter"
        );
    }

    #[test]
    fn test_event_outside_30min_window_drops() {
        // epoch 0s is before cutoff 60s — must be dropped
        assert!(
            !event_passes_time_filter(&serde_json::json!({"ts": "1970-01-01T00:00:00Z"}), 60),
            "old event should be dropped by 30-min filter"
        );
    }

    #[test]
    fn test_event_exactly_at_cutoff_passes() {
        // epoch 60s == cutoff 60s — must NOT be dropped (strict less-than in production)
        // If the comparison ever regresses to `<=`, this test will fail.
        assert!(
            event_passes_time_filter(&serde_json::json!({"ts": "1970-01-01T00:01:00Z"}), 60),
            "event at exactly the cutoff boundary must not be dropped"
        );
    }

    // --- event_passes_time_filter (caller-path coverage for issues 1 & 3) ---

    #[test]
    fn test_malformed_ts_is_excluded_by_filter() {
        // Exercises the caller path: parse_iso_ts(ts)==None must NOT fall through to push.
        let cutoff = now_unix_secs().saturating_sub(30 * 60);
        let e = serde_json::json!({"ts": "not-a-date", "hook": "test"});
        assert!(
            !event_passes_time_filter(&e, cutoff),
            "event with unparseable ts must be excluded, not fall through the 30-min filter"
        );
    }

    #[test]
    fn test_non_string_ts_is_excluded_by_filter() {
        // ts present as number, object, or array — must be excluded, not silently admitted.
        let cutoff = now_unix_secs().saturating_sub(30 * 60);
        assert!(!event_passes_time_filter(&serde_json::json!({"ts": 123456789}), cutoff),
            "numeric ts must be excluded");
        assert!(!event_passes_time_filter(&serde_json::json!({"ts": {}}), cutoff),
            "object ts must be excluded");
        assert!(!event_passes_time_filter(&serde_json::json!({"ts": []}), cutoff),
            "array ts must be excluded");
        assert!(!event_passes_time_filter(&serde_json::json!({"ts": null}), cutoff),
            "null ts must be excluded");
    }

    #[test]
    fn test_no_ts_field_passes_filter() {
        // Events with no ts field have no timestamp to validate — include them.
        let cutoff = now_unix_secs().saturating_sub(30 * 60);
        let e = serde_json::json!({"hook": "test"});
        assert!(event_passes_time_filter(&e, cutoff));
    }

    #[test]
    fn test_recent_ts_passes_filter() {
        let now = now_unix_secs();
        let cutoff = now.saturating_sub(30 * 60);
        // 1970-01-01T00:00:00Z = 0 secs — far older than cutoff, should be dropped
        assert!(!event_passes_time_filter(
            &serde_json::json!({"ts": "1970-01-01T00:00:00Z"}),
            cutoff
        ));
        // epoch + cutoff + 60 secs — inside the window, should pass
        // Use a timestamp we know is "recent" relative to a cutoff of 0
        assert!(event_passes_time_filter(
            &serde_json::json!({"ts": "1970-01-01T00:00:00Z"}),
            0
        ));
    }

    // --- session ID filter (via production event_passes_session_filter) ---

    #[test]
    fn test_different_session_is_excluded() {
        let e = serde_json::json!({"session": "sess-B", "hook": "test"});
        assert!(!event_passes_session_filter(&e, "sess-A"),
            "event from different session must be excluded");
    }

    #[test]
    fn test_same_session_is_included() {
        let e = serde_json::json!({"session": "sess-A", "hook": "test"});
        assert!(event_passes_session_filter(&e, "sess-A"),
            "event from same session must be included");
    }

    #[test]
    fn test_missing_session_field_is_included() {
        let e = serde_json::json!({"hook": "test"});
        assert!(event_passes_session_filter(&e, "sess-A"),
            "event with no session field must be included");
    }

    // --- run() integration tests: exercise the full production path via run_inner ---
    // These tests verify that run()'s wiring is correct: JSONL parsing, skip-hook filtering,
    // session filter, time-window filter, events.len() < 3 early return, metrics file append,
    // and LEARN_SUGGESTED stdout output.

    fn make_args(dir: &str) -> Vec<String> {
        vec!["sess-A".to_string(), dir.to_string()]
    }

    fn tmp_dir_for_test(suffix: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("vg-sm-test-{suffix}"));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn test_run_skip_hooks_reduce_count_below_threshold() {
        // 3 skip-hook events + 2 valid events = 2 valid < 3 → early return, no metrics file.
        let dir = tmp_dir_for_test("skip-hooks");
        let metrics_path = dir.join("session-metrics.jsonl");
        let input = concat!(
            "{\"hook\":\"stop-guard\",\"session\":\"sess-A\"}\n",
            "{\"hook\":\"learn-evaluator\",\"session\":\"sess-A\"}\n",
            "{\"hook\":\"stop-guard\",\"session\":\"sess-A\"}\n",
            "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"pass\"}\n",
            "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"pass\"}\n",
        );
        let mut out = Vec::<u8>::new();
        run_inner(&make_args(dir.to_str().unwrap()), io::Cursor::new(input), &mut out, 0).unwrap();
        assert!(out.is_empty(), "no output expected when event count < 3 after skip filtering");
        assert!(!metrics_path.exists(), "metrics file must not be written when event count < 3");
    }

    #[test]
    fn test_run_session_filter_reduces_count_below_threshold() {
        // 3 events from sess-B (filtered out) + 2 from sess-A = 2 valid < 3 → early return.
        let dir = tmp_dir_for_test("session-filter");
        let metrics_path = dir.join("session-metrics.jsonl");
        let input = concat!(
            "{\"hook\":\"pre-tool\",\"session\":\"sess-B\",\"decision\":\"pass\"}\n",
            "{\"hook\":\"pre-tool\",\"session\":\"sess-B\",\"decision\":\"pass\"}\n",
            "{\"hook\":\"pre-tool\",\"session\":\"sess-B\",\"decision\":\"pass\"}\n",
            "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"pass\"}\n",
            "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"pass\"}\n",
        );
        let mut out = Vec::<u8>::new();
        run_inner(&make_args(dir.to_str().unwrap()), io::Cursor::new(input), &mut out, 0).unwrap();
        assert!(out.is_empty(), "no output expected when event count < 3 after session filtering");
        assert!(!metrics_path.exists(), "metrics file must not be written when event count < 3");
    }

    #[test]
    fn test_run_time_filter_reduces_count_below_threshold() {
        // 3 events with ts=epoch (far before cutoff=60s) + 2 with no ts (always pass).
        // Result: 2 valid < 3 → early return.
        let dir = tmp_dir_for_test("time-filter");
        let metrics_path = dir.join("session-metrics.jsonl");
        let input = concat!(
            "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"ts\":\"1970-01-01T00:00:00Z\"}\n",
            "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"ts\":\"1970-01-01T00:00:00Z\"}\n",
            "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"ts\":\"1970-01-01T00:00:00Z\"}\n",
            "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"pass\"}\n",
            "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"pass\"}\n",
        );
        let cutoff = 60u64;
        let mut out = Vec::<u8>::new();
        run_inner(&make_args(dir.to_str().unwrap()), io::Cursor::new(input), &mut out, cutoff).unwrap();
        assert!(out.is_empty(), "no output expected when event count < 3 after time filtering");
        assert!(!metrics_path.exists(), "metrics file must not be written when event count < 3");
    }

    #[test]
    fn test_run_produces_learn_suggested_and_appends_metrics() {
        // 6 valid events: 4 with warn/block decision (>25%, ≥3 negative) → Signal 1.
        // Verifies: metrics file written, LEARN_SUGGESTED on stdout.
        let dir = tmp_dir_for_test("signals");
        let metrics_path = dir.join("session-metrics.jsonl");
        let input = concat!(
            "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"warn\"}\n",
            "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"block\"}\n",
            "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"warn\"}\n",
            "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"block\"}\n",
            "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"pass\"}\n",
            "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"pass\"}\n",
        );
        let mut out = Vec::<u8>::new();
        run_inner(&make_args(dir.to_str().unwrap()), io::Cursor::new(input), &mut out, 0).unwrap();
        let stdout_text = String::from_utf8(out).unwrap();
        assert!(stdout_text.contains("LEARN_SUGGESTED"), "expected LEARN_SUGGESTED in stdout");
        assert!(metrics_path.exists(), "metrics file must be written when ≥3 events processed");
        let file_content = std::fs::read_to_string(&metrics_path).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(file_content.trim()).unwrap();
        assert_eq!(parsed["session"], "sess-A");
        assert_eq!(parsed["event_count"], 6);
    }

    #[test]
    fn test_run_no_signals_with_all_pass_events() {
        // 5 valid pass events — no warn/block signals → no LEARN_SUGGESTED, but metrics written.
        let dir = tmp_dir_for_test("no-signals");
        let metrics_path = dir.join("session-metrics.jsonl");
        let input = concat!(
            "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"pass\"}\n",
            "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"pass\"}\n",
            "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"pass\"}\n",
            "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"pass\"}\n",
            "{\"hook\":\"pre-tool\",\"session\":\"sess-A\",\"decision\":\"pass\"}\n",
        );
        let mut out = Vec::<u8>::new();
        run_inner(&make_args(dir.to_str().unwrap()), io::Cursor::new(input), &mut out, 0).unwrap();
        let stdout_text = String::from_utf8(out).unwrap();
        assert!(!stdout_text.contains("LEARN_SUGGESTED"), "no signal expected for clean session");
        assert!(metrics_path.exists(), "metrics file must still be written even with no signals");
    }
}
