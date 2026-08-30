use serde_json::{Value, json};
use std::collections::BTreeMap;

use crate::event_schema::{field, hook, status};
use crate::time_utils::parse_iso_ts;

use super::Result;
use super::aggregate::{
    ObserveAggregate, observe_effective_duration_ms, observe_is_attention_state,
    observe_normalized_status, observe_string_field,
};
use super::model::ObserveOptions;
use super::read::LogEvents;

const EVIDENCE_BOUNDARY: &str = "Evidence boundary: this view reports only associations observable in the local event stream. It does not claim incidents prevented, causal recovery, token savings, time savings, money savings, or compliance.";
const ESTIMATED_UNAVAILABLE_REASON: &str = "The local event stream has no causal, incident, token, time, or money outcome evidence for estimates.";
const VERIFIED_DEFINITION: &str = "A strictly later ordinary pass from post-build-check in the same non-empty session after attention; this is an association, not proof VibeGuard caused the result.";
const ASSOCIATION_LIMITATION: &str = "Later passes and build checks are associations in the event stream, not proof VibeGuard caused the result.";

#[derive(Default)]
struct ValueEvidence {
    attention_events: u64,
    attention_sessions: BTreeMap<String, AttentionSession>,
    uncorrelatable_attention_events: u64,
    suppression_events: u64,
    durations_ms: Vec<u64>,
}

#[derive(Default)]
struct AttentionSession {
    attention_count: u64,
    attention_timestamps: Vec<u64>,
    later_follow_up_pass: bool,
    later_build_pass: bool,
}

struct OrdinaryPass {
    timestamp: u64,
    is_build_check: bool,
}

impl ValueEvidence {
    fn from_events(events: &[Value], slow_ms: u64) -> Self {
        let mut evidence = Self::default();
        let mut ordinary_passes: BTreeMap<String, Vec<OrdinaryPass>> = BTreeMap::new();

        for event in events {
            if let Some(duration_ms) = observe_effective_duration_ms(event) {
                evidence.durations_ms.push(duration_ms);
            }

            let normalized_status = observe_normalized_status(event, slow_ms);
            let reason = observe_string_field(event, field::REASON);
            if normalized_status == status::SKIPPED
                && reason.to_ascii_lowercase().contains("suppressed")
            {
                evidence.suppression_events += 1;
            }

            let session = observe_string_field(event, field::SESSION);
            if observe_is_attention_state(event, slow_ms) {
                evidence.attention_events += 1;
                let timestamp = parse_iso_ts(&observe_string_field(event, field::TS));
                if session.is_empty() || timestamp.is_none() {
                    evidence.uncorrelatable_attention_events += 1;
                }

                if !session.is_empty() {
                    let attention_session = evidence
                        .attention_sessions
                        .entry(session.clone())
                        .or_default();
                    attention_session.attention_count += 1;
                    if let Some(timestamp) = timestamp {
                        attention_session.attention_timestamps.push(timestamp);
                    }
                }
            }

            if !is_ordinary_pass(event, slow_ms) || session.is_empty() {
                continue;
            }
            let Some(timestamp) = parse_iso_ts(&observe_string_field(event, field::TS)) else {
                continue;
            };
            ordinary_passes
                .entry(session)
                .or_default()
                .push(OrdinaryPass {
                    timestamp,
                    is_build_check: observe_string_field(event, field::HOOK)
                        == hook::POST_BUILD_CHECK,
                });
        }

        for (session, attention_session) in &mut evidence.attention_sessions {
            let Some(passes) = ordinary_passes.get(session) else {
                continue;
            };
            attention_session.later_follow_up_pass = passes.iter().any(|pass| {
                attention_session
                    .attention_timestamps
                    .iter()
                    .any(|attention_timestamp| pass.timestamp > *attention_timestamp)
            });
            attention_session.later_build_pass = passes.iter().any(|pass| {
                pass.is_build_check
                    && attention_session
                        .attention_timestamps
                        .iter()
                        .any(|attention_timestamp| pass.timestamp > *attention_timestamp)
            });
        }

        evidence.durations_ms.sort_unstable();
        evidence
    }

    fn sessions_with_later_follow_up_pass(&self) -> u64 {
        self.attention_sessions
            .values()
            .filter(|session| session.later_follow_up_pass)
            .count() as u64
    }

    fn sessions_without_later_follow_up_pass(&self) -> u64 {
        self.attention_sessions
            .values()
            .filter(|session| !session.later_follow_up_pass)
            .count() as u64
    }

    fn sessions_with_repeated_attention(&self) -> u64 {
        self.attention_sessions
            .values()
            .filter(|session| session.attention_count >= 2)
            .count() as u64
    }

    fn sessions_with_later_build_pass(&self) -> u64 {
        self.attention_sessions
            .values()
            .filter(|session| session.later_build_pass)
            .count() as u64
    }

    fn duration_json(&self) -> Value {
        let count = self.durations_ms.len() as u64;
        if count == 0 {
            return json!({
                "count": 0,
                "total_ms": 0,
                "avg_ms": 0,
                "p95_ms": null,
            });
        }

        let total_ms = self
            .durations_ms
            .iter()
            .copied()
            .fold(0_u64, u64::saturating_add);
        let p95_index = ((self.durations_ms.len() * 95).div_ceil(100)).saturating_sub(1);
        json!({
            "count": count,
            "total_ms": total_ms,
            "avg_ms": total_ms / count,
            "p95_ms": self.durations_ms.get(p95_index).copied(),
        })
    }

    fn to_json(&self, data_state: &str, read_limitation: &str) -> Value {
        json!({
            "data_state": data_state,
            "verified": {
                "sessions_with_later_build_pass": self.sessions_with_later_build_pass(),
                "definition": VERIFIED_DEFINITION,
            },
            "observed": {
                "attention_events": self.attention_events,
                "sessions_with_attention": self.attention_sessions.len(),
                "sessions_with_later_follow_up_pass": self.sessions_with_later_follow_up_pass(),
                "sessions_without_later_follow_up_pass": self.sessions_without_later_follow_up_pass(),
                "sessions_with_repeated_attention": self.sessions_with_repeated_attention(),
                "uncorrelatable_attention_events": self.uncorrelatable_attention_events,
                "suppression_events": self.suppression_events,
                "hook_duration_ms": self.duration_json(),
            },
            "estimated": {
                "available": false,
                "reason": ESTIMATED_UNAVAILABLE_REASON,
            },
            "limitations": [ASSOCIATION_LIMITATION, read_limitation],
        })
    }
}

fn read_limitation(limit: usize) -> String {
    if limit == usize::MAX {
        return "Because --limit all was explicitly requested, counts consider all parsed events from the selected scope, then apply the selected time window; events outside it are not considered. Events with missing or unparseable timestamps are retained as uncorrelatable because their time position cannot be established.".to_string();
    }
    format!(
        "Counts consider at most the configured {limit} most-recent parsed events from the selected scope, then apply the selected time window; earlier parsed events and events outside it are not considered. Events with missing or unparseable timestamps are retained as uncorrelatable because their time position cannot be established."
    )
}

fn is_ordinary_pass(event: &Value, slow_ms: u64) -> bool {
    if observe_normalized_status(event, slow_ms) != status::PASS {
        return false;
    }
    let reason = observe_string_field(event, field::REASON).to_ascii_lowercase();
    !reason.starts_with("skip:") && !reason.starts_with("skipped:")
}

pub(super) fn render(
    options: &ObserveOptions,
    log_events: &LogEvents,
    aggregate: &ObserveAggregate,
) -> Result<String> {
    let evidence = ValueEvidence::from_events(&log_events.events, options.slow_ms);
    let data_state = if !log_events.source_exists {
        "missing"
    } else if log_events.events.is_empty() {
        "empty"
    } else {
        "observed"
    };
    let read_limitation = read_limitation(options.limit);

    if options.json {
        let mut output = super::render::observe_summary_json(options, log_events, aggregate);
        output["value"] = evidence.to_json(data_state, &read_limitation);
        return Ok(format!("{}\n", serde_json::to_string_pretty(&output)?));
    }

    Ok(render_human(
        options,
        log_events,
        &evidence,
        data_state,
        &read_limitation,
    ))
}

fn render_human(
    options: &ObserveOptions,
    log_events: &LogEvents,
    evidence: &ValueEvidence,
    data_state: &str,
    read_limitation: &str,
) -> String {
    let mut output = String::new();
    output.push_str(EVIDENCE_BOUNDARY);
    output.push('\n');
    output.push_str(&format!(
        "VibeGuard Observe Value ({})\n",
        options.window.label()
    ));
    output.push_str(&format!("Data state: {data_state}\n"));
    match data_state {
        "missing" => output.push_str(&format!(
            "No event log exists at {}.\n",
            log_events.log_path
        )),
        "empty" => output.push_str(&format!(
            "No events were found in the selected window ({}) at {}.\n",
            options.window.label(),
            log_events.log_path
        )),
        "observed" => output.push_str(&format!(
            "Events in selected window: {}\n",
            log_events.events.len()
        )),
        _ => output.push_str("Data state is unavailable.\n"),
    }

    output.push_str("\nVerified\n");
    output.push_str(&format!(
        "  sessions_with_later_build_pass: {}\n",
        evidence.sessions_with_later_build_pass()
    ));
    output.push_str(&format!("  definition: {VERIFIED_DEFINITION}\n"));

    output.push_str("\nObserved\n");
    output.push_str(&format!(
        "  attention_events: {}\n",
        evidence.attention_events
    ));
    output.push_str(&format!(
        "  sessions_with_attention: {}\n",
        evidence.attention_sessions.len()
    ));
    output.push_str(&format!(
        "  sessions_with_later_follow_up_pass: {}\n",
        evidence.sessions_with_later_follow_up_pass()
    ));
    output.push_str(&format!(
        "  sessions_without_later_follow_up_pass: {}\n",
        evidence.sessions_without_later_follow_up_pass()
    ));
    output.push_str(&format!(
        "  sessions_with_repeated_attention: {}\n",
        evidence.sessions_with_repeated_attention()
    ));
    output.push_str(&format!(
        "  uncorrelatable_attention_events: {}\n",
        evidence.uncorrelatable_attention_events
    ));
    output.push_str(&format!(
        "  suppression_events: {}\n",
        evidence.suppression_events
    ));
    output.push_str(&format!(
        "  hook_duration_ms: {}\n",
        duration_human(&evidence.duration_json())
    ));

    output.push_str("\nEstimated/unavailable\n");
    output.push_str("  available: false\n");
    output.push_str(&format!("  reason: {ESTIMATED_UNAVAILABLE_REASON}\n"));

    output.push_str("\nLimitations\n");
    output.push_str(&format!("  {ASSOCIATION_LIMITATION}\n"));
    output.push_str(&format!("  {read_limitation}\n"));
    output
}

fn duration_human(duration: &Value) -> String {
    format!(
        "count={} total_ms={} avg_ms={} p95_ms={}",
        duration["count"], duration["total_ms"], duration["avg_ms"], duration["p95_ms"]
    )
}
