use serde_json::{Value, json};
use std::collections::BTreeMap;

use crate::event_schema::{UNKNOWN, decision, field, status};

pub(super) struct ObserveAggregate {
    pub(super) event_count: usize,
    pub(super) attention_count: usize,
    pub(super) decision_counts: BTreeMap<String, u64>,
    pub(super) hook_counts: BTreeMap<String, u64>,
    pub(super) client_distribution: BTreeMap<String, u64>,
    pub(super) rule_ids: BTreeMap<String, u64>,
    pub(super) reason_codes: BTreeMap<String, u64>,
    pub(super) durations_ms: Vec<u64>,
    pub(super) first_ts: String,
    pub(super) last_ts: String,
}

pub(super) fn aggregate_events(events: &[Value], slow_ms: u64) -> ObserveAggregate {
    let mut aggregate = ObserveAggregate {
        event_count: events.len(),
        attention_count: 0,
        decision_counts: BTreeMap::new(),
        hook_counts: BTreeMap::new(),
        client_distribution: BTreeMap::new(),
        rule_ids: BTreeMap::new(),
        reason_codes: BTreeMap::new(),
        durations_ms: Vec::new(),
        first_ts: String::new(),
        last_ts: String::new(),
    };

    for event in events {
        if aggregate.first_ts.is_empty() {
            aggregate.first_ts = observe_string_field(event, field::TS);
        }
        let ts = observe_string_field(event, field::TS);
        if !ts.is_empty() {
            aggregate.last_ts = ts;
        }
        observe_increment(
            &mut aggregate.decision_counts,
            observe_non_empty_or(observe_normalized_decision(event), UNKNOWN),
        );
        observe_increment(
            &mut aggregate.hook_counts,
            observe_non_empty_or(observe_string_field(event, field::HOOK), UNKNOWN),
        );
        observe_increment(
            &mut aggregate.client_distribution,
            observe_non_empty_or(observe_client_name(event), UNKNOWN),
        );
        if observe_is_attention_or_diagnostic(event, slow_ms) {
            aggregate.attention_count += 1;
        }
        let reason = observe_string_field(event, field::REASON);
        for rule_id in observe_extract_rule_ids(&reason) {
            observe_increment(&mut aggregate.rule_ids, rule_id);
        }
        if let Some(reason_code) = observe_reason_code(&reason) {
            observe_increment(&mut aggregate.reason_codes, reason_code);
        }
        if let Some(duration_ms) = observe_effective_duration_ms(event) {
            aggregate.durations_ms.push(duration_ms);
        }
    }
    aggregate.durations_ms.sort_unstable();
    aggregate
}

pub(super) fn observe_event_json(event: &Value, slow_ms: u64) -> Value {
    json!({
        field::TS: observe_string_field(event, field::TS),
        field::SESSION: observe_string_field(event, field::SESSION),
        field::HOOK: observe_non_empty_or(observe_string_field(event, field::HOOK), UNKNOWN),
        field::EVENT: observe_event_name(event),
        field::TOOL: observe_string_field(event, field::TOOL),
        field::DECISION: observe_normalized_decision(event),
        field::STATUS: observe_normalized_status(event, slow_ms),
        field::REASON: observe_string_field(event, field::REASON),
        field::DETAIL: observe_string_field(event, field::DETAIL),
        field::DURATION_MS: observe_effective_duration_ms(event),
        "client": observe_client_name(event),
        "diagnostic": observe_diagnostic_kind(event, slow_ms),
        field::MODEL_CONTEXT: observe_is_attention_state(event, slow_ms),
    })
}

pub(super) fn observe_string_field(value: &Value, key: &str) -> String {
    value
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim()
        .to_string()
}

pub(super) fn observe_numeric_field(value: &Value, key: &str) -> Option<u64> {
    value
        .get(key)
        .and_then(|raw| raw.as_u64().or_else(|| raw.as_str()?.parse::<u64>().ok()))
}

fn observe_effective_duration_ms(event: &Value) -> Option<u64> {
    observe_numeric_field(event, field::DURATION_MS)
        .or_else(|| observe_numeric_field(event, field::ELAPSED_MS))
}

pub(super) fn observe_is_attention_state(event: &Value, slow_ms: u64) -> bool {
    let status_value = observe_normalized_status(event, slow_ms);
    matches!(
        status_value.as_str(),
        status::WARN | status::BLOCK | status::GATE | status::ESCALATE | status::CORRECTION
    )
}

pub(super) fn observe_is_diagnostic_event(event: &Value, slow_ms: u64) -> bool {
    observe_diagnostic_kind(event, slow_ms) != "none"
}

fn observe_increment(map: &mut BTreeMap<String, u64>, key: String) {
    *map.entry(key).or_default() += 1;
}

pub(super) fn observe_non_empty_or(value: String, fallback: &str) -> String {
    if value.is_empty() {
        fallback.to_string()
    } else {
        value
    }
}

pub(super) fn observe_normalized_decision(event: &Value) -> String {
    let decision_value = observe_string_field(event, field::DECISION).to_ascii_lowercase();
    if !decision_value.is_empty() {
        return decision_value;
    }
    observe_string_field(event, field::STATUS).to_ascii_lowercase()
}

fn observe_normalized_status(event: &Value, slow_ms: u64) -> String {
    let explicit = observe_string_field(event, field::STATUS).to_ascii_lowercase();
    if !explicit.is_empty() {
        return observe_canonical_status(&explicit);
    }
    let decision_value = observe_normalized_decision(event);
    let reason = observe_string_field(event, field::REASON).to_ascii_lowercase();
    if reason.contains("timeout") {
        return status::TIMEOUT.to_string();
    }
    if reason.starts_with("skip:") || reason.starts_with("skipped:") {
        return status::SKIPPED.to_string();
    }
    if decision_value == decision::PASS
        && observe_effective_duration_ms(event).is_some_and(|duration| duration >= slow_ms)
    {
        return status::SLOW.to_string();
    }
    observe_canonical_status(&decision_value)
}

fn observe_canonical_status(value: &str) -> String {
    match value {
        status::PASS => status::PASS,
        status::SKIPPED => status::SKIPPED,
        status::WARN => status::WARN,
        status::BLOCK => status::BLOCK,
        status::GATE => status::GATE,
        status::ESCALATE => status::ESCALATE,
        status::CORRECTION => status::CORRECTION,
        status::COMPLETE => status::COMPLETE,
        status::SLOW => status::SLOW,
        status::TIMEOUT => status::TIMEOUT,
        status::RUNNING => status::RUNNING,
        status::ADAPTER_ERROR => status::ADAPTER_ERROR,
        status::HOOK_ERROR => status::HOOK_ERROR,
        status::UNKNOWN | "" => status::UNKNOWN,
        _ => status::UNKNOWN,
    }
    .to_string()
}

fn observe_event_name(event: &Value) -> String {
    for key in [field::EVENT, "hook_event_name", "hookEventName"] {
        let value = observe_string_field(event, key);
        if !value.is_empty() {
            return value;
        }
    }
    let tool_value = observe_string_field(event, field::TOOL);
    if !tool_value.is_empty() {
        return tool_value;
    }
    UNKNOWN.to_string()
}

pub(super) fn observe_client_name(event: &Value) -> String {
    for key in [field::CLIENT, field::CLI, field::AGENT] {
        let value = observe_string_field(event, key);
        if !value.is_empty() {
            return value;
        }
    }
    UNKNOWN.to_string()
}

fn observe_is_attention_or_diagnostic(event: &Value, slow_ms: u64) -> bool {
    observe_is_attention_state(event, slow_ms) || observe_is_diagnostic_event(event, slow_ms)
}

fn observe_diagnostic_kind(event: &Value, slow_ms: u64) -> &'static str {
    let status_value = observe_normalized_status(event, slow_ms);
    let reason = observe_string_field(event, field::REASON).to_ascii_lowercase();
    if status_value == status::TIMEOUT || reason.contains("timeout") {
        return "timeout";
    }
    if status_value == status::HOOK_ERROR {
        return "hook_error";
    }
    if status_value == status::ADAPTER_ERROR {
        return "adapter_error";
    }
    if status_value == status::SLOW
        || observe_effective_duration_ms(event).is_some_and(|duration| duration >= slow_ms)
    {
        return "slow";
    }
    "none"
}

fn observe_extract_rule_ids(text: &str) -> Vec<String> {
    text.split(|ch: char| !(ch.is_ascii_alphanumeric() || ch == '-'))
        .filter_map(|token| {
            let token = token.to_ascii_uppercase();
            observe_looks_like_rule_id(&token).then_some(token)
        })
        .collect()
}

fn observe_looks_like_rule_id(token: &str) -> bool {
    let Some((prefix, suffix)) = token.split_once('-') else {
        return false;
    };
    !prefix.is_empty()
        && !suffix.is_empty()
        && prefix.len() <= 5
        && suffix.len() <= 4
        && prefix.bytes().all(|byte| byte.is_ascii_uppercase())
        && suffix.bytes().all(|byte| byte.is_ascii_digit())
}

fn observe_reason_code(reason: &str) -> Option<String> {
    let trimmed = reason.trim();
    if trimmed.is_empty() {
        return None;
    }
    if let Some(rule_id) = observe_extract_rule_ids(trimmed).first() {
        return Some(rule_id.clone());
    }
    let head = trimmed
        .split([':', '|', '\n'])
        .next()
        .unwrap_or(trimmed)
        .trim();
    if head.is_empty() {
        return None;
    }
    Some(head.chars().take(80).collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn aggregate_counts_attention_diagnostics_and_rule_ids() {
        let events = vec![
            json!({"ts":"2026-06-01T00:00:01Z","session":"s1","hook":"pre-bash-guard","decision":"pass","duration_ms":10,"client":"codex"}),
            json!({"ts":"2026-06-01T00:00:02Z","session":"s1","hook":"post-edit-guard","decision":"warn","reason":"U-16 file too large","duration_ms":30,"client":"codex"}),
            json!({"ts":"2026-06-01T00:00:03Z","session":"s2","hook":"post-build-check","status":"timeout","reason":"timeout","duration_ms":30000,"client":"claude"}),
        ];

        let aggregate = aggregate_events(&events, 2_000);

        assert_eq!(aggregate.event_count, 3);
        assert_eq!(aggregate.attention_count, 2);
        assert_eq!(aggregate.decision_counts.get("pass"), Some(&1));
        assert_eq!(aggregate.decision_counts.get("warn"), Some(&1));
        assert_eq!(aggregate.decision_counts.get("timeout"), Some(&1));
        assert_eq!(aggregate.rule_ids.get("U-16"), Some(&1));
        assert_eq!(aggregate.client_distribution.get("codex"), Some(&2));
    }

    #[test]
    fn slow_pass_diagnostic_does_not_set_model_context() {
        let event = json!({
            "ts":"2026-06-01T00:00:05Z",
            "session":"s1",
            "hook":"post-write-guard",
            "decision":"pass",
            "duration_ms":2500
        });

        let rendered = observe_event_json(&event, 2_000);

        assert_eq!(rendered[field::STATUS], status::SLOW);
        assert_eq!(rendered["diagnostic"], "slow");
        assert_eq!(rendered[field::MODEL_CONTEXT], false);
    }

    #[test]
    fn elapsed_only_slow_pass_counts_as_diagnostic() {
        let event = json!({
            "ts":"2026-06-01T00:00:06Z",
            "session":"s1",
            "hook":"codex-wrapper",
            "decision":"pass",
            "elapsed_ms":2500
        });
        let events = vec![event.clone()];

        let aggregate = aggregate_events(&events, 2_000);
        let rendered = observe_event_json(&event, 2_000);

        assert_eq!(aggregate.durations_ms, vec![2500]);
        assert_eq!(aggregate.attention_count, 1);
        assert_eq!(rendered[field::DURATION_MS], 2500);
        assert_eq!(rendered[field::STATUS], status::SLOW);
        assert_eq!(rendered["diagnostic"], "slow");
        assert_eq!(rendered[field::MODEL_CONTEXT], false);
    }

    #[test]
    fn diagnostic_status_wins_over_warn_decision_for_model_context() {
        let event = json!({
            "ts":"2026-06-01T00:00:08Z",
            "session":"s1",
            "hook":"post-build-check",
            "decision":"warn",
            "status":"timeout",
            "reason":"post-build-check timeout after 30s",
            "duration_ms":30000
        });

        let rendered = observe_event_json(&event, 2_000);

        assert_eq!(rendered[field::STATUS], status::TIMEOUT);
        assert_eq!(rendered["diagnostic"], "timeout");
        assert_eq!(rendered[field::MODEL_CONTEXT], false);
        assert!(!observe_is_attention_state(&event, 2_000));
        assert!(observe_is_diagnostic_event(&event, 2_000));
    }

    #[test]
    fn unknown_status_values_render_schema_safe_status() {
        let explicit_status = json!({
            "ts":"2026-06-01T00:00:06Z",
            "session":"s1",
            "hook":"post-build-check",
            "decision":"pass",
            "status":"healthy"
        });
        let unknown_decision = json!({
            "ts":"2026-06-01T00:00:07Z",
            "session":"s1",
            "hook":"pre-bash-guard",
            "decision":"allow"
        });

        assert_eq!(
            observe_event_json(&explicit_status, 2_000)[field::STATUS],
            status::UNKNOWN
        );
        assert_eq!(
            observe_event_json(&unknown_decision, 2_000)[field::STATUS],
            status::UNKNOWN
        );
    }

    #[test]
    fn suppressed_w14_is_counted_without_attention_or_warn_inflation() {
        let event = json!({
            "ts":"2026-06-01T00:00:09Z",
            "session":"s1",
            "hook":"post-edit-guard",
            "tool":"Edit",
            "decision":"pass",
            "status":"skipped",
            "reason":"[W-14] overlap suppressed cooldown",
            "detail":"src/main.rs||w14_key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        });

        let aggregate = aggregate_events(std::slice::from_ref(&event), 2_000);
        let rendered = observe_event_json(&event, 2_000);

        assert_eq!(aggregate.attention_count, 0);
        assert_eq!(aggregate.decision_counts.get("pass"), Some(&1));
        assert_eq!(aggregate.decision_counts.get("warn"), None);
        assert_eq!(aggregate.rule_ids.get("W-14"), Some(&1));
        assert_eq!(rendered[field::STATUS], status::SKIPPED);
        assert_eq!(rendered[field::MODEL_CONTEXT], false);
    }
}
