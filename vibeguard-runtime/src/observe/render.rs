use serde_json::{Map, Value, json};
use std::collections::BTreeMap;

use crate::event_schema::UNKNOWN;
use crate::log_scope::LogScope;

use super::OBSERVE_SCHEMA_VERSION;
use super::Result;
use super::aggregate::{
    ObserveAggregate, observe_event_json, observe_is_attention_state, observe_is_diagnostic_event,
};
use super::model::{ObserveCommand, ObserveOptions};
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
        |event| observe_is_diagnostic_event(event, options.slow_ms),
        options.slow_ms,
    );
    if options.json {
        let mut output = observe_summary_json(options, log_events, aggregate);
        output["command"] = json!("health");
        output["attention_states"] = Value::Array(attention_states);
        output["diagnostics"] = Value::Array(diagnostics);
        return Ok(format!("{}\n", serde_json::to_string_pretty(&output)?));
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

pub(super) fn render_session(
    options: &ObserveOptions,
    log_events: &LogEvents,
    aggregate: &ObserveAggregate,
) -> Result<String> {
    let session_id = options.session.as_deref().unwrap_or("");
    let recent_events =
        observe_recent_events_json(&log_events.events, options.top, |_| true, options.slow_ms);
    let attention_states = observe_recent_events_json(
        &log_events.events,
        options.top,
        observe_is_attention_state,
        options.slow_ms,
    );
    let diagnostics = observe_recent_events_json(
        &log_events.events,
        options.top,
        |event| observe_is_diagnostic_event(event, options.slow_ms),
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
    F: Fn(&Value) -> bool,
{
    let mut selected = Vec::new();
    for event in events.iter().rev() {
        if !predicate(event) {
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

fn observe_sorted_counts(map: &BTreeMap<String, u64>) -> Vec<(String, u64)> {
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

fn observe_blank_as_unknown(value: &str) -> &str {
    if value.is_empty() { UNKNOWN } else { value }
}
