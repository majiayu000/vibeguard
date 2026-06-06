use serde_json::{Map, Value, json};
use std::collections::BTreeMap;

use crate::event_schema::{UNKNOWN, decision, field};
use crate::log_scope::LogScope;
use crate::time_utils::parse_iso_ts;

use super::OBSERVE_SCHEMA_VERSION;
use super::Result;
use super::aggregate::{
    ObserveAggregate, observe_client_name, observe_event_json, observe_is_attention_state,
    observe_is_diagnostic_event, observe_non_empty_or, observe_normalized_decision,
    observe_string_field,
};
use super::legacy_stats;
use super::model::{ObserveCommand, ObserveOptions, TimeWindow};
use super::read::LogEvents;

pub(super) fn render_summary(
    options: &ObserveOptions,
    log_events: &LogEvents,
    aggregate: &ObserveAggregate,
) -> Result<String> {
    if options.json {
        return Ok(format!(
            "{}\n",
            serde_json::to_string_pretty(&observe_summary_json(options, log_events, aggregate))?
        ));
    }
    if options.legacy {
        return legacy_stats::render_legacy_summary(options, log_events, aggregate);
    }
    if aggregate.event_count == 0 {
        return Ok(format!(
            "No observe events found in {} for {}.\n",
            log_events.log_path,
            options.window.label()
        ));
    }
    Ok(format!(
        "VibeGuard observe summary ({})\nTime range: {} ~ {}\nEvents: {} | Attention: {} ({:.1}%)\nTop hooks: {}\nTop reasons: {}\n",
        options.window.label(),
        observe_blank_as_unknown(&aggregate.first_ts),
        observe_blank_as_unknown(&aggregate.last_ts),
        aggregate.event_count,
        aggregate.attention_count,
        observe_percentage(aggregate.attention_count, aggregate.event_count),
        observe_top_human(&aggregate.hook_counts, 5),
        observe_top_human(&aggregate.reason_codes, 5)
    ))
}

pub(super) fn render_health(
    options: &ObserveOptions,
    log_events: &LogEvents,
    aggregate: &ObserveAggregate,
) -> Result<String> {
    let attention_states = observe_recent_events_json(
        &log_events.events,
        options.top,
        observe_is_attention_state,
        options.slow_ms,
    );
    let diagnostics = observe_recent_events_json(
        &log_events.events,
        options.top,
        observe_is_diagnostic_event,
        options.slow_ms,
    );
    if options.json {
        let mut output = observe_summary_json(options, log_events, aggregate);
        output["command"] = json!("health");
        output["attention_states"] = Value::Array(attention_states);
        output["diagnostics"] = Value::Array(diagnostics);
        return Ok(format!("{}\n", serde_json::to_string_pretty(&output)?));
    }
    if options.legacy {
        return render_legacy_health(options, log_events, aggregate);
    }
    if aggregate.event_count == 0 {
        return Ok(format!(
            "No observe health events found in {} for {}.\n",
            log_events.log_path,
            options.window.label()
        ));
    }
    Ok(format!(
        "VibeGuard observe health ({})\nEvents: {} | Attention: {} ({:.1}%)\nAttention states: {}\nDiagnostics: {}\n",
        options.window.label(),
        aggregate.event_count,
        aggregate.attention_count,
        observe_percentage(aggregate.attention_count, aggregate.event_count),
        attention_states.len(),
        diagnostics.len()
    ))
}

fn render_legacy_health(
    options: &ObserveOptions,
    log_events: &LogEvents,
    aggregate: &ObserveAggregate,
) -> Result<String> {
    if aggregate.event_count == 0 {
        if !log_events.source_exists {
            return Ok(format!(
                "No log data. Hooks will be automatically logged to {} after being triggered.\n",
                log_events.log_path
            ));
        }
        return Ok(match options.window {
            TimeWindow::Hours(hours) => format!("No log data for the last {hours} hours.\n"),
            TimeWindow::Days(days) => format!("No log data for the last {days} days.\n"),
            TimeWindow::All => "No log data.\n".to_string(),
        });
    }

    let pass_count = legacy_decision_count(aggregate, decision::PASS);
    let risk_count = aggregate.event_count as u64 - pass_count;
    let by_cli = legacy_count_by(&log_events.events, |event| {
        observe_non_empty_or(observe_string_field(event, field::CLI), UNKNOWN)
    });
    let by_client = legacy_count_by(&log_events.events, |event| {
        observe_non_empty_or(observe_client_name(event), UNKNOWN)
    });
    let (first_ts, last_ts) = legacy_parsed_time_range(&log_events.events)
        .unwrap_or_else(|| (aggregate.first_ts.clone(), aggregate.last_ts.clone()));
    let mut non_pass_events = log_events
        .events
        .iter()
        .filter(|event| observe_normalized_decision(event) != decision::PASS)
        .collect::<Vec<_>>();
    non_pass_events
        .sort_by_key(|event| parse_iso_ts(&observe_string_field(event, field::TS)).unwrap_or(0));
    let risk_hook_counts = legacy_count_by_refs(&non_pass_events, |event| {
        observe_non_empty_or(observe_string_field(event, field::HOOK), UNKNOWN)
    });

    let mut output = String::new();
    let period = options.window.label();
    output.push_str(&format!("VibeGuard Hook Health ({period})\n"));
    output.push_str(&format!("{}\n", "=".repeat(44)));
    output.push_str(&format!(
        "Time range: {} ~ {}\n",
        observe_blank_as_unknown(&first_ts),
        observe_blank_as_unknown(&last_ts)
    ));
    output.push_str(&format!("Total triggers: {}\n", aggregate.event_count));
    output.push_str(&format!("Pass: {pass_count}\n"));
    output.push_str(&format!("Risk (non-pass): {risk_count}\n"));
    output.push_str(&format!(
        "Risk rate: {:.1}%\n",
        observe_percentage(risk_count as usize, aggregate.event_count)
    ));
    for status in [
        decision::BLOCK,
        decision::GATE,
        decision::WARN,
        decision::ESCALATE,
        decision::CORRECTION,
    ] {
        output.push_str(&format!(
            "  {status}: {}\n",
            legacy_decision_count(aggregate, status)
        ));
    }

    output.push_str("CLI distribution:\n");
    for (cli, count) in observe_sorted_counts(&by_cli) {
        output.push_str(&format!("  {cli}: {count}\n"));
    }
    output.push_str("Client distribution:\n");
    for (client, count) in observe_sorted_counts(&by_client) {
        output.push_str(&format!("  {client}: {count}\n"));
    }

    if !non_pass_events.is_empty() {
        output.push_str("\nRisk Hook Top 5:\n");
        for (hook, count) in observe_sorted_counts(&risk_hook_counts).into_iter().take(5) {
            output.push_str(&format!("  {hook}: {count}\n"));
        }

        output.push_str("\nTop 10 recent risk events:\n");
        for (index, event) in non_pass_events.iter().rev().take(10).enumerate() {
            let cli = observe_non_empty_or(observe_string_field(event, field::CLI), UNKNOWN);
            let client = observe_non_empty_or(observe_client_name(event), &cli);
            output.push_str(&format!(
                "  {}. {} | {} | {} | cli={} | client={} | session={}\n",
                index + 1,
                observe_non_empty_or(observe_string_field(event, field::TS), "?"),
                observe_non_empty_or(observe_string_field(event, field::HOOK), UNKNOWN),
                observe_non_empty_or(observe_normalized_decision(event), UNKNOWN),
                cli,
                client,
                observe_non_empty_or(observe_string_field(event, field::SESSION), "?")
            ));
            let reason = legacy_clean_detail(&observe_string_field(event, field::REASON));
            let detail = legacy_clean_detail(&observe_string_field(event, field::DETAIL));
            if !reason.is_empty() {
                output.push_str(&format!("     reason: {}\n", legacy_truncate(&reason, 100)));
            }
            if !detail.is_empty() {
                output.push_str(&format!("     detail: {}\n", legacy_truncate(&detail, 100)));
            }
        }
    }

    output.push('\n');
    Ok(output)
}

pub(super) fn legacy_decision_count(aggregate: &ObserveAggregate, status: &str) -> u64 {
    aggregate.decision_counts.get(status).copied().unwrap_or(0)
}

pub(super) fn legacy_count_by<F>(events: &[Value], mut mapper: F) -> BTreeMap<String, u64>
where
    F: FnMut(&Value) -> String,
{
    let mut counts = BTreeMap::new();
    for event in events {
        observe_increment(&mut counts, mapper(event));
    }
    counts
}

fn legacy_count_by_refs<F>(events: &[&Value], mut mapper: F) -> BTreeMap<String, u64>
where
    F: FnMut(&Value) -> String,
{
    let mut counts = BTreeMap::new();
    for event in events {
        observe_increment(&mut counts, mapper(event));
    }
    counts
}

fn legacy_parsed_time_range(events: &[Value]) -> Option<(String, String)> {
    let mut timestamps = events
        .iter()
        .filter_map(|event| {
            let ts = observe_string_field(event, field::TS);
            parse_iso_ts(&ts).map(|parsed| (parsed, ts))
        })
        .collect::<Vec<_>>();
    timestamps.sort_by_key(|(parsed, _)| *parsed);
    let first_ts = timestamps.first()?.1.clone();
    let last_ts = timestamps.last()?.1.clone();
    Some((first_ts, last_ts))
}

pub(super) fn observe_increment(map: &mut BTreeMap<String, u64>, key: String) {
    *map.entry(key).or_default() += 1;
}

fn legacy_clean_detail(value: &str) -> String {
    value.replace('\n', " ").trim().to_string()
}

pub(super) fn legacy_truncate(value: &str, max_chars: usize) -> String {
    let mut chars = value.chars();
    let prefix = chars.by_ref().take(max_chars).collect::<String>();
    if chars.next().is_some() && max_chars >= 3 {
        let keep = max_chars - 3;
        format!("{}...", prefix.chars().take(keep).collect::<String>())
    } else {
        prefix
    }
}

pub(super) fn render_session(
    options: &ObserveOptions,
    log_events: &LogEvents,
    aggregate: &ObserveAggregate,
) -> Result<String> {
    let session_id = options.session.as_deref().unwrap_or("");
    let recent_events = observe_recent_events_json(
        &log_events.events,
        options.top,
        |_, _| true,
        options.slow_ms,
    );
    let attention_states = observe_recent_events_json(
        &log_events.events,
        options.top,
        observe_is_attention_state,
        options.slow_ms,
    );
    let diagnostics = observe_recent_events_json(
        &log_events.events,
        options.top,
        observe_is_diagnostic_event,
        options.slow_ms,
    );
    if options.json {
        let mut output = observe_summary_json(options, log_events, aggregate);
        output["command"] = json!("session");
        output["session"] = json!(session_id);
        output["recent_events"] = Value::Array(recent_events);
        output["attention_states"] = Value::Array(attention_states);
        output["diagnostics"] = Value::Array(diagnostics);
        return Ok(format!("{}\n", serde_json::to_string_pretty(&output)?));
    }
    if aggregate.event_count == 0 {
        return Ok(format!(
            "No observe events found for session {session_id} in {}.\n",
            log_events.log_path
        ));
    }
    Ok(format!(
        "VibeGuard observe session {session_id}\nTime range: {} ~ {}\nEvents: {} | Attention: {} ({:.1}%)\nTop hooks: {}\n",
        observe_blank_as_unknown(&aggregate.first_ts),
        observe_blank_as_unknown(&aggregate.last_ts),
        aggregate.event_count,
        aggregate.attention_count,
        observe_percentage(aggregate.attention_count, aggregate.event_count),
        observe_top_human(&aggregate.hook_counts, 5)
    ))
}

fn observe_summary_json(
    options: &ObserveOptions,
    log_events: &LogEvents,
    aggregate: &ObserveAggregate,
) -> Value {
    json!({
        "schema_version": OBSERVE_SCHEMA_VERSION,
        "command": observe_command_name(options.command),
        "source": {
            "log_path": log_events.log_path,
            "scope": observe_scope_name(options.scope),
            "period": options.window.label(),
            "limit": options.limit,
        },
        "time_range": {
            "first_ts": aggregate.first_ts,
            "last_ts": aggregate.last_ts,
        },
        "event_count": aggregate.event_count,
        "decision_counts": observe_map_to_json(&aggregate.decision_counts),
        "hook_counts": observe_map_to_json(&aggregate.hook_counts),
        "client_distribution": observe_map_to_json(&aggregate.client_distribution),
        "attention": {
            "count": aggregate.attention_count,
            "rate": observe_ratio(aggregate.attention_count, aggregate.event_count),
            "percent": observe_percentage(aggregate.attention_count, aggregate.event_count),
        },
        "top_rule_ids": observe_top_counts_json(&aggregate.rule_ids, options.top),
        "top_reason_codes": observe_top_counts_json(&aggregate.reason_codes, options.top),
        "duration_stats": observe_duration_stats_json(&aggregate.durations_ms, options.slow_ms),
    })
}

fn observe_command_name(command: ObserveCommand) -> &'static str {
    match command {
        ObserveCommand::Summary => "summary",
        ObserveCommand::Health => "health",
        ObserveCommand::Session => "session",
    }
}

fn observe_scope_name(scope: LogScope) -> &'static str {
    match scope {
        LogScope::Project => "project",
        LogScope::Global => "global",
    }
}

fn observe_map_to_json(map: &BTreeMap<String, u64>) -> Value {
    let mut json_map = Map::new();
    for (key, value) in map {
        json_map.insert(key.clone(), json!(*value));
    }
    Value::Object(json_map)
}

fn observe_top_counts_json(map: &BTreeMap<String, u64>, limit: usize) -> Value {
    Value::Array(
        observe_sorted_counts(map)
            .into_iter()
            .take(limit)
            .map(|(value, count)| json!({ "value": value, "count": count }))
            .collect(),
    )
}

fn observe_duration_stats_json(durations: &[u64], slow_ms: u64) -> Value {
    if durations.is_empty() {
        return json!({
            "count": 0,
            "avg_ms": 0,
            "min_ms": null,
            "p95_ms": null,
            "max_ms": null,
            "slow_count": 0,
            "slow_ms": slow_ms,
        });
    }
    let sum = durations.iter().sum::<u64>();
    let p95_index = ((durations.len() * 95).div_ceil(100)).saturating_sub(1);
    json!({
        "count": durations.len(),
        "avg_ms": sum / durations.len() as u64,
        "min_ms": durations.first().copied(),
        "p95_ms": durations.get(p95_index).copied(),
        "max_ms": durations.last().copied(),
        "slow_count": durations.iter().filter(|duration| **duration >= slow_ms).count(),
        "slow_ms": slow_ms,
    })
}

fn observe_recent_events_json<F>(
    events: &[Value],
    limit: usize,
    predicate: F,
    slow_ms: u64,
) -> Vec<Value>
where
    F: Fn(&Value, u64) -> bool,
{
    let mut selected = Vec::new();
    for event in events.iter().rev() {
        if !predicate(event, slow_ms) {
            continue;
        }
        selected.push(observe_event_json(event, slow_ms));
        if selected.len() >= limit {
            break;
        }
    }
    selected.reverse();
    selected
}

pub(super) fn observe_sorted_counts(map: &BTreeMap<String, u64>) -> Vec<(String, u64)> {
    let mut values: Vec<(String, u64)> = map
        .iter()
        .map(|(key, value)| (key.clone(), *value))
        .collect();
    values.sort_by(|left, right| right.1.cmp(&left.1).then_with(|| left.0.cmp(&right.0)));
    values
}

fn observe_top_human(map: &BTreeMap<String, u64>, limit: usize) -> String {
    let values = observe_sorted_counts(map);
    if values.is_empty() {
        return "none".to_string();
    }
    values
        .into_iter()
        .take(limit)
        .map(|(value, count)| format!("{value}={count}"))
        .collect::<Vec<_>>()
        .join(", ")
}

fn observe_ratio(count: usize, total: usize) -> f64 {
    if total == 0 {
        return 0.0;
    }
    ((count as f64 / total as f64) * 1_000.0).round() / 1_000.0
}

fn observe_percentage(count: usize, total: usize) -> f64 {
    if total == 0 {
        return 0.0;
    }
    ((count as f64 / total as f64) * 1_000.0).round() / 10.0
}

pub(super) fn observe_blank_as_unknown(value: &str) -> &str {
    if value.is_empty() { UNKNOWN } else { value }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn duration_stats_reports_sorted_bounds_and_slow_count() {
        let stats = observe_duration_stats_json(&[5, 10, 2_500, 30_000], 2_000);

        assert_eq!(stats["count"], 4);
        assert_eq!(stats["avg_ms"], 8_128);
        assert_eq!(stats["min_ms"], 5);
        assert_eq!(stats["p95_ms"], 30_000);
        assert_eq!(stats["max_ms"], 30_000);
        assert_eq!(stats["slow_count"], 2);
    }

    #[test]
    fn top_counts_sort_by_count_then_name() {
        let mut counts = BTreeMap::new();
        counts.insert("zeta".to_string(), 2);
        counts.insert("alpha".to_string(), 2);
        counts.insert("beta".to_string(), 1);

        let sorted = observe_sorted_counts(&counts);

        assert_eq!(sorted[0], ("alpha".to_string(), 2));
        assert_eq!(sorted[1], ("zeta".to_string(), 2));
        assert_eq!(sorted[2], ("beta".to_string(), 1));
    }
}
