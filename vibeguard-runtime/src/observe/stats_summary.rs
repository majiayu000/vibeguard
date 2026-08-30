use serde_json::Value;
use std::collections::BTreeMap;

use crate::event_schema::{UNKNOWN, decision, field};

use super::Result;
use super::aggregate::{
    ObserveAggregate, observe_non_empty_or, observe_normalized_decision, observe_string_field,
};
use super::model::{ObserveOptions, TimeWindow};
use super::read::LogEvents;
use super::render::{
    observe_blank_as_unknown, observe_count_by, observe_decision_count, observe_increment,
    observe_sorted_counts, observe_truncate,
};
use super::rule_descriptions::RuleDescriptions;

pub(super) fn render_stats_summary(
    options: &ObserveOptions,
    log_events: &LogEvents,
    aggregate: &ObserveAggregate,
    rule_descriptions: &RuleDescriptions,
) -> Result<String> {
    if aggregate.event_count == 0 {
        if !log_events.source_exists {
            return Ok(format!(
                "No log data. Hooks will be automatically logged to {} after being triggered\n",
                log_events.log_path
            ));
        }
        return Ok(match options.window {
            TimeWindow::All => "No log data.\n".to_string(),
            TimeWindow::Days(days) => format!("No log data for the last {days} days.\n"),
            TimeWindow::Hours(hours) => format!("No log data for the last {hours} hours.\n"),
        });
    }

    let hook_counts = observe_count_by(&log_events.events, |event| {
        observe_non_empty_or(observe_string_field(event, field::HOOK), UNKNOWN)
    });
    let cli_counts = observe_count_by(&log_events.events, |event| {
        observe_non_empty_or(observe_string_field(event, field::CLI), UNKNOWN)
    });
    let block_reasons = stats_count_by_matching(&log_events.events, decision::BLOCK, |event| {
        observe_non_empty_or(rule_descriptions.human_reason(event), "Unknown")
    });
    let warn_reasons = stats_count_by_matching(&log_events.events, decision::WARN, |event| {
        observe_non_empty_or(rule_descriptions.human_reason(event), "Unknown")
    });

    let mut output = String::new();
    output.push_str(&format!(
        "\nVibeGuard Statistics ({})\n{}\n",
        options.window.label(),
        "=".repeat(40)
    ));
    output.push_str(&format!(
        "Time range: {} ~ {}\n",
        observe_blank_as_unknown(&aggregate.first_ts),
        observe_blank_as_unknown(&aggregate.last_ts)
    ));
    output.push_str(&format!(
        "Total triggers: {} times\n",
        aggregate.event_count
    ));
    let block_total = aggregate.block_counts.total_blocks;
    output.push_str(&format!("  Interception (block): {block_total} times\n"));
    output.push_str(&format!(
        "    non-protocol blocks: {} times\n",
        aggregate.block_counts.non_protocol_blocks
    ));
    output.push_str(&format!(
        "    protocol errors (malformed hook input, not rule hits): {} times\n",
        aggregate.block_counts.protocol_errors
    ));
    output.push_str(&format!(
        "  Warning: {} times\n",
        observe_decision_count(aggregate, decision::WARN)
    ));
    output.push_str(&format!(
        "  Pass (pass): {} times\n\n",
        observe_decision_count(aggregate, decision::PASS)
    ));

    output.push_str("Distributed by Hook:\n");
    for (hook, count) in observe_sorted_counts(&hook_counts) {
        output.push_str(&format!(" {hook}: {count} times\n"));
    }

    output.push_str("\nDistributed by CLI:\n");
    for (cli, count) in observe_sorted_counts(&cli_counts) {
        output.push_str(&format!(" {cli}: {count} times\n"));
    }

    if !block_reasons.is_empty() {
        output.push_str("\nInterception reasons Top 5:\n");
        for (reason, count) in observe_sorted_counts(&block_reasons).into_iter().take(5) {
            output.push_str(&format!("  {count}x  {}\n", observe_truncate(&reason, 180)));
        }
    }

    if !warn_reasons.is_empty() {
        output.push_str("\nWarning reasons Top 5:\n");
        for (reason, count) in observe_sorted_counts(&warn_reasons).into_iter().take(5) {
            output.push_str(&format!("  {count}x  {}\n", observe_truncate(&reason, 180)));
        }
    }

    append_daily_counts(&mut output, &log_events.events);
    append_file_type_distribution(&mut output, &log_events.events);
    append_time_distribution(&mut output, &log_events.events);
    append_performance_analysis(&mut output, &log_events.events);

    output.push('\n');
    Ok(output)
}

fn append_daily_counts(output: &mut String, events: &[Value]) {
    let day_counts = stats_count_by_day(events);
    if day_counts.len() <= 1 {
        return;
    }
    output.push_str("\nDaily trigger amount:\n");
    for (day, count) in day_counts
        .iter()
        .rev()
        .take(7)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
    {
        let bar = std::iter::repeat_n('\u{2588}', (*count).min(50) as usize).collect::<String>();
        output.push_str(&format!("  {day}  {bar} {count}\n"));
    }
}

fn append_file_type_distribution(output: &mut String, events: &[Value]) {
    let mut ext_counts = BTreeMap::new();
    for event in events {
        if let Some(ext) = stats_file_extension(&observe_string_field(event, field::DETAIL)) {
            observe_increment(&mut ext_counts, ext);
        }
    }
    if ext_counts.is_empty() {
        return;
    }

    output.push_str("\nDistributed by file type:\n");
    for (ext, count) in observe_sorted_counts(&ext_counts).into_iter().take(10) {
        output.push_str(&format!(" .{ext}: {count} times\n"));
    }
}

fn append_time_distribution(output: &mut String, events: &[Value]) {
    let mut work_hours = 0_u64;
    let mut off_hours = 0_u64;
    for event in events {
        let ts = observe_string_field(event, field::TS);
        let Some(hour) = ts.get(11..13).and_then(|value| value.parse::<u64>().ok()) else {
            continue;
        };
        if (9..18).contains(&hour) {
            work_hours += 1;
        } else {
            off_hours += 1;
        }
    }
    let total = work_hours + off_hours;
    if total == 0 {
        return;
    }

    output.push_str("\nDistributed by time period:\n");
    output.push_str(&format!(
        " working time (09-18): {work_hours} times ({}%)\n",
        work_hours * 100 / total
    ));
    output.push_str(&format!(
        " Non-working hours: {off_hours} times ({}%)\n",
        off_hours * 100 / total
    ));
}

fn append_performance_analysis(output: &mut String, events: &[Value]) {
    let mut sessions: BTreeMap<String, Vec<&Value>> = BTreeMap::new();
    for event in events {
        let session = observe_string_field(event, field::SESSION);
        if !session.is_empty() {
            sessions.entry(session).or_default().push(event);
        }
    }
    if sessions.is_empty() {
        return;
    }

    output.push_str("\n== Performance analysis ==\n");
    output.push_str(&format!("Total number of sessions: {}\n", sessions.len()));
    let trigger_count = sessions.values().map(Vec::len).sum::<usize>();
    let avg_triggers = trigger_count as f64 / sessions.len() as f64;
    output.push_str(&format!(
        "Average triggers per session: {avg_triggers:.1} times\n"
    ));

    let mut block_rate_sum = 0.0_f64;
    let mut warn_rate_sum = 0.0_f64;
    for events in sessions.values() {
        let total = events.len() as f64;
        block_rate_sum += stats_decision_ref_count(events, decision::BLOCK) as f64 / total * 100.0;
        warn_rate_sum += stats_decision_ref_count(events, decision::WARN) as f64 / total * 100.0;
    }
    output.push_str(&format!(
        "Average block rate per session: {:.1}%\n",
        block_rate_sum / sessions.len() as f64
    ));
    output.push_str(&format!(
        "Average warning rate per session: {:.1}%\n",
        warn_rate_sum / sessions.len() as f64
    ));

    append_problem_sessions(output, &sessions);
}

fn append_problem_sessions(output: &mut String, sessions: &BTreeMap<String, Vec<&Value>>) {
    let mut problem_sessions = sessions
        .iter()
        .map(|(session, events)| {
            (
                session,
                events,
                stats_decision_ref_count(events, decision::BLOCK)
                    + stats_decision_ref_count(events, decision::WARN),
            )
        })
        .collect::<Vec<_>>();
    problem_sessions.sort_by(|left, right| right.2.cmp(&left.2).then_with(|| left.0.cmp(right.0)));
    if !problem_sessions
        .iter()
        .take(3)
        .any(|(_, _, issues)| *issues > 0)
    {
        return;
    }

    output.push_str("\nConversations with the most questions Top 3:\n");
    for (session, events, issues) in problem_sessions.into_iter().take(3) {
        if issues == 0 {
            break;
        }
        let ts_start = events
            .first()
            .map(|event| stats_ts_prefix(event))
            .unwrap_or_else(|| "?".to_string());
        let ts_end = events
            .last()
            .map(|event| stats_ts_prefix(event))
            .unwrap_or_else(|| "?".to_string());
        output.push_str(&format!(
            " {session}: {issues} issues / {} triggers ({ts_start} ~ {ts_end})\n",
            events.len()
        ));
    }
}

fn stats_count_by_matching<F>(
    events: &[Value],
    decision_value: &str,
    mut mapper: F,
) -> BTreeMap<String, u64>
where
    F: FnMut(&Value) -> String,
{
    let mut counts = BTreeMap::new();
    for event in events {
        if observe_normalized_decision(event) == decision_value {
            observe_increment(&mut counts, mapper(event));
        }
    }
    counts
}

fn stats_count_by_day(events: &[Value]) -> BTreeMap<String, u64> {
    let mut counts = BTreeMap::new();
    for event in events {
        let ts = observe_string_field(event, field::TS);
        if ts.len() >= 10 {
            observe_increment(&mut counts, ts[..10].to_string());
        }
    }
    counts
}

fn stats_decision_ref_count(events: &[&Value], decision_value: &str) -> u64 {
    events
        .iter()
        .filter(|event| observe_normalized_decision(event) == decision_value)
        .count() as u64
}

fn stats_file_extension(detail: &str) -> Option<String> {
    for part in detail.split_whitespace() {
        let Some((_, ext)) = part.rsplit_once('.') else {
            continue;
        };
        let ext = ext.chars().take(5).collect::<String>();
        if !ext.is_empty() && ext.chars().all(|char| char.is_ascii_alphabetic()) {
            return Some(ext);
        }
    }
    None
}

fn stats_ts_prefix(event: &Value) -> String {
    let ts = observe_string_field(event, field::TS);
    if ts.is_empty() {
        "?".to_string()
    } else {
        ts.chars().take(16).collect()
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::super::aggregate::aggregate_events;
    use super::super::model::parse_observe_args;
    use super::*;

    fn args(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).to_string()).collect()
    }

    fn rule_descriptions() -> RuleDescriptions {
        match RuleDescriptions::load() {
            Ok(descriptions) => descriptions,
            Err(error) => panic!("rule descriptions should load: {error}"),
        }
    }

    #[test]
    fn stats_summary_includes_analysis_sections() {
        let events = vec![
            json!({
                "ts": "2026-06-05T10:00:00Z",
                "session": "session-a",
                "hook": "pre-bash-guard",
                "tool": "Bash",
                "decision": "warn",
                "reason": "non-standard markdown",
                "detail": "notes.md",
                "cli": "codex"
            }),
            json!({
                "ts": "2026-06-05T11:00:00Z",
                "session": "session-a",
                "hook": "pre-bash-guard",
                "tool": "Bash",
                "decision": "pass",
                "reason": "",
                "detail": "src/main.rs",
                "cli": "codex"
            }),
            json!({
                "ts": "2026-06-05T20:00:00Z",
                "session": "session-b",
                "hook": "post-edit-guard",
                "tool": "Edit",
                "decision": "block",
                "reason": "U-16 block",
                "detail": "src/lib.rs",
                "cli": "claude"
            }),
            json!({
                "ts": "2026-06-05T21:00:00Z",
                "session": "session-b",
                "hook": "post-edit-guard",
                "tool": "Edit",
                "decision": "warn",
                "reason": "needs review",
                "detail": "README.md",
                "cli": "claude"
            }),
        ];
        let options = match parse_observe_args(&args(&["summary", "--days", "all"])) {
            Ok(options) => options,
            Err(error) => panic!("stats summary options should parse: {error}"),
        };
        let log_events = LogEvents {
            events,
            log_path: "events.jsonl".to_string(),
            source_exists: true,
        };
        let aggregate = aggregate_events(&log_events.events, 2_000);

        let descriptions = rule_descriptions();
        let output = match render_stats_summary(&options, &log_events, &aggregate, &descriptions) {
            Ok(output) => output,
            Err(error) => panic!("stats summary should render: {error}"),
        };

        assert!(!output.contains("Warn compliance"));
        assert!(!output.contains("upgrade to block"));
        assert!(output.contains("Distributed by file type:"));
        assert!(output.contains(".rs: 2 times"));
        assert!(output.contains("Distributed by time period:"));
        assert!(output.contains("working time (09-18): 2 times (50%)"));
        assert!(output.contains("== Performance analysis =="));
        assert!(output.contains("Average triggers per session: 2.0 times"));
        assert!(!output.contains("estimated savings"));
        assert!(output.contains("session-b: 2 issues / 2 triggers"));
    }

    #[test]
    fn stats_summary_splits_protocol_error_blocks_from_rule_blocks() {
        let events = vec![
            json!({
                "ts": "2026-06-05T20:00:00Z",
                "session": "session-a",
                "hook": "pre-bash-guard",
                "tool": "Bash",
                "decision": "block",
                "reason": "invalid Bash hook input JSON; fail-closed",
                "detail": "empty hook stdin (0 bytes)",
                "cli": "claude"
            }),
            json!({
                "ts": "2026-06-05T20:01:00Z",
                "session": "session-a",
                "hook": "pre-write-guard",
                "tool": "Write",
                "decision": "block",
                "reason": "Malformed hook input",
                "detail": "invalid JSON (1 chars; EOF while parsing an object at line 1 column 1); head={",
                "cli": "claude"
            }),
            json!({
                "ts": "2026-06-05T20:02:00Z",
                "session": "session-a",
                "hook": "pre-write-guard",
                "tool": "Write",
                "decision": "block",
                "reason": "Malformed hook input",
                "detail": "existing file unreadable for U-16 baseline: /private/source.rs",
                "cli": "claude"
            }),
            json!({
                "ts": "2026-06-05T20:03:00Z",
                "session": "session-a",
                "hook": "post-edit-guard",
                "tool": "Edit",
                "decision": "block",
                "reason": "U-16 block",
                "detail": "src/lib.rs",
                "cli": "claude"
            }),
        ];
        let options = match parse_observe_args(&args(&["summary", "--days", "all"])) {
            Ok(options) => options,
            Err(error) => panic!("stats summary options should parse: {error}"),
        };
        let log_events = LogEvents {
            events,
            log_path: "events.jsonl".to_string(),
            source_exists: true,
        };
        let aggregate = aggregate_events(&log_events.events, 2_000);

        let descriptions = rule_descriptions();
        let output = match render_stats_summary(&options, &log_events, &aggregate, &descriptions) {
            Ok(output) => output,
            Err(error) => panic!("stats summary should render: {error}"),
        };

        assert!(output.contains("Interception (block): 4 times"));
        assert!(output.contains("non-protocol blocks: 2 times"));
        assert!(output.contains("protocol errors (malformed hook input, not rule hits): 2 times"));
    }
}
