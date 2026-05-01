use serde_json::{Value, json};
use std::collections::HashMap;
use std::fs::OpenOptions;
use std::io::{self, BufRead, Write};

use crate::event_schema::{
    SESSION_METRICS_SCHEMA_VERSION, UNKNOWN, decision, field, hook, metric_field, tool,
};

use super::signals::build_signals;
use super::time::{
    chrono_now, event_passes_session_filter, event_passes_time_filter, now_unix_secs,
};

type Result = std::result::Result<(), Box<dyn std::error::Error>>;

/// Usage: tail -1000 $LOG | vg-helper session-metrics <session_id> <project_log_dir>
pub fn run(args: &[String]) -> Result {
    let cutoff_secs = now_unix_secs().saturating_sub(30 * 60);
    run_inner(args, io::stdin().lock(), &mut io::stdout(), cutoff_secs)
}

pub(super) fn run_inner(
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
    for line in stdin.lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => continue,
        };
        let line = line.trim().to_string();
        if line.is_empty() {
            continue;
        }
        let Ok(e) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        let hook_name = e.get(field::HOOK).and_then(Value::as_str).unwrap_or("");
        if hook::SKIP_SESSION_METRICS.contains(&hook_name) {
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
        let d = e
            .get(field::DECISION)
            .and_then(Value::as_str)
            .unwrap_or(UNKNOWN);
        *decisions.entry(d.into()).or_default() += 1;
        let h = e
            .get(field::HOOK)
            .and_then(Value::as_str)
            .unwrap_or(UNKNOWN);
        *hooks.entry(h.into()).or_default() += 1;
        let t = e
            .get(field::TOOL)
            .and_then(Value::as_str)
            .unwrap_or(UNKNOWN);
        *tools.entry(t.into()).or_default() += 1;

        if t == tool::EDIT {
            if let Some(detail) = e.get(field::DETAIL).and_then(Value::as_str) {
                if let Some(last) = detail.split_whitespace().last() {
                    *edited_files.entry(last.into()).or_default() += 1;
                }
            }
        }

        if let Some(d_ms) = e.get(field::DURATION_MS).and_then(Value::as_u64) {
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
    let negative = decision::NEGATIVE
        .iter()
        .map(|key| *decisions.get(*key).unwrap_or(&0))
        .sum::<u64>();
    let warn_ratio = negative as f64 / total;

    let signals = build_signals(
        &events,
        &decisions,
        &edited_files,
        warn_ratio,
        negative,
        project_dir,
    );

    // top_edited_files: top 5 by edit count (mirrors Python edited_files.most_common(5))
    let mut top_files: Vec<_> = edited_files.iter().collect();
    top_files.sort_by(|a, b| b.1.cmp(a.1));
    let top_edited_files: serde_json::Map<String, Value> = top_files
        .iter()
        .take(5)
        .map(|(k, v)| ((*k).clone(), json!(**v)))
        .collect();

    // Write metrics
    let metrics_path = format!("{project_dir}/session-metrics.jsonl");
    let mut metrics_map = serde_json::Map::new();
    metrics_map.insert(
        metric_field::SCHEMA_VERSION.into(),
        json!(SESSION_METRICS_SCHEMA_VERSION),
    );
    metrics_map.insert(metric_field::TS.into(), json!(chrono_now()));
    metrics_map.insert(metric_field::SESSION.into(), json!(session));
    metrics_map.insert(metric_field::EVENT_COUNT.into(), json!(events.len()));
    metrics_map.insert(metric_field::DECISIONS.into(), json!(decisions));
    metrics_map.insert(metric_field::HOOKS.into(), json!(hooks));
    metrics_map.insert(metric_field::TOOLS.into(), json!(tools));
    metrics_map.insert(
        metric_field::TOP_EDITED_FILES.into(),
        Value::Object(top_edited_files),
    );
    metrics_map.insert(metric_field::AVG_DURATION_MS.into(), json!(avg_duration_ms));
    metrics_map.insert(metric_field::SLOW_OPS.into(), json!(slow_ops));
    metrics_map.insert(metric_field::CORRECTION_SIGNALS.into(), json!(signals));
    metrics_map.insert(
        metric_field::WARN_RATIO.into(),
        json!((warn_ratio * 100.0).round() / 100.0),
    );
    let metrics = Value::Object(metrics_map);

    if let Ok(mut f) = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&metrics_path)
    {
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
